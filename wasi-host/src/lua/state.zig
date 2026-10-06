const std = @import("std");
const lua = @import("api.zig");
const events = @import("events.zig");
const host_functions = @import("host_functions.zig").HostFunctions;

/// Error codes for Lua operations
pub const LuaError = error{
    ScriptCompilationError,
    ScriptExecutionError,
    MemoryLimitExceeded,
    ExecutionTimeout,
    CallStackOverflow,
    AccessDenied,
    InvalidParameter,
    NotInitialized,
    NoConnection,
};

/// Embedded Lua script for runtime configuration
pub const EmbeddedLuaScript = struct {
    name: []const u8,
    content: []const u8,
};

pub const LuaStateManager = struct {
    global_state: *lua.Lua,
    connection_states: std.AutoHashMap(u64, struct { lua.LuaState, u64, u64 }), // state, created_at, last_activity
    event_queue: events.EventQueue,
    allocator: std.mem.Allocator,
    callbacks: std.StringHashMap(lua.LuaState),
    // 32 位原子计数器（32 位目标不支持 64 位原子操作），使用处拓宽为 u64 句柄
    next_plugin_handle: std.atomic.Value(u32),
    connection_plugins: std.AutoHashMap(u64, std.ArrayList(u64)), // connection_id -> list of plugin_handles

    // Error handling
    error_callback: ?*const fn (message: []const u8, source: ?[]const u8, line: i32) void,
    error_stack_depth: u32,
    execution_timeout_ns: u64,
    max_call_depth: u32,

    // Memory management
    mem_limit_kb: u64,
    max_mem_usage_kb: u64,
    track_mem_usage: bool,
    mem_tracker: ?lua.MemTracker,

    // Sandbox configuration
    sandbox_config: lua.SandboxConfig,
    sandboxed_connections: std.AutoHashMap(u64, bool),

    pub fn init(allocator: std.mem.Allocator) !LuaStateManager {
        // 创建全局 Lua 状态并打开标准库
        const gstate = lua.luaL_newstate() orelse return error.OutOfMemory;
        lua.luaL_openlibs(gstate);

        const sandbox_config = lua.SandboxConfig.init(allocator);

        const manager = LuaStateManager{
            .global_state = gstate,
            .connection_states = std.AutoHashMap(u64, struct { lua.LuaState, u64, u64 }).init(allocator),
            .connection_plugins = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
            .event_queue = events.EventQueue.init(allocator),
            .allocator = allocator,
            .callbacks = std.StringHashMap(lua.LuaState).init(allocator),
            .next_plugin_handle = std.atomic.Value(u32).init(1),
            .error_callback = null,
            .error_stack_depth = 100,
            .execution_timeout_ns = 30 * std.time.ns_per_s,
            .max_call_depth = 100,
            .mem_limit_kb = 512,
            .max_mem_usage_kb = 0,
            .track_mem_usage = true,
            .mem_tracker = null,
            .sandbox_config = sandbox_config,
            .sandboxed_connections = std.AutoHashMap(u64, bool).init(allocator),
        };

        return manager;
    }

    /// Load and execute a Lua script from a file
    pub fn loadScript(self: *LuaStateManager, script_path: []const u8) !void {
        const logger = std.log.scoped(.wasi_lua);

        const file = std.fs.cwd().openFile(script_path, .{}) catch |err| {
            logger.err("Failed to open Lua script {s}: {s}", .{ script_path, @errorName(err) });
            return err;
        };
        defer file.close();

        const script_content = try file.readToEndAlloc(self.allocator, 64 * 1024); // 64KB max script size
        defer self.allocator.free(script_content);

        logger.info("Executing Lua script: {s}", .{script_path});

        // Compile the script using luaL_loadbuffer
        const status = lua.luaL_loadbuffer(self.global_state, script_content.ptr, script_content.len, "script");
        if (status != lua.Status.ok) {
            logger.err("Failed to compile Lua script: {d}", .{@intFromEnum(status)});
            return error.ScriptCompilationError;
        }

        // Execute the script
        const exec_status = lua.lua_pcall(self.global_state, 0, 0, 0);
        if (exec_status != lua.Status.ok) {
            const error_msg = lua.lua_tostring(self.global_state, -1);
            if (error_msg) |msg| {
                logger.err("Lua script execution error: {s}", .{std.mem.sliceTo(msg, 0)});
            }
            lua.lua_pop(self.global_state, 1);
            return error.ScriptExecutionError;
        }

        logger.info("Lua script executed successfully: {s}", .{script_path});
    }

    /// Load and execute an embedded Lua script
    pub fn loadEmbeddedScript(self: *LuaStateManager, script: EmbeddedLuaScript) !void {
        const logger = std.log.scoped(.wasi_lua);

        logger.info("Executing embedded Lua script: {s}", .{script.name});

        // Compile the script using luaL_loadbuffer
        const status = lua.luaL_loadbuffer(self.global_state, script.content.ptr, script.content.len, script.name);
        if (status != lua.Lua.Status.ok) {
            logger.err("Failed to compile embedded Lua script {}: {d}", .{ script.name, @intFromEnum(status) });
            return error.ScriptCompilationError;
        }

        // Execute the script
        const exec_status = lua.lua_pcall(self.global_state, 0, 0, 0);
        if (exec_status != lua.Lua.Status.ok) {
            const error_msg = lua.lua_tostring(self.global_state, -1);
            if (error_msg) |msg| {
                logger.err("Embedded Lua script execution error: {s}", .{std.mem.sliceTo(msg, 0)});
            }
            lua.lua_pop(self.global_state, 1);
            return error.ScriptExecutionError;
        }

        logger.info("Embedded Lua script executed successfully: {s}", .{script.name});
    }

    pub fn deinit(self: *LuaStateManager) void {
        lua.lua_close(self.global_state);
        var it = self.connection_states.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr[0].state) |s| {
                lua.lua_close(s);
            }
            entry.value_ptr[1] = 0;
            entry.value_ptr[2] = 0;
        }
        self.connection_states.deinit();

        // Deinit plugin lists
        var plugin_it = self.connection_plugins.iterator();
        while (plugin_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.connection_plugins.deinit();

        self.event_queue.deinit();
        var callback_it = self.callbacks.iterator();
        while (callback_it.next()) |_| {
            // Allocator does not need explicit deinit
        }
        self.callbacks.deinit();

        // SandboxConfig doesn't need explicit deinit
        var sandboxed_it = self.sandboxed_connections.iterator();
        while (sandboxed_it.next()) |entry| {
            _ = entry;
        }
        self.sandboxed_connections.deinit();

        if (self.mem_tracker) |_| {
            // MemTracker doesn't need explicit deinit
        }
    }

    pub fn setErrorCallback(self: *LuaStateManager, callback: lua.ErrorCallback) void {
        self._error_callback = callback;
    }

    pub fn setSandboxConfig(self: *LuaStateManager, config: lua.SandboxConfig) void {
        self._sandbox_config = config;
    }

    pub fn getGlobalState(self: *LuaStateManager) *lua.Lua {
        return self.global_state;
    }

    pub fn getConnectionState(self: *LuaStateManager, connection_id: u64) !*lua.LuaState {
        if (self.connection_states.get(connection_id)) |entry| {
            // Update last activity timestamp
            entry.value.last_activity = std.time.nanoTime();
            return &entry.value.state;
        } else {
            const new_state = try lua.LuaState.init();
            // Register host functions to new connection state
            host_functions.register(new_state.state);
            const now = std.time.nanoTimestamp();
            try self.connection_states.put(connection_id, .{ new_state, now, now });
            return &new_state;
        }
    }

    pub fn removeConnectionState(self: *LuaStateManager, connection_id: u64) void {
        if (self.connection_states.fetchRemove(connection_id)) |entry| {
            if (entry.value[0].state) |s| lua.lua_close(s);
        }
        // Remove plugin list for this connection
        if (self.connection_plugins.fetchRemove(connection_id)) |entry| {
            entry.value.deinit();
        }
    }

    pub fn cleanupExpiredStates(self: *LuaStateManager) void {
        const logger = std.log.scoped(.wasi_lua);
        const now = std.time.nanoTimestamp();
        const timeout_ns: u64 = 30 * std.time.ns_per_sec; // 30 second timeout
        var to_remove: std.ArrayList(u64) = std.ArrayList(u64).init(self.allocator);

        var it = self.connection_states.iterator();
        while (it.next()) |entry| {
            const age = now - entry.value.last_activity;
            if (age > timeout_ns) {
                try to_remove.append(entry.key_ptr.*);
                logger.debug("Expire connection state: {d} (age={d}ms)", .{ entry.key_ptr.*, age / std.time.ns_per_ms });
            }
        }

        // Remove expired states
        for (to_remove.items) |conn_id| {
            self.removeConnectionState(conn_id);
        }
        to_remove.deinit();
    }

    pub fn postEvent(self: *LuaStateManager, payload: events.EventPayload) !void {
        try self.event_queue.post(payload);
    }

    /// Register a callback for a specific event type
    pub fn registerCallback(self: *LuaStateManager, event_type: []const u8, callback_state: lua.LuaState) !void {
        const key = try self.allocator.dupe(u8, event_type);
        try self.callbacks.put(key, callback_state);
    }

    /// Unregister a callback for a specific event type
    pub fn unregisterCallback(self: *LuaStateManager, event_type: []const u8) void {
        if (self.callbacks.fetchRemove(event_type)) |entry| {
            entry.value.deinit();
            if (self.callbacks.get(event_type) == null) {
                self.allocator.free(entry.key);
            }
        }
    }

    /// Default event handler that logs events to console
    fn defaultEventHandler(_: *LuaStateManager, payload: events.EventPayload) void {
        const logger = std.log.scoped(.wasi_lua);

        switch (payload) {
            .plugin_start => |e| logger.debug("Lua event: plugin_start handle={} name={s}", .{ e.plugin_handle, e.plugin_name }),
            .plugin_stop => |e| logger.debug("Lua event: plugin_stop handle={} exit_code={}", .{ e.plugin_handle, e.exit_code }),
            .plugin_error => |e| logger.err("Lua event: plugin_error handle={} code={} msg={s}", .{ e.plugin_handle, e.error_code, e.error_message }),
            .plugin_complete => |e| logger.debug("Lua event: plugin_complete handle={} exit_code={} duration_ms={}", .{ e.plugin_handle, e.exit_code, e.duration_ms }),
            .plugin_timeout => |e| logger.warn("Lua event: plugin_timeout handle={} timeout_ms={}", .{ e.plugin_handle, e.timeout_ms }),
            .chord_node_join => |e| logger.debug("Lua event: chord_node_join node_id={s} host={s} port={}", .{ e.node_id, e.host, e.port }),
            .chord_successor_change => |e| logger.debug("Lua event: chord_successor_change old={s} new={s}", .{ e.old_successor_id, e.new_successor_id }),
            .dht_put => |e| logger.debug("Lua event: dht_put key={s} size={}", .{ e.key, e.value_size }),
        }
    }

    /// Encode event payload to Lua table with key-value pairs
    fn encodePayloadToTable(self: *LuaStateManager, payload: events.EventPayload) ?void {
        const logger = std.log.scoped(.wasi_lua);

        // Create Lua table
        _ = lua.lua_createtable(self.global_state, 0, 0);

        // Add event_type field
        const event_type_str = @tagName(payload);
        lua.lua_pushlstring(self.global_state, event_type_str.ptr, event_type_str.len);
        lua.lua_setfield(self.global_state, -2, "event_type");

        // Add event-specific fields
        switch (payload) {
            .plugin_start => |e| {
                lua.lua_pushnumber(self.global_state, @floatFromInt(e.plugin_handle));
                lua.lua_setfield(self.global_state, -2, "plugin_handle");

                lua.lua_pushlstring(self.global_state, e.plugin_name.ptr, e.plugin_name.len);
                lua.lua_setfield(self.global_state, -2, "plugin_name");

                if (e.connection_id) |cid| {
                    lua.lua_pushnumber(self.global_state, @floatFromInt(cid));
                    lua.lua_setfield(self.global_state, -2, "connection_id");
                }
            },
            .plugin_stop => |e| {
                lua.lua_pushnumber(self.global_state, @floatFromInt(e.plugin_handle));
                lua.lua_setfield(self.global_state, -2, "plugin_handle");

                lua.lua_pushnumber(self.global_state, @floatFromInt(e.exit_code));
                lua.lua_setfield(self.global_state, -2, "exit_code");
            },
            .plugin_error => |e| {
                lua.lua_pushnumber(self.global_state, @floatFromInt(e.plugin_handle));
                lua.lua_setfield(self.global_state, -2, "plugin_handle");

                lua.lua_pushnumber(self.global_state, @floatFromInt(e.error_code));
                lua.lua_setfield(self.global_state, -2, "error_code");

                lua.lua_pushlstring(self.global_state, e.error_message.ptr, e.error_message.len);
                lua.lua_setfield(self.global_state, -2, "error_message");
            },
            .plugin_complete => |e| {
                lua.lua_pushnumber(self.global_state, @floatFromInt(e.plugin_handle));
                lua.lua_setfield(self.global_state, -2, "plugin_handle");

                lua.lua_pushnumber(self.global_state, @floatFromInt(e.exit_code));
                lua.lua_setfield(self.global_state, -2, "exit_code");

                lua.lua_pushnumber(self.global_state, @floatFromInt(e.duration_ms));
                lua.lua_setfield(self.global_state, -2, "duration_ms");
            },
            .plugin_timeout => |e| {
                lua.lua_pushnumber(self.global_state, @floatFromInt(e.plugin_handle));
                lua.lua_setfield(self.global_state, -2, "plugin_handle");

                lua.lua_pushnumber(self.global_state, @floatFromInt(e.timeout_ms));
                lua.lua_setfield(self.global_state, -2, "timeout_ms");
            },
            .chord_node_join => |e| {
                lua.lua_pushlstring(self.global_state, &e.node_id, e.node_id.len);
                lua.lua_setfield(self.global_state, -2, "node_id");

                lua.lua_pushlstring(self.global_state, e.host.ptr, e.host.len);
                lua.lua_setfield(self.global_state, -2, "host");

                lua.lua_pushnumber(self.global_state, @floatFromInt(e.port));
                lua.lua_setfield(self.global_state, -2, "port");
            },
            .chord_successor_change => |e| {
                lua.lua_pushlstring(self.global_state, &e.old_successor_id, e.old_successor_id.len);
                lua.lua_setfield(self.global_state, -2, "old_successor_id");

                lua.lua_pushlstring(self.global_state, &e.new_successor_id, e.new_successor_id.len);
                lua.lua_setfield(self.global_state, -2, "new_successor_id");
            },
            .dht_put => |e| {
                lua.lua_pushlstring(self.global_state, e.key.ptr, e.key.len);
                lua.lua_setfield(self.global_state, -2, "key");

                lua.lua_pushnumber(self.global_state, @floatFromInt(e.value_size));
                lua.lua_setfield(self.global_state, -2, "value_size");
            },
        }

        logger.debug("Encoded Lua event table", .{});
    }

    /// Invoke Lua callback with error handling
    fn invokeCallback(_: *LuaStateManager, callback_state: lua.LuaState, payload_table_idx: c_int) !void {
        const logger = std.log.scoped(.wasi_lua);

        // Get the callback function from the registry
        lua.lua_pushvalue(callback_state.state, payload_table_idx); // Copy payload table to top

        // Call the callback function with the payload table
        const status = lua.lua_pcall(callback_state.state, 1, 0, 0);
        if (status != lua.Status.ok) {
            // Callback failed - get error message and log it
            const error_msg = lua.lua_tostring(callback_state.state, -1);
            if (error_msg) |msg| {
                logger.err("Lua callback error: {s}", .{std.mem.sliceTo(msg, 0)});
            }
            // Remove error message from stack
            lua.lua_pop(callback_state.state, 1);
        }
    }

    pub fn processEvents(self: *LuaStateManager, time_budget_ms: u32) void {
        const start = std.time.nanoTimestamp();
        const budget_ns = time_budget_ms * std.time.ns_per_ms;
        var events_processed: usize = 0;

        while (true) {
            if (self.event_queue.consume()) |payload| {
                const event_type_name = @tagName(payload);
                var handled = false;

                // 路径 1：LuaStateManager.callbacks（p2p 内部注册）
                if (self.callbacks.get(event_type_name)) |callback_state| {
                    const result = self.encodePayloadToTable(payload);
                    if (result != null) {
                        // Payload table is on top of the stack
                        self.invokeCallback(callback_state, lua.lua_gettop(callback_state.state)) catch {};
                        // Pop the payload table from stack
                        lua.lua_pop(callback_state.state, 1);
                        handled = true;
                    }
                }

                // 路径 2：经 Lua wasm_on_event 注册的 registry ref
                if (!handled) {
                    if (host_functions.lookupEventRef(event_type_name)) |ref| {
                        const result = self.encodePayloadToTable(payload);
                        if (result != null) {
                            // 栈: [payload table]
                            lua.lua_rawgeti(self.global_state, lua.LuaRegistryIndex, ref); // [table, fn]
                            lua.lua_pushvalue(self.global_state, -2); // [table, fn, table]
                            const status = lua.lua_pcall(self.global_state, 1, 0, 0);
                            if (status != lua.Status.ok) {
                                const error_msg = lua.lua_tostring(self.global_state, -1);
                                if (error_msg) |msg| {
                                    std.log.err("Lua callback error: {s}", .{std.mem.sliceTo(msg, 0)});
                                }
                                lua.lua_pop(self.global_state, 1);
                            }
                            lua.lua_pop(self.global_state, 1); // pop payload table
                            handled = true;
                        }
                    }
                }

                if (!handled) {
                    // No callback registered, use default logging handler
                    self.defaultEventHandler(payload);
                }

                self.event_queue.freePayload(payload);
                events_processed += 1;

                // Check time budget
                if (std.time.nanoTimestamp() - start > budget_ns) {
                    break;
                }
            } else {
                break; // Queue empty
            }
        }

        // Trigger GC if few events were processed (idle period)
        if (events_processed == 0 and self.event_queue.isEmpty()) {
            self.triggerGC();
        }
    }

    pub fn triggerGC(self: *LuaStateManager) void {
        // Trigger garbage collection on global state
        _ = lua.lua_gc(self.global_state, @intFromEnum(lua.GC.COLLECT), 0);

        // Trigger GC on all connection states
        var it = self.connection_states.iterator();
        while (it.next()) |entry| {
            _ = lua.lua_gc(entry.value_ptr.@"0".state, @intFromEnum(lua.GC.COLLECT), 0);
        }
    }

    pub fn generatePluginHandle(self: *LuaStateManager, connection_id: ?u64) !u64 {
        const handle: u64 = @intCast(self.next_plugin_handle.fetchAdd(1, .monotonic));

        if (connection_id) |cid| {
            // 按 connection_id 归类插件句柄（ArrayList 按值存入 HashMap）
            const entry = try self.connection_plugins.getOrPut(cid);
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList(u64).init(self.allocator);
            }
            try entry.value_ptr.append(handle);
        }

        return handle;
    }

    /// Get all plugin handles for a connection
    pub fn getPluginsForConnection(self: *LuaStateManager, connection_id: u64) !std.ArrayList(u64) {
        const logger = std.log.scoped(.wasi_lua);
        if (self.connection_plugins.get(connection_id)) |plugins| {
            // Return a copy of the plugin list
            const copy = std.ArrayList(u64).init(self.allocator);
            try copy.appendSlice(plugins.items);
            return copy;
        } else {
            logger.debug("No plugins found for connection {d}", .{connection_id});
            const empty = std.ArrayList(u64).init(self.allocator);
            return empty;
        }
    }
};
