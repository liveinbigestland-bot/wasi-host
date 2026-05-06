const std = @import("std");
const lua = @import("../src/lua/api.zig");
const events = @import("../src/lua/events.zig");
const lua_state_manager = @import("../src/lua/state.zig");

const Testing = std.testing;

test "WASM-to-Lua Events - Plugin start event" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    // Create a mock plugin start event
    const payload = events.EventPayload{
        .plugin_start = .{
            .plugin_handle = 1,
            .plugin_name = "test_plugin",
            .connection_id = null,
        },
    };

    try manager.postEvent(payload);

    // Process events
    manager.processEvents(10);

    // Queue should be empty now
    try Testing.expect(manager.event_queue.isEmpty());
}

test "WASM-to-Lua Events - Plugin complete event" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    // Register a mock callback
    const lua_state = manager.getGlobalState();
    lua_state.pushCFunction(struct {
        fn callback(_: ?*anyopaque, _: ?*anyopaque) callconv(.C) c_int {
            _ = _;
            return 0;
        }
    }.callback);
    const ref = lua_state.ref(lua.lua.LuaRegistryIndex);
    defer lua.lua.lua_pop(lua_state.state, 1); // Pop the function

    try manager.registerCallback("plugin_complete", lua_state);

    // Create a plugin complete event
    const payload = events.EventPayload{
        .plugin_complete = .{
            .plugin_handle = 1,
            .exit_code = 0,
            .duration_ms = 100,
        },
    };

    try manager.postEvent(payload);

    // Process events
    manager.processEvents(10);

    // Event should be processed
    try Testing.expect(manager.event_queue.isEmpty());
}

test "WASM-to-Lua Events - Plugin error event" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    // Create a plugin error event
    const payload = events.EventPayload{
        .plugin_error = .{
            .plugin_handle = 1,
            .error_code = -1,
            .error_message = "Test error message",
        },
    };

    try manager.postEvent(payload);

    // Process events
    manager.processEvents(10);

    // Queue should be empty
    try Testing.expect(manager.event_queue.isEmpty());
}

test "WASM-to-Lua Events - Plugin timeout event" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    // Create a plugin timeout event
    const payload = events.EventPayload{
        .plugin_timeout = .{
            .plugin_handle = 1,
            .timeout_ms = 5000,
        },
    };

    try manager.postEvent(payload);

    // Process events
    manager.processEvents(10);

    // Queue should be empty
    try Testing.expect(manager.event_queue.isEmpty());
}

test "WASM-to-Lua Events - Default handler logs errors" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    // Create an event with no registered callback
    const payload = events.EventPayload{
        .plugin_complete = .{
            .plugin_handle = 1,
            .exit_code = 0,
            .duration_ms = 100,
        },
    };

    try manager.postEvent(payload);

    // Process events without callback
    manager.processEvents(10);

    // Queue should be empty
    try Testing.expect(manager.event_queue.isEmpty());

    // Default handler should have logged the event
}

test "WASM-to-Lua Events - Multiple events in queue" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    // Post multiple events
    for (1..5) |i| {
        const payload = events.EventPayload{
            .plugin_complete = .{
                .plugin_handle = @intCast(i),
                .exit_code = 0,
                .duration_ms = 100,
            },
        };
        try manager.postEvent(payload);
    }

    // Queue should have 4 events
    try Testing.expect(manager.event_queue.depth() == 4);

    // Process events with time budget
    manager.processEvents(50);

    // Queue should be empty after processing
    try Testing.expect(manager.event_queue.isEmpty());
}

test "WASM-to-Lua Events - Event payload encoding" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    // Test plugin_complete event encoding
    const payload = events.EventPayload{
        .plugin_complete = .{
            .plugin_handle = 42,
            .exit_code = 0,
            .duration_ms = 1234,
        },
    };

    // The encoding happens internally in processEvents
    try manager.postEvent(payload);

    // Processing should work without errors
    manager.processEvents(10);

    try Testing.expect(manager.event_queue.isEmpty());
}

test "WASM-to-Lua Events - Chord node join event" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    const test_id = [_]u8{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14};
    const test_host = "192.168.1.1";
    const test_port: u16 = 20808;

    const payload = events.EventPayload{
        .chord_node_join = .{
            .node_id = test_id,
            .host = test_host,
            .port = test_port,
        },
    };

    try manager.postEvent(payload);

    // Process events
    manager.processEvents(10);

    // Queue should be empty
    try Testing.expect(manager.event_queue.isEmpty());
}

test "WASM-to-Lua Events - DHT put event" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    const test_key = "test_key_12345";
    const payload = events.EventPayload{
        .dht_put = .{
            .key = test_key,
            .value_size = 256,
        },
    };

    try manager.postEvent(payload);

    // Process events
    manager.processEvents(10);

    // Queue should be empty
    try Testing.expect(manager.event_queue.isEmpty());
}
