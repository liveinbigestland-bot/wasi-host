const std = @import("std");

pub const EventType = enum(u8) {
    plugin_start,
    plugin_stop,
    plugin_error,
    plugin_complete,
    plugin_timeout,
    chord_node_join,
    chord_successor_change,
    dht_put,
};

pub const EventPayload = union(EventType) {
    plugin_start: PluginStartEvent,
    plugin_stop: PluginStopEvent,
    plugin_error: PluginErrorEvent,
    plugin_complete: PluginCompleteEvent,
    plugin_timeout: PluginTimeoutEvent,
    chord_node_join: ChordNodeJoinEvent,
    chord_successor_change: ChordSuccessorChangeEvent,
    dht_put: DhtPutEvent,
};

pub const PluginStartEvent = struct {
    plugin_handle: u64,
    plugin_name: []const u8,
    connection_id: ?u64,
};

pub const PluginStopEvent = struct {
    plugin_handle: u64,
    exit_code: i32,
};

pub const PluginErrorEvent = struct {
    plugin_handle: u64,
    error_code: i32,
    error_message: []const u8,
};

pub const PluginCompleteEvent = struct {
    plugin_handle: u64,
    exit_code: i32,
    duration_ms: u64,
};

pub const PluginTimeoutEvent = struct {
    plugin_handle: u64,
    timeout_ms: u32,
};

pub const ChordNodeJoinEvent = struct {
    node_id: [20]u8,
    host: []const u8,
    port: u16,
};

pub const ChordSuccessorChangeEvent = struct {
    old_successor_id: [20]u8,
    new_successor_id: [20]u8,
};

pub const DhtPutEvent = struct {
    key: []const u8,
    value_size: usize,
};

/// Lock-free MPMC event queue for WASM-Lua communication
/// Uses atomic operations for thread-safe access without mutexes
pub const EventQueue = struct {
    const Capacity = 256;
    const Event = struct {
        payload: EventPayload,
        allocated: bool,
    };

    buffer: [Capacity]Event align(128),
    head: std.atomic.Value(u32),
    tail: std.atomic.Value(u32),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        var buffer: [Capacity]Event align(128) = undefined;
        for (&buffer, 0..) |*e, i| {
            e.* = Event{
                .payload = undefined,
                .allocated = false,
            };
        }

        return Self{
            .buffer = buffer,
            .head = std.atomic.Value(u32).init(0),
            .tail = std.atomic.Value(u32).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Static buffer, no cleanup needed
    }

    /// Post an event from any thread (producer)
    /// Returns error.Overflow if queue is full
    pub fn post(self: *Self, payload: EventPayload) !void {
        // Clone string fields to heap for thread safety
        const cloned = try self.clonePayload(payload);

        // Get tail position
        const tail = self.tail.load(.acquire);

        // Find next available slot
        var attempts: u32 = 0;
        while (attempts < Capacity * 2) {
            const idx = tail % Capacity;
            const slot = &self.buffer[idx];

            // Try to claim slot
            if (!slot.allocated and @cmpxchgStrong(bool, &slot.allocated, false, true, .acquire, .acquire) == null) {
                // Successfully claimed slot
                slot.payload = cloned;
                self.tail.store(tail + 1, .release);
                return;
            }
            attempts += 1;
            std.atomic.thread_fence(.acquire);
        }

        // Cleanup and return overflow error
        self.freePayload(cloned);
        return error.Overflow;
    }

    /// Consume next event from queue (consumer)
    /// Returns null if queue is empty
    pub fn consume(self: *Self) ?EventPayload {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);

        if (head >= tail) {
            return null; // Queue is empty
        }

        const idx = head % Capacity;
        const slot = &self.buffer[idx];

        if (!slot.allocated) {
            return null; // Slot not ready yet
        }

        // Take ownership of payload
        const payload = slot.payload;
        slot.allocated = false;
        self.head.store(head + 1, .release);

        return payload;
    }

    /// Check if queue is empty
    pub fn isEmpty(self: *Self) bool {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        return head >= tail;
    }

    /// Get current queue depth
    pub fn depth(self: *Self) u32 {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        if (tail > head) return tail - head;
        return 0;
    }

    /// Clone payload with heap-allocated strings
    fn clonePayload(self: *Self, payload: EventPayload) !EventPayload {
        return switch (payload) {
            .plugin_start => |e| EventPayload{
                .plugin_start = .{
                    .plugin_handle = e.plugin_handle,
                    .plugin_name = try self.allocator.dupe(u8, e.plugin_name),
                    .connection_id = e.connection_id,
                },
            },
            .plugin_error => |e| EventPayload{
                .plugin_error = .{
                    .plugin_handle = e.plugin_handle,
                    .error_code = e.error_code,
                    .error_message = try self.allocator.dupe(u8, e.error_message),
                },
            },
            .plugin_complete => |e| EventPayload{ .plugin_complete = e },
            .plugin_timeout => |e| EventPayload{ .plugin_timeout = e },
            .plugin_stop => |e| EventPayload{ .plugin_stop = e },
            .chord_node_join => |e| EventPayload{
                .chord_node_join = .{
                    .node_id = e.node_id,
                    .host = try self.allocator.dupe(u8, e.host),
                    .port = e.port,
                },
            },
            .chord_successor_change => |e| EventPayload{ .chord_successor_change = e },
            .dht_put => |e| EventPayload{
                .dht_put = .{
                    .key = try self.allocator.dupe(u8, e.key),
                    .value_size = e.value_size,
                },
            },
        };
    }

    /// Free heap-allocated strings in payload
    fn freePayload(self: *Self, payload: EventPayload) void {
        switch (payload) {
            .plugin_start => |e| {
                self.allocator.free(e.plugin_name);
            },
            .plugin_error => |e| {
                self.allocator.free(e.error_message);
            },
            .chord_node_join => |e| {
                self.allocator.free(e.host);
            },
            .dht_put => |e| {
                self.allocator.free(e.key);
            },
            else => {},
        }
    }

    /// Process and free all pending events
    pub fn drain(self: *Self, comptime callback: fn (EventPayload) void) void {
        while (self.consume()) |payload| {
            callback(payload);
            self.freePayload(payload);
        }
    }
};
