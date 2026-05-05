/// Encrypted Relay Adapter — 同步 sendRequest 接口适配层
///
/// 包装 relay/client.RelayClient，为 ChordNode.sendAndWait() 提供
/// 同步请求/响应模式。使用 TCP 持久连接，在等待响应时处理 PING/PONG。
const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const relay_client = @import("../relay/client.zig");
const NodeID = @import("../relay/registry.zig").NodeID;

pub const RelayAddr = relay_client.RelayAddr;

pub const EncryptedRelayConfig = struct {
    enabled: bool = false,
    relays: []const RelayAddr = &.{},
    use_tcp: bool = true,
    heartbeat_interval_ms: u64 = 25_000,
    timeout_ms: u64 = 5_000,
};

pub const EncryptedRelayAdapter = struct {
    alloc: std.mem.Allocator,
    config: EncryptedRelayConfig,
    node_id: [20]u8,
    secret_key: [32]u8,
    public_key: [32]u8,

    client: relay_client.RelayClient,
    connected: bool,

    read_buf: [65536]u8,

    pub fn init(alloc: std.mem.Allocator, config: EncryptedRelayConfig, node_id: [20]u8, secret_key: [32]u8, public_key: [32]u8) !EncryptedRelayAdapter {
        const client_config = relay_client.ClientConfig{
            .relays = config.relays,
            .node_id = node_id,
            .secret_key = secret_key,
            .public_key = public_key,
            .use_tcp = config.use_tcp,
            .timeout_ms = config.timeout_ms,
            .heartbeat_interval_ms = config.heartbeat_interval_ms,
        };

        return EncryptedRelayAdapter{
            .alloc = alloc,
            .config = config,
            .node_id = node_id,
            .secret_key = secret_key,
            .public_key = public_key,
            .client = try relay_client.RelayClient.init(alloc, client_config),
            .connected = false,
            .read_buf = undefined,
        };
    }

    pub fn deinit(self: *EncryptedRelayAdapter) void {
        self.client.deinit();
    }

    /// 连接并注册到加密中继（自动重连备用中继）
    pub fn connect(self: *EncryptedRelayAdapter) !void {
        if (self.connected) return;
        try self.client.connectAndRegister();
        self.connected = true;
    }

    /// 同步发送请求并等待响应
    ///
    /// 发送 CMD_DATA 帧到中继，阻塞等待响应。
    /// 等待期间处理 PING/PONG 心跳，响应超时返回 error.Timeout。
    pub fn sendRequest(self: *EncryptedRelayAdapter, target_id: [20]u8, data: []const u8, resp_buf: []u8, timeout_ms: u64) !usize {
        try self.ensureConnected();

        try self.client.sendTo(target_id, data);

        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        return self.readResponse(resp_buf, deadline) catch |err| {
            self.connected = false;
            if (err == error.ConnectionClosed or err == error.ConnectionLost) {
                self.client.reconnect() catch {};
                self.connected = self.client.registered;
            }
            return err;
        };
    }

    fn ensureConnected(self: *EncryptedRelayAdapter) !void {
        if (!self.connected) {
            try self.client.connectAndRegister();
            self.connected = true;
        }
    }

    /// 从 TCP 连接读取响应，处理 PING/PONG
    fn readResponse(self: *EncryptedRelayAdapter, resp_buf: []u8, deadline: i64) !usize {
        while (std.time.milliTimestamp() < deadline) {
            const remaining = deadline - std.time.milliTimestamp();
            if (remaining <= 0) return error.Timeout;

            const recv_to = @min(@as(u64, @intCast(remaining)), 3000);
            setRecvTimeout(self.client.fd, recv_to);

            const n = posix.read(self.client.fd, &self.read_buf) catch |err| {
                if (err == error.WouldBlock or err == error.Timeout) continue;
                return error.ConnectionLost;
            };
            if (n == 0) return error.ConnectionClosed;

            if (self.read_buf[0] == relay_client.CMD_CTRL) {
                if (n >= 2 and self.read_buf[1] == relay_client.CTRL_PING) {
                    const pong = [_]u8{ relay_client.CMD_CTRL, relay_client.CTRL_PONG };
                    _ = posix.write(self.client.fd, &pong) catch {};
                }
                continue;
            }
            if (self.read_buf[0] == relay_client.CMD_DATA and n > 1) {
                const payload = self.read_buf[1..n];
                const copy_len = @min(payload.len, resp_buf.len);
                @memcpy(resp_buf[0..copy_len], payload[0..copy_len]);
                return copy_len;
            }
        }
        return error.Timeout;
    }
};

fn setRecvTimeout(fd: posix.socket_t, timeout_ms: u64) void {
    if (builtin.os.tag == .windows) {
        const ms: u32 = @intCast(@min(timeout_ms, std.math.maxInt(u32)));
        _ = posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(ms)) catch {};
        return;
    }
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
