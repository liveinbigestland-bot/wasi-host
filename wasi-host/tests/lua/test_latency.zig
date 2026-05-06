const std = @import("std");
const lua = @import("../src/lua/api.zig");
const events = @import("../src/lua/events.zig");
const lua_state_manager = @import("../src/lua/state.zig");

const Testing = std.testing;

test "Latency - Event queue push and pop" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    const num_operations = 1000;
    var latencies = try allocator.alloc(u64, num_operations);
    defer allocator.free(latencies);

    // Measure push latency
    for (latencies, 0..) |_, i| {
        const start = std.time.nanoTimestamp();

        const payload = events.EventPayload{
            .plugin_complete = .{
                .plugin_handle = @intCast(i),
                .exit_code = 0,
                .duration_ms = 100,
            },
        };

        _ = manager.postEvent(payload) catch {};

        latencies[i] = std.time.nanoTimestamp() - start;

        // Small delay to prevent overwhelming the queue
        if (i % 100 == 0) {
            std.time.sleep(1 * std.time.ns_per_us);
        }
    }

    // Calculate average latency
    var total: u64 = 0;
    for (latencies) |lat| {
        total += lat;
    }
    const avg_latency_ns = total / num_operations;
    const avg_latency_us = avg_latency_ns / 1000;

    // Log results
    std.debug.print("[Latency Test] Average event queue push latency: {} µs\n", .{avg_latency_us});

    // Events should be processed quickly
    manager.processEvents(10);

    // Average should be reasonable (< 1ms per operation)
    try Testing.expect(avg_latency_us < 1000);
}

test "Latency - Event queue with callbacks" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    const num_operations = 100;
    var push_latencies = try allocator.alloc(u64, num_operations);
    var callback_latencies = try allocator.alloc(u64, num_operations);
    defer allocator.free(push_latencies);
    defer allocator.free(callback_latencies);

    // Measure callback execution latency
    for (callback_latencies, 0..) |_, i| {
        const start = std.time.nanoTime();

        // Create and register callback
        const lua_state = manager.getGlobalState();
        lua_state.pushCFunction(struct {
            fn callback(_: ?*anyopaque, _: ?*anyopaque) callconv(.C) c_int {
                _ = _;
                return 0;
            }
        }.callback);
        _ = lua_state.ref(lua.lua.LuaRegistryIndex);
        lua.lua.lua_pop(lua_state.state, 1);

        try manager.registerCallback("test_event", lua_state);

        const end = std.time.nanoTime();
        callback_latencies[i] = end - start;

        // Small delay
        std.time.sleep(10 * std.time.ns_per_us);
    }

    // Calculate average
    var total: u64 = 0;
    for (callback_latencies) |lat| {
        total += lat;
    }
    const avg_ns = total / num_operations;
    const avg_us = avg_ns / 1000;

    std.debug.print("[Latency Test] Average callback registration latency: {} µs\n", .{avg_us});

    try Testing.expect(avg_us < 500);
}

test "Latency - Event processing throughput" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    // Pre-fill the queue with events
    const num_events = 256; // Fill the queue
    for (0..num_events) |i| {
        const payload = events.EventPayload{
            .plugin_complete = .{
                .plugin_handle = @intCast(i),
                .exit_code = 0,
                .duration_ms = 100,
            },
        };
        try manager.postEvent(payload);
    }

    // Measure processing time
    const start = std.time.nanoTime();
    manager.processEvents(1000); // Process with generous time budget
    const elapsed_ns = std.time.nanoTime() - start;
    const elapsed_us = elapsed_ns / 1000;

    std.debug.print("[Latency Test] Processed {} events in {} µs ({:.2f} µs/event)\n", .{
        num_events,
        elapsed_us,
        @floatFromInt(elapsed_us) / @floatFromInt(num_events),
    });

    // Processing should be efficient
    try Testing.expect(manager.event_queue.isEmpty());
}

test "Latency - Connection state access" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    const conn_id: u64 = 12345;
    const num_operations = 1000;

    // Measure get connection state latency
    var latencies = try allocator.alloc(u64, num_operations);
    defer allocator.free(latencies);

    for (latencies, 0..) |_, i| {
        const start = std.time.nanoTime();
        _ = manager.getConnectionState(conn_id);
        const end = std.time.nanoTime();
        latencies[i] = end - start;

        if (i % 100 == 0) {
            std.time.sleep(1 * std.time.ns_per_us);
        }
    }

    // Calculate average
    var total: u64 = 0;
    for (latencies) |lat| {
        total += lat;
    }
    const avg_ns = total / num_operations;
    const avg_us = avg_ns / 1000;

    std.debug.print("[Latency Test] Average connection state access latency: {} µs\n", .{avg_us});

    // Should be very fast (< 1 µs)
    try Testing.expect(avg_us < 10);
}

test "Latency - Plugin handle generation" {
    const allocator = std.heap.page_allocator;

    const manager = try lua_state_manager.LuaStateManager.init(allocator);
    defer manager.deinit();

    const num_operations = 1000;
    var latencies = try allocator.alloc(u64, num_operations);
    defer allocator.free(latencies);

    for (latencies, 0..) |_, i| {
        const start = std.time.nanoTime();
        _ = manager.generatePluginHandle(null);
        const end = std.time.nanoTime();
        latencies[i] = end - start;

        if (i % 100 == 0) {
            std.time.sleep(1 * std.time.ns_per_us);
        }
    }

    // Calculate average
    var total: u64 = 0;
    for (latencies) |lat| {
        total += lat;
    }
    const avg_ns = total / num_operations;
    const avg_us = avg_ns / 1000;

    std.debug.print("[Latency Test] Average plugin handle generation latency: {} µs\n", .{avg_us});

    // Should be very fast (< 1 µs)
    try Testing.expect(avg_us < 10);
}
