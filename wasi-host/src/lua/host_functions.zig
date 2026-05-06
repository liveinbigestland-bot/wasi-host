const std = @import("std");
const Lua = @import("api.zig").Lua;
const LuaState = @import("api.zig").LuaState;
const events = @import("events.zig");

pub const HostFunctions = struct {
    /// wasm_start(plugin_name, config) -> plugin_handle
    /// Start a WASM plugin with optional configuration
    /// config table may contain: mem_kb (default 512), timeout_ms (default 5000), network (default false), write (default false)
    fn wasmStart(l: ?*Lua) callconv(.C) c_int {
        const L = LuaState.fromPtr(l);
        const alloc = L.allocator();
        defer L.setTop(0);

        // Get plugin_name (arg 1)
        if (L.getType(1) != .string) {
            L.pushNil();
            L.pushString("Expected plugin_name as string");
            return 2;
        }

        const plugin_name = L.toString(1) orelse "";
        defer if (plugin_name.len > 0) alloc.free(plugin_name);

        // Get config table (arg 2, optional)
        var mem_kb: u32 = 512;
        var timeout_ms: u32 = 5000;
        var network: bool = false;
        var write: bool = false;
        var allow_host_info: bool = true;

        if (L.getType(2) == .table) {
            L.pushString("mem_kb");
            if (L.getTable(2) != .nil) {
                mem_kb = @intCast(L.toInteger(3));
            }

            L.pushString("timeout_ms");
            if (L.getTable(2) != .nil) {
                timeout_ms = @intCast(L.toInteger(3));
            }

            L.pushString("network");
            if (L.getTable(2) != .nil) {
                network = L.toBoolean(3);
            }

            L.pushString("write");
            if (L.getTable(2) != .nil) {
                write = L.toBoolean(3);
            }

            L.pushString("allow_host_info");
            if (L.getTable(2) != .nil) {
                allow_host_info = L.toBoolean(3);
            }
        }

        // TODO: Actually start the WASM plugin
        // For now, return a fake handle
        _ = plugin_name;
        _ = mem_kb;
        _ = timeout_ms;
        _ = network;
        _ = write;
        _ = allow_host_info;

        const fake_handle: u64 = 0;
        L.pushInteger(fake_handle);
        L.pushNil();
        return 2;
    }

    /// wasm_stop(plugin_handle) -> success, error
    /// Stop a running WASM plugin
    fn wasmStop(l: ?*Lua) callconv(.C) c_int {
        const L = LuaState.fromPtr(l);
        defer L.setTop(0);

        if (L.getType(1) != .number) {
            L.pushBoolean(false);
            L.pushString("Expected plugin_handle as number");
            return 2;
        }

        const plugin_handle = L.toInteger(1);

        // TODO: Implement actual plugin stopping
        _ = plugin_handle;

        L.pushBoolean(true);
        L.pushNil();
        return 2;
    }

    /// wasm_pause(plugin_handle) -> success, error
    /// Pause a running WASM plugin
    fn wasmPause(l: ?*Lua) callconv(.C) c_int {
        const L = LuaState.fromPtr(l);
        defer L.setTop(0);

        if (L.getType(1) != .number) {
            L.pushBoolean(false);
            L.pushString("Expected plugin_handle as number");
            return 2;
        }

        const plugin_handle = L.toInteger(1);

        // TODO: Implement actual plugin pausing
        _ = plugin_handle;

        L.pushBoolean(true);
        L.pushNil();
        return 2;
    }

    /// wasm_resume(plugin_handle) -> success, error
    /// Resume a paused WASM plugin
    fn wasmResume(l: ?*Lua) callconv(.C) c_int {
        const L = LuaState.fromPtr(l);
        defer L.setTop(0);

        if (L.getType(1) != .number) {
            L.pushBoolean(false);
            L.pushString("Expected plugin_handle as number");
            return 2;
        }

        const plugin_handle = L.toInteger(1);

        // TODO: Implement actual plugin resuming
        _ = plugin_handle;

        L.pushBoolean(true);
        L.pushNil();
        return 2;
    }

    /// wasm_list_plugins() -> array of plugin names
    /// List available embedded and file-based plugins
    fn wasmListPlugins(l: ?*Lua) callconv(.C) c_int {
        const L = LuaState.fromPtr(l);
        defer L.setTop(0);

        L.newTable();
        var i: c_int = 1;

        // Embedded plugins
        const embedded = [2][]const u8{ "ai_plugin.wasm", "api_plugin.wasm" };
        for (embedded) |name| {
            L.pushInteger(i);
            L.pushString(name);
            L.setTable(-3);
            i += 1;
        }

        // TODO: Scan for file-based plugins
        return 1;
    }

    /// wasm_list_active() -> array of active plugin handles
    /// List currently active plugins
    fn wasmListActive(l: ?*Lua) callconv(.C) c_int {
        const L = LuaState.fromPtr(l);
        defer L.setTop(0);

        // TODO: Implement active plugin tracking
        L.newTable();
        return 1;
    }

    /// wasm_plugin_info(plugin_name) -> info table
    /// Get metadata for a plugin
    fn wasmPluginInfo(l: ?*Lua) callconv(.C) c_int {
        const L = LuaState.fromPtr(l);
        const alloc = L.allocator();
        defer L.setTop(0);

        if (L.getType(1) != .string) {
            L.pushNil();
            return 1;
        }

        const plugin_name = L.toString(1) orelse "";
        defer if (plugin_name.len > 0) alloc.free(plugin_name);

        L.newTable();

        L.pushString("name");
        L.pushString(plugin_name);
        L.setTable(-3);

        L.pushString("default_mem_kb");
        L.pushInteger(512);
        L.setTable(-3);

        L.pushString("default_timeout_ms");
        L.pushInteger(5000);
        L.setTable(-3);

        return 1;
    }

    /// wasm_on_event(event_type, callback) -> success
    /// Register a callback for a specific event type
    /// Requires global LuaStateManager reference to be set via setLuaStateManager()
    var global_lua_manager: ?*@import("state.zig").LuaStateManager = null;

    pub fn setLuaStateManager(manager: *@import("state.zig").LuaStateManager) void {
        global_lua_manager = manager;
    }

    fn wasmOnEvent(l: ?*Lua) callconv(.C) c_int {
        const L = LuaState.fromPtr(l);
        const alloc = L.allocator();
        defer L.setTop(0);

        if (global_lua_manager == null) {
            L.pushBoolean(false);
            L.pushString("LuaStateManager not initialized");
            return 2;
        }

        if (L.getType(1) != .string) {
            L.pushBoolean(false);
            L.pushString("Expected event_type as string");
            return 2;
        }

        if (L.getType(2) != .function) {
            L.pushBoolean(false);
            L.pushString("Expected callback as function");
            return 2;
        }

        const event_type = L.toString(1) orelse "";
        defer if (event_type.len > 0) alloc.free(event_type);

        // Validate event type
        const valid = checkValidEventType(event_type);
        if (!valid) {
            L.pushBoolean(false);
            L.pushString("Invalid event_type");
            return 2;
        }

        // Store callback function reference
        // We need to create a persistent reference to the Lua function
        L.pushValue(2); // Push callback onto stack
        const ref = L.ref(lua.lua.LuaRegistryIndex);
        _ = ref;

        // Store in LuaStateManager
        // TODO: Store the reference for later invocation
        _ = global_lua_manager;

        L.pushBoolean(true);
        L.pushNil();
        return 2;
    }

    /// wasm_off_event(event_type) -> success
    /// Unregister a callback for a specific event type
    fn wasmOffEvent(l: ?*Lua) callconv(.C) c_int {
        const L = LuaState.fromPtr(l);
        const alloc = L.allocator();
        defer L.setTop(0);

        if (global_lua_manager == null) {
            L.pushBoolean(false);
            L.pushString("LuaStateManager not initialized");
            return 2;
        }

        if (L.getType(1) != .string) {
            L.pushBoolean(false);
            L.pushString("Expected event_type as string");
            return 2;
        }

        const event_type = L.toString(1) orelse "";
        defer if (event_type.len > 0) alloc.free(event_type);

        // Unregister callback from LuaStateManager
        global_lua_manager.?.unregisterCallback(event_type);

        L.pushBoolean(true);
        L.pushNil();
        return 2;
    }

    /// wasm_get_connection_config(connection_id) -> config table
    /// Get configuration for a specific connection
    fn wasmGetConnectionConfig(l: ?*Lua) callconv(.C) c_int {
        const L = LuaState.fromPtr(l);
        const alloc = L.allocator();
        defer L.setTop(0);

        if (global_lua_manager == null) {
            L.pushNil();
            L.pushString("LuaStateManager not initialized");
            return 2;
        }

        if (L.getType(1) != .number) {
            L.pushNil();
            L.pushString("Expected connection_id as number");
            return 2;
        }

        const connection_id = L.toInteger(1);
        const manager = global_lua_manager.?;

        // Get connection state
        if (manager.getConnectionState(connection_id)) |state| {
            // Create config table with default values
            L.newTable();

            // TODO: Read actual connection config from connection-specific Lua state
            // For now, return defaults
            L.pushString("mem_kb");
            L.pushInteger(512);
            L.setTable(-3);

            L.pushString("timeout_ms");
            L.pushInteger(5000);
            L.setTable(-3);

            L.pushString("network");
            L.pushBoolean(false);
            L.setTable(-3);

            L.pushString("write");
            L.pushBoolean(false);
            L.setTable(-3);

            return 1;
        } else {
            L.pushNil();
            L.pushString("Connection not found");
            return 2;
        }
    }

    /// wasm_set_connection_config(connection_id, config) -> success, error
    /// Set configuration for a specific connection
    fn wasmSetConnectionConfig(l: ?*Lua) callconv(.C) c_int {
        const L = LuaState.fromPtr(l);
        const alloc = L.allocator();
        defer L.setTop(0);

        if (global_lua_manager == null) {
            L.pushBoolean(false);
            L.pushString("LuaStateManager not initialized");
            return 2;
        }

        if (L.getType(1) != .number) {
            L.pushBoolean(false);
            L.pushString("Expected connection_id as number");
            return 2;
        }

        if (L.getType(2) != .table) {
            L.pushBoolean(false);
            L.pushString("Expected config as table");
            return 2;
        }

        const connection_id = L.toInteger(1);

        // Get connection state
        if (global_lua_manager.?.getConnectionState(connection_id)) |_| {
            // TODO: Apply config to connection-specific Lua state
            // For now, just validate and return success
            L.pushBoolean(true);
            L.pushNil();
            return 2;
        } else {
            L.pushBoolean(false);
            L.pushString("Connection not found");
            return 2;
        }
    }

    /// wasm_remove_connection_state(connection_id) -> success, error
    /// Explicitly remove a connection state and clean up resources
    fn wasmRemoveConnectionState(l: ?*Lua) callconv(.C) c_int {
        const L = LuaState.fromPtr(l);
        const alloc = L.allocator();
        defer L.setTop(0);

        if (global_lua_manager == null) {
            L.pushBoolean(false);
            L.pushString("LuaStateManager not initialized");
            return 2;
        }

        if (L.getType(1) != .number) {
            L.pushBoolean(false);
            L.pushString("Expected connection_id as number");
            return 2;
        }

        const connection_id = L.toInteger(1);

        // Remove connection state from manager
        global_lua_manager.?.removeConnectionState(connection_id);

        L.pushBoolean(true);
        L.pushNil();
        return 2;
    }

    fn checkValidEventType(event_type: []const u8) bool {
        const types = [_][]const u8{
            "plugin_start",
            "plugin_stop",
            "plugin_error",
            "plugin_complete",
            "plugin_timeout",
            "chord_node_join",
            "chord_successor_change",
            "dht_put",
        };

        for (types) |t| {
            if (std.mem.eql(u8, t, event_type)) {
                return true;
            }
        }
        return false;
    }

    /// Register all host functions to a Lua state
    pub fn register(state: *LuaState) void {
        state.pushCFunction(wasmStart);
        state.setGlobal("wasm_start");

        state.pushCFunction(wasmStop);
        state.setGlobal("wasm_stop");

        state.pushCFunction(wasmPause);
        state.setGlobal("wasm_pause");

        state.pushCFunction(wasmResume);
        state.setGlobal("wasm_resume");

        state.pushCFunction(wasmListPlugins);
        state.setGlobal("wasm_list_plugins");

        state.pushCFunction(wasmListActive);
        state.setGlobal("wasm_list_active");

        state.pushCFunction(wasmPluginInfo);
        state.setGlobal("wasm_plugin_info");

        state.pushCFunction(wasmOnEvent);
        state.setGlobal("wasm_on_event");

        state.pushCFunction(wasmOffEvent);
        state.setGlobal("wasm_off_event");

        state.pushCFunction(wasmGetConnectionConfig);
        state.setGlobal("wasm_get_connection_config");

        state.pushCFunction(wasmSetConnectionConfig);
        state.setGlobal("wasm_set_connection_config");

        state.pushCFunction(wasmRemoveConnectionState);
        state.setGlobal("wasm_remove_connection_state");
    }
};
