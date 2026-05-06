const std = @import("std");
const net = std.net;
const posix = std.posix;
const logging = @import("logging");

/// NATS Client for wasi-host
/// Supports basic pub/sub operations over TCP
pub const NatsClient = struct {
    stream: net.Stream,
    allocator: std.mem.Allocator,
    running: bool,
    logger: ?*logging.Logger = null,
    subscriptions: std.StringHashMap(SubscriptionHandler),
    mutex: std.Thread.Mutex = .{},

    const SubscriptionHandler = struct {
        callback: *const fn (msg: []const u8) void,
        queue_group: ?[]const u8 = null,
    };

    /// Connect to NATS server
    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !NatsClient {
        const addr = try net.Address.parseIp(host, port);
        const stream = try net.tcpConnectToAddress(addr);

        var client = NatsClient{
            .stream = stream,
            .allocator = allocator,
            .running = true,
            .subscriptions = std.StringHashMap(SubscriptionHandler).init(allocator),
        };

        // Send CONNECT message
        try client.sendConnect();

        return client;
    }

    /// Set logger for the client
    pub fn setLogger(self: *NatsClient, logger: ?*logging.Logger) void {
        self.logger = logger;
    }

    /// Send CONNECT message to NATS server
    fn sendConnect(self: *NatsClient) !void {
        const connect_msg =
            \\CONNECT {"verbose":false,"pedantic":false,"tls_required":false,"name":"wasi-host","lang":"zig","version":"1.0.0"}
            \\
        ;
        _ = try self.stream.write(connect_msg);
    }

    /// Publish message to subject
    pub fn publish(self: *NatsClient, subject: []const u8, payload: []const u8) !void {
        const msg = try std.fmt.allocPrint(self.allocator, "PUB {s} {d}\r\n{d}\r\n{s}\r\n", .{
            subject, payload.len, payload.len, payload,
        });
        defer self.allocator.free(msg);

        _ = try self.stream.write(msg);

        if (self.logger) |l| {
            l.info("[nats] Published to {s}: {d} bytes", .{ subject, payload.len });
        }
    }

    /// Subscribe to subject with callback
    pub fn subscribe(self: *NatsClient, subject: []const u8, callback: *const fn (msg: []const u8) void) !void {
        const sub_msg = try std.fmt.allocPrint(self.allocator, "SUB {s} {d}\r\n", .{ subject, 1 });
        defer self.allocator.free(sub_msg);

        _ = try self.stream.write(sub_msg);

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.subscriptions.put(subject, .{ .callback = callback });

        if (self.logger) |l| {
            l.info("[nats] Subscribed to {s}", .{ subject });
        }
    }

    /// Subscribe with queue group
    pub fn subscribeQueue(self: *NatsClient, subject: []const u8, queue_group: []const u8, callback: *const fn (msg: []const u8) void) !void {
        const sub_msg = try std.fmt.allocPrint(self.allocator, "SUB {s} {s} {d}\r\n", .{ subject, queue_group, 1 });
        defer self.allocator.free(sub_msg);

        _ = try self.stream.write(sub_msg);

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.subscriptions.put(subject, .{ .callback = callback, .queue_group = queue_group });

        if (self.logger) |l| {
            l.info("[nats] Subscribed to {s} with queue {s}", .{ subject, queue_group });
        }
    }

    /// Unsubscribe from subject
    pub fn unsubscribe(self: *NatsClient, subject: []const u8) !void {
        const unsub_msg = try std.fmt.allocPrint(self.allocator, "UNSUB {s}\r\n", .{ subject });
        defer self.allocator.free(unsub_msg);

        _ = try self.stream.write(unsub_msg);

        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.subscriptions.remove(subject);

        if (self.logger) |l| {
            l.info("[nats] Unsubscribed from {s}", .{ subject });
        }
    }

    /// Request-reply pattern
    pub fn request(self: *NatsClient, subject: []const u8, payload: []const u8, timeout_ms: u64) ![]const u8 {
        const reply_subject = try std.fmt.allocPrint(self.allocator, "_INBOX.{d}", .{ std.time.milliTimestamp() });
        defer self.allocator.free(reply_subject);

        var response: ?[]const u8 = null;
        var response_mutex = std.Thread.Mutex{};
        var response_cond = std.Thread.Condition{};

        const reply_handler = struct {
            fn handle(msg: []const u8) void {
                response_mutex.lock();
                defer response_mutex.unlock();
                response = msg;
                response_cond.signal();
            }
        };

        try self.subscribe(reply_subject, reply_handler.handle);
        defer self.unsubscribe(reply_subject) catch {};

        try self.publish(subject, payload);

        self.mutex.lock();
        defer self.mutex.unlock();

        const start_time = std.time.milliTimestamp();
        while (response == null) {
            const elapsed = std.time.milliTimestamp() - start_time;
            if (elapsed > timeout_ms) {
                return error.Timeout;
            }
            std.time.sleep(10_000_000); // 10ms
        }

        return response.?;
    }

    /// Start message processing loop (run in separate thread)
    pub fn startLoop(self: *NatsClient) void {
        var buffer: [65536]u8 = undefined;
        while (self.running) {
            const n = self.stream.read(&buffer) catch |err| {
                if (err == error.ConnectionResetByPeer or err == error.EndOfStream) {
                    if (self.logger) |l| {
                        l.err("[nats] Connection lost", .{});
                    }
                    break;
                }
                continue;
            };

            if (n == 0) continue;

            self.processMessage(buffer[0..n]);
        }
    }

    /// Process incoming NATS message
    fn processMessage(self: *NatsClient, data: []const u8) void {
        // Simple MSG parsing: "MSG subject sid bytes\r\npayload\r\n"
        var lines = std.mem.split(u8, data, "\r\n");
        const header = lines.next() orelse return;

        if (std.mem.startsWith(u8, header, "MSG ")) {
            var parts = std.mem.split(u8, header[4..], " ");
            const subject = parts.next() orelse return;
            const _sid = parts.next(); // subscription ID (ignore)
            const _bytes_str = parts.next(); // payload length (ignore)

            if (lines.next()) |payload| {
                self.mutex.lock();
                const handler = self.subscriptions.get(subject);
                self.mutex.unlock();

                if (handler) |h| {
                    h.callback(payload);
                }
            }
        }
    }

    /// Close connection
    pub fn close(self: *NatsClient) void {
        self.running = false;
        self.stream.close();
        self.subscriptions.deinit();

        if (self.logger) |l| {
            l.info("[nats] Connection closed", .{});
        }
    }
};

/// NATS message structure
pub const NatsMessage = struct {
    subject: []const u8,
    payload: []const u8,
    reply_to: ?[]const u8 = null,

    pub fn deinit(self: *NatsMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.subject);
        allocator.free(self.payload);
        if (self.reply_to) |rt| {
            allocator.free(rt);
        }
    }
};
