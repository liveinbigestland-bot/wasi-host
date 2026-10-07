/// Encrypted Relay Adapter �?�?reader 架构
///
/// 包装 relay/client.RelayClient，为 ChordNode.sendAndWait() 提供
/// 同步请求/响应模式�?
///
/// ## �?Reader 架构
///
/// readerLoop 是唯一读取 TCP fd 的线程，消除�?readerLoop �?sendRequest
/// 之间�?fd 竞争（原 ~30% 超时率）。sendRequest 写入请求后轮询共享响应缓冲�?
///
/// 转发数据（其他节点的入站消息）通过 readerLoop 注入本地 UDP 端口
/// �?27.0.0.1:listen_port），�?Chord 节点的消息处理管线处理�?
const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const logging = @import("logging");
const log = logging.log;

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

/// 单请求挂起状�?�?readerLoop �?sendRequest 之间的共享通信�?
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

    /// 当前中继索引（relay switching�?
    relay_index: usize = 0,
    /// 当前中继的连续尝试次�?
    attempts_on_relay: u32 = 0,
    /// 每个中继最大尝试次数后切换
    relay_switch_threshold: u32 = 3,
    /// 所有中继已轮完仍不可用
    relays_exhausted: bool = false,

    /// 连接建立互斥锁：reader 断线重连与 sendRequest 的 ensureConnected
    /// 会并发 connectTo+register，导致同 NodeID 双连接在服务器端互相踢
    connect_mutex: std.Thread.Mutex = .{},

    /// 请求串行化锁：整条中继连接只有一个 pending 响应槽且无请求关联 ID，
    /// 并发 sendRequest 会互相偷响应（ProxyWrongType）或吞掉对方响应。
    /// 串行化后，挂起期内的入站帧只需区分「我的响应」与「他人请求」。
    request_mutex: std.Thread.Mutex = .{},

    read_buf: [65536]u8,

    /// �?reader 共享响应�?�?无锁，仅两个原子 bool
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
        log.info("[encrypted_relay] 已重置 exhausted 状态", .{});
    }

    pub fn connect(self: *EncryptedRelayAdapter) !void {
        if (self.connected) return;
        try self.client.connectAndRegister();
        self.connected = true;
        self.consecutive_failures = 0;
    }

    /// 同步发送请求并等待响应 — 不读取 fd，由 readerLoop 负责填充响应
    pub fn sendRequest(self: *EncryptedRelayAdapter, target_id: [20]u8, data: []const u8, resp_buf: []u8, timeout_ms: u64) !usize {
        // 串行化整个请求/响应周期（见 request_mutex 注释）
        self.request_mutex.lock();
        defer self.request_mutex.unlock();

        try self.ensureConnected();

        // 注册等待 �?readerLoop 会将下一�?CMD_DATA 存入 pending
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

        // 超时 �?不主动重连，readerLoop 已独立处理实际断线重�?
        // sendRequest 超时通常意味着目标节点暂时不可达，而非本节点连接断开
        // 若在此处重连会踢掉当前会话，导致其他节点对本节点的转发也失败（级联效应）
        self.consecutive_failures += 1;
        self.attempts_on_relay += 1;
        return error.Timeout;
    }

    pub fn startReaderLoop(self: *EncryptedRelayAdapter) !std.Thread {
        return try std.Thread.spawn(.{}, readerLoopFn, .{self});
    }

    fn readerLoopFn(adapter: *EncryptedRelayAdapter) void {
        var buf: [65536]u8 = undefined;
        var consecutive_fails: u32 = 0;
        var last_read_ms = std.time.milliTimestamp();

        // 僵死判定：此时长内未收到任何入站字节（PONG / 服务器 PING / 数据），
        // 说明 NAT 映射可能已静默失效（对端 RST 送不进来），主动断开重连。
        const dead_peer_ms: i64 = 10_000;

        while (true) {
            if (adapter.relays_exhausted) {
                log.info("[encrypted_relay/reader] 所有中继不可用, reader 退出", .{});
                return;
            }

            setRecvTimeout(adapter.client.fd, 2000);

            const n = posix.read(adapter.client.fd, &buf) catch |err| {
                if (err == error.WouldBlock or err == error.Timeout) {
                    const now = std.time.milliTimestamp();
                    adapter.client.sendPing() catch {};
                    if (now - last_read_ms <= dead_peer_ms) {
                        consecutive_fails = 0;
                        continue;
                    }
                    log.warn("[encrypted_relay/reader] {}ms 无任何入站，判定连接僵死（NAT 静默失效），强制重连", .{now - last_read_ms});
                    // 落入下方断线重连流程
                }

                // 连接断开 �?指数退避重�?
                consecutive_fails += 1;
                adapter.connected = false;

                if (adapter.relays_exhausted) return;

                // 连续失败达到阈�?�?切换中继
                adapter.attempts_on_relay += 1;
                if (adapter.attempts_on_relay >= adapter.relay_switch_threshold) {
                    adapter.relay_index += 1;
                    adapter.attempts_on_relay = 0;
                    if (adapter.relay_index >= adapter.config.relays.len) {
                        adapter.relays_exhausted = true;
                        log.info("[encrypted_relay/reader] 所有 {} 个中继均不可用，标记 exhausted", .{adapter.config.relays.len});
                        return;
                    }
                    log.info("[encrypted_relay/reader] 切换到中继[{}]", .{adapter.relay_index});
                }

                const backoff_ms = @min(
                    @as(u64, 1000) * (@as(u64, 1) << @min(consecutive_fails, @as(u32, 6))),
                    @as(u64, 60000),
                );
                log.info("[encrypted_relay/reader] 断开, {}ms 后重试#{}, 中继[{}])", .{ backoff_ms, consecutive_fails, adapter.relay_index });
                std.time.sleep(backoff_ms * @as(u64, std.time.ns_per_ms));

                if (adapter.relays_exhausted) return;

                if (adapter.readerConnectLocked()) {
                    consecutive_fails = 0;
                    last_read_ms = std.time.milliTimestamp();
                    log.info("[encrypted_relay/reader] 重连成功", .{});
                }
                continue;
            };
            if (n == 0) {
                consecutive_fails += 1;
                adapter.connected = false;
                if (adapter.relays_exhausted) return;

                adapter.attempts_on_relay += 1;
                if (adapter.attempts_on_relay >= adapter.relay_switch_threshold) {
                    adapter.relay_index += 1;
                    adapter.attempts_on_relay = 0;
                    if (adapter.relay_index >= adapter.config.relays.len) {
                        adapter.relays_exhausted = true;
                        log.info("[encrypted_relay/reader] 所有 {} 个中继均不可用，标记 exhausted", .{adapter.config.relays.len});
                        return;
                    }
                }

                const backoff_ms = @min(@as(u64, 1000) * (@as(u64, 1) << @min(consecutive_fails, 6)), 60000);
                std.time.sleep(backoff_ms * @as(u64, std.time.ns_per_ms));
                if (adapter.readerConnectLocked()) {
                    consecutive_fails = 0;
                    last_read_ms = std.time.milliTimestamp();
                }
                continue;
            }

            consecutive_fails = 0;
            last_read_ms = std.time.milliTimestamp();

            // PING/PONG 控制消息
            if (buf[0] == relay_client.CMD_CTRL) {
                if (n >= 2 and buf[1] == relay_client.CTRL_PING) {
                    const pong = [_]u8{ relay_client.CMD_CTRL, relay_client.CTRL_PONG };
                    _ = posix.write(adapter.client.fd, &pong) catch {};
                }
                continue;
            }

            if (buf[0] != relay_client.CMD_DATA) continue;

            // sendRequest 挂起�?�?存为响应
            if (n <= 21) continue;

            // sendRequest 挂起中：只有「响应类型」的帧才填入 pending 槽。
            // 请求类型（notify/ping/find_successor 等）是其他节点的入站消息，
            // 必须照常注入本地 Chord 节点——曾因一律当作响应吞掉，
            // 导致 greet notify 在对端 stabilize 请求挂起期间被静默丢弃。
            if (adapter.pending.active) {
                const payload = buf[21..n];
                if (isChordResponseType(payload)) {
                    adapter.pending.len = payload.len;
                    @memcpy(adapter.pending.data[0..payload.len], payload);
                    adapter.pending.ready = true;
                } else {
                    adapter.injectFromRelay(buf[1..21], payload);
                }
                continue;
            }

            // 转发数据：包�?[sender_id(20)][payload]，通过本地 UDP 注入 Chord 节点
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

    /// 将中继转发的入站帧经本地 UDP 注入 Chord 节点，并同步等待 Chord 的
    /// 响应回写中继（保持既有行为；注入期间 reader 阻塞是已知限制）。
    fn injectFromRelay(adapter: *EncryptedRelayAdapter, sender_id: []const u8, payload: []const u8) void {
        const tmp_udp = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP) catch return;
        defer posix.close(tmp_udp);

        const tmp_bind = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        posix.bind(tmp_udp, &tmp_bind.any, tmp_bind.getOsSockLen()) catch return;

        const target_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, adapter.config.listen_port);
        _ = posix.sendto(tmp_udp, payload, 0, &target_addr.any, target_addr.getOsSockLen()) catch return;

        var resp_buf: [65536]u8 = undefined;
        var poll_fds = [_]posix.pollfd{.{ .fd = tmp_udp, .events = posix.POLL.IN, .revents = 0 }};
        const rc = posix.poll(&poll_fds, 5000) catch 0;
        if (rc > 0 and poll_fds[0].revents & posix.POLL.IN != 0) {
            var resp_addr: std.net.Address = undefined;
            var resp_addr_len: posix.socklen_t = @sizeOf(std.net.Address);
            const resp_n = posix.recvfrom(tmp_udp, &resp_buf, 0, &resp_addr.any, &resp_addr_len) catch return;
            if (resp_n > 0) {
                var frame: [1 + 20 + 65536]u8 = undefined;
                frame[0] = relay_client.CMD_DATA;
                @memcpy(frame[1..21], sender_id);
                @memcpy(frame[21..][0..resp_n], resp_buf[0..resp_n]);
                _ = posix.write(adapter.client.fd, frame[0 .. 21 + resp_n]) catch {};
            }
        }
    }

    /// 判断中继帧负载（Chord 消息，JSON 编码 {"<type>":...}）是否为响应类型。
    /// 用于挂起请求期间区分「我的响应」与「他人入站请求」。
    fn isChordResponseType(payload: []const u8) bool {
        if (payload.len < 3 or payload[0] != '{') return false;
        // 跳过 "{" 与首个键名的开头引号
        var i: usize = 1;
        while (i < payload.len and (payload[i] == ' ' or payload[i] == '"')) : (i += 1) {}
        const resp_names = [_][]const u8{
            "pong",          "find_successor_resp", "get_predecessor_resp",
            "notify_ok",     "ping_resp",           "dht_put_resp",
            "dht_get_resp",  "dht_delete_resp",     "dht_replicate_resp",
            "identity_resp", "relay_service_resp",
        };
        for (resp_names) |nm| {
            // 尾部引号检查避免前缀误判（如 notify vs notify_ok、dht_get vs dht_get_resp）
            if (i + nm.len < payload.len and std.mem.eql(u8, payload[i .. i + nm.len], nm) and payload[i + nm.len] == '"') return true;
        }
        return false;
    }

    /// reader 持锁建立连接（与 ensureConnected 互斥）。
    /// 返回 true = 已连接（含其他线程抢先建好的情况）
    fn readerConnectLocked(adapter: *EncryptedRelayAdapter) bool {
        adapter.connect_mutex.lock();
        defer adapter.connect_mutex.unlock();
        if (adapter.connected) return true;
        adapter.client.connectTo(adapter.relay_index) catch return false;
        adapter.client.register() catch return false;
        adapter.connected = true;
        return true;
    }

    fn ensureConnected(self: *EncryptedRelayAdapter) !void {
        if (self.connected) return;
        self.connect_mutex.lock();
        defer self.connect_mutex.unlock();
        if (self.connected) return; // 已被 reader/其他线程重连
        if (self.relays_exhausted) return error.NotConnected;
        try self.client.connectTo(self.relay_index);
        try self.client.register();
        self.connected = true;
        self.consecutive_failures = 0;
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
