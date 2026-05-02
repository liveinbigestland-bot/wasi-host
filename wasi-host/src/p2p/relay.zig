/// 原生 TCP Relay — 替代 index.js Node.js 侧车
///
/// 协议格式（所有帧以 type byte 开头）:
///   [0x00][len: u8]["host:port"]     — 注册 (Client→Server)
///   [0x01][target_ip 4BE][target_port 2BE][seq 4LE][payload_len 4BE][payload]  — 请求 (Client→Server)
///   [0x02][req_id 4LE][payload_len 4BE][payload]  — 响应 (Client→Server)
///   [0x03][req_id 4LE][payload_len 4BE][payload]  — 转发 (Server→Client)
///   [0x04][seq 4LE][payload_len 4BE][payload]  — 回复 (Server→Client)

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const FRAME_REGISTER: u8 = 0;
const FRAME_REQUEST: u8 = 1;
const FRAME_RESPONSE: u8 = 2;
const FRAME_FORWARD: u8 = 3;
const FRAME_REPLY: u8 = 4;

const BUF_SIZE = 65536;

fn closeSocket(fd: posix.socket_t) void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ws2_32.closesocket(fd);
        return;
    }
    if (fd < 0) return;
    // 使用 raw system close 避免 zig 的 posix.close 在 EBADF 时 unreachable
    // relay 的连接替换逻辑可能导致 double-close，这是正常情况
    _ = posix.system.close(fd);
}

fn setRecvTimeout(fd: posix.socket_t, timeout_ms: u64) void {
    if (builtin.os.tag == .windows) {
        const ms: u32 = @intCast(@min(timeout_ms, std.math.maxInt(u32)));
        _ = posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(ms)) catch {};
    } else {
        const tv = posix.timeval{
            .sec = @as(isize, @intCast(timeout_ms / 1000)),
            .usec = @as(isize, @intCast((timeout_ms % 1000) * 1000)),
        };
        _ = posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(tv)) catch {};
    }
}

fn readExact(fd: posix.socket_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = posix.read(fd, buf[off..]) catch |err| {
            if (err == error.WouldBlock) return error.Timeout;
            return err;
        };
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}

/// 读取一个完整帧：先读 type byte，再根据 type 读后续字段
fn readFrame(fd: posix.socket_t, buf: []u8) !usize {
    var frame_type: u8 = undefined;
    {
        var type_buf: [1]u8 = undefined;
        try readExact(fd, &type_buf);
        frame_type = type_buf[0];
    }
    buf[0] = frame_type;
    switch (frame_type) {
        FRAME_REGISTER => {
            // [0x00][len: u8][host:port bytes]
            var len_buf: [1]u8 = undefined;
            try readExact(fd, &len_buf);
            const reg_len = len_buf[0];
            buf[1] = reg_len;
            if (reg_len > 0) try readExact(fd, buf[2..][0..reg_len]);
            return 2 + reg_len;
        },
        FRAME_REQUEST => {
            // [type(1)] [target_ip(4)] [target_port(2)] [seq(4)] [payload_len(4)] [payload]
            const header_len = 1 + 4 + 2 + 4 + 4;
            if (buf.len < header_len) return error.ResponseTooLarge;
            try readExact(fd, buf[1..header_len]);
            const payload_len = std.mem.readInt(u32, buf[header_len - 4 ..][0..4], .big);
            const total = header_len + payload_len;
            if (total > buf.len) return error.ResponseTooLarge;
            if (payload_len > 0) try readExact(fd, buf[header_len..total]);
            return total;
        },
        FRAME_RESPONSE, FRAME_FORWARD, FRAME_REPLY => {
            // [type(1)] [seq/req_id(4)] [payload_len(4)] [payload]
            const header_len = 1 + 4 + 4;
            if (buf.len < header_len) return error.ResponseTooLarge;
            try readExact(fd, buf[1..header_len]);
            const payload_len = std.mem.readInt(u32, buf[header_len - 4 ..][0..4], .big);
            const total = header_len + payload_len;
            if (total > buf.len) return error.ResponseTooLarge;
            if (payload_len > 0) try readExact(fd, buf[header_len..total]);
            return total;
        },
        else => return error.InvalidData,
    }
}

/// 写一个帧（不包含 type byte，调用者已在 buf[0] 放了 type）
fn writeFrame(fd: posix.socket_t, buf: []const u8) !void {
    _ = try posix.write(fd, buf);
}

// ── Relay Server ────────────────────────────────────────────────

const Connection = struct {
    fd: posix.socket_t,
    addr: std.net.Address,
    node_key: []u8, // "host:port" 的 alloc 副本
};

/// 速率限制器（线程安全）
const RateLimiter = struct {
    alloc: std.mem.Allocator,
    max_connections: u32,
    max_per_user: u32,
    bandwidth_limit_bytes: u64,

    active_connections: u32,
    /// 每个源 IP 的活跃连接数
    user_connections: std.StringHashMap(u32),
    bytes_this_second: u64,
    last_reset: i64,
    mutex: std.Thread.Mutex = .{},

    pub fn init(alloc: std.mem.Allocator, max_connections: u32, max_per_user: u32, bandwidth_limit_kb: u32) RateLimiter {
        return RateLimiter{
            .alloc = alloc,
            .max_connections = max_connections,
            .max_per_user = max_per_user,
            .bandwidth_limit_bytes = @as(u64, bandwidth_limit_kb) * 1024,
            .active_connections = 0,
            .user_connections = std.StringHashMap(u32).init(alloc),
            .bytes_this_second = 0,
            .last_reset = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.user_connections.deinit();
    }

    /// 尝试获取连接许可。返回 null 表示允许，否则返回拒绝原因。
    pub fn acquire(self: *RateLimiter, user_key: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // 总连接数限制
        if (self.max_connections > 0 and self.active_connections >= self.max_connections) {
            return "超过最大连接数限制";
        }

        // 每用户连接数限制
        if (self.max_per_user > 0) {
            const count = self.user_connections.get(user_key) orelse 0;
            if (count >= self.max_per_user) {
                return "超过每用户连接数限制";
            }
            self.user_connections.put(user_key, count + 1) catch {};
        }

        self.active_connections += 1;
        return null;
    }

    /// 释放连接许可
    pub fn release(self: *RateLimiter, user_key: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.active_connections > 0) {
            self.active_connections -= 1;
        }
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

    /// 跟踪带宽使用，必要时延时以 throttle
    pub fn trackBytes(self: *RateLimiter, n: usize) void {
        if (self.bandwidth_limit_bytes == 0) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        // 每秒重置计数器
        if (now != self.last_reset) {
            self.bytes_this_second = 0;
            self.last_reset = now;
        }

        self.bytes_this_second += @as(u64, n);

        // 超过带宽限制时主动延时
        if (self.bytes_this_second > self.bandwidth_limit_bytes) {
            self.mutex.unlock();
            std.time.sleep(100 * std.time.ns_per_ms); // 100ms backpressure
            self.mutex.lock();
        }
    }
};

pub const RelayServer = struct {
    listen_fd: posix.socket_t,
    port: u16,
    routing: std.StringHashMap(*Connection),
    pending: std.AutoHashMap(u32, PendingEntry),
    next_req_id: u32,
    alloc: std.mem.Allocator,
    running: bool,
    limiter: RateLimiter,
    mutex: std.Thread.Mutex = .{},
    upstream_client: ?*RelayClient = null,

    const PendingEntry = struct {
        requester_key: []const u8,
        original_seq: u32,
    };

    pub fn init(alloc: std.mem.Allocator, listen_host: []const u8, port: u16, max_connections: u32, max_per_user: u32, bandwidth_limit_kb: u32) !RelayServer {
        const listen_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer closeSocket(listen_fd);

        const reuse: u32 = 1;
        _ = posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(reuse)) catch {};

        const addr = try std.net.Address.parseIp(listen_host, port);
        try posix.bind(listen_fd, &addr.any, addr.getOsSockLen());
        try posix.listen(listen_fd, 16);

        return RelayServer{
            .listen_fd = listen_fd,
            .port = port,
            .routing = std.StringHashMap(*Connection).init(alloc),
            .pending = std.AutoHashMap(u32, PendingEntry).init(alloc),
            .next_req_id = 1,
            .alloc = alloc,
            .running = false,
            .limiter = RateLimiter.init(alloc, max_connections, max_per_user, bandwidth_limit_kb),
        };
    }

    pub fn stop(self: *RelayServer) void {
        self.running = false;
        closeSocket(self.listen_fd);
    }

    pub fn deinit(self: *RelayServer) void {
        self.routing.deinit();
        self.pending.deinit();
        self.limiter.deinit();
    }

    pub fn run(self: *RelayServer) void {
        self.running = true;
        std.debug.print("[relay] TCP relay server 已启动 :{d}\n", .{self.port});
        while (self.running) {
            var client_addr: std.net.Address = undefined;
            var addr_len: posix.socklen_t = @sizeOf(std.net.Address);
            const client_fd = posix.accept(self.listen_fd, &client_addr.any, &addr_len, 0) catch |err| {
                if (!self.running) break;
                if (err != error.WouldBlock and err != error.ConnectionAborted) {
                    std.debug.print("[relay] accept 错误: {}\n", .{err});
                }
                continue;
            };
            const thread = std.Thread.spawn(.{}, handleConnection, .{ self, client_fd, client_addr }) catch |err| {
                std.debug.print("[relay] 线程创建失败: {}\n", .{err});
                closeSocket(client_fd);
                continue;
            };
            thread.detach();
        }
    }

    fn handleConnection(self: *RelayServer, fd: posix.socket_t, addr: std.net.Address) void {
        defer closeSocket(fd);

        // 设置超时防止恶意连接或半开连接长期占用
        setRecvTimeout(fd, 5000);

        // 1. 等待注册帧
        var buf: [BUF_SIZE]u8 = undefined;
        const n = readFrame(fd, &buf) catch |err| {
            std.debug.print("[relay] 注册帧读取失败: {}\n", .{err});
            return;
        };
        if (buf[0] != FRAME_REGISTER) {
            std.debug.print("[relay] 期望注册帧, 收到 type={}\n", .{buf[0]});
            return;
        }
        const node_key = self.alloc.dupe(u8, buf[2..n]) catch {
            std.debug.print("[relay] 注册地址 alloc 失败\n", .{});
            return;
        };
        errdefer self.alloc.free(node_key);

        // 速率限制检查：生成用户标识（源 IP:port）
        var user_key_buf: [48]u8 = undefined;
        const user_key = std.fmt.bufPrint(&user_key_buf, "{}", .{addr}) catch "unknown";
        if (self.limiter.acquire(user_key)) |reason| {
            std.debug.print("[relay] 拒绝连接 {s} (来自 {}): {s}\n", .{ node_key, addr, reason });
            return;
        }
        errdefer self.limiter.release(user_key);

        // 2. 注册连接 (如果已存在, 关闭旧连接)
        const conn = self.alloc.create(Connection) catch {
            std.debug.print("[relay] Connection alloc 失败\n", .{});
            return;
        };
        conn.* = .{ .fd = fd, .addr = addr, .node_key = node_key };
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.routing.get(node_key)) |old_conn| {
                closeSocket(old_conn.fd);
                // 不释放 old_conn.node_key 和 old_conn 本身:
                // 旧线程仍持有这些指针作为局部变量，会在其清理代码中释放。
                // 如果在这里释放，旧线程后续会 double-free。
            }
            self.routing.put(node_key, conn) catch {};
        }
        std.debug.print("[relay] 节点已注册: {s} ({})\n", .{ node_key, addr });

        // 3. 处理该连接的帧（超时时继续等待，不断开）
        setRecvTimeout(fd, 5000);
        while (true) {
            _ = readFrame(fd, &buf) catch |err| {
                if (err == error.Timeout) continue;
                if (err == error.ConnectionClosed or err == error.WouldBlock) break;
                std.debug.print("[relay] 帧读取错误 {s}: {}\n", .{ node_key, err });
                break;
            };
            switch (buf[0]) {
                FRAME_REQUEST => {
                    // [1][target_ip 4][target_port 2][seq 4][payload_len 4][payload]
                    const target_ip = std.mem.readInt(u32, buf[1..5], .big);
                    const target_port = std.mem.readInt(u16, buf[5..7], .big);
                    const seq = std.mem.readInt(u32, buf[7..11], .little);
                    const payload_len = std.mem.readInt(u32, buf[11..15], .big);
                    const payload = buf[15..][0..payload_len];
                    self.routeRequest(node_key, target_ip, target_port, seq, payload);
                },
                FRAME_RESPONSE => {
                    // [2][req_id 4][payload_len 4][payload]
                    const req_id = std.mem.readInt(u32, buf[1..5], .little);
                    const payload_len = std.mem.readInt(u32, buf[5..9], .big);
                    const payload = buf[9..][0..payload_len];
                    self.routeResponse(req_id, payload);
                },
                else => {
                    std.debug.print("[relay] 未知帧类型 {} 来自 {s}\n", .{ buf[0], node_key });
                    break;
                },
            }
        }

        // 4. 清理
        std.debug.print("[relay] 节点断开: {s}\n", .{node_key});
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            // 只移除仍属于本线程的路由条目（防止被新连接替换后误删新条目）
            if (self.routing.get(node_key)) |current| {
                if (current == conn) {
                    _ = self.routing.remove(node_key);
                }
            }
        }
        // 释放速率限制许可
        {
            var key_buf: [48]u8 = undefined;
            const ip_key = std.fmt.bufPrint(&key_buf, "{}", .{addr}) catch "unknown";
            self.limiter.release(ip_key);
        }
        // 始终释放本线程自己的分配（由本线程 alloc.dupe/alloc.create 的）
        self.alloc.free(node_key);
        self.alloc.destroy(conn);
    }

    fn routeRequest(self: *RelayServer, from_key: []const u8, target_ip: u32, target_port: u16, seq: u32, payload: []const u8) void {
        // target_ip 是 u32 网络字节序（大端），在小端机上 asBytes 得到颠倒的字节顺序。
        // 先转为主机字节序，再取字节。
        var ip_bytes: [4]u8 = undefined;
        const native_ip = std.mem.bigToNative(u32, target_ip);
        @memcpy(&ip_bytes, std.mem.asBytes(&native_ip));
        var key_buf: [60]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{d}.{d}.{d}.{d}:{d}", .{
            ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3], target_port,
        }) catch {
            std.debug.print("[relay] ROUTEKEY_FAIL\n", .{});
            return;
        };
        std.debug.print("[relay] ROUTEKEY: {s}\n", .{key});

        const target_conn = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.routing.get(key);
        };

        if (target_conn) |conn| {
            // 目标在本地路由表中，通过 FORWARD 帧转发
            const req_id = @atomicRmw(u32, &self.next_req_id, .Add, 1, .monotonic);
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.pending.put(req_id, .{ .requester_key = from_key, .original_seq = seq }) catch {};
            }

            var fwd_buf: [BUF_SIZE]u8 = undefined;
            fwd_buf[0] = FRAME_FORWARD;
            std.mem.writeInt(u32, fwd_buf[1..5], req_id, .little);
            std.mem.writeInt(u32, fwd_buf[5..9], @as(u32, @intCast(payload.len)), .big);
            if (payload.len > 0) @memcpy(fwd_buf[9..][0..payload.len], payload);
            writeFrame(conn.fd, fwd_buf[0 .. 9 + payload.len]) catch |err| {
                std.debug.print("[relay] 转发失败 {s}→{s}: {}\n", .{ from_key, key, err });
                self.mutex.lock();
                defer self.mutex.unlock();
                _ = self.pending.remove(req_id);
            };
            // 跟踪转发流量
            self.limiter.trackBytes(payload.len);
        } else if (self.upstream_client) |client| {
            // 目标不在本地路由表，通过上游 relay client 转发
            std.debug.print("[relay] 上游转发 {s}→{s}\n", .{ from_key, key });
            var resp_buf: [BUF_SIZE]u8 = undefined;
            const resp_len = client.sendRequest(target_ip, target_port, payload, &resp_buf, 5000) catch |err| {
                std.debug.print("[relay] 上游转发失败 {s}→{s}: {}\n", .{ from_key, key, err });
                return;
            };
            // 跟踪转发流量（请求 + 响应）
            self.limiter.trackBytes(payload.len + resp_len);
            // 回送响应给原始请求者
            self.sendReply(from_key, seq, resp_buf[0..resp_len]);
        } else {
            std.debug.print("[relay] 目标未注册: {s}\n", .{key});
        }
    }

    fn routeResponse(self: *RelayServer, req_id: u32, payload: []const u8) void {
        const requester_key = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const entry = self.pending.get(req_id) orelse {
                std.debug.print("[relay] 未知 req_id={}\n", .{req_id});
                return;
            };
            const key = self.alloc.dupe(u8, entry.requester_key) catch return;
            _ = self.pending.remove(req_id);
            break :blk .{ .key = key, .original_seq = entry.original_seq };
        };
        defer self.alloc.free(requester_key.key);

        // 查找原始请求者的连接
        const requester_conn = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.routing.get(requester_key.key) orelse {
                std.debug.print("[relay] 请求者已断开: {s}\n", .{requester_key.key});
                return;
            };
        };

        // 回复请求者: [FRAME_REPLY(1)][seq(4)][payload_len(4)][payload]
        var reply_buf: [BUF_SIZE]u8 = undefined;
        reply_buf[0] = FRAME_REPLY;
        // 使用原始请求的 seq（不是 req_id），这样客户端能匹配其 pending 表
        std.mem.writeInt(u32, reply_buf[1..5], requester_key.original_seq, .little);
        std.mem.writeInt(u32, reply_buf[5..9], @as(u32, @intCast(payload.len)), .big);
        if (payload.len > 0) @memcpy(reply_buf[9..][0..payload.len], payload);
        writeFrame(requester_conn.fd, reply_buf[0 .. 9 + payload.len]) catch |err| {
            std.debug.print("[relay] 回复失败 {s}: {}\n", .{ requester_key.key, err });
        };
    }

    /// 直接发送 REPLY 帧给请求者（用于上游转发后的回送）
    fn sendReply(self: *RelayServer, requester_key: []const u8, original_seq: u32, payload: []const u8) void {
        const requester_conn = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.routing.get(requester_key) orelse {
                std.debug.print("[relay] sendReply: 请求者已断开: {s}\n", .{requester_key});
                return;
            };
        };

        var reply_buf: [BUF_SIZE]u8 = undefined;
        reply_buf[0] = FRAME_REPLY;
        std.mem.writeInt(u32, reply_buf[1..5], original_seq, .little);
        std.mem.writeInt(u32, reply_buf[5..9], @as(u32, @intCast(payload.len)), .big);
        if (payload.len > 0) @memcpy(reply_buf[9..][0..payload.len], payload);
        writeFrame(requester_conn.fd, reply_buf[0 .. 9 + payload.len]) catch |err| {
            std.debug.print("[relay] sendReply 失败 {s}: {}\n", .{ requester_key, err });
        };
    }
};

// ── Relay Client ────────────────────────────────────────────────

pub const RelayClient = struct {
    fd: posix.socket_t,
    alloc: std.mem.Allocator,
    pending: std.AutoHashMap(u32, *PendingEntry),
    next_seq: u32,
    udp_fd: posix.socket_t,
    own_udp_port: u16,
    listen_host: []const u8,
    listen_port: u16,
    running: bool,
    read_mutex: std.Thread.Mutex,
    write_mutex: std.Thread.Mutex,
    pending_mutex: std.Thread.Mutex,
    /// WebSocket 传输模式 (通过 WS 帧封装 relay 帧)
    ws_mode: bool,
    /// 重连用的远程服务器信息
    remote_host: []const u8,
    remote_port: u16,
    ws_path: []const u8,

    const PendingEntry = struct {
        event: std.Thread.ResetEvent,
        result_buf: []u8,
        result_len: usize,
        timed_out: bool,
    };

    pub fn init(alloc: std.mem.Allocator, remote_host: []const u8, remote_port: u16, local_host: []const u8, local_port: u16, udp_port: u16) !RelayClient {
        return initWithOpts(alloc, remote_host, remote_port, local_host, local_port, udp_port, false, "");
    }

    /// 初始化 RelayClient，支持 WS 传输模式
    pub fn initWithOpts(alloc: std.mem.Allocator, remote_host: []const u8, remote_port: u16, local_host: []const u8, local_port: u16, udp_port: u16, ws_mode: bool, ws_path: []const u8) !RelayClient {
        // 连接 relay server
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer closeSocket(fd);

        // 解析 hostname（支持 IP 地址和域名）
        const addr_list = try std.net.getAddressList(alloc, remote_host, remote_port);
        defer addr_list.deinit();
        if (addr_list.addrs.len == 0) return error.HostNotFound;
        const addr = addr_list.addrs[0];
        try posix.connect(fd, &addr.any, addr.getOsSockLen());

        // WS 模式: 发送 HTTP Upgrade 请求
        if (ws_mode) {
            try wsClientUpgrade(fd, remote_host, remote_port, ws_path);
        }

        var client = RelayClient{
            .fd = fd,
            .alloc = alloc,
            .pending = std.AutoHashMap(u32, *PendingEntry).init(alloc),
            .next_seq = 1,
            .udp_fd = undefined,
            .own_udp_port = udp_port,
            .listen_host = try alloc.dupe(u8, local_host),
            .listen_port = local_port,
            .running = true,
            .read_mutex = .{},
            .write_mutex = .{},
            .pending_mutex = .{},
            .ws_mode = ws_mode,
            .remote_host = try alloc.dupe(u8, remote_host),
            .remote_port = remote_port,
            .ws_path = try alloc.dupe(u8, ws_path),
        };

        // 创建 UDP socket 用于转发到本地 wasi-host
        client.udp_fd = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP) catch |err| {
            client.deinit();
            return err;
        };
        const bind_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        posix.bind(client.udp_fd, &bind_addr.any, bind_addr.getOsSockLen()) catch |err| {
            client.deinit();
            return err;
        };

        // 发送注册帧: [FRAME_REGISTER][len: u8][host:port]
        const reg_addr = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ local_host, local_port });
        defer alloc.free(reg_addr);
        var reg_buf: [BUF_SIZE]u8 = undefined;
        reg_buf[0] = FRAME_REGISTER;
        reg_buf[1] = @as(u8, @intCast(reg_addr.len));
        @memcpy(reg_buf[2..][0..reg_addr.len], reg_addr);
        try relayWriteRaw(&client, reg_buf[0 .. 2 + reg_addr.len]);

        std.debug.print("[relay/conn] 连接到 relay {s}:{d} (本机 {s}:{d})\n", .{ remote_host, remote_port, local_host, local_port });
        return client;
    }

    pub fn deinit(self: *RelayClient) void {
        self.running = false;
        self.pending.deinit();
        closeSocket(self.udp_fd);
        closeSocket(self.fd);
        self.alloc.free(self.listen_host);
        self.alloc.free(self.remote_host);
        if (self.ws_path.len > 0) self.alloc.free(self.ws_path);
    }

    /// 发送请求到目标节点，等待响应
    pub fn sendRequest(self: *RelayClient, target_ip_be: u32, target_port: u16, data: []const u8, recv_buf: []u8, timeout_ms: u64) !usize {
        const seq = @atomicRmw(u32, &self.next_seq, .Add, 1, .monotonic);

        // 注册 pending 条目
        var entry = PendingEntry{
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

        // 构建并发送请求帧
        // [FRAME_REQUEST(1)][target_ip(4)][target_port(2)][seq(4)][payload_len(4)][payload]
        var frame: [BUF_SIZE]u8 = undefined;
        frame[0] = FRAME_REQUEST;
        std.mem.writeInt(u32, frame[1..5], target_ip_be, .big);
        std.mem.writeInt(u16, frame[5..7], target_port, .big);
        std.mem.writeInt(u32, frame[7..11], seq, .little);
        std.mem.writeInt(u32, frame[11..15], @as(u32, @intCast(data.len)), .big);
        if (data.len > 0) @memcpy(frame[15..][0..data.len], data);

        {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            relayWriteRaw(self, frame[0 .. 15 + data.len]) catch |err| {
                self.pending_mutex.lock();
                _ = self.pending.remove(seq);
                self.pending_mutex.unlock();
                return err;
            };
        }

        // 等待响应或超时
        const timeout_ns = timeout_ms * std.time.ns_per_ms;
        entry.event.timedWait(timeout_ns) catch {
            self.pending_mutex.lock();
            _ = self.pending.remove(seq);
            self.pending_mutex.unlock();
            return error.Timeout;
        };

        return entry.result_len;
    }

    /// 重新连接到 relay server（连接断开后自动重连）
    fn reconnect(self: *RelayClient) bool {
        // 关闭旧 socket
        closeSocket(self.fd);
        closeSocket(self.udp_fd);
        self.pending.deinit();
        self.pending = std.AutoHashMap(u32, *PendingEntry).init(self.alloc);
        self.next_seq = 1;

        // 重试连接
        var retries: u32 = 0;
        const max_retries = 10;
        while (retries < max_retries) {
            retries += 1;
            const wait_s = retries * 5; // 指数退避: 5s, 10s, 15s, ...
            std.debug.print("[relay/reader] 重连 ({d}/{d}), {d}s...\n", .{ retries, max_retries, wait_s });
            var elapsed: u32 = 0;
            while (elapsed < wait_s) {
                if (!self.running) return false;
                std.time.sleep(1 * std.time.ns_per_s);
                elapsed += 1;
            }

            // 创建新 TCP 连接
            const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch continue;
            errdefer closeSocket(fd);

            const addr_list = std.net.getAddressList(self.alloc, self.remote_host, self.remote_port) catch continue;
            defer addr_list.deinit();
            if (addr_list.addrs.len == 0) continue;
            const addr = addr_list.addrs[0];
            posix.connect(fd, &addr.any, addr.getOsSockLen()) catch continue;

            if (self.ws_mode) {
                wsClientUpgrade(fd, self.remote_host, self.remote_port, self.ws_path) catch continue;
            }

            self.fd = fd;

            // 创建新 UDP socket
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
            relayWriteRaw(self, reg_buf[0 .. 2 + reg_addr.len]) catch continue;

            std.debug.print("[relay/reader] 重连成功\n", .{});
            setRecvTimeout(self.fd, 3000);
            return true;
        }

        return false;
    }

    /// Reader 线程入口：读取 relay server 的帧，处理转发请求或回复
    pub fn readerLoop(self: *RelayClient) void {
        const target_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, self.own_udp_port);

        std.debug.print("[relay/reader] 启动 reader 线程\n", .{});

        // 外层循环：连接断开后自动重连
        while (self.running) {
            setRecvTimeout(self.fd, 3000);
            var buf: [BUF_SIZE]u8 = undefined;

            // 内层循环：正常帧读取处理
            while (self.running) {
                const frame_n = relayReadRaw(self, &buf) catch |err| {
                    if (err == error.Timeout) continue;
                    if (err == error.ConnectionClosed or err == error.WouldBlock) {
                        std.debug.print("[relay/reader] 连接断开\n", .{});
                        break;
                    }
                    std.debug.print("[relay/reader] 读取错误: {}\n", .{err});
                    break;
                };
                _ = frame_n;

                switch (buf[0]) {
                    FRAME_FORWARD => {
                        // [3][req_id(4)][payload_len(4)][payload]
                        const req_id = std.mem.readInt(u32, buf[1..5], .little);
                        const payload_len = std.mem.readInt(u32, buf[5..9], .big);
                        const payload = buf[9..][0..payload_len];

                        // 转发到本地 wasi-host UDP
                        _ = posix.sendto(self.udp_fd, payload, 0, &target_addr.any, @sizeOf(posix.sockaddr.in)) catch |err| {
                            std.debug.print("[relay/reader] UDP 转发错误: {}\n", .{err});
                            continue;
                        };

                        // 等待 UDP 响应（最多 5s）
                        var resp_buf: [BUF_SIZE]u8 = undefined;
                        var resp_addr: std.net.Address = undefined;
                        var resp_addr_len: posix.socklen_t = @sizeOf(std.net.Address);
                        setRecvTimeout(self.udp_fd, 5000);
                        const resp_n = posix.recvfrom(self.udp_fd, &resp_buf, 0, &resp_addr.any, &resp_addr_len) catch |err| {
                            if (err == error.WouldBlock or err == error.Timeout) {
                                // 无响应（如 notify 等单向消息）
                                continue;
                            }
                            std.debug.print("[relay/reader] UDP recv 错误: {}\n", .{err});
                            continue;
                        };

                        // 发送响应回 relay server
                        var resp_frame: [BUF_SIZE]u8 = undefined;
                        resp_frame[0] = FRAME_RESPONSE;
                        std.mem.writeInt(u32, resp_frame[1..5], req_id, .little);
                        std.mem.writeInt(u32, resp_frame[5..9], @as(u32, @intCast(resp_n)), .big);
                        if (resp_n > 0) @memcpy(resp_frame[9..][0..resp_n], resp_buf[0..resp_n]);

                        self.write_mutex.lock();
                        relayWriteRaw(self, resp_frame[0 .. 9 + resp_n]) catch {
                            self.write_mutex.unlock();
                            break;
                        };
                        self.write_mutex.unlock();
                    },
                    FRAME_REPLY => {
                        // [4][seq(4)][payload_len(4)][payload]
                        const seq = std.mem.readInt(u32, buf[1..5], .little);
                        const payload_len = std.mem.readInt(u32, buf[5..9], .big);
                        const payload = buf[9..][0..payload_len];

                        self.pending_mutex.lock();
                        const entry = self.pending.get(seq) orelse {
                            self.pending_mutex.unlock();
                            continue;
                        };
                        _ = self.pending.remove(seq);
                        self.pending_mutex.unlock();

                        // 复制响应数据到等待者的缓冲区
                        const copy_len = @min(payload_len, entry.result_buf.len);
                        if (copy_len > 0) @memcpy(entry.result_buf[0..copy_len], payload);
                        entry.result_len = copy_len;
                        entry.event.set();
                    },
                    else => {
                        std.debug.print("[relay/reader] 未知帧类型 {}\n", .{buf[0]});
                        continue;
                    },
                }
            }

            // 连接断开后尝试自动重连
            if (!self.running) break;
            std.debug.print("[relay/reader] 连接断开, 尝试重连...\n", .{});
            if (self.reconnect()) {
                continue; // 重连成功，回到外层循环继续
            }
            std.debug.print("[relay/reader] 重连失败, reader 退出\n", .{});
            break;
        }
        self.running = false;
        std.debug.print("[relay/reader] reader 线程退出\n", .{});
    }
};

// ── 辅助函数 ────────────────────────────────────────────────────

/// 根据传方式选择 RelayClient 发送或原有 proxy 发送
pub fn sendViaRelay(client: *RelayClient, target_ip_be: u32, target_port: u16, data: []const u8, recv_buf: []u8, timeout_ms: u64) !usize {
    return client.sendRequest(target_ip_be, target_port, data, recv_buf, timeout_ms);
}

/// WS 模式: 写入（自动包裹 WS 帧）
fn relayWriteRaw(self: *RelayClient, data: []const u8) !void {
    if (self.ws_mode) {
        try wsClientSendFrame(self.fd, data);
    } else {
        _ = try posix.write(self.fd, data);
    }
}

/// WS 模式: 读取（自动解包 WS 帧）
fn relayReadRaw(self: *RelayClient, buf: []u8) !usize {
    if (self.ws_mode) {
        return wsClientRecvFrame(self.fd, buf);
    }
    return readFrame(self.fd, buf);
}

// ── WebSocket Client 函数（用于 relay 客户端 WS 传输模式）────

/// WebSocket 客户端 Upgrade 请求
fn wsClientUpgrade(fd: posix.socket_t, host: []const u8, port: u16, path: []const u8) !void {
    // 生成随机 Sec-WebSocket-Key (16 bytes → base64)
    var key_bytes: [16]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.nanoTimestamp())));
    prng.random().bytes(&key_bytes);
    var key_buf: [std.base64.standard.Encoder.calcSize(16)]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&key_buf, &key_bytes);

    var req: [512]u8 = undefined;
    const req_slice = try std.fmt.bufPrint(&req,
        "GET {s} HTTP/1.1\r\n" ++
        "Host: {s}:{d}\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: {s}\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n",
        .{ path, host, port, key },
    );

    _ = try posix.write(fd, req_slice);

    // 读取 101 响应
    var resp: [1024]u8 = undefined;
    var pos: usize = 0;
    while (pos < resp.len) {
        const n = posix.read(fd, resp[pos..]) catch |err| {
            if (err == error.WouldBlock) return error.Timeout;
            return err;
        };
        if (n == 0) return error.ConnectionClosed;
        pos += n;
        if (std.mem.indexOf(u8, resp[0..pos], "\r\n\r\n")) |_| break;
    }

    // 验证 HTTP 101
    if (std.mem.indexOf(u8, resp[0..pos], "101") == null) {
        return error.UnexpectedResponse;
    }
}

/// WebSocket 客户端发送帧（带 mask，client→server）
fn wsClientSendFrame(fd: posix.socket_t, data: []const u8) !void {
    var mask_key: [4]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.nanoTimestamp())));
    prng.random().bytes(&mask_key);

    var hdr: [14]u8 = undefined;
    var hdr_len: usize = 0;

    hdr[0] = 0x82; // FIN=1, Binary opcode
    if (data.len < 126) {
        hdr[1] = @as(u8, @intCast(0x80 | data.len)); // mask bit + len
        @memcpy(hdr[2..6], &mask_key);
        hdr_len = 6;
    } else if (data.len < 65536) {
        hdr[1] = 0x80 | 126; // mask bit + 16-bit len
        std.mem.writeInt(u16, hdr[2..4], @as(u16, @intCast(data.len)), .big);
        @memcpy(hdr[4..8], &mask_key);
        hdr_len = 8;
    } else {
        hdr[1] = 0x80 | 127; // mask bit + 64-bit len
        std.mem.writeInt(u64, hdr[2..10], @as(u64, @intCast(data.len)), .big);
        @memcpy(hdr[10..14], &mask_key);
        hdr_len = 14;
    }

    _ = try posix.write(fd, hdr[0..hdr_len]);

    // 写入 masked payload
    if (data.len > 0) {
        var masked_buf: [BUF_SIZE]u8 = undefined;
        const to_copy = @min(data.len, masked_buf.len);
        @memcpy(masked_buf[0..to_copy], data[0..to_copy]);
        for (masked_buf[0..to_copy], 0..) |*b, i| {
            b.* ^= mask_key[i % 4];
        }
        _ = try posix.write(fd, masked_buf[0..to_copy]);
    }
}

/// WebSocket 客户端接收帧（server→client，无 mask）
fn wsClientRecvFrame(fd: posix.socket_t, buf: []u8) !usize {
    var first: [2]u8 = undefined;
    var off: usize = 0;
    while (off < 2) {
        const n = posix.read(fd, first[off..]) catch |err| {
            if (err == error.WouldBlock) return error.Timeout;
            return err;
        };
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }

    const opcode = first[0] & 0x0F;
    const masked = (first[1] & 0x80) != 0;
    var payload_len: usize = first[1] & 0x7F;

    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        off = 0;
        while (off < 2) {
            const n = posix.read(fd, ext[off..]) catch |err| {
                if (err == error.WouldBlock) return error.Timeout;
                return err;
            };
            if (n == 0) return error.ConnectionClosed;
            off += n;
        }
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        off = 0;
        while (off < 8) {
            const n = posix.read(fd, ext[off..]) catch |err| {
                if (err == error.WouldBlock) return error.Timeout;
                return err;
            };
            if (n == 0) return error.ConnectionClosed;
            off += n;
        }
        payload_len = @as(usize, @intCast(std.mem.readInt(u64, &ext, .big)));
    }

    if (payload_len > buf.len) return error.MessageTooBig;

    // 读取 mask key (server→client 通常不 mask, 但支持)
    var mk: [4]u8 = undefined;
    if (masked) {
        off = 0;
        while (off < 4) {
            const n = posix.read(fd, mk[off..]) catch |err| {
                if (err == error.WouldBlock) return error.Timeout;
                return err;
            };
            if (n == 0) return error.ConnectionClosed;
            off += n;
        }
    }

    // 读取 payload
    off = 0;
    while (off < payload_len) {
        const n = posix.read(fd, buf[off..payload_len]) catch |err| {
            if (err == error.WouldBlock) return error.Timeout;
            return err;
        };
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }

    // 解 mask
    if (masked) {
        for (buf[0..payload_len], 0..) |*b, i| {
            b.* ^= mk[i % 4];
        }
    }

    // Ping 帧
    if (opcode == 0x9) {
        var pong: [2]u8 = .{ 0x8A, @as(u8, @intCast(payload_len)) };
        _ = try posix.write(fd, &pong);
        if (payload_len > 0) _ = try posix.write(fd, buf[0..payload_len]);
        return wsClientRecvFrame(fd, buf);
    }

    // Close 帧
    if (opcode == 0x8) return error.ConnectionClosed;

    // 只接受 Binary 或 Text 帧
    if (opcode != 0x2 and opcode != 0x1) {
        return wsClientRecvFrame(fd, buf);
    }

    return payload_len;
}
