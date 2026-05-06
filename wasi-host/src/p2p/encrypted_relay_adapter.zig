/// Encrypted Relay Adapter — 单 reader 架构
///
/// 包装 relay/client.RelayClient，为 ChordNode.sendAndWait() 提供
/// 同步请求/响应模式。
///
/// ## 单 Reader 架构
///
/// readerLoop 是唯一读取 TCP fd 的线程，消除了 readerLoop 与 sendRequest
/// 之间的 fd 竞争（原 ~30% 超时率）。sendRequest 写入请求后轮询共享响应缓冲。
///
/// 转发数据（其他节点的入站消息）通过 readerLoop 注入本地 UDP 端口
/// （127.0.0.1:listen_port），由 Chord 节点的消息处理管线处理。
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
    listen_port: u16 = 20808,
};

/// 单请求挂起状态 — readerLoop 与 sendRequest 之间的共享通信区
const PendingResponse = struct {
    active: bool = false,
    ready: bool = false,
    data: [65536]u8 = undefined,
    len: usize = 0,
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

    /// 单 reader 共享响应区 — 无锁，仅两个原子 bool
    pending: PendingResponse,

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
            .pending = .{},
        };
    }

    pub fn deinit(self: *EncryptedRelayAdapter) void {
        self.client.deinit();
    }

    pub fn connect(self: *EncryptedRelayAdapter) !void {
        if (self.connected) return;
        try self.client.connectAndRegister();
        self.connected = true;
    }

    /// 同步发送请求并等待响应 — 不读取 fd，由 readerLoop 负责填充响应
    pub fn sendRequest(self: *EncryptedRelayAdapter, target_id: [20]u8, data: []const u8, resp_buf: []u8, timeout_ms: u64) !usize {
        try self.ensureConnected();

        // 注册等待 — readerLoop 会将下一条 CMD_DATA 存入 pending
        self.pending.active = true;
        self.pending.ready = false;
        defer self.pending.active = false;

        try self.client.sendTo(target_id, data);

        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (std.time.milliTimestamp() < deadline) {
            if (self.pending.ready) {
                const n = self.pending.len;
                const copy_len = @min(n, resp_buf.len);
                @memcpy(resp_buf[0..copy_len], self.pending.data[0..copy_len]);
                self.pending.ready = false;
                return copy_len;
            }
            std.time.sleep(1 * std.time.ns_per_ms);
        }

        self.connected = false;
        self.client.reconnect() catch {};
        self.connected = self.client.registered;
        return error.Timeout;
    }

    pub fn startReaderLoop(self: *EncryptedRelayAdapter) !std.Thread {
        return try std.Thread.spawn(.{}, readerLoopFn, .{self});
    }

    fn readerLoopFn(adapter: *EncryptedRelayAdapter) void {
        var buf: [65536]u8 = undefined;

        while (true) {
            setRecvTimeout(adapter.client.fd, 2000);

            const n = posix.read(adapter.client.fd, &buf) catch |err| {
                if (err == error.WouldBlock or err == error.Timeout) {
                    adapter.client.sendPing() catch {};
                    continue;
                }
                if (err == error.ConnectionClosed or err == error.ConnectionResetByPeer) break;
                std.debug.print("[encrypted_relay/reader] 错误: {}\n", .{err});
                continue;
            };
            if (n == 0) break;

            // PING/PONG 控制消息
            if (buf[0] == relay_client.CMD_CTRL) {
                if (n >= 2 and buf[1] == relay_client.CTRL_PING) {
                    const pong = [_]u8{ relay_client.CMD_CTRL, relay_client.CTRL_PONG };
                    _ = posix.write(adapter.client.fd, &pong) catch {};
                }
                continue;
            }

            if (buf[0] != relay_client.CMD_DATA) continue;

            // sendRequest 挂起中 → 存为响应（忽略转发数据 vs 响应的歧义，
            // Chord 层验证不匹配时会重试）
            if (adapter.pending.active) {
                if (n > 21) {
                    adapter.pending.len = n - 21;
                    @memcpy(adapter.pending.data[0..adapter.pending.len], buf[21..n]);
                    adapter.pending.ready = true;
                }
                continue;
            }

            // 转发数据：包含 [sender_id(20)][payload]，通过本地 UDP 注入 Chord 节点
            if (n > 21) {
                const sender_id = buf[1..21];
                const payload = buf[21..n];

                const tmp_udp = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP) catch continue;
                defer posix.close(tmp_udp);

                const tmp_bind = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
                posix.bind(tmp_udp, &tmp_bind.any, tmp_bind.getOsSockLen()) catch continue;

                const target_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, adapter.config.listen_port);
                _ = posix.sendto(tmp_udp, payload, 0, &target_addr.any, target_addr.getOsSockLen()) catch continue;

                var resp_buf: [65536]u8 = undefined;
                var poll_fds = [_]posix.pollfd{.{ .fd = tmp_udp, .events = posix.POLL.IN, .revents = 0 }};
                const rc = posix.poll(&poll_fds, 5000) catch 0;
                if (rc > 0 and poll_fds[0].revents & posix.POLL.IN != 0) {
                    var resp_addr: std.net.Address = undefined;
                    var resp_addr_len: posix.socklen_t = @sizeOf(std.net.Address);
                    const resp_n = posix.recvfrom(tmp_udp, &resp_buf, 0, &resp_addr.any, &resp_addr_len) catch continue;
                    if (resp_n > 0) {
                        var frame: [1 + 20 + 65536]u8 = undefined;
                        frame[0] = relay_client.CMD_DATA;
                        @memcpy(frame[1..21], sender_id);
                        @memcpy(frame[21..][0..resp_n], resp_buf[0..resp_n]);
                        _ = posix.write(adapter.client.fd, frame[0 .. 21 + resp_n]) catch {};
                    }
                }
            }
        }
    }

    fn ensureConnected(self: *EncryptedRelayAdapter) !void {
        if (!self.connected) {
            try self.client.connectAndRegister();
            self.connected = true;
        }
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
