/// 事件驱动 TCP Relay — 非阻塞 + EventLoop
///
/// 协议格式与 relay.zig 完全兼容：
///   [0x00][len: u8]["host:port"]     — 注册 (Client→Server)
///   [0x01][target_ip 4BE][target_port 2BE][seq 4LE][payload_len 4BE][payload]  — 请求 (Client→Server)
///   [0x02][req_id 4LE][payload_len 4BE][payload]  — 响应 (Client→Server)
///   [0x03][req_id 4LE][payload_len 4BE][payload]  — 转发 (Server→Client)
///   [0x04][seq 4LE][payload_len 4BE][payload]  — 回复 (Server→Client)
///   [0x05][conn_id 4LE][host_len 1][host][port 2BE] — TCP 隧道连接请求
///   [0x06][conn_id 4LE][data_len 4BE][data] — TCP 隧道数据
///   [0x07][conn_id 4LE] — TCP 隧道关闭
///   [0x08] — PING 心跳
///   [0x09] — PONG 心跳回复
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const event_loop = @import("event_loop.zig");
const EventLoop = event_loop.EventLoop;
const HandlerVTable = event_loop.HandlerVTable;

const FRAME_REGISTER: u8 = 0;
const FRAME_REQUEST: u8 = 1;
const FRAME_RESPONSE: u8 = 2;
const FRAME_FORWARD: u8 = 3;
const FRAME_REPLY: u8 = 4;
const FRAME_TCP_CONNECT: u8 = 5;
const FRAME_TCP_DATA: u8 = 6;
const FRAME_TCP_CLOSE: u8 = 7;
const FRAME_PING: u8 = 8;
const FRAME_PONG: u8 = 9;

const BUF_SIZE = 65536;

// ── 辅助函数 ──

fn closeSocket(fd: posix.socket_t) void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ws2_32.closesocket(fd);
        return;
    }
    if (fd < 0) return;
    _ = posix.system.close(fd);
}

/// 写完整 buf 到 fd（非阻塞，可能部分写入）
fn writeAll(fd: posix.socket_t, buf: []const u8) !usize {
    var off: usize = 0;
    while (off < buf.len) {
        const n = posix.write(fd, buf[off..]) catch |err| {
            if (err == error.WouldBlock) return off;
            return err;
        };
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
    return off;
}

/// 增量帧解析 — 纯函数
fn tryCompleteFrame(buf: []const u8) ?usize {
    if (buf.len == 0) return null;
    const frame_type = buf[0];
    const total = switch (frame_type) {
        FRAME_REGISTER => blk: {
            if (buf.len < 2) return null;
            break :blk @as(usize, 2) + buf[1];
        },
        FRAME_REQUEST => blk: {
            const header = 1 + 4 + 2 + 4 + 4;
            if (buf.len < header) return null;
            const payload_len = std.mem.readInt(u32, buf[header - 4 ..][0..4], .big);
            break :blk header + payload_len;
        },
        FRAME_RESPONSE, FRAME_FORWARD, FRAME_REPLY => blk: {
            const header = 1 + 4 + 4;
            if (buf.len < header) return null;
            const payload_len = std.mem.readInt(u32, buf[header - 4 ..][0..4], .big);
            break :blk header + payload_len;
        },
        FRAME_TCP_CONNECT => blk: {
            const header = 1 + 4 + 1;
            if (buf.len < header) return null;
            break :blk header + buf[header - 1] + 2;
        },
        FRAME_TCP_DATA => blk: {
            const header = 1 + 4 + 4;
            if (buf.len < header) return null;
            const data_len = std.mem.readInt(u32, buf[header - 4 ..][0..4], .big);
            break :blk header + data_len;
        },
        FRAME_TCP_CLOSE => 1 + 4,
        FRAME_PING, FRAME_PONG => 1,
        else => return null,
    };
    if (buf.len >= total) return total;
    return null;
}

// ── 速率限制器 ──

const RateLimiter = struct {
    alloc: std.mem.Allocator,
    max_connections: u32,
    max_per_user: u32,

    active_connections: u32,
    user_connections: std.StringHashMap(u32),
    mutex: std.Thread.Mutex = .{},

    pub fn init(alloc: std.mem.Allocator, max_connections: u32, max_per_user: u32) RateLimiter {
        return RateLimiter{
            .alloc = alloc,
            .max_connections = max_connections,
            .max_per_user = max_per_user,
            .active_connections = 0,
            .user_connections = std.StringHashMap(u32).init(alloc),
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.user_connections.deinit();
    }

    pub fn acquire(self: *RateLimiter, user_key: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.max_connections > 0 and self.active_connections >= self.max_connections)
            return "超过最大连接数限制";
        if (self.max_per_user > 0) {
            const count = self.user_connections.get(user_key) orelse 0;
            if (count >= self.max_per_user)
                return "超过每用户连接数限制";
            self.user_connections.put(user_key, count + 1) catch {};
        }
        self.active_connections += 1;
        return null;
    }

    pub fn release(self: *RateLimiter, user_key: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active_connections > 0) self.active_connections -= 1;
        if (self.max_per_user > 0) {
            if (self.user_connections.get(user_key)) |count| {
                if (count <= 1) {
                    _ = self.user_connections.remove(user_key);
                } else {
                    self.user_connections.put(user_key, count - 1) catch {};
                }
            }
        }
    }
};

// ── 连接状态机：每个已接受的 TCP 连接 ──

const ConnectionState = enum {
    waiting_register,
    active,
};

const Connection = struct {
    fd: posix.socket_t,
    addr: std.net.Address,
    node_key: []u8,
};

const ClientHandler = struct {
    server: *RelayServer,
    fd: posix.socket_t,
    state: ConnectionState,
    addr: std.net.Address,
    node_key: []u8, // valid after waiting_register → active
    conn: ?*Connection, // valid after waiting_register → active
    user_key_buf: [48]u8,
    user_key_len: usize,

    /// 读缓冲
    read_buf: [BUF_SIZE]u8,
    read_len: usize,

    /// 写缓冲（非阻塞 write 写不完时缓存）
    write_buf: [BUF_SIZE]u8,
    write_len: usize,
    write_sent: usize,
};

// ── TCP 隧道状态机 ──

const TunnelHandler = struct {
    server: *RelayServer,
    conn_id: u32,
    target_fd: posix.socket_t,
    relay_fd: posix.socket_t,
    node_key: []const u8,
};

// ── RelayServer ──

const PendingEntry = struct {
    requester_key: []const u8,
    original_seq: u32,
};

pub const RelayServer = struct {
    alloc: std.mem.Allocator,
    loop: EventLoop,
    listen_fd: posix.socket_t,
    port: u16,
    routing: std.StringHashMap(*Connection),
    pending: std.AutoHashMap(u32, PendingEntry),
    /// fd → ClientHandler 映射（用于路由查找写缓冲）
    handlers: std.AutoHashMap(posix.socket_t, *ClientHandler),
    tcp_tunnels: std.AutoHashMap(u32, *TunnelHandler),
    next_req_id: u32,
    running: bool,
    limiter: RateLimiter,
    upstream_client: ?*anyopaque = null,
    mutex: std.Thread.Mutex = .{},

    // 为了让 ClientHandler 和 TunnelHandler 能找到 vtable，存在 server 上
    client_vtbl: HandlerVTable,
    tunnel_vtbl: HandlerVTable,
    accept_vtbl: HandlerVTable,

    pub fn init(alloc: std.mem.Allocator, listen_host: []const u8, port: u16, max_connections: u32, max_per_user: u32, _: u32) !RelayServer {
        const listen_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer closeSocket(listen_fd);

        const reuse: u32 = 1;
        _ = posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(reuse)) catch {};

        const addr = try std.net.Address.parseIp(listen_host, port);
        try posix.bind(listen_fd, &addr.any, addr.getOsSockLen());
        try posix.listen(listen_fd, 128);

        // 设为非阻塞（用于 accept）
        event_loop.setNonblocking(listen_fd) catch {};

        var server = RelayServer{
            .alloc = alloc,
            .loop = EventLoop.init(alloc),
            .listen_fd = listen_fd,
            .port = port,
            .routing = std.StringHashMap(*Connection).init(alloc),
            .pending = std.AutoHashMap(u32, PendingEntry).init(alloc),
            .handlers = std.AutoHashMap(posix.socket_t, *ClientHandler).init(alloc),
            .tcp_tunnels = std.AutoHashMap(u32, *TunnelHandler).init(alloc),
            .next_req_id = 1,
            .running = false,
            .limiter = RateLimiter.init(alloc, max_connections, max_per_user),
            .client_vtbl = undefined,
            .tunnel_vtbl = undefined,
            .accept_vtbl = undefined,
        };

        // 初始化 vtable
        server.accept_vtbl = HandlerVTable{ .onReadable = onAcceptReadable, .onTimer = onHeartbeatTimer };
        server.client_vtbl = HandlerVTable{ .onReadable = clientOnReadable, .onWritable = clientOnWritable, .onHup = clientOnHup };
        server.tunnel_vtbl = HandlerVTable{ .onReadable = tunnelOnReadable, .onHup = tunnelOnHup };

        return server;
    }

    pub fn stop(self: *RelayServer) void {
        self.running = false;
        self.loop.stop();
        closeSocket(self.listen_fd);
    }

    pub fn deinit(self: *RelayServer) void {
        self.routing.deinit();
        self.pending.deinit();
        self.handlers.deinit();
        self.tcp_tunnels.deinit();
        self.limiter.deinit();
        self.loop.deinit();
    }

    pub fn run(self: *RelayServer) void {
        self.running = true;
        std.debug.print("[relay/v2] TCP relay server 已启动 :{d}\n", .{self.port});

        // 注册 listen fd
        self.loop.addFd(self.listen_fd, posix.POLL.IN, self, &self.accept_vtbl);

        // 心跳定时器（每 5s 检查）
        self.loop.addTimer(5000, self, &self.accept_vtbl);

        self.loop.run();
        std.debug.print("[relay/v2] 事件循环退出\n", .{});
    }

    // ── Accept 回调 ──

    fn onAcceptReadable(ctx: *anyopaque, fd: posix.socket_t, loop: *EventLoop) void {
        _ = loop;
        const self = @as(*RelayServer, @ptrCast(@alignCast(ctx)));
        while (self.running) {
            var client_addr: std.net.Address = undefined;
            var addr_len: posix.socklen_t = @sizeOf(std.net.Address);
            const client_fd = posix.accept(fd, &client_addr.any, &addr_len, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch |err| {
                if (err == error.WouldBlock) break;
                if (self.running) {
                    std.debug.print("[relay/v2] accept 错误: {}\n", .{err});
                }
                break;
            };
            self.startClient(client_fd, client_addr);
        }
    }

    fn startClient(self: *RelayServer, fd: posix.socket_t, addr: std.net.Address) void {
        const handler = self.alloc.create(ClientHandler) catch {
            closeSocket(fd);
            return;
        };
        handler.* = ClientHandler{
            .server = self,
            .fd = fd,
            .state = .waiting_register,
            .addr = addr,
            .node_key = "",
            .conn = null,
            .user_key_buf = undefined,
            .user_key_len = 0,
            .read_buf = undefined,
            .read_len = 0,
            .write_buf = undefined,
            .write_len = 0,
            .write_sent = 0,
        };
        // user_key
        const user_key = std.fmt.bufPrint(&handler.user_key_buf, "{}", .{addr}) catch "unknown";
        handler.user_key_len = user_key.len;

        // 速率限制检查
        if (self.limiter.acquire(user_key)) |reason| {
            std.debug.print("[relay/v2] 拒绝连接 (来自 {}): {s}\n", .{ addr, reason });
            self.alloc.destroy(handler);
            closeSocket(fd);
            return;
        }

        self.loop.addFd(fd, posix.POLL.IN, handler, &self.client_vtbl);
        self.handlers.put(fd, handler) catch {};
    }

    // ── ClientHandler 回调 ──

    fn clientOnReadable(ctx: *anyopaque, fd: posix.socket_t, loop: *EventLoop) void {
        const handler = @as(*ClientHandler, @ptrCast(@alignCast(ctx)));
        const self = handler.server;

        // 读入数据
        const space = handler.read_buf[handler.read_len..];
        const n = posix.read(fd, space) catch |err| {
            if (err == error.WouldBlock) return;
            if (err == error.ConnectionClosed or err == error.ConnectionResetByPeer) {
                clientCleanup(handler, loop);
                return;
            }
            std.debug.print("[relay/v2] 读取错误: {}\n", .{err});
            clientCleanup(handler, loop);
            return;
        };
        if (n == 0) {
            clientCleanup(handler, loop);
            return;
        }
        handler.read_len += n;

        // 循环处理所有已完整的帧
        while (tryCompleteFrame(handler.read_buf[0..handler.read_len])) |frame_len| {
            const frame = handler.read_buf[0..frame_len];
            // 移除已处理的帧数据（移动剩余数据到开头）
            const remaining = handler.read_len - frame_len;
            if (remaining > 0) {
                std.mem.copyForwards(u8, handler.read_buf[0..remaining], handler.read_buf[frame_len..][0..remaining]);
            }
            handler.read_len = remaining;

            switch (handler.state) {
                .waiting_register => {
                    if (frame[0] != FRAME_REGISTER) {
                        std.debug.print("[relay/v2] 期望注册帧, 收到 type={}\n", .{frame[0]});
                        clientCleanup(handler, loop);
                        return;
                    }
                    const node_key = self.alloc.dupe(u8, frame[2..frame_len]) catch {
                        clientCleanup(handler, loop);
                        return;
                    };
                    handler.node_key = node_key;

                    const conn = self.alloc.create(Connection) catch {
                        self.alloc.free(node_key);
                        clientCleanup(handler, loop);
                        return;
                    };
                    conn.* = .{ .fd = fd, .addr = handler.addr, .node_key = node_key };
                    handler.conn = conn;

                    {
                        self.mutex.lock();
                        defer self.mutex.unlock();
                        if (self.routing.get(node_key)) |old_conn| {
                            closeSocket(old_conn.fd);
                        }
                        self.routing.put(node_key, conn) catch {};
                    }

                    handler.state = .active;
                    std.debug.print("[relay/v2] 节点已注册: {s} ({})\n", .{ node_key, handler.addr });
                },
                .active => {
                    self.handleFrame(handler, frame);
                },
            }
        }
    }

    fn clientOnWritable(ctx: *anyopaque, fd: posix.socket_t, loop: *EventLoop) void {
        const handler = @as(*ClientHandler, @ptrCast(@alignCast(ctx)));
        flushWriteBuffer(handler, fd, loop);
    }

    fn clientOnHup(ctx: *anyopaque, fd: posix.socket_t, loop: *EventLoop) void {
        _ = fd;
        const handler = @as(*ClientHandler, @ptrCast(@alignCast(ctx)));
        clientCleanup(handler, loop);
    }

    fn clientCleanup(handler: *ClientHandler, loop: *EventLoop) void {
        const self = handler.server;
        loop.removeFd(handler.fd);
        _ = self.handlers.remove(handler.fd);
        closeSocket(handler.fd);

        // 只移除本 handler 的 routing 条目
        if (handler.conn) |conn| {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.routing.get(handler.node_key)) |current| {
                if (current == conn) {
                    _ = self.routing.remove(handler.node_key);
                }
            }
            self.alloc.free(conn.node_key);
            self.alloc.destroy(conn);
        }
        if (handler.node_key.len > 0) {
            self.alloc.free(handler.node_key);
        }
        const user_key = handler.user_key_buf[0..handler.user_key_len];
        self.limiter.release(user_key);
        self.alloc.destroy(handler);
    }

    // ── 写缓冲 ──

    /// 尝试写入数据，如果套接字阻塞则缓冲
    fn writeOrBuffer(handler: *ClientHandler, data: []const u8, loop: *EventLoop) void {
        // 如果已有未写完的缓冲数据，追加到缓冲
        if (handler.write_len > handler.write_sent) {
            if (handler.write_len + data.len > handler.write_buf.len) {
                std.debug.print("[relay/v2] 写缓冲满, 断开\n", .{});
                clientCleanup(handler, loop);
                return;
            }
            @memcpy(handler.write_buf[handler.write_len..][0..data.len], data);
            handler.write_len += data.len;
            return;
        }

        // 尝试直接写入
        const n = posix.write(handler.fd, data) catch |err| {
            if (err == error.WouldBlock) {
                // 缓冲
                if (data.len > handler.write_buf.len) {
                    clientCleanup(handler, loop);
                    return;
                }
                @memcpy(handler.write_buf[0..data.len], data);
                handler.write_len = data.len;
                handler.write_sent = 0;
                loop.modFd(handler.fd, posix.POLL.IN | posix.POLL.OUT);
                return;
            }
            clientCleanup(handler, loop);
            return;
        };
        if (n < data.len) {
            // 部分写入，缓冲剩余
            const remaining = data[n..];
            if (remaining.len > handler.write_buf.len) {
                clientCleanup(handler, loop);
                return;
            }
            @memcpy(handler.write_buf[0..remaining.len], remaining);
            handler.write_len = remaining.len;
            handler.write_sent = 0;
            loop.modFd(handler.fd, posix.POLL.IN | posix.POLL.OUT);
        }
    }

    fn flushWriteBuffer(handler: *ClientHandler, fd: posix.socket_t, loop: *EventLoop) void {
        const data = handler.write_buf[handler.write_sent..handler.write_len];
        if (data.len == 0) {
            handler.write_len = 0;
            handler.write_sent = 0;
            loop.modFd(fd, posix.POLL.IN);
            return;
        }
        const n = posix.write(fd, data) catch |err| {
            if (err == error.WouldBlock) return;
            clientCleanup(handler, loop);
            return;
        };
        handler.write_sent += n;
        if (handler.write_sent >= handler.write_len) {
            handler.write_len = 0;
            handler.write_sent = 0;
            loop.modFd(fd, posix.POLL.IN);
        }
    }

    // ── 帧处理 ──

    fn handleFrame(self: *RelayServer, handler: *ClientHandler, frame: []const u8) void {
        switch (frame[0]) {
            FRAME_REQUEST => {
                const target_ip = std.mem.readInt(u32, frame[1..5], .big);
                const target_port = std.mem.readInt(u16, frame[5..7], .big);
                const seq = std.mem.readInt(u32, frame[7..11], .little);
                const payload_len = std.mem.readInt(u32, frame[11..15], .big);
                const payload = frame[15..][0..payload_len];
                self.routeRequest(handler, target_ip, target_port, seq, payload);
            },
            FRAME_RESPONSE => {
                const req_id = std.mem.readInt(u32, frame[1..5], .little);
                const payload_len = std.mem.readInt(u32, frame[5..9], .big);
                const payload = frame[9..][0..payload_len];
                self.routeResponse(req_id, payload);
            },
            FRAME_TCP_CONNECT => {
                const conn_id = std.mem.readInt(u32, frame[1..5], .little);
                const host_len = frame[5];
                const host = frame[6..][0..host_len];
                const port = std.mem.readInt(u16, frame[6 + host_len ..][0..2], .big);
                self.handleTcpConnect(handler, conn_id, host, port);
            },
            FRAME_TCP_DATA => {
                const conn_id = std.mem.readInt(u32, frame[1..5], .little);
                const data_len = std.mem.readInt(u32, frame[5..9], .big);
                const data = frame[9..][0..data_len];
                self.handleTcpData(conn_id, data);
            },
            FRAME_TCP_CLOSE => {
                const conn_id = std.mem.readInt(u32, frame[1..5], .little);
                self.handleTcpClose(conn_id);
            },
            FRAME_PING => {
                const pong: [1]u8 = .{FRAME_PONG};
                writeOrBuffer(handler, &pong, &self.loop);
            },
            FRAME_PONG => {},
            else => {
                std.debug.print("[relay/v2] 未知帧类型 {} 来自 {s}\n", .{ frame[0], handler.node_key });
                clientCleanup(handler, &self.loop);
            },
        }
    }

    fn routeRequest(self: *RelayServer, handler: *ClientHandler, target_ip: u32, target_port: u16, seq: u32, payload: []const u8) void {
        var ip_bytes: [4]u8 = undefined;
        const native_ip = std.mem.bigToNative(u32, target_ip);
        @memcpy(&ip_bytes, std.mem.asBytes(&native_ip));
        var key_buf: [60]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{d}.{d}.{d}.{d}:{d}", .{
            ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3], target_port,
        }) catch {
            std.debug.print("[relay/v2] ROUTEKEY_FAIL\n", .{});
            return;
        };

        const target_conn = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.routing.get(key);
        };

        if (target_conn) |conn| {
            const req_id = @atomicRmw(u32, &self.next_req_id, .Add, 1, .monotonic);
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.pending.put(req_id, .{ .requester_key = handler.node_key, .original_seq = seq }) catch {};
            }

            // 查找目标 handler
            const target_handler = self.findHandlerByFd(conn.fd);
            if (target_handler) |th| {
                var fwd_buf: [BUF_SIZE]u8 = undefined;
                fwd_buf[0] = FRAME_FORWARD;
                std.mem.writeInt(u32, fwd_buf[1..5], req_id, .little);
                std.mem.writeInt(u32, fwd_buf[5..9], @as(u32, @intCast(payload.len)), .big);
                if (payload.len > 0) @memcpy(fwd_buf[9..][0..payload.len], payload);
                writeOrBuffer(th, fwd_buf[0 .. 9 + payload.len], &self.loop);
            } else {
                self.mutex.lock();
                defer self.mutex.unlock();
                _ = self.pending.remove(req_id);
            }
        } else {
            std.debug.print("[relay/v2] 目标未注册: {s}\n", .{key});
        }
    }

    fn findHandlerByFd(self: *RelayServer, fd: posix.socket_t) ?*ClientHandler {
        return self.handlers.get(fd);
    }

    fn routeResponse(self: *RelayServer, req_id: u32, payload: []const u8) void {
        const requester_key = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const entry = self.pending.get(req_id) orelse return;
            const key = self.alloc.dupe(u8, entry.requester_key) catch return;
            _ = self.pending.remove(req_id);
            break :blk .{ .key = key, .original_seq = entry.original_seq };
        };
        defer self.alloc.free(requester_key.key);

        const requester_conn = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.routing.get(requester_key.key) orelse return;
        };

        const requester_handler = self.findHandlerByFd(requester_conn.fd) orelse return;
        var reply_buf: [BUF_SIZE]u8 = undefined;
        reply_buf[0] = FRAME_REPLY;
        std.mem.writeInt(u32, reply_buf[1..5], requester_key.original_seq, .little);
        std.mem.writeInt(u32, reply_buf[5..9], @as(u32, @intCast(payload.len)), .big);
        if (payload.len > 0) @memcpy(reply_buf[9..][0..payload.len], payload);
        writeOrBuffer(requester_handler, reply_buf[0 .. 9 + payload.len], &self.loop);
    }

    fn handleTcpConnect(self: *RelayServer, handler: *ClientHandler, conn_id: u32, host: []const u8, port: u16) void {
        const addr_list = std.net.getAddressList(self.alloc, host, port) catch |err| {
            std.debug.print("[relay/v2/tcp] DNS 解析失败 {s}:{d}: {}\n", .{ host, port, err });
            return;
        };
        defer addr_list.deinit();

        if (addr_list.addrs.len == 0) return;

        const target_fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch |err| {
            std.debug.print("[relay/v2/tcp] 创建 socket 失败: {}\n", .{err});
            return;
        };
        errdefer closeSocket(target_fd);

        var connected = false;
        for (addr_list.addrs) |addr| {
            if (addr.any.family != posix.AF.INET) continue;
            posix.connect(target_fd, &addr.any, addr.getOsSockLen()) catch |err| {
                std.debug.print("[relay/v2/tcp] 连接地址 {} 失败: {}\n", .{ addr, err });
                continue;
            };
            connected = true;
            break;
        }
        if (!connected) return;

        event_loop.setNonblocking(target_fd) catch {};

        const tunnel = self.alloc.create(TunnelHandler) catch return;
        tunnel.* = TunnelHandler{
            .server = self,
            .conn_id = conn_id,
            .target_fd = target_fd,
            .relay_fd = handler.fd,
            .node_key = handler.node_key,
        };

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.tcp_tunnels.get(conn_id)) |old| {
                closeSocket(old.target_fd);
                self.alloc.destroy(old);
            }
            self.tcp_tunnels.put(conn_id, tunnel) catch {};
        }

        self.loop.addFd(target_fd, posix.POLL.IN, tunnel, &self.tunnel_vtbl);
        std.debug.print("[relay/v2/tcp] 隧道建立 conn_id={d} → {s}:{d}\n", .{ conn_id, host, port });
    }

    fn handleTcpData(self: *RelayServer, conn_id: u32, data: []const u8) void {
        self.mutex.lock();
        const tunnel = self.tcp_tunnels.get(conn_id) orelse {
            self.mutex.unlock();
            return;
        };
        const target_fd = tunnel.target_fd;
        self.mutex.unlock();

        _ = posix.write(target_fd, data) catch {};
    }

    fn handleTcpClose(self: *RelayServer, conn_id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tcp_tunnels.get(conn_id)) |tunnel| {
            self.loop.removeFd(tunnel.target_fd);
            closeSocket(tunnel.target_fd);
            self.alloc.destroy(tunnel);
            _ = self.tcp_tunnels.remove(conn_id);
        }
    }

    // ── TCP Tunnel 回调 ──

    fn tunnelOnReadable(ctx: *anyopaque, fd: posix.socket_t, loop: *EventLoop) void {
        const tunnel = @as(*TunnelHandler, @ptrCast(@alignCast(ctx)));
        const self = tunnel.server;

        var buf: [BUF_SIZE]u8 = undefined;
        const n = posix.read(fd, &buf) catch |err| {
            if (err == error.WouldBlock) return;
            tunnelCleanup(tunnel, loop);
            return;
        };
        if (n == 0) {
            tunnelCleanup(tunnel, loop);
            return;
        }

        var frame: [BUF_SIZE]u8 = undefined;
        frame[0] = FRAME_TCP_DATA;
        std.mem.writeInt(u32, frame[1..5], tunnel.conn_id, .little);
        std.mem.writeInt(u32, frame[5..9], @as(u32, @intCast(n)), .big);
        if (n > 0) @memcpy(frame[9..][0..n], buf[0..n]);

        // 查找 relay client 的 handler 并写入
        const client_handler = self.findHandlerByFd(tunnel.relay_fd) orelse {
            tunnelCleanup(tunnel, loop);
            return;
        };
        writeOrBuffer(client_handler, frame[0 .. 9 + n], loop);
    }

    fn tunnelOnHup(ctx: *anyopaque, fd: posix.socket_t, loop: *EventLoop) void {
        _ = fd;
        const tunnel = @as(*TunnelHandler, @ptrCast(@alignCast(ctx)));
        tunnelCleanup(tunnel, loop);
    }

    fn tunnelCleanup(tunnel: *TunnelHandler, loop: *EventLoop) void {
        const self = tunnel.server;
        loop.removeFd(tunnel.target_fd);
        closeSocket(tunnel.target_fd);

        // 发送 TCP_CLOSE 通知
        var close_frame: [5]u8 = undefined;
        close_frame[0] = FRAME_TCP_CLOSE;
        std.mem.writeInt(u32, close_frame[1..5], tunnel.conn_id, .little);
        _ = posix.write(tunnel.relay_fd, &close_frame) catch {};

        self.mutex.lock();
        _ = self.tcp_tunnels.remove(tunnel.conn_id);
        self.mutex.unlock();
        self.alloc.destroy(tunnel);
    }

    // ── 心跳 ──

    fn onHeartbeatTimer(ctx: *anyopaque, loop: *EventLoop) void {
        const self = @as(*RelayServer, @ptrCast(@alignCast(ctx)));
        if (!self.running) {
            loop.stop();
            return;
        }
        // 重新注册心跳
        loop.addTimer(5000, self, &self.accept_vtbl);
    }
};

// 编译验证
comptime {
    _ = RelayServer;
}

// ── RelayClient ──

const PendingEntryClient = struct {
    event: std.Thread.ResetEvent,
    result_buf: []u8,
    result_len: usize,
    timed_out: bool,
};

pub const RelayClient = struct {
    alloc: std.mem.Allocator,
    loop: EventLoop,

    fd: posix.socket_t,
    udp_fd: posix.socket_t,
    own_udp_port: u16,
    listen_host: []u8,
    listen_port: u16,
    remote_host: []u8,
    remote_port: u16,
    ws_path: []u8,

    running: bool,
    registered: bool,
    ws_mode: bool,

    /// 写缓冲（非阻塞 write 缓存）
    write_buf: [BUF_SIZE]u8,
    write_len: usize,
    write_sent: usize,

    /// 读缓冲
    read_buf: [BUF_SIZE]u8,
    read_len: usize,

    /// 挂起的请求（seq → PendingEntryClient）
    pending: std.AutoHashMap(u32, *PendingEntryClient),
    next_seq: u32,

    /// TCP 隧道回调
    tcp_callback: ?*const fn (conn_id: u32, data: ?[]const u8) void = null,

    /// 上一次收到数据的时间
    last_recv_ms: i64 = 0,

    /// 同步锁
    write_mutex: std.Thread.Mutex = .{},
    pending_mutex: std.Thread.Mutex = .{},

    fd_vtbl: HandlerVTable,
    udp_vtbl: HandlerVTable,

    pub fn init(alloc: std.mem.Allocator, remote_host: []const u8, remote_port: u16, local_host: []const u8, local_port: u16, udp_port: u16) !RelayClient {
        return initWithOpts(alloc, remote_host, remote_port, local_host, local_port, udp_port, false, "");
    }

    pub fn initWithOpts(alloc: std.mem.Allocator, remote_host: []const u8, remote_port: u16, local_host: []const u8, local_port: u16, udp_port: u16, ws_mode: bool, ws_path: []const u8) !RelayClient {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer closeSocket(fd);

        const addr_list = try std.net.getAddressList(alloc, remote_host, remote_port);
        defer addr_list.deinit();
        if (addr_list.addrs.len == 0) return error.HostNotFound;
        const addr = addr_list.addrs[0];
        try posix.connect(fd, &addr.any, addr.getOsSockLen());

        if (ws_mode) {
            // TODO: WS upgrade
        }

        event_loop.setNonblocking(fd) catch {};

        // UDP socket for local forwarding
        const udp_fd = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP) catch |err| {
            closeSocket(fd);
            return err;
        };
        const bind_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        posix.bind(udp_fd, &bind_addr.any, bind_addr.getOsSockLen()) catch |err| {
            closeSocket(fd);
            closeSocket(udp_fd);
            return err;
        };

        var client = RelayClient{
            .alloc = alloc,
            .loop = EventLoop.init(alloc),
            .fd = fd,
            .udp_fd = udp_fd,
            .own_udp_port = udp_port,
            .listen_host = try alloc.dupe(u8, local_host),
            .listen_port = local_port,
            .remote_host = try alloc.dupe(u8, remote_host),
            .remote_port = remote_port,
            .ws_path = try alloc.dupe(u8, ws_path),
            .running = true,
            .registered = false,
            .ws_mode = ws_mode,
            .write_buf = undefined,
            .write_len = 0,
            .write_sent = 0,
            .read_buf = undefined,
            .read_len = 0,
            .pending = std.AutoHashMap(u32, *PendingEntryClient).init(alloc),
            .next_seq = 1,
            .fd_vtbl = undefined,
            .udp_vtbl = undefined,
        };
        client.fd_vtbl = HandlerVTable{ .onReadable = clientOnReadable, .onWritable = clientOnWritable, .onHup = clientOnHup, .onTimer = clientOnHeartbeat };
        client.udp_vtbl = HandlerVTable{ .onReadable = clientUdpOnReadable };

        // 发送注册帧: [FRAME_REGISTER][len: u8][host:port]
        const reg_addr = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ local_host, local_port });
        defer alloc.free(reg_addr);
        var reg_buf: [BUF_SIZE]u8 = undefined;
        reg_buf[0] = FRAME_REGISTER;
        reg_buf[1] = @as(u8, @intCast(reg_addr.len));
        @memcpy(reg_buf[2..][0..reg_addr.len], reg_addr);
        _ = posix.write(fd, reg_buf[0 .. 2 + reg_addr.len]) catch |err| {
            client.deinit();
            return err;
        };
        client.registered = true;

        // 发 PING 防 NAT 断连
        const ping: [1]u8 = .{FRAME_PING};
        _ = posix.write(fd, &ping) catch {};

        std.debug.print("[relay/v2/conn] 连接到 {s}:{d} (本机 {s}:{d})\n", .{ remote_host, remote_port, local_host, local_port });
        return client;
    }

    pub fn deinit(self: *RelayClient) void {
        self.running = false;
        self.loop.stop();
        self.pending.deinit();
        closeSocket(self.udp_fd);
        closeSocket(self.fd);
        self.loop.deinit();
        self.alloc.free(self.listen_host);
        self.alloc.free(self.remote_host);
        if (self.ws_path.len > 0) self.alloc.free(self.ws_path);
    }

    /// 同步发送请求（兼容旧 API，阻塞等待响应）
    /// 内部使用 EventLoop 驱动 I/O
    pub fn sendRequest(self: *RelayClient, target_ip_be: u32, target_port: u16, data: []const u8, recv_buf: []u8, timeout_ms: u64) !usize {
        var attempt: u2 = 0;
        while (attempt < 2) : (attempt += 1) {
            const seq = @atomicRmw(u32, &self.next_seq, .Add, 1, .monotonic);

            var entry = PendingEntryClient{
                .event = .{},
                .result_buf = recv_buf,
                .result_len = 0,
                .timed_out = false,
            };

            self.pending_mutex.lock();
            self.pending.put(seq, &entry) catch {
                self.pending_mutex.unlock();
                return error.OutOfMemory;
            };
            self.pending_mutex.unlock();

            // 构建并发送 FRAME_REQUEST
            var frame: [BUF_SIZE]u8 = undefined;
            frame[0] = FRAME_REQUEST;
            std.mem.writeInt(u32, frame[1..5], target_ip_be, .big);
            std.mem.writeInt(u16, frame[5..7], target_port, .big);
            std.mem.writeInt(u32, frame[7..11], seq, .little);
            std.mem.writeInt(u32, frame[11..15], @as(u32, @intCast(data.len)), .big);
            if (data.len > 0) @memcpy(frame[15..][0..data.len], data);

            self.write_mutex.lock();
            _ = posix.write(self.fd, frame[0 .. 15 + data.len]) catch |err| {
                self.write_mutex.unlock();
                self.pending_mutex.lock();
                _ = self.pending.remove(seq);
                self.pending_mutex.unlock();
                return err;
            };
            self.write_mutex.unlock();

            const timeout_ns = timeout_ms * std.time.ns_per_ms;
            entry.event.timedWait(timeout_ns) catch {
                self.pending_mutex.lock();
                _ = self.pending.remove(seq);
                self.pending_mutex.unlock();
                if (attempt == 0) continue;
                return error.Timeout;
            };
            return entry.result_len;
        }
        return error.Timeout;
    }

    /// TCP 隧道：发送连接请求
    pub fn tcpConnect(self: *RelayClient, conn_id: u32, host: []const u8, port: u16) !void {
        var frame: [BUF_SIZE]u8 = undefined;
        frame[0] = FRAME_TCP_CONNECT;
        std.mem.writeInt(u32, frame[1..5], conn_id, .little);
        const host_len = @as(u8, @intCast(@min(host.len, @as(usize, 255))));
        frame[5] = host_len;
        @memcpy(frame[6..][0..host_len], host[0..host_len]);
        std.mem.writeInt(u16, frame[6 + host_len ..][0..2], port, .big);
        const total = 6 + host_len + 2;

        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        _ = posix.write(self.fd, frame[0..total]) catch {};
    }

    /// TCP 隧道：发送数据
    pub fn tcpData(self: *RelayClient, conn_id: u32, data: []const u8) !void {
        var frame: [BUF_SIZE]u8 = undefined;
        frame[0] = FRAME_TCP_DATA;
        std.mem.writeInt(u32, frame[1..5], conn_id, .little);
        const write_len = @min(data.len, BUF_SIZE - 9);
        std.mem.writeInt(u32, frame[5..9], @as(u32, @intCast(write_len)), .big);
        if (write_len > 0) @memcpy(frame[9..][0..write_len], data[0..write_len]);

        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        _ = posix.write(self.fd, frame[0 .. 9 + write_len]) catch {};
    }

    /// TCP 隧道：关闭连接
    pub fn tcpClose(self: *RelayClient, conn_id: u32) !void {
        var frame: [5]u8 = undefined;
        frame[0] = FRAME_TCP_CLOSE;
        std.mem.writeInt(u32, frame[1..5], conn_id, .little);

        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        _ = posix.write(self.fd, &frame) catch {};
    }

    /// Reader 线程入口：启动 EventLoop
    pub fn readerLoop(self: *RelayClient) void {
        self.running = true;
        self.last_recv_ms = std.time.milliTimestamp();

        // 注册 fd 和定时器
        self.loop.addFd(self.fd, posix.POLL.IN, self, &self.fd_vtbl);
        // 心跳定时器（每 5s 检查）
        self.loop.addTimer(5000, self, &self.fd_vtbl);

        std.debug.print("[relay/v2/reader] 启动 reader 线程\n", .{});
        self.loop.run();
        self.running = false;
        std.debug.print("[relay/v2/reader] reader 线程退出\n", .{});
    }

    /// 重新连接
    fn reconnect(self: *RelayClient) bool {
        closeSocket(self.fd);
        closeSocket(self.udp_fd);
        self.pending.deinit();
        self.pending = std.AutoHashMap(u32, *PendingEntryClient).init(self.alloc);
        self.next_seq = 1;
        self.read_len = 0;
        self.write_len = 0;
        self.write_sent = 0;

        var retries: u32 = 0;
        const max_retries = 10;
        while (retries < max_retries) {
            retries += 1;
            const wait_s = retries * 5;
            std.debug.print("[relay/v2/reader] 重连 ({d}/{d}), {d}s...\n", .{ retries, max_retries, wait_s });
            var elapsed: u32 = 0;
            while (elapsed < wait_s) {
                if (!self.running) return false;
                std.time.sleep(1 * std.time.ns_per_s);
                elapsed += 1;
            }

            const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch continue;
            errdefer closeSocket(fd);

            const addr_list = std.net.getAddressList(self.alloc, self.remote_host, self.remote_port) catch continue;
            defer addr_list.deinit();
            if (addr_list.addrs.len == 0) continue;
            const addr = addr_list.addrs[0];
            posix.connect(fd, &addr.any, addr.getOsSockLen()) catch continue;

            event_loop.setNonblocking(fd) catch {};

            self.fd = fd;

            // 新 UDP socket
            self.udp_fd = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP) catch continue;
            const bind_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
            posix.bind(self.udp_fd, &bind_addr.any, bind_addr.getOsSockLen()) catch {
                closeSocket(self.udp_fd);
                continue;
            };

            // 重新注册
            const reg_addr = std.fmt.allocPrint(self.alloc, "{s}:{d}", .{ self.listen_host, self.listen_port }) catch continue;
            defer self.alloc.free(reg_addr);
            var reg_buf: [BUF_SIZE]u8 = undefined;
            reg_buf[0] = FRAME_REGISTER;
            reg_buf[1] = @as(u8, @intCast(reg_addr.len));
            @memcpy(reg_buf[2..][0..reg_addr.len], reg_addr);
            _ = posix.write(fd, reg_buf[0 .. 2 + reg_addr.len]) catch continue;

            {
                const ping: [1]u8 = .{FRAME_PING};
                _ = posix.write(self.fd, &ping) catch {};
            }

            std.debug.print("[relay/v2/reader] 重连成功\n", .{});
            return true;
        }
        return false;
    }

    // ── FD 回调 ──

    fn clientOnReadable(ctx: *anyopaque, fd: posix.socket_t, loop: *EventLoop) void {
        const self = @as(*RelayClient, @ptrCast(@alignCast(ctx)));
        const space = self.read_buf[self.read_len..];
        const n = posix.read(fd, space) catch |err| {
            if (err == error.WouldBlock) return;
            if (err == error.ConnectionClosed or err == error.ConnectionResetByPeer) {
                clientReaderCleanup(self, loop);
                return;
            }
            std.debug.print("[relay/v2/reader] 读取错误: {}\n", .{err});
            clientReaderCleanup(self, loop);
            return;
        };
        if (n == 0) {
            clientReaderCleanup(self, loop);
            return;
        }
        self.read_len += n;
        self.last_recv_ms = std.time.milliTimestamp();

        // 处理完整帧
        while (tryCompleteFrame(self.read_buf[0..self.read_len])) |frame_len| {
            const frame = self.read_buf[0..frame_len];
            const remaining = self.read_len - frame_len;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.read_buf[0..remaining], self.read_buf[frame_len..][0..remaining]);
            }
            self.read_len = remaining;
            self.handleFrame(frame, loop);
        }
    }

    fn clientOnWritable(ctx: *anyopaque, fd: posix.socket_t, loop: *EventLoop) void {
        const self = @as(*RelayClient, @ptrCast(@alignCast(ctx)));
        const data = self.write_buf[self.write_sent..self.write_len];
        if (data.len == 0) {
            self.write_len = 0;
            self.write_sent = 0;
            loop.modFd(fd, posix.POLL.IN);
            return;
        }
        const n = posix.write(fd, data) catch |err| {
            if (err == error.WouldBlock) return;
            clientReaderCleanup(self, loop);
            return;
        };
        self.write_sent += n;
        if (self.write_sent >= self.write_len) {
            self.write_len = 0;
            self.write_sent = 0;
            loop.modFd(fd, posix.POLL.IN);
        }
    }

    fn clientOnHup(ctx: *anyopaque, fd: posix.socket_t, loop: *EventLoop) void {
        _ = fd;
        const self = @as(*RelayClient, @ptrCast(@alignCast(ctx)));
        clientReaderCleanup(self, loop);
    }

    fn clientOnHeartbeat(ctx: *anyopaque, loop: *EventLoop) void {
        const self = @as(*RelayClient, @ptrCast(@alignCast(ctx)));
        if (!self.running) {
            loop.stop();
            return;
        }
        const now = std.time.milliTimestamp();
        if (now - self.last_recv_ms > 5000) {
            const ping: [1]u8 = .{FRAME_PING};
            _ = posix.write(self.fd, &ping) catch {};
            self.last_recv_ms = now;
        }
        // 重新注册定时器
        loop.addTimer(5000, self, &self.fd_vtbl);
    }

    fn clientReaderCleanup(self: *RelayClient, loop: *EventLoop) void {
        loop.removeFd(self.fd);
        loop.removeFd(self.udp_fd);
        if (!self.running) return;
        std.debug.print("[relay/v2/reader] 连接断开, 尝试重连...\n", .{});
        if (self.reconnect()) {
            self.loop.addFd(self.fd, posix.POLL.IN, self, &self.fd_vtbl);
            self.last_recv_ms = std.time.milliTimestamp();
            loop.addTimer(5000, self, &self.fd_vtbl);
        } else {
            std.debug.print("[relay/v2/reader] 重连失败, reader 退出\n", .{});
            self.running = false;
            loop.stop();
        }
    }

    // ── UDP 回调 ──

    fn clientUdpOnReadable(_: *anyopaque, _: posix.socket_t, _: *EventLoop) void {
        // 共享 UDP socket — 用于 FRAME_FORWARD 响应路由
        // TODO: 匹配 pending forwards
    }

    // ── 帧处理 ──

    fn handleFrame(self: *RelayClient, frame: []const u8, _: *EventLoop) void {
        switch (frame[0]) {
            FRAME_FORWARD => {
                // [3][req_id(4)][payload_len(4)][payload]
                const req_id = std.mem.readInt(u32, frame[1..5], .little);
                const payload_len = std.mem.readInt(u32, frame[5..9], .big);
                const payload = frame[9..][0..payload_len];

                // 临时 UDP socket 转发到本地 Chord
                const tmp_udp = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP) catch return;
                defer closeSocket(tmp_udp);

                const tmp_bind = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
                posix.bind(tmp_udp, &tmp_bind.any, tmp_bind.getOsSockLen()) catch return;

                const target_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, self.own_udp_port);
                _ = posix.sendto(tmp_udp, payload, 0, &target_addr.any, @sizeOf(posix.sockaddr.in)) catch return;

                // 等待 UDP 响应（非阻塞 + poll）
                var resp_buf: [BUF_SIZE]u8 = undefined;
                var poll_fds = [_]posix.pollfd{.{ .fd = tmp_udp, .events = posix.POLL.IN, .revents = 0 }};
                const rc = posix.poll(&poll_fds, 5000) catch 0;
                if (rc > 0 and poll_fds[0].revents & posix.POLL.IN != 0) {
                    var resp_addr: std.net.Address = undefined;
                    var resp_addr_len: posix.socklen_t = @sizeOf(std.net.Address);
                    const resp_n = posix.recvfrom(tmp_udp, &resp_buf, 0, &resp_addr.any, &resp_addr_len) catch return;
                    if (resp_n > 0) {
                        var resp_frame: [BUF_SIZE]u8 = undefined;
                        resp_frame[0] = FRAME_RESPONSE;
                        std.mem.writeInt(u32, resp_frame[1..5], req_id, .little);
                        std.mem.writeInt(u32, resp_frame[5..9], @as(u32, @intCast(resp_n)), .big);
                        if (resp_n > 0) @memcpy(resp_frame[9..][0..resp_n], resp_buf[0..resp_n]);
                        _ = posix.write(self.fd, resp_frame[0 .. 9 + resp_n]) catch {};
                    }
                }
            },
            FRAME_TCP_DATA => {
                // [6][conn_id 4LE][data_len 4BE][data]
                const conn_id = std.mem.readInt(u32, frame[1..5], .little);
                const data_len = std.mem.readInt(u32, frame[5..9], .big);
                const data = frame[9..][0..data_len];
                if (self.tcp_callback) |cb| {
                    cb(conn_id, data);
                }
            },
            FRAME_TCP_CLOSE => {
                const conn_id = std.mem.readInt(u32, frame[1..5], .little);
                if (self.tcp_callback) |cb| {
                    cb(conn_id, null);
                }
            },
            FRAME_REPLY => {
                // [4][seq(4)][payload_len(4)][payload]
                const seq = std.mem.readInt(u32, frame[1..5], .little);
                const payload_len = std.mem.readInt(u32, frame[5..9], .big);
                const payload = frame[9..][0..payload_len];

                self.pending_mutex.lock();
                const entry = self.pending.get(seq) orelse {
                    self.pending_mutex.unlock();
                    return;
                };
                _ = self.pending.remove(seq);
                self.pending_mutex.unlock();

                const copy_len = @min(payload_len, entry.result_buf.len);
                if (copy_len > 0) @memcpy(entry.result_buf[0..copy_len], payload);
                entry.result_len = copy_len;
                entry.event.set();
            },
            FRAME_PING => {
                const pong: [1]u8 = .{FRAME_PONG};
                _ = posix.write(self.fd, &pong) catch {};
            },
            FRAME_PONG => {},
            else => {
                std.debug.print("[relay/v2/reader] 未知帧类型 {}\n", .{frame[0]});
            },
        }
    }
};

/// 兼容包装：通过 relay client 发送请求
pub fn sendViaRelay(client: *RelayClient, target_ip_be: u32, target_port: u16, data: []const u8, recv_buf: []u8, timeout_ms: u64) !usize {
    return client.sendRequest(target_ip_be, target_port, data, recv_buf, timeout_ms);
}

comptime {
    _ = RelayClient;
    _ = sendViaRelay;
}
