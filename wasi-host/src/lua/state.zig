const std = @import("std");
const lua = @import("api.zig");
const events = @import("events.zig");
const host_functions = @import("host_functions.zig").HostFunctions;

/// Embedded Lua script for runtime configuration
pub const EmbeddedLuaScript = struct {
    name: []const u8,
    content: []const u8,
};

pub const LuaStateManager = struct {
    global_state: lua.LuaState,
    connection_states: std.AutoHashMap(u64, struct { lua.LuaState, u64, u64 }), // state, created_at, last_activity
    event_queue: events.EventQueue,
    allocator: std.mem.Allocator,
    callbacks: std.StringHashMap(lua.LuaState),
    next_plugin_handle: std.atomic.Value(u64),
    connection_plugins: std.AutoHashMap(u64, std.ArrayList(u64)), // connection_id -> list of plugin_handles

    pub fn init(allocator: std.mem.Allocator) !LuaStateManager {
        const global_state = try lua.LuaState.init();
        const manager = LuaStateManager{
            .global_state = global_state,
            .connection_states = std.AutoHashMap(u64, lua.LuaState).init(allocator),
            .connection_plugins = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
            .event_queue = events.EventQueue.init(allocator),
            .allocator = allocator,
            .callbacks = std.StringHashMap(lua.LuaState).init(allocator),
            .next_plugin_handle = std.atomic.Value(u64).init(1),
        };
        // Register host functions to global state
        host_functions.register(&manager.global_state);
        return manager;
    }

    /// Load and execute a Lua script from a file
    pub fn loadScript(self: *LuaStateManager, script_path: []const u8) !void {
        const logger = std.log.scoped(.wasi_lua);

        const file = std.fs.cwd().openFile(script_path, .{}) catch |err| {
            logger.err("Failed to open Lua script {}: {}", .{ script_path, err });
            return err;
        };
        defer file.close();

        const script_content = try file.readToEndAlloc(self.allocator, 64 * 1024); // 64KB max script size
        defer self.allocator.free(script_content);

        logger.info("Executing Lua script: {}", .{script_path});

        // Push the script to Lua stack
        lua.lua_pushstring(self.global_state.state, script_content);

        // Compile the script
        const status = lua.lua_load(self.global_state.state, script_content.ptr, script_content.len, "script", null);
        if (status != lua.Lua.Status.ok) {
            logger.err("Failed to compile Lua script: {}", .{status});
            return error.ScriptCompilationError;
        }

        // Execute the script
        const exec_status = lua.lua_pcall(self.global_state.state, 0, 0, 0);
        if (exec_status != lua.Lua.Status.ok) {
            const error_msg = lua.lua_tostring(self.global_state.state, -1);
            if (error_msg) |msg| {
                logger.err("Lua script execution error: {}", .{msg});
            }
            lua.lua_pop(self.global_state.state, 1);
            return error.ScriptExecutionError;
        }

        logger.info("Lua script executed successfully: {}", .{script_path});
    }

    /// Load and execute an embedded Lua script
    pub fn loadEmbeddedScript(self: *LuaStateManager, script: EmbeddedLuaScript) !void {
        const logger = std.log.scoped(.wasi_lua);

        logger.info("Executing embedded Lua script: {}", .{script.name});

        // Push the script content to Lua stack
        lua.lua_pushstring(self.global_state.state, script.content);

        // Compile the script
        const status = lua.lua_load(self.global_state.state, script.content.ptr, script.content.len, script.name, null);
        if (status != lua.Lua.Status.ok) {
            logger.err("Failed to compile embedded Lua script {}: {}", .{ script.name, status });
            return error.ScriptCompilationError;
        }

        // Execute the script
        const exec_status = lua.lua_pcall(self.global_state.state, 0, 0, 0);
        if (exec_status != lua.Lua.Status.ok) {
            const error_msg = lua.lua_tostring(self.global_state.state, -1);
            if (error_msg) |msg| {
                logger.err("Embedded Lua script execution error: {}", .{msg});
            }
            lua.lua_pop(self.global_state.state, 1);
            return error.ScriptExecutionError;
        }

        logger.info("Embedded Lua script executed successfully: {}", .{script.name});
    }

    pub fn deinit(self: *LuaStateManager) void {
        self.global_state.deinit();
        var it = self.connection_states.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
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
        while (callback_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.callbacks.deinit();
    }

    pub fn getGlobalState(self: *LuaStateManager) *lua.LuaState {
        return &self.global_state;
    }

    pub fn getConnectionState(self: *LuaStateManager, connection_id: u64) !*lua.LuaState {
        if (self.connection_states.get(connection_id)) |entry| {
            // Update last activity timestamp
            entry.value.2 = std.time.nanoTime();
            return &entry.value.state;
        } else {
            const new_state = try lua.LuaState.init();
            // Register host functions to new connection state
            host_functions.register(&new_state);
            const now = std.time.nanoTimestamp();
            try self.connection_states.put(connection_id, .{ new_state, now, now });
            return &new_state;
        }
    }

    pub fn removeConnectionState(self: *LuaStateManager, connection_id: u64) void {
        if (self.connection_states.fetchRemove(connection_id)) |entry| {
            entry.value.state.deinit();
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
            const age = now - entry.value.2; // Use last_activity instead of created_at
            if (age > timeout_ns) {
                try to_remove.append(entry.key_ptr.*);
                logger.debug("Expire connection state: {} (age={}ms)", .{ entry.key_ptr.*, age / std.time.ns_per_ms });
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
    fn defaultEventHandler(self: *LuaStateManager, payload: events.EventPayload) void {
        const event_type_name = @tagName(payload);
        const logger = std.log.scoped(.wasi_lua);

        switch (payload) {
            .plugin_start => |e| logger.debug("Lua event: plugin_start handle={} name={}", .{ e.plugin_handle, e.plugin_name }),
            .plugin_stop => |e| logger.debug("Lua event: plugin_stop handle={} exit_code={}", .{ e.plugin_handle, e.exit_code }),
            .plugin_error => |e| logger.err("Lua event: plugin_error handle={} code={} msg={}", .{ e.plugin_handle, e.error_code, e.error_message }),
            .plugin_complete => |e| logger.debug("Lua event: plugin_complete handle={} exit_code={} duration_ms={}", .{ e.plugin_handle, e.exit_code, e.duration_ms }),
            .plugin_timeout => |e| logger.warn("Lua event: plugin_timeout handle={} timeout_ms={}", .{ e.plugin_handle, e.timeout_ms }),
            .chord_node_join => |e| logger.debug("Lua event: chord_node_join node_id={} host={} port={}", .{ std.fmt.fmtSliceHexLower(&e.node_id), e.host, e.port }),
            .chord_successor_change => |e| logger.debug("Lua event: chord_successor_change old={} new={}", .{ std.fmt.fmtSliceHexLower(&e.old_successor_id), std.fmt.fmtSliceHexLower(&e.new_successor_id) }),
            .dht_put => |e| logger.debug("Lua event: dht_put key={} size={}", .{ e.key, e.value_size }),
        }
    }

    /// Encode event payload to Lua table with key-value pairs
    fn encodePayloadToTable(self: *LuaStateManager, payload: events.EventPayload) !void {
        const logger = std.log.scoped(.wasi_lua);

        // Create Lua table
        _ = lua.lua_createtable(self.global_state.state, 0, 0);

        // Add event_type field
        try lua.lua_pushstring(self.global_state.state, @tagName(payload));
        lua.lua_setfield(self.global_state.state, -2, "event_type");

        // Add event-specific fields
        switch (payload) {
            .plugin_start => |e| {
                try lua.lua_pushnumber(self.global_state.state, e.plugin_handle);
                lua.lua_setfield(self.global_state.state, -2, "plugin_handle");

                try lua.lua_pushstring(self.global_state.state, e.plugin_name);
                lua.lua_setfield(self.global_state.state, -2, "plugin_name");

                if (e.connection_id) |cid| {
                    try lua.lua_pushnumber(self.global_state.state, cid);
                    lua.lua_setfield(self.global_state.state, -2, "connection_id");
                }
            },
            .plugin_stop => |e| {
                try lua.lua_pushnumber(self.global_state.state, e.plugin_handle);
                lua.lua_setfield(self.global_state.state, -2, "plugin_handle");

                try lua.lua_pushnumber(self.global_state.state, e.exit_code);
                lua.lua_setfield(self.global_state.state, -2, "exit_code");
            },
            .plugin_error => |e| {
                try lua.lua_pushnumber(self.global_state.state, e.plugin_handle);
                lua.lua_setfield(self.global_state.state, -2, "plugin_handle");

                try lua.lua_pushnumber(self.global_state.state, e.error_code);
                lua.lua_setfield(self.global_state.state, -2, "error_code");

                try lua.lua_pushstring(self.global_state.state, e.error_message);
                lua.lua_setfield(self.global_state.state, -2, "error_message");
            },
            .plugin_complete => |e| {
                try lua.lua_pushnumber(self.global_state.state, e.plugin_handle);
                lua.lua_setfield(self.global_state.state, -2, "plugin_handle");

                try lua.lua_pushnumber(self.global_state.state, e.exit_code);
                lua.lua_setfield(self.global_state.state, -2, "exit_code");

                try lua.lua_pushnumber(self.global_state.state, e.duration_ms);
                lua.lua_setfield(self.global_state.state, -2, "duration_ms");
            },
            .plugin_timeout => |e| {
                try lua.lua_pushnumber(self.global_state.state, e.plugin_handle);
                lua.lua_setfield(self.global_state.state, -2, "plugin_handle");

                try lua.lua_pushnumber(self.global_state.state, e.timeout_ms);
                lua.lua_setfield(self.global_state.state, -2, "timeout_ms");
            },
            .chord_node_join => |e| {
                try lua.lua_pushlstring(self.global_state.state, &e.node_id, e.node_id.len);
                lua.lua_setfield(self.global_state.state, -2, "node_id");

                try lua.lua_pushstring(self.global_state.state, e.host);
                lua.lua_setfield(self.global_state.state, -2, "host");

                try lua.lua_pushnumber(self.global_state.state, e.port);
                lua.lua_setfield(self.global_state.state, -2, "port");
            },
            .chord_successor_change => |e| {
                try lua.lua_pushlstring(self.global_state.state, &e.old_successor_id, e.old_successor_id.len);
                lua.lua_setfield(self.global_state.state, -2, "old_successor_id");

                try lua.lua_pushlstring(self.global_state.state, &e.new_successor_id, e.new_successor_id.len);
                lua.lua_setfield(self.global_state.state, -2, "new_successor_id");
            },
            .dht_put => |e| {
                try lua.lua_pushstring(self.global_state.state, e.key);
                lua.lua_setfield(self.global_state.state, -2, "key");

                try lua.lua_pushnumber(self.global_state.state, e.value_size);
                lua.lua_setfield(self.global_state.state, -2, "value_size");
            },
        }

        logger.debug("Encoded Lua event table", .{});
    }

    /// Invoke Lua callback with error handling
    fn invokeCallback(self: *LuaStateManager, callback_state: lua.LuaState, payload_table_idx: c_int) !void {
        const logger = std.log.scoped(.wasi_lua);

        // Get the callback function from the registry
        lua.lua_pushvalue(callback_state.state, payload_table_idx); // Copy payload table to top

        // Call the callback function with the payload table
        const status = lua.lua_pcall(callback_state.state, 1, 0, 0);
        if (status != lua.Lua.Status.ok) {
            // Callback failed - get error message and log it
            const error_msg = lua.lua_tostring(callback_state.state, -1);
            if (error_msg) |msg| {
                logger.err("Lua callback error: {}", .{msg});
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
                // Invoke callback for this event type, or use default handler
                const event_type_name = @tagName(payload);
                if (self.callbacks.get(event_type_name)) |callback_state| {
                    // Encode payload to Lua table
                    if (self.encodePayloadToTable(payload)) {
                        // Payload table is on top of the stack
                        // Invoke callback with error handling
                        _ = self.invokeCallback(callback_state, lua.lua_getTop(callback_state));
                        // Pop the payload table from stack
                        lua.lua_pop(callback_state.state, 1);
                    } else {
                        // Payload encoding failed - use default handler
                        self.defaultEventHandler(payload);
                    }
                } else {
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
        _ = lua.lua_gc(self.global_state.state, lua.Lua.GC.COLLECT, 0);

        // Trigger GC on all connection states
        var it = self.connection_states.iterator();
        while (it.next()) |entry| {
            _ = lua.lua_gc(entry.value_ptr.state, lua.Lua.GC.COLLECT, 0);
        }
    }

    pub fn generatePluginHandle(self: *LuaStateManager, connection_id: ?u64) u64 {
        const handle = self.next_plugin_handle.fetchAdd(1, .monotonic);

        if (connection_id) |cid| {
            if (self.connection_plugins.get(cid)) |plugins| {
                try plugins.append(handle);
            } else {
                // Create new plugin list for this connection
                const list = std.ArrayList(u64).init(self.allocator);
                try list.append(handle);
                try self.connection_plugins.put(cid, list);
            }
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
            logger.debug("No plugins found for connection {}", .{connection_id});
            const empty = std.ArrayList(u64).init(self.allocator);
            return empty;
        }
    }
};