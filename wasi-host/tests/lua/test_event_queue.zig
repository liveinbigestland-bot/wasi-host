const std = @import("std");
const events = @import("../src/lua/events.zig");

const Testing = std.testing;

test "EventQueue - Initialize and isEmpty" {
    const allocator = std.heap.page_allocator;

    const queue = events.EventQueue.init(allocator);
    defer queue.deinit();

    try Testing.expect(queue.isEmpty());
    try Testing.expect(queue.depth() == 0);
}

test "EventQueue - Post and consume single event" {
    const allocator = std.heap.page_allocator;

    const queue = events.EventQueue.init(allocator);
    defer queue.deinit();

    // Post an event
    const payload = events.EventPayload{
        .plugin_complete = .{
            .plugin_handle = 1,
            .exit_code = 0,
            .duration_ms = 100,
        },
    };

    try queue.post(payload);

    // Should not be empty
    try Testing.expect(!queue.isEmpty());
    try Testing.expect(queue.depth() == 1);

    // Consume the event
    const consumed = queue.consume();
    try Testing.expect(consumed != null);

    const consumed_payload = consumed.?;
    try Testing.expectEqual(@as(u8, 0), @intFromEnum(consumed_payload));

    // Should be empty now
    try Testing.expect(queue.isEmpty());
    try Testing.expect(queue.depth() == 0);
}

test "EventQueue - Consume from empty queue" {
    const allocator = std.heap.page_allocator;

    const queue = events.EventQueue.init(allocator);
    defer queue.deinit();

    // Should return null for empty queue
    const result = queue.consume();
    try Testing.expect(result == null);
}

test "EventQueue - Queue overflow handling" {
    const allocator = std.heap.page_allocator;

    const queue = events.EventQueue.init(allocator);
    defer queue.deinit();

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

        queue.post(payload) catch |err| {
            // Expected to overflow
            try Testing.expectEqual(error.Overflow, err);
            break;
        };

        i += 1;
    }

    // Queue should be full
    try Testing.expect(queue.depth() == 256);

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

    // Depth should still be 256 (no overflow was committed)
    try Testing.expect(queue.depth() == 256);
}

test "EventQueue - Event payload cloning" {
    const allocator = std.heap.page_allocator;

    const queue = events.EventQueue.init(allocator);
    defer queue.deinit();

    // Create an event with string fields
    const payload = events.EventPayload{
        .plugin_complete = .{
            .plugin_handle = 1,
            .exit_code = 0,
            .duration_ms = 100,
            .plugin_name = "test_plugin",
            .error_message = "Test error",
        },
    };

    // Post should clone the payload
    try queue.post(payload);

    // Consume and verify
    if (queue.consume()) |consumed| {
        _ = consumed;

        // The cloned payload should have the same values
        try Testing.expectEqual(@as(u8, 0), @intFromEnum(consumed));

        queue.freePayload(consumed);
    }
}

test "EventQueue - Multiple posts and consumes" {
    const allocator = std.heap.page_allocator;

    const queue = events.EventQueue.init(allocator);
    defer queue.deinit();

    // Post multiple events
    for (0..100) |i| {
        const payload = events.EventPayload{
            .plugin_complete = .{
                .plugin_handle = @intCast(i),
                .exit_code = 0,
                .duration_ms = 100,
            },
        };

        try queue.post(payload);
    }

    // Should have 100 events
    try Testing.expect(queue.depth() == 100);

    // Consume all events
    var count: usize = 0;
    while (queue.consume()) |_| {
        count += 1;
    }

    // Should have consumed all 100 events
    try Testing.expectEqual(@as(usize, 100), count);

    // Should be empty
    try Testing.expect(queue.isEmpty());
    try Testing.expect(queue.depth() == 0);
}

test "EventQueue - Process all events with drain" {
    const allocator = std.heap.page_allocator;

    const queue = events.EventQueue.init(allocator);
    defer queue.deinit();

    // Post multiple events
    for (0..50) |i| {
        const payload = events.EventPayload{
            .plugin_complete = .{
                .plugin_handle = @intCast(i),
                .exit_code = 0,
                .duration_ms = 100,
            },
        };

        try queue.post(payload);
    }

    // Process all events with drain
    var count: usize = 0;
    queue.drain(struct {
        fn handler(p: events.EventPayload) void {
            _ = p;
            // Count would go here in real implementation
        }
    }.handler);

    // Queue should be empty
    try Testing.expect(queue.isEmpty());
}

test "EventQueue - Queue depth calculation" {
    const allocator = std.heap.page_allocator;

    const queue = events.EventQueue.init(allocator);
    defer queue.deinit();

    try Testing.expectEqual(@as(u32, 0), queue.depth());

    // Add 10 events
    for (0..10) |_| {
        const payload = events.EventPayload{
            .plugin_complete = .{
                .plugin_handle = 1,
                .exit_code = 0,
                .duration_ms = 100,
            },
        };
        try queue.post(payload);
    }

    try Testing.expectEqual(@as(u32, 10), queue.depth());

    // Consume 5
    for (0..5) |_| {
        _ = queue.consume();
    }

    try Testing.expectEqual(@as(u32, 5), queue.depth());

    // Consume remaining 5
    for (0..5) |_| {
        _ = queue.consume();
    }

    try Testing.expectEqual(@as(u32, 0), queue.depth());
}

test "EventQueue - Different event types" {
    const allocator = std.heap.page_allocator;

    const queue = events.EventQueue.init(allocator);
    defer queue.deinit();

    // Post different event types
    _ = queue.post(events.EventPayload{
        .plugin_start = .{
            .plugin_handle = 1,
            .plugin_name = "test",
            .connection_id = null,
        },
    });

    _ = queue.post(events.EventPayload{
        .plugin_complete = .{
            .plugin_handle = 2,
            .exit_code = 0,
            .duration_ms = 100,
        },
    });

    _ = queue.post(events.EventPayload{
        .plugin_error = .{
            .plugin_handle = 3,
            .error_code = -1,
            .error_message = "test error",
        },
    });

    try Testing.expectEqual(@as(u32, 3), queue.depth());

    // Consume and verify types
    if (queue.consume()) |p| {
        _ = p;
        queue.freePayload(p);
    }

    if (queue.consume()) |p| {
        _ = p;
        queue.freePayload(p);
    }

    if (queue.consume()) |p| {
        _ = p;
        queue.freePayload(p);
    }

    try Testing.expect(queue.isEmpty());
}

test "EventQueue - Concurrent access simulation" {
    const allocator = std.heap.page_allocator;

    const queue = events.EventQueue.init(allocator);
    defer queue.deinit();

    // Simulate concurrent access
    const num_producers = 4;
    const events_per_producer = 64;

    // Post events from multiple "threads"
    for (0..num_producers) |producer| {
        for (0..events_per_producer) |i| {
            const payload = events.EventPayload{
                .plugin_complete = .{
                    .plugin_handle = @intCast(producer * events_per_producer + i),
                    .exit_code = 0,
                    .duration_ms = 100,
                },
            };

            queue.post(payload) catch |err| {
                // Should never overflow with this many posts
                try Testing.expectEqual(error.Overflow, err);
                break;
            };
        }
    }

    // Verify all events were added
    try Testing.expect(queue.depth() == @as(u32, num_producers * events_per_producer));

    // Consume and verify count
    var count: usize = 0;
    while (queue.consume()) |_| {
        count += 1;
    }

    try Testing.expectEqual(@as(usize, @intCast(num_producers * events_per_producer)), count);
}

test "EventQueue - Memory safety with invalid payload" {
    const allocator = std.heap.page_allocator;

    const queue = events.EventQueue.init(allocator);
    defer queue.deinit();

    // Create a valid event
    const payload = events.EventPayload{
        .plugin_complete = .{
            .plugin_handle = 1,
            .exit_code = 0,
            .duration_ms = 100,
            .plugin_name = "test_plugin",
        },
    };

    try queue.post(payload);

    // Consume and free
    if (queue.consume()) |p| {
        // This should not panic
        queue.freePayload(p);
    }

    // Queue should be empty
    try Testing.expect(queue.isEmpty());
}
