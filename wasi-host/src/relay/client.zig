/// Encrypted Relay Client — 多中继自动切换客户端
///
/// 连接到加密中继服务器，注册并鉴权，发送/接收转发数据。
/// 支持主/备中继列表，主中继不可达时自动切换备用。
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const crypto = std.crypto;

const Ed25519 = crypto.sign.Ed25519;
const NodeID = @import("registry.zig").NodeID;

/// 跨平台无效套接字值
const invalid_socket: posix.socket_t = if (builtin.os.tag == .windows)
    @ptrFromInt(@as(usize, std.math.maxInt(usize)))
else
    @as(posix.socket_t, -1);

// ── 协议常量（与 main.zig 一致）──

pub const CMD_CTRL: u8 = 0x00;
pub const CMD_DATA: u8 = 0x01;

pub const CTRL_REGISTER: u8 = 0x01;
pub const CTRL_CHALLENGE: u8 = 0x02;
pub const CTRL_AUTH: u8 = 0x03;
pub const CTRL_AUTH_OK: u8 = 0x04;
pub const CTRL_AUTH_FAIL: u8 = 0x05;
pub const CTRL_PING: u8 = 0x06;
pub const CTRL_PONG: u8 = 0x07;
pub const CTRL_ERROR: u8 = 0x08;

// ── 配置 ──

pub const RelayAddr = struct {
    host: []const u8,
    port: u16,
};

pub const ClientConfig = struct {
    /// 中继地址列表（主/备）
    relays: []const RelayAddr,
    /// 本机 NodeID（20 字节 SHA-1）
    node_id: NodeID,
    /// ED25519 私钥种子（用于签名挑战）
    secret_key: [32]u8,
    /// ED25519 公钥
    public_key: [32]u8,
    /// UDP 还是 TCP
    use_tcp: bool = false,
    /// 超时 (ms)
    timeout_ms: u64 = 5000,
    /// 心跳间隔 (ms)
    heartbeat_interval_ms: u64 = 25_000,
};

// ── Relay Client ──

pub const RelayClient = struct {
    alloc: std.mem.Allocator,
    config: ClientConfig,

    fd: posix.socket_t,
    relay_addr: std.net.Address,
    current_relay_index: usize,
    registered: bool,

    running: bool,

    pub fn init(alloc: std.mem.Allocator, config: ClientConfig) !RelayClient {
        if (config.relays.len == 0) return error.NoRelaysConfigured;

        return RelayClient{
            .alloc = alloc,
            .config = config,
            .fd = invalid_socket,
            .relay_addr = undefined,
            .current_relay_index = 0,
            .registered = false,
            .running = false,
        };
    }

    pub fn deinit(self: *RelayClient) void {
        self.running = false;
        if (self.fd != invalid_socket) {
            posix.close(self.fd);
        }
    }

    /// 连接到主中继（失败时自动尝试备用）
    pub fn connect(self: *RelayClient) !void {
        for (self.config.relays, 0..) |relay, i| {
            const addr = resolveRelay(self.alloc, relay) catch {
                continue;
            };

            const fd = if (self.config.use_tcp)
                connectTCP(addr, self.config.timeout_ms) catch continue
            else
                connectUDP(addr) catch continue;

            self.fd = fd;
            self.relay_addr = addr;
            self.current_relay_index = i;
            return; // success
        }

        return error.AllRelaysFailed;
    }

    /// 连接 + 注册 + 鉴权（完整握手）
    pub fn register(self: *RelayClient) !void {
        // 1. 发送注册帧
        try self.sendRegister();

        // 2. 等待挑战
        const challenge = try self.recvChallenge();

        // 3. 签名并发送鉴权响应
        try self.sendAuth(challenge);

        // 4. 等待鉴权结果
        try self.waitAuthResult();

        self.registered = true;
    }

    /// 完整连接流程：connect → register
    pub fn connectAndRegister(self: *RelayClient) !void {
        try self.connect();
        try self.register();
    }

    /// 发送数据到目标节点
    pub fn sendTo(self: *RelayClient, target_id: NodeID, data: []const u8) !void {
        // 构建数据帧: [CMD_DATA][target NodeID 20][payload]
        // For UDP: single datagram
        // For TCP: framed write
        if (self.config.use_tcp) {
            var frame: [1 + 20 + 1400]u8 = undefined;
            frame[0] = CMD_DATA;
            @memcpy(frame[1..21], &target_id);
            const payload_len = @min(data.len, frame.len - 21);
            if (payload_len > 0) @memcpy(frame[21..][0..payload_len], data[0..payload_len]);
            _ = try posix.write(self.fd, frame[0 .. 21 + payload_len]);
        } else {
            var packet: [1 + 20 + 1400]u8 = undefined;
            packet[0] = CMD_DATA;
            @memcpy(packet[1..21], &target_id);
            const payload_len = @min(data.len, packet.len - 21);
            if (payload_len > 0) @memcpy(packet[21..][0..payload_len], data[0..payload_len]);
            _ = try posix.sendto(self.fd, packet[0 .. 21 + payload_len], 0, &self.relay_addr.any, self.relay_addr.getOsSockLen());
        }
    }

    /// 接收数据（阻塞）
    pub fn recvFrom(self: *RelayClient, buf: []u8) !usize {
        if (self.config.use_tcp) {
            return posix.read(self.fd, buf);
        } else {
            var from: std.net.Address = undefined;
            var from_len: posix.socklen_t = @sizeOf(std.net.Address);
            return posix.recvfrom(self.fd, buf, 0, &from.any, &from_len);
        }
    }

    /// 自动重新连接（切换到下一个可用中继）
    pub fn reconnect(self: *RelayClient) !void {
        if (self.fd != invalid_socket) {
            posix.close(self.fd);
            self.fd = invalid_socket;
        }
        self.registered = false;

        // 尝试下一个中继
        const next = (self.current_relay_index + 1) % self.config.relays.len;
        for (0..self.config.relays.len) |i| {
            const idx = (next + i) % self.config.relays.len;
            const relay = self.config.relays[idx];
            const addr = resolveRelay(self.alloc, relay) catch continue;

            const fd = if (self.config.use_tcp)
                connectTCP(addr, self.config.timeout_ms) catch continue
            else
                connectUDP(addr) catch continue;

            self.fd = fd;
            self.relay_addr = addr;
            self.current_relay_index = idx;
            try self.register();
            return;
        }
        return error.AllRelaysFailed;
    }

    /// PING 心跳
    pub fn sendPing(self: *RelayClient) !void {
        var frame: [22]u8 = undefined;
        frame[0] = CMD_CTRL;
        frame[1] = CTRL_PING;
        @memcpy(frame[2..22], &self.config.node_id);
        if (self.config.use_tcp) {
            _ = try posix.write(self.fd, &frame);
        } else {
            _ = try posix.sendto(self.fd, &frame, 0, &self.relay_addr.any, self.relay_addr.getOsSockLen());
        }
    }

    // ── 内部方法 ──

    fn sendRegister(self: *RelayClient) !void {
        var frame: [54]u8 = undefined;
        frame[0] = CMD_CTRL;
        frame[1] = CTRL_REGISTER;
        @memcpy(frame[2..22], &self.config.node_id);
        @memcpy(frame[22..54], &self.config.public_key);

        if (self.config.use_tcp) {
            _ = try posix.write(self.fd, &frame);
        } else {
            _ = try posix.sendto(self.fd, &frame, 0, &self.relay_addr.any, self.relay_addr.getOsSockLen());
        }
    }

    fn recvChallenge(self: *RelayClient) ![32]u8 {
        var buf: [34]u8 = undefined;
        const n = if (self.config.use_tcp) try posix.read(self.fd, &buf) else blk: {
            var from: std.net.Address = undefined;
            var from_len: posix.socklen_t = @sizeOf(std.net.Address);
            break :blk try posix.recvfrom(self.fd, &buf, 0, &from.any, &from_len);
        };

        if (n < 34) return error.InvalidResponse;
        if (buf[0] != CMD_CTRL or buf[1] != CTRL_CHALLENGE) return error.UnexpectedResponse;

        var challenge: [32]u8 = undefined;
        @memcpy(&challenge, buf[2..34]);
        return challenge;
    }

    fn sendAuth(self: *RelayClient, challenge: [32]u8) !void {
        // 用 ED25519 签名挑战
        const key_pair = try Ed25519.KeyPair.generateDeterministic(self.config.secret_key);
        const sig = try key_pair.sign(&challenge, null);

        var frame: [86]u8 = undefined;
        frame[0] = CMD_CTRL;
        frame[1] = CTRL_AUTH;
        @memcpy(frame[2..22], &self.config.node_id);
        const sig_bytes = sig.toBytes();
        @memcpy(frame[22..86], &sig_bytes);

        if (self.config.use_tcp) {
            _ = try posix.write(self.fd, &frame);
        } else {
            _ = try posix.sendto(self.fd, &frame, 0, &self.relay_addr.any, self.relay_addr.getOsSockLen());
        }
    }

    fn waitAuthResult(self: *RelayClient) !void {
        var buf: [2]u8 = undefined;
        const n = if (self.config.use_tcp) try posix.read(self.fd, &buf) else blk: {
            var from: std.net.Address = undefined;
            var from_len: posix.socklen_t = @sizeOf(std.net.Address);
            break :blk try posix.recvfrom(self.fd, &buf, 0, &from.any, &from_len);
        };
        if (n < 2) return error.InvalidResponse;
        if (buf[0] != CMD_CTRL) return error.UnexpectedResponse;
        if (buf[1] == CTRL_AUTH_OK) return;
        if (buf[1] == CTRL_AUTH_FAIL) return error.AuthenticationFailed;
        return error.UnexpectedResponse;
    }

    /// Reader 线程：持续接收数据，处理控制消息
    pub fn readerLoop(self: *RelayClient, data_callback: *const fn (data: []const u8) void) void {
        self.running = true;
        var buf: [65536]u8 = undefined;
        var last_ping_ms: i64 = std.time.milliTimestamp();

        while (self.running) {
            if (self.config.use_tcp) {
                setRecvTimeout(self.fd, 3000);
            }

            const n = if (self.config.use_tcp)
                posix.read(self.fd, &buf) catch |err| {
                    if (err == error.WouldBlock or err == error.Timeout) {
                        // 心跳
                        const now = std.time.milliTimestamp();
                        if (now - last_ping_ms > @as(i64, @intCast(self.config.heartbeat_interval_ms))) {
                            self.sendPing() catch {};
                            last_ping_ms = now;
                        }
                        return; // TCP 断线处理在外层
                    }
                    if (err == error.ConnectionClosed) return;
                    return;
                }
            else
                blk: {
                    var from_addr: std.net.Address = undefined;
                    var from_len: posix.socklen_t = @sizeOf(std.net.Address);
                    setRecvTimeout(self.fd, 3000);
                    break :blk posix.recvfrom(self.fd, &buf, 0, &from_addr.any, &from_len) catch |err| {
                        if (err == error.WouldBlock or err == error.Timeout) {
                            const now = std.time.milliTimestamp();
                            if (now - last_ping_ms > @as(i64, @intCast(self.config.heartbeat_interval_ms))) {
                                self.sendPing() catch {};
                                last_ping_ms = now;
                            }
                            continue;
                        }
                        return;
                    };
                };

            if (n == 0) return;

            last_ping_ms = std.time.milliTimestamp();

            const msg_type = buf[0];
            const payload = buf[1..n];

            switch (msg_type) {
                CMD_CTRL => {
                    if (payload.len < 1) continue;
                    const ctrl_type = payload[0];
                    switch (ctrl_type) {
                        CTRL_PING => {
                            // 回复 PONG
                            var pong: [2]u8 = .{ CMD_CTRL, CTRL_PONG };
                            _ = posix.write(self.fd, &pong) catch {};
                        },
                        CTRL_PONG => {},
                        else => {},
                    }
                },
                CMD_DATA => {
                    // 收到的转发数据，去掉类型前缀回调
                    if (payload.len > 0) data_callback(payload);
                },
                else => {},
            }
        }
    }
};

// ── 辅助函数 ──

fn resolveRelay(alloc: std.mem.Allocator, relay: RelayAddr) !std.net.Address {
    const list = try std.net.getAddressList(alloc, relay.host, relay.port);
    defer list.deinit();
    if (list.addrs.len == 0) return error.HostNotFound;
    // 优先 IPv4
    for (list.addrs) |a| {
        if (a.any.family == posix.AF.INET) return a;
    }
    return list.addrs[0];
}

fn connectTCP(addr: std.net.Address, timeout_ms: u64) !posix.socket_t {
    _ = timeout_ms;
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);
    try posix.connect(fd, &addr.any, addr.getOsSockLen());
    return fd;
}

fn connectUDP(_: std.net.Address) !posix.socket_t {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    errdefer posix.close(fd);
    // 绑定随机端口
    const bind_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    try posix.bind(fd, &bind_addr.any, bind_addr.getOsSockLen());
    return fd;
}

fn setRecvTimeout(fd: posix.socket_t, timeout_ms: u64) void {
    const tv = posix.timeval{
        .sec = @as(isize, @intCast(timeout_ms / 1000)),
        .usec = @as(isize, @intCast((timeout_ms % 1000) * 1000)),
    };
    _ = posix.system.setsockopt(
        @as(i32, @intCast(fd)),
        @as(u32, @intCast(posix.SOL.SOCKET)),
        @as(u32, @intCast(posix.SO.RCVTIMEO)),
        @as(*const posix.timeval, @ptrCast(&tv)),
        @as(u32, @intCast(@sizeOf(posix.timeval))),
    );
}
