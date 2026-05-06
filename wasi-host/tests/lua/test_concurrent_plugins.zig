const std = @import("std");
const lua = @import("../src/lua/api.zig");
const lua_state_manager = @import("../src/lua/state.zig");
const events = @import("../src/lua/events.zig");

const Testing = std.testing;

test "Concurrent Plugin Management - Multiple plugin handles" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    // Generate multiple plugin handles
    const handles = try allocator.alloc(u64, 10);
    defer allocator.free(handles);

    for (handles, 0..) |_, i| {
        handles[i] = manager.generatePluginHandle(null);
        try Testing.expect(handles[i] != 0);
    }

    // All handles should be unique
    for (handles, 0..) |h1, i| {
        for (handles[i + 1..], i + 1..) |h2, j| {
            try Testing.expect(h1 != h2);
        }
    }
}

test "Concurrent Plugin Management - Per-connection plugin isolation" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    const conn1: u64 = 100;
    const conn2: u64 = 200;

    // Generate handles for both connections
    const conn1_handles = try allocator.alloc(u64, 5);
    const conn2_handles = try allocator.alloc(u64, 5);
    defer allocator.free(conn1_handles);
    defer allocator.free(conn2_handles);

    for (conn1_handles, 0..) |_, i| {
        conn1_handles[i] = manager.generatePluginHandle(conn1);
    }

    for (conn2_handles, 0..) |_, i| {
        conn2_handles[i] = manager.generatePluginHandle(conn2);
    }

    // Handles should be unique across connections
    for (conn1_handles, 0..) |h1| {
        for (conn2_handles, 0..) |h2| {
            try Testing.expect(h1 != h2);
        }
    }

    // Verify connection state tracking
    const plugins1 = try manager.getPluginsForConnection(conn1);
    defer plugins1.deinit();

    const plugins2 = try manager.getPluginsForConnection(conn2);
    defer plugins2.deinit();

    try Testing.expect(plugins1.items.len >= 5);
    try Testing.expect(plugins2.items.len >= 5);
}

test "Concurrent Plugin Management - Dynamic handle generation" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    // Generate handles one at a time
    const handle1 = manager.generatePluginHandle(null);
    try Testing.expect(handle1 != 0);

    const handle2 = manager.generatePluginHandle(null);
    try Testing.expect(handle2 != 0);

    const handle3 = manager.generatePluginHandle(null);
    try Testing.expect(handle3 != 0);

    // Handles should be sequential
    try Testing.expect(handle2 == handle1 + 1);
    try Testing.expect(handle3 == handle2 + 1);
}

test "Concurrent Plugin Management - Event batching" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    const conn1: u64 = 100;

    // Generate handles for a connection
    const handles = try allocator.alloc(u64, 3);
    defer allocator.free(handles);

    for (handles, 0..) |_, i| {
        handles[i] = manager.generatePluginHandle(conn1);
    }

    // Post events for all handles
    for (handles, 0..) |handle, i| {
        const payload = events.EventPayload{
            .plugin_complete = .{
                .plugin_handle = handle,
                .exit_code = 0,
                .duration_ms = @intCast(100 + i),
            },
        };
        try manager.postEvent(payload);
    }

    // All events should be in queue
    try Testing.expect(manager.event_queue.depth() == 3);

    // Process all events
    manager.processEvents(100);

    // Queue should be empty
    try Testing.expect(manager.event_queue.isEmpty());
}

test "Concurrent Plugin Management - Handle removal" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    const conn1: u64 = 100;

    // Generate handles
    const handle1 = manager.generatePluginHandle(conn1);
    const handle2 = manager.generatePluginHandle(conn1);

    try Testing.expect(handle1 != 0);
    try Testing.expect(handle2 != 0);
    try Testing.expect(handle1 != handle2);

    // Verify both are tracked
    const plugins = try manager.getPluginsForConnection(conn1);
    defer plugins.deinit();

    try Testing.expect(plugins.items.len >= 2);

    // Remove one handle (simulating plugin termination)
    manager.removeConnectionState(conn1);

    // Connection state should be removed
    const result = manager.connection_states.get(conn1);
    try Testing.expect(result == null);

    // Plugins should be cleaned up
    const plugins_after = try manager.getPluginsForConnection(conn1);
    defer plugins_after.deinit();
    try Testing.expect(plugins_after.items.len == 0);
}

test "Concurrent Plugin Management - Zero handles allowed" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    // Generate handle with null connection (global)
    const handle1 = manager.generatePluginHandle(null);
    try Testing.expect(handle1 != 0);

    // Generate second handle
    const handle2 = manager.generatePluginHandle(null);
    try Testing.expect(handle2 != 0);
    try Testing.expect(handle2 > handle1);

    // Get plugins for non-existent connection
    const conn: u64 = 99999;
    const plugins = try manager.getPluginsForConnection(conn);
    defer plugins.deinit();

    // Should return empty list, not error
    try Testing.expect(plugins.items.len == 0);
}

test "Concurrent Plugin Management - Thread safety simulation" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    // Simulate concurrent access
    var counters = [_]u64{ 0 } ** 4;

    // Simulate 4 "threads" accessing the manager
    for (counters, 0..) |_, thread_id| {
        // Each thread generates handles
        for (1..10) |i| {
            const handle = manager.generatePluginHandle(null);
            _ = handle;

            // Simulate small delay
            std.time.sleep(1);
        }

        // Each thread posts events
        for (1..5) |i| {
            const payload = events.EventPayload{
                .plugin_complete = .{
                    .plugin_handle = handle,
                    .exit_code = 0,
                    .duration_ms = 100,
                },
            };

            _ = manager.postEvent(payload);
        }
    }

    // After all operations, queue should have some events
    try Testing.expect(manager.event_queue.depth() > 0);
}

test "Concurrent Plugin Management - Handle sequence stability" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    const handles = try allocator.alloc(u64, 10);
    defer allocator.free(handles);

    // Generate handles sequentially
    for (handles, 0..) |_, i| {
        handles[i] = manager.generatePluginHandle(null);
        try Testing.expect(handles[i] != 0);
    }

    // Verify sequential order
    for (handles, 0..) |h, i| {
        try Testing.expect(h == @intCast(u64, i + 1));
    }
}
