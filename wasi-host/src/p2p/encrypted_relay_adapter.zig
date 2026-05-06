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

    /// 连续失败次数（指数退避）
    consecutive_failures: u32 = 0,
    /// 当前退避截止时间戳（毫秒）
    last_backoff_end_ms: i64 = 0,

    /// 当前中继索引（relay switching）
    relay_index: usize = 0,
    /// 当前中继的连续尝试次数
    attempts_on_relay: u32 = 0,
    /// 每个中继最大尝试次数后切换
    relay_switch_threshold: u32 = 3,
    /// 所有中继已轮完仍不可用
    relays_exhausted: bool = false,

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

    /// 重置 exhausted 状态（收到控制节点审批后调用）
    pub fn resetExhausted(self: *EncryptedRelayAdapter) void {
        self.relays_exhausted = false;
        self.relay_index = 0;
        self.attempts_on_relay = 0;
        self.consecutive_failures = 0;
        self.connected = false;
        std.debug.print("[encrypted_relay] 已重置 exhausted 状态\n", .{});
    }

    pub fn connect(self: *EncryptedRelayAdapter) !void {
        if (self.connected) return;
        try self.client.connectAndRegister();
        self.connected = true;
        self.consecutive_failures = 0;
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
                self.consecutive_failures = 0;
                return copy_len;
            }
            std.time.sleep(1 * std.time.ns_per_ms);
        }

        // 超时 — 指数退避 + 中继切换
        self.connected = false;
        self.consecutive_failures += 1;
        self.attempts_on_relay += 1;

        // 当前中继尝试次数达到阈值 → 切换下一个中继
        if (self.attempts_on_relay >= self.relay_switch_threshold) {
            self.relay_index += 1;
            self.attempts_on_relay = 0;
            if (self.relay_index >= self.config.relays.len) {
                self.relays_exhausted = true;
                std.debug.print("[encrypted_relay] 所有 {d} 个中继均不可用, 标记 exhausted\n", .{self.config.relays.len});
            }
        }

        // 指数退避
        const backoff_ms = @min(
            @as(u64, 1000) * (@as(u64, 1) << @min(self.consecutive_failures, @as(u32, 6))),
            @as(u64, 60000),
        );
        self.last_backoff_end_ms = std.time.milliTimestamp() + @as(i64, @intCast(backoff_ms));
        std.debug.print("[encrypted_relay] 超时退避 {d}ms (连续失败#{d}, 中继[{d}])\n", .{ backoff_ms, self.consecutive_failures, self.relay_index });
        std.time.sleep(backoff_ms * @as(u64, std.time.ns_per_ms));

        // 重连 — 如果 relays_exhausted 则跳过
        if (!self.relays_exhausted) {
            self.client.connectTo(self.relay_index) catch {
                self.connected = false;
                return error.Timeout;
            };
            self.client.register() catch {
                self.connected = false;
                return error.Timeout;
            };
            self.connected = true;
            std.debug.print("[encrypted_relay] 重连成功: 中继[{d}]\n", .{self.relay_index});
        }
        return error.Timeout;
    }

    pub fn startReaderLoop(self: *EncryptedRelayAdapter) !std.Thread {
        return try std.Thread.spawn(.{}, readerLoopFn, .{self});
    }

    fn readerLoopFn(adapter: *EncryptedRelayAdapter) void {
        var buf: [65536]u8 = undefined;
        var consecutive_fails: u32 = 0;

        while (true) {
            if (adapter.relays_exhausted) {
                std.debug.print("[encrypted_relay/reader] 所有中继不可用, reader 退出\n", .{});
                return;
            }

            setRecvTimeout(adapter.client.fd, 2000);

            const n = posix.read(adapter.client.fd, &buf) catch |err| {
                if (err == error.WouldBlock or err == error.Timeout) {
                    consecutive_fails = 0;
                    adapter.client.sendPing() catch {};
                    continue;
                }

                // 连接断开 — 指数退避重连
                consecutive_fails += 1;
                adapter.connected = false;

                if (adapter.relays_exhausted) return;

                const backoff_ms = @min(
                    @as(u64, 1000) * (@as(u64, 1) << @min(consecutive_fails, @as(u32, 6))),
                    @as(u64, 60000),
                );
                std.debug.print("[encrypted_relay/reader] 断开, {d}ms 后重连(#{d})\n", .{ backoff_ms, consecutive_fails });
                std.time.sleep(backoff_ms * @as(u64, std.time.ns_per_ms));

                if (adapter.relays_exhausted) return;

                adapter.client.connectTo(adapter.relay_index) catch continue;
                adapter.client.register() catch continue;
                adapter.connected = true;
                consecutive_fails = 0;
                std.debug.print("[encrypted_relay/reader] 重连成功\n", .{});
                continue;
            };
            if (n == 0) {
                consecutive_fails += 1;
                adapter.connected = false;
                if (adapter.relays_exhausted) return;
                const backoff_ms = @min(@as(u64, 1000) * (@as(u64, 1) << @min(consecutive_fails, 6)), 60000);
                std.time.sleep(backoff_ms * @as(u64, std.time.ns_per_ms));
                adapter.client.connectTo(adapter.relay_index) catch continue;
                adapter.client.register() catch continue;
                adapter.connected = true;
                consecutive_fails = 0;
                continue;
            }

            consecutive_fails = 0;

            // PING/PONG 控制消息
            if (buf[0] == relay_client.CMD_CTRL) {
                if (n >= 2 and buf[1] == relay_client.CTRL_PING) {
                    const pong = [_]u8{ relay_client.CMD_CTRL, relay_client.CTRL_PONG };
                    _ = posix.write(adapter.client.fd, &pong) catch {};
                }
                continue;
            }

            if (buf[0] != relay_client.CMD_DATA) continue;

            // sendRequest 挂起中 → 存为响应
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
            if (self.relays_exhausted) return error.NotConnected;
            try self.client.connectAndRegister();
            self.connected = true;
            self.consecutive_failures = 0;
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
