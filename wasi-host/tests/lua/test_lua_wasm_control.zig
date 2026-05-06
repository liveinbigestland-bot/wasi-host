const std = @import("std");
const lua = @import("../src/lua/api.zig");
const events = @import("../src/lua/events.zig");
const lua_state_manager = @import("../src/lua/state.zig");

const Testing = std.testing;

test "LuaStateManager - Initialize and deinit" {
    const allocator = std.heap.page_allocator;
    defer {
        // Cleanup will be handled by the test framework
    }

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    try Testing.expect(manager.getGlobalState().state != null);
}

test "LuaStateManager - Create and access connection state" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    const conn_id: u64 = 12345;
    const state = try manager.getConnectionState(conn_id);

    try Testing.expect(state.state != null);

    // Verify we can get the same state again
    const state2 = try manager.getConnectionState(conn_id);
    try Testing.expect(state2.state != null);
}

test "LuaStateManager - Connection state cleanup" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    const conn_id: u64 = 99999;
    const state = try manager.getConnectionState(conn_id);

    // Remove the connection state
    manager.removeConnectionState(conn_id);

    // Verify it's removed
    const result = manager.connection_states.get(conn_id);
    try Testing.expect(result == null);
}

test "LuaStateManager - Generate plugin handle" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    const handle1 = manager.generatePluginHandle(null);
    const handle2 = manager.generatePluginHandle(null);
    const handle3 = manager.generatePluginHandle(null);

    try Testing.expect(handle1 != 0);
    try Testing.expect(handle2 != 0);
    try Testing.expect(handle3 != 0);
    try Testing.expect(handle2 > handle1); // Should be sequential
    try Testing.expect(handle3 > handle2);
}

test "LuaStateManager - Event queue operations" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    // Post an event
    const payload = events.EventPayload{
        .plugin_complete = .{
            .plugin_handle = 1,
            .exit_code = 0,
            .duration_ms = 100,
        },
    };

    try manager.postEvent(payload);

    // Check queue is not empty
    try Testing.expect(!manager.event_queue.isEmpty());
    try Testing.expect(manager.event_queue.depth() == 1);

    // Drain the queue
    manager.event_queue.drain(struct {
        fn handler(_: events.EventPayload) void {
            _ = _;
        }
    }.handler);
}

test "LuaStateManager - Event queue overflow handling" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    // Fill the queue to overflow (Capacity = 256)
    var i: u32 = 0;
    while (i < 256) {
        const payload = events.EventPayload{
            .plugin_complete = .{
                .plugin_handle = i,
                .exit_code = 0,
                .duration_ms = 100,
            },
        };
        manager.postEvent(payload) catch |err| {
            // If it fails with overflow, that's expected
            try Testing.expectEqual(error.Overflow, err);
            break;
        };
        i += 1;
    }

    // Queue should be full
    try Testing.expect(manager.event_queue.depth() == 256);

    // Try to add one more - should overflow
    const overflow_payload = events.EventPayload{
        .plugin_complete = .{
            .plugin_handle = 256,
            .exit_code = 0,
            .duration_ms = 100,
        },
    };

    overflow_payload catch |err| {
        try Testing.expectEqual(error.Overflow, err);
    };
}

test "LuaStateManager - Per-connection plugin handles" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    const conn1: u64 = 100;
    const conn2: u64 = 200;

    // Generate handles for different connections
    const handle1 = manager.generatePluginHandle(conn1);
    const handle2 = manager.generatePluginHandle(conn1);
    const handle3 = manager.generatePluginHandle(conn2);

    // All handles should be unique
    try Testing.expect(handle1 != handle2);
    try Testing.expect(handle1 != handle3);
    try Testing.expect(handle2 != handle3);

    // Verify we can get plugins for a connection
    const plugins = try manager.getPluginsForConnection(conn1);
    defer plugins.deinit();

    try Testing.expect(plugins.items.len >= 2); // At least 2 handles
}
