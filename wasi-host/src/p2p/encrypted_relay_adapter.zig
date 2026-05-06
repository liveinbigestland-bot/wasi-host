/// Encrypted Relay Adapter — 同步 sendRequest 接口适配层
///
/// 包装 relay/client.RelayClient，为 ChordNode.sendAndWait() 提供
/// 同步请求/响应模式。使用 TCP 持久连接，在等待响应时处理 PING/PONG。
///
/// 同时运行 readerLoop 后台线程，接收其他节点转发来的数据，
/// 通过本地 UDP 注入到 Chord 节点的消息处理流水线。
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
    /// 本地 Chord 监听端口（用于 readerLoop 注入数据）
    listen_port: u16 = 20808,
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

    /// sendRequest 进行中时暂停 readerLoop，避免 fd 读取竞争
    reader_pause: std.atomic.Value(bool),

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
            .reader_pause = std.atomic.Value(bool).init(false),
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
    /// 等待期间暂停 readerLoop 避免 fd 竞争。
    pub fn sendRequest(self: *EncryptedRelayAdapter, target_id: [20]u8, data: []const u8, resp_buf: []u8, timeout_ms: u64) !usize {
        try self.ensureConnected();

        // 暂停 readerLoop，避免与 readResponse 竞争同一 fd
        self.reader_pause.store(true, .monotonic);
        defer self.reader_pause.store(false, .monotonic);

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

    pub fn startReaderLoop(self: *EncryptedRelayAdapter) !std.Thread {
        return try std.Thread.spawn(.{}, readerLoopFn, .{self});
    }

    fn readerLoopFn(adapter: *EncryptedRelayAdapter) void {
        var buf: [65536]u8 = undefined;

        while (true) {
            // sendRequest 进行中时暂停读取
            if (adapter.reader_pause.load(.monotonic)) {
                std.time.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            setRecvTimeout(adapter.client.fd, 2000);

            const n = posix.read(adapter.client.fd, &buf) catch |err| {
                if (err == error.WouldBlock or err == error.Timeout) {
                    // 定期 PING
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

            // 转发数据：包含 [sender_id(20)][payload]，通过本地 UDP 注入 Chord 节点
            if (buf[0] == relay_client.CMD_DATA and n > 21) {
                const sender_id = buf[1..21];
                const payload = buf[21..n];

                // 创建临时 UDP socket 发送到本地 Chord 端口
                const tmp_udp = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP) catch continue;
                defer posix.close(tmp_udp);

                const tmp_bind = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
                posix.bind(tmp_udp, &tmp_bind.any, tmp_bind.getOsSockLen()) catch continue;

                const target_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, adapter.config.listen_port);
                _ = posix.sendto(tmp_udp, payload, 0, &target_addr.any, target_addr.getOsSockLen()) catch continue;

                // 等待响应，然后通过中继发回给发送方
                var resp_buf: [65536]u8 = undefined;
                var poll_fds = [_]posix.pollfd{.{ .fd = tmp_udp, .events = posix.POLL.IN, .revents = 0 }};
                const rc = posix.poll(&poll_fds, 5000) catch 0;
                if (rc > 0 and poll_fds[0].revents & posix.POLL.IN != 0) {
                    var resp_addr: std.net.Address = undefined;
                    var resp_addr_len: posix.socklen_t = @sizeOf(std.net.Address);
                    const resp_n = posix.recvfrom(tmp_udp, &resp_buf, 0, &resp_addr.any, &resp_addr_len) catch continue;
                    if (resp_n > 0) {
                        // 构建 [CMD_DATA][sender_id][response] 发回中继
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

            // forwardTCP 写入 [CMD_DATA][sender_id(20)][payload]
            if (self.read_buf[0] == relay_client.CMD_DATA and n > 21) {
                const payload = self.read_buf[21..n];
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
