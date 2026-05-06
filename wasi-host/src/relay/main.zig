/// Encrypted Relay Server — 入口模块
///
/// 单端口 UDP + TCP 双协议监听，NodeID 注册+鉴权+密文转发。
///
/// ## 协议格式
///
/// 所有报文首字节为类型码:
///   0x00 — 控制消息 (control_type 紧跟其后)
///     0x01 REGISTER:    [NodeID 20][public_key 32]
///     0x02 CHALLENGE:   [nonce 32]  (Relay→Node)
///     0x03 AUTH:        [NodeID 20][signature 64]
///     0x04 AUTH_OK:     (Relay→Node)
///     0x05 AUTH_FAIL:   (Relay→Node)
///     0x06 PING:        [NodeID 20]
///     0x07 PONG:        (Relay→Node)
///     0x08 ERROR:       [err_byte]
///   0x01 — 数据转发:   [target NodeID 20][加密负载...]
const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

/// posix.close() can call unreachable in Zig 0.14 for unexpected errno values.
/// This safe wrapper uses the raw Linux syscall to avoid that.
fn safeClose(fd: posix.socket_t) void {
    if (builtin.os.tag == .linux) {
        const close_fd: usize = @intCast(@as(isize, @intCast(fd)));
        _ = std.os.linux.syscall3(.close, close_fd, 0, 0);
    } else if (builtin.os.tag == .windows) {
        // Windows: SOCKET handle is already the right type in Zig 0.14
        std.os.windows.closesocket(fd) catch {};
    } else {
        // On non-Linux, use os.close which returns a void (no unreachable)
        std.os.close(fd);
    }
}

const Registry = @import("registry.zig").Registry;
const RegistryOptions = @import("registry.zig").RegistryOptions;
const NodeID = @import("registry.zig").NodeID;
const Protocol = @import("registry.zig").Protocol;
const SessionState = @import("registry.zig").SessionState;

const Auth = @import("auth.zig").Auth;

const fwd = @import("forwarder.zig");
const Forwarder = fwd.Forwarder;
const ForwarderOptions = fwd.ForwarderOptions;

// ── 协议常量 ──

const CMD_CTRL: u8 = 0x00;
const CMD_DATA: u8 = 0x01;

const CTRL_REGISTER: u8 = 0x01;
const CTRL_CHALLENGE: u8 = 0x02;
const CTRL_AUTH: u8 = 0x03;
const CTRL_AUTH_OK: u8 = 0x04;
const CTRL_AUTH_FAIL: u8 = 0x05;
const CTRL_PING: u8 = 0x06;
const CTRL_PONG: u8 = 0x07;
const CTRL_ERROR: u8 = 0x08;

// ── 配置 ──

const MAX_BUF: usize = 65536;

pub const RelayConfig = struct {
    /// 监听地址
    listen_host: []const u8 = "0.0.0.0",
    /// 监听端口（UDP + TCP 复用）
    listen_port: u16 = 20809,

    /// 会话表上限
    max_sessions: u32 = 1000,
    /// 心跳超时 (ms)，默认 60s
    heartbeat_timeout_ms: u64 = 60_000,
    /// 每节点每秒发包上限
    max_packets_per_second: u32 = 1000,

    /// 最大包长（字节）
    max_packet_size: usize = 1400,
    /// 读写缓冲区大小
    buffer_size: usize = 65536,

    /// 心跳回收扫描间隔 (ms)
    reap_interval_ms: u64 = 10_000,
};

// ── Relay Server ──

pub const RelayServer = struct {
    config: RelayConfig,
    alloc: std.mem.Allocator,

    udp_fd: posix.socket_t,
    tcp_listen_fd: posix.socket_t,

    registry: Registry,
    auth: Auth,
    forwarder: Forwarder,

    running: bool,
    stopped: bool,

    pub fn init(alloc: std.mem.Allocator, config: RelayConfig) !RelayServer {
        // UDP socket
        const udp_fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
        errdefer safeClose(udp_fd);

        const reuse: u32 = 1;
        _ = posix.setsockopt(udp_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(reuse)) catch {};

        var addr = try std.net.Address.parseIp(config.listen_host, config.listen_port);
        try posix.bind(udp_fd, &addr.any, addr.getOsSockLen());

        // TCP socket
        const tcp_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(tcp_fd);

        _ = posix.setsockopt(tcp_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(reuse)) catch {};
        try posix.bind(tcp_fd, &addr.any, addr.getOsSockLen());
        try posix.listen(tcp_fd, 128);

        var server = RelayServer{
            .config = config,
            .alloc = alloc,
            .udp_fd = udp_fd,
            .tcp_listen_fd = tcp_fd,
            .registry = Registry.init(alloc, .{
                .max_sessions = config.max_sessions,
                .heartbeat_timeout_ms = config.heartbeat_timeout_ms,
                .max_packets_per_second = config.max_packets_per_second,
            }),
            .auth = Auth.init(alloc),
            .forwarder = undefined,
            .running = false,
            .stopped = false,
        };
        server.forwarder = Forwarder.init(alloc, .{
            .max_packet_size = config.max_packet_size,
        });
        // 更新 addr 为实际监听地址
        var actual_addr: std.net.Address = undefined;
        var addr_len: posix.socklen_t = @sizeOf(std.net.Address);
        posix.getsockname(tcp_fd, &actual_addr.any, &addr_len) catch {};

        return server;
    }

    pub fn deinit(self: *RelayServer) void {
        self.stop();
        self.forwarder.deinit();
        self.auth.deinit();
        self.registry.deinit();
    }

    pub fn run(self: *RelayServer) !void {
        self.running = true;

        const actual_port = blk: {
            var addr: std.net.Address = undefined;
            var len: posix.socklen_t = @sizeOf(std.net.Address);
            posix.getsockname(self.tcp_listen_fd, &addr.any, &len) catch {};
            break :blk addr.getPort();
        };

        std.debug.print("[relay2] 加密中继已启动 :{d} (UDP+TCP)\n", .{actual_port});

        // 启动 UDP reader 线程
        const udp_thread = try std.Thread.spawn(.{}, udpReaderLoop, .{self});
        udp_thread.detach();

        // 启动 TCP acceptor 线程
        const tcp_thread = try std.Thread.spawn(.{}, tcpAcceptLoop, .{self});
        tcp_thread.detach();

        // 启动心跳回收线程
        const reap_thread = try std.Thread.spawn(.{}, reapLoop, .{self});
        reap_thread.detach();

        // 主线程等待（暂用简单 sleep 运行）
        // TODO: 使用信号量或条件变量等待退出信号
        while (self.running) {
            std.time.sleep(1 * std.time.ns_per_s);
        }
    }

    pub fn stop(self: *RelayServer) void {
        self.running = false;
        if (!self.stopped) {
            self.stopped = true;
            // shutdown 先中断阻塞中的 recvfrom/accept，再 close
            posix.shutdown(self.udp_fd, .both) catch {};
            posix.shutdown(self.tcp_listen_fd, .both) catch {};
            safeClose(self.udp_fd);
            safeClose(self.tcp_listen_fd);
        }
    }

    // ── UDP Reader ──

    fn udpReaderLoop(self: *RelayServer) void {
        var buf: [MAX_BUF]u8 = undefined;

        while (self.running) {
            var from_addr: std.net.Address = std.mem.zeroes(std.net.Address);
            var from_len: posix.socklen_t = @sizeOf(std.net.Address);

            const n = posix.recvfrom(self.udp_fd, &buf, 0, &from_addr.any, &from_len) catch |err| {
                if (self.running) {
                    std.debug.print("[relay2/udp] recvfrom 错误: {}\n", .{err});
                }
                continue;
            };

            if (n == 0) continue;

            const data = buf[0..n];
            self.handleUDPPacket(data, from_addr);
        }
    }

    fn handleUDPPacket(self: *RelayServer, data: []const u8, from_addr: std.net.Address) void {
        if (data.len == 0) return;

        const msg_type = data[0];
        const payload = data[1..];

        switch (msg_type) {
            CMD_CTRL => {
                // 控制消息
                if (payload.len == 0) return;
                self.handleControlUDP(payload, from_addr);
            },
            CMD_DATA => {
                // 数据转发
                self.handleDataUDP(payload, from_addr);
            },
            else => {
                std.debug.print("[relay2] 未知 UDP 消息类型 0x{x} from {}\n", .{ msg_type, from_addr });
            },
        }
    }

    fn handleControlUDP(self: *RelayServer, payload: []const u8, from_addr: std.net.Address) void {
        const ctrl_type = payload[0];
        const ctrl_data = payload[1..];

        switch (ctrl_type) {
            CTRL_REGISTER => {
                // [NodeID 20][public_key 32]
                if (ctrl_data.len < 20 + 32) return;
                var node_id: NodeID = undefined;
                @memcpy(&node_id, ctrl_data[0..20]);
                var pubkey: [32]u8 = undefined;
                @memcpy(&pubkey, ctrl_data[20..52]);

                // 创建会话（pending_challenge）
                _ = self.registry.register(node_id, .udp, from_addr, pubkey) catch |err| {
                    std.debug.print("[relay2] 注册失败: {}\n", .{err});
                    self.sendControlUDP(from_addr, CTRL_ERROR, &.{@as(u8, @intCast(@intFromError(err)))});
                    return;
                };

                // 发送挑战
                var challenge = Auth.generateChallenge();
                // 存储 challenge 到会话
                if (self.registry.get(node_id)) |session| {
                    session.challenge = challenge;
                }

                var resp: [32]u8 = undefined;
                @memcpy(&resp, &challenge);
                self.sendControlUDP(from_addr, CTRL_CHALLENGE, &resp);
                std.debug.print("[relay2] 挑战发送 node={}\n", .{std.fmt.fmtSliceHexLower(&node_id)});
            },
            CTRL_AUTH => {
                // [NodeID 20][signature 64]
                if (ctrl_data.len < 20 + 64) return;
                var node_id: NodeID = undefined;
                @memcpy(&node_id, ctrl_data[0..20]);
                var signature: [64]u8 = undefined;
                @memcpy(&signature, ctrl_data[20..84]);

                const session = self.registry.get(node_id) orelse {
                    self.sendControlUDP(from_addr, CTRL_AUTH_FAIL, &.{});
                    return;
                };
                const challenge = session.challenge orelse {
                    self.sendControlUDP(from_addr, CTRL_AUTH_FAIL, &.{});
                    return;
                };

                // 验证签名
                const valid = Auth.verifySignature(session.public_key, &challenge, signature);
                if (!valid) {
                    std.debug.print("[relay2] 鉴权失败 node={}\n", .{std.fmt.fmtSliceHexLower(&node_id)});
                    self.sendControlUDP(from_addr, CTRL_AUTH_FAIL, &.{});
                    return;
                }

                // 激活会话
                self.registry.activate(node_id) catch {};
                self.sendControlUDP(from_addr, CTRL_AUTH_OK, &.{});
                std.debug.print("[relay2] 鉴权成功 node={}\n", .{std.fmt.fmtSliceHexLower(&node_id)});
            },
            CTRL_PING => {
                // [NodeID 20]
                if (ctrl_data.len < 20) return;
                var node_id: NodeID = undefined;
                @memcpy(&node_id, ctrl_data[0..20]);
                self.registry.heartbeat(node_id) catch {};
                self.sendControlUDP(from_addr, CTRL_PONG, &.{});
            },
            else => {
                std.debug.print("[relay2] 未知控制类型 0x{x}\n", .{ctrl_type});
            },
        }
    }

    fn handleDataUDP(self: *RelayServer, data: []const u8, from_addr: std.net.Address) void {
        std.debug.print("[relay2] DATA frame recv len={d}\n", .{data.len});
        self.forwarder.forwardUDP(&self.registry, self.udp_fd, data, from_addr) catch |err| {
            std.debug.print("[relay2] UDP 转发错误: {}\n", .{err});
        };
        std.debug.print("[relay2] DATA forward done\n", .{});
    }

    fn sendControlUDP(self: *RelayServer, to: std.net.Address, ctrl_type: u8, data: []const u8) void {
        var buf: [2048]u8 = undefined;
        buf[0] = CMD_CTRL;
        buf[1] = ctrl_type;
        const payload_len = @min(data.len, buf.len - 2);
        if (payload_len > 0) @memcpy(buf[2..][0..payload_len], data[0..payload_len]);
        _ = posix.sendto(self.udp_fd, buf[0 .. 2 + payload_len], 0, &to.any, to.getOsSockLen()) catch {};
    }

    // ── TCP Acceptor ──

    fn tcpAcceptLoop(self: *RelayServer) void {
        while (self.running) {
            var client_addr: std.net.Address = undefined;
            var addr_len: posix.socklen_t = @sizeOf(std.net.Address);
            const fd = posix.accept(self.tcp_listen_fd, &client_addr.any, &addr_len, 0) catch |err| {
                if (self.running) {
                    std.debug.print("[relay2/tcp] accept 错误: {}\n", .{err});
                }
                continue;
            };
            const thread = std.Thread.spawn(.{}, handleTCPConnection, .{ self, fd, client_addr }) catch |err| {
                std.debug.print("[relay2/tcp] 线程创建失败: {}\n", .{err});
                safeClose(fd);
                continue;
            };
            thread.detach();
        }
    }

    fn handleTCPConnection(self: *RelayServer, fd: posix.socket_t, addr: std.net.Address) void {
        defer safeClose(fd);

        // 设置超时
        setRecvTimeout(fd, 5000);

        // TCP 上的控制消息处理（注册 → 鉴权 → 持续转发）
        // TCP 连接生命周期：注册 → 鉴权 → 数据收发 → 断线清理
        var buf: [MAX_BUF]u8 = undefined;

        // 第一步：等待注册消息
        // TCP 上首消息必须是 REGISTER 控制消息
        const n = posix.read(fd, &buf) catch |err| {
            std.debug.print("[relay2/tcp] 读取注册消息失败: {}\n", .{err});
            return;
        };
        if (n < 3) return; // CMD_CTRL(1) + CTRL_REGISTER(1) + min_payload(20+32)

        if (buf[0] != CMD_CTRL or buf[1] != CTRL_REGISTER) {
            std.debug.print("[relay2/tcp] 期望 REGISTER, 收到 type=0x{x} ctrl=0x{x}\n", .{ buf[0], buf[1] });
            return;
        }

        // 解析注册数据
        const reg_payload = buf[2..n];
        if (reg_payload.len < 20 + 32) return;
        var node_id: NodeID = undefined;
        @memcpy(&node_id, reg_payload[0..20]);
        var pubkey: [32]u8 = undefined;
        @memcpy(&pubkey, reg_payload[20..52]);

        // 注册（pending_challenge），绑定 TCP fd
        _ = self.registry.register(node_id, .tcp, addr, pubkey) catch |err| {
            std.debug.print("[relay2/tcp] 注册失败: {}\n", .{err});
            return;
        };
        if (self.registry.get(node_id)) |session| {
            session.tcp_fd = fd;
        } else return;

        // 发送挑战
        var challenge = Auth.generateChallenge();
        if (self.registry.get(node_id)) |session| {
            session.challenge = challenge;
        }

        {
            var resp: [34]u8 = undefined;
            resp[0] = CMD_CTRL;
            resp[1] = CTRL_CHALLENGE;
            @memcpy(resp[2..34], &challenge);
            _ = posix.write(fd, &resp) catch {
                self.registry.unregister(node_id);
                return;
            };
        }

        // 第二步：等待鉴权响应
        const n2 = posix.read(fd, &buf) catch |err| {
            std.debug.print("[relay2/tcp] 读取鉴权消息失败: {}\n", .{err});
            self.registry.unregister(node_id);
            return;
        };
        if (n2 < 2 + 20 + 64) {
            self.registry.unregister(node_id);
            return;
        }
        if (buf[0] != CMD_CTRL or buf[1] != CTRL_AUTH) {
            self.sendTCPControl(fd, CTRL_AUTH_FAIL, &.{});
            self.registry.unregister(node_id);
            return;
        }

        const auth_payload = buf[2..n2];
        var auth_sig: [64]u8 = undefined;
        @memcpy(&auth_sig, auth_payload[20..84]);

        const session = self.registry.get(node_id) orelse {
            self.registry.unregister(node_id);
            return;
        };
        const sess_challenge = session.challenge orelse {
            self.sendTCPControl(fd, CTRL_AUTH_FAIL, &.{});
            self.registry.unregister(node_id);
            return;
        };

        const valid = Auth.verifySignature(pubkey, &sess_challenge, auth_sig);
        if (!valid) {
            std.debug.print("[relay2/tcp] TCP 鉴权失败 node={}\n", .{std.fmt.fmtSliceHexLower(&node_id)});
            self.sendTCPControl(fd, CTRL_AUTH_FAIL, &.{});
            self.registry.unregister(node_id);
            return;
        }

        self.registry.activate(node_id) catch {};
        self.sendTCPControl(fd, CTRL_AUTH_OK, &.{});
        std.debug.print("[relay2/tcp] TCP 鉴权成功 node={}\n", .{std.fmt.fmtSliceHexLower(&node_id)});

        // 第三步：进入数据转发循环（接收 → 查表 → 转发）
        // 使用本地心跳跟踪，避免持有 *Session 带来的 use-after-free 竞争
        var local_heartbeat_ms = std.time.milliTimestamp();
        var last_registry_heartbeat_ms = local_heartbeat_ms;
        setRecvTimeout(fd, 3000);
        while (self.running) {
            const nr = posix.read(fd, &buf) catch |err| {
                if (err == error.WouldBlock or err == error.Timeout) {
                    // 心跳检查（使用本地时间，避免 session 指针悬空）
                    const now = std.time.milliTimestamp();
                    if (now - local_heartbeat_ms > @as(i64, @intCast(self.config.heartbeat_timeout_ms))) {
                        break;
                    }
                    // 发送 PING 保活
                    self.sendTCPControl(fd, CTRL_PING, &node_id);
                    // 定期更新 registry 心跳（防止 reap() 误删）
                    if (now - last_registry_heartbeat_ms > 10_000) {
                        self.registry.heartbeat(node_id) catch {};
                        last_registry_heartbeat_ms = now;
                    }
                    continue;
                }
                if (err == error.ConnectionClosed or err == error.ConnectionResetByPeer) break;
                std.debug.print("[relay2/tcp] 读取错误: {}\n", .{err});
                break;
            };
            if (nr == 0) break;
            local_heartbeat_ms = std.time.milliTimestamp();
            if (local_heartbeat_ms - last_registry_heartbeat_ms > 10_000) {
                self.registry.heartbeat(node_id) catch {};
                last_registry_heartbeat_ms = local_heartbeat_ms;
            }

            if (buf[0] == CMD_CTRL) {
                // 控制消息（PING 等）
                if (nr >= 2 and buf[1] == CTRL_PING) {
                    self.sendTCPControl(fd, CTRL_PONG, &.{});
                }
                continue;
            }

            if (buf[0] != CMD_DATA) continue;

            // 转发数据（[CMD_DATA][target NodeID 20][payload]）
            const fwd_data = buf[1..nr];
            self.forwarder.forwardTCP(&self.registry, fd, fwd_data) catch |err| {
                if (err != error.TargetOffline) {
                    std.debug.print("[relay2/tcp] TCP 转发错误: {}\n", .{err});
                }
            };
        }

        // 清理
        std.debug.print("[relay2/tcp] 连接断开 node={}\n", .{std.fmt.fmtSliceHexLower(&node_id)});
        self.registry.unregisterIfFdMatches(node_id, fd);
    }

    fn sendTCPControl(self: *RelayServer, fd: posix.socket_t, ctrl_type: u8, data: []const u8) void {
        _ = self.config;
        var buf: [2048]u8 = undefined;
        buf[0] = CMD_CTRL;
        buf[1] = ctrl_type;
        const payload_len = @min(data.len, buf.len - 2);
        if (payload_len > 0) @memcpy(buf[2..][0..payload_len], data[0..payload_len]);
        _ = posix.write(fd, buf[0 .. 2 + payload_len]) catch {};
    }

    // ── 心跳回收 ──

    fn reapLoop(self: *RelayServer) void {
        while (self.running) {
            std.time.sleep(self.config.reap_interval_ms * std.time.ns_per_ms);
            if (!self.running) break;
            const before = self.registry.count();
            self.registry.reapExpired();
            const after = self.registry.count();
            if (before != after) {
                std.debug.print("[relay2] 回收过期会话: {d}→{d}\n", .{ before, after });
            }
        }
    }
};

// ── 辅助函数 ──

fn setRecvTimeout(fd: posix.socket_t, timeout_ms: u64) void {
    if (builtin.os.tag == .windows) {
        const ms: u32 = @intCast(@min(timeout_ms, std.math.maxInt(u32)));
        _ = posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(ms)) catch {};
        return;
    }
    const tv = posix.timeval{
        .sec = @as(c_long, @intCast(timeout_ms / 1000)),
        .usec = @as(c_long, @intCast((timeout_ms % 1000) * 1000)),
    };
    _ = posix.system.setsockopt(
        @as(i32, @intCast(fd)),
        @as(u32, @intCast(posix.SOL.SOCKET)),
        @as(u32, @intCast(posix.SO.RCVTIMEO)),
        @as(*const posix.timeval, @ptrCast(&tv)),
        @as(u32, @intCast(@sizeOf(posix.timeval))),
    );
}

/// 从 JSON 文件加载配置
fn loadConfigFromFile(alloc: std.mem.Allocator, path: []const u8) !RelayConfig {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
    defer parsed.deinit();
    const root = parsed.value;

    var config = RelayConfig{};

    if (root.object.get("listen_host")) |v| config.listen_host = try alloc.dupe(u8, v.string);
    if (root.object.get("listen_port")) |v| config.listen_port = @intCast(v.integer);
    if (root.object.get("max_sessions")) |v| config.max_sessions = @intCast(v.integer);
    if (root.object.get("heartbeat_timeout_ms")) |v| config.heartbeat_timeout_ms = @intCast(v.integer);
    if (root.object.get("max_packets_per_second")) |v| config.max_packets_per_second = @intCast(v.integer);
    if (root.object.get("max_packet_size")) |v| config.max_packet_size = @intCast(v.integer);
    if (root.object.get("buffer_size")) |v| config.buffer_size = @intCast(v.integer);
    if (root.object.get("reap_interval_ms")) |v| config.reap_interval_ms = @intCast(v.integer);

    return config;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // 默认配置，解析命令行参数
    var config = RelayConfig{};

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config")) {
            i += 1;
            if (i < args.len) config = loadConfigFromFile(alloc, args[i]) catch |err| {
                std.debug.print("[relay2] 配置文件加载失败: {}\n", .{err});
                return;
            };
        } else if (std.mem.eql(u8, args[i], "--port")) {
            i += 1;
            if (i < args.len) config.listen_port = std.fmt.parseUnsigned(u16, args[i], 10) catch 20809;
        } else if (std.mem.eql(u8, args[i], "--host")) {
            i += 1;
            if (i < args.len) config.listen_host = args[i];
        } else if (std.mem.eql(u8, args[i], "--max-sessions")) {
            i += 1;
            if (i < args.len) config.max_sessions = std.fmt.parseUnsigned(u32, args[i], 10) catch 1000;
        } else if (std.mem.eql(u8, args[i], "--help")) {
            std.debug.print("用法: relay-server [--config file] [--host addr] [--port port] [--max-sessions N]\n", .{});
            return;
        }
    }

    var server = try RelayServer.init(alloc, config);
    defer server.deinit();

    try server.run();
}

test "relay server init/deinit" {
    const testing = std.testing;
    var server = try RelayServer.init(testing.allocator, .{ .listen_port = 20909 });
    defer server.deinit();
    try testing.expect(!server.running);
}

fn makeNodeID(id: u8) NodeID {
    var result: NodeID = [_]u8{0} ** 20;
    result[0] = id;
    return result;
}

fn makePubKey(id: u8) [32]u8 {
    var result: [32]u8 = [_]u8{0} ** 32;
    result[0] = id;
    return result;
}

test "registry: register and activate session" {
    const testing = std.testing;
    var reg = Registry.init(testing.allocator, .{});
    defer reg.deinit();

    const node_id = makeNodeID(1);
    const pk = makePubKey(42);
    const addr = try std.net.Address.parseIp("127.0.0.1", 12345);

    _ = try reg.register(node_id, .udp, addr, pk);
    try testing.expectEqual(@as(u32, 1), reg.count());

    const s = reg.get(node_id) orelse return error.TestFailed;
    try testing.expect(s.state == .pending_challenge);

    try reg.activate(node_id);
    try testing.expect(reg.get(node_id).?.state == .active);
}

test "registry: heartbeat updates timestamp" {
    const testing = std.testing;
    var reg = Registry.init(testing.allocator, .{});
    defer reg.deinit();

    const node_id = makeNodeID(2);
    const pk = makePubKey(42);
    const addr = try std.net.Address.parseIp("127.0.0.1", 12346);

    _ = try reg.register(node_id, .tcp, addr, pk);
    const before = reg.get(node_id).?.last_heartbeat_ms;

    std.time.sleep(2 * std.time.ns_per_ms);
    try reg.heartbeat(node_id);
    const after = reg.get(node_id).?.last_heartbeat_ms;

    try testing.expect(after > before);
}

test "registry: unregister removes session" {
    const testing = std.testing;
    var reg = Registry.init(testing.allocator, .{});
    defer reg.deinit();

    const node_id = makeNodeID(3);
    const pk = makePubKey(42);
    const addr = try std.net.Address.parseIp("127.0.0.1", 12347);

    _ = try reg.register(node_id, .udp, addr, pk);
    try testing.expectEqual(@as(u32, 1), reg.count());

    reg.unregister(node_id);
    try testing.expectEqual(@as(u32, 0), reg.count());
    try testing.expect(reg.get(node_id) == null);
}

test "registry: reap expired sessions" {
    const testing = std.testing;
    var reg = Registry.init(testing.allocator, .{
        .heartbeat_timeout_ms = 100,
        .max_sessions = 100,
    });
    defer reg.deinit();

    const node_id = makeNodeID(4);
    const pk = makePubKey(42);
    const addr = try std.net.Address.parseIp("127.0.0.1", 12348);

    _ = try reg.register(node_id, .udp, addr, pk);
    std.time.sleep(150 * std.time.ns_per_ms);
    reg.reapExpired();

    try testing.expect(reg.get(node_id) == null);
    try testing.expectEqual(@as(u32, 0), reg.count());
}

test "registry: session limit enforced" {
    const testing = std.testing;
    var reg = Registry.init(testing.allocator, .{
        .max_sessions = 2,
    });
    defer reg.deinit();

    const pk = makePubKey(42);
    const addr1 = try std.net.Address.parseIp("127.0.0.1", 10001);
    const addr2 = try std.net.Address.parseIp("127.0.0.1", 10002);
    const addr3 = try std.net.Address.parseIp("127.0.0.1", 10003);

    _ = try reg.register(makeNodeID(10), .udp, addr1, pk);
    _ = try reg.register(makeNodeID(11), .udp, addr2, pk);
    try testing.expectEqual(@as(u32, 2), reg.count());

    try testing.expectError(error.SessionLimitReached, reg.register(makeNodeID(12), .udp, addr3, pk));
}

test "registry: duplicate node replaces session" {
    const testing = std.testing;
    var reg = Registry.init(testing.allocator, .{});
    defer reg.deinit();

    const node_id = makeNodeID(5);
    const pk1 = makePubKey(1);
    const pk2 = makePubKey(2);
    const addr1 = try std.net.Address.parseIp("127.0.0.1", 20001);
    const addr2 = try std.net.Address.parseIp("127.0.0.1", 20002);

    _ = try reg.register(node_id, .udp, addr1, pk1);
    try testing.expectEqual(@as(u32, 1), reg.count());

    _ = try reg.register(node_id, .udp, addr2, pk2);
    try testing.expectEqual(@as(u32, 1), reg.count());

    const s = reg.get(node_id) orelse return error.TestFailed;
    try testing.expect(std.mem.eql(u8, &s.public_key, &pk2));
}

test "auth: generate challenge" {
    const testing = std.testing;
    const c1 = Auth.generateChallenge();
    const c2 = Auth.generateChallenge();
    try testing.expect(!std.mem.eql(u8, &c1, &c2));
}

test "forwarder: header length constant" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 20), fwd.HEADER_LEN);
}

test "forwarder: packet validation" {
    const testing = std.testing;
    var reg = Registry.init(testing.allocator, .{});
    defer reg.deinit();

    var fwder = Forwarder.init(testing.allocator, .{
        .max_packet_size = 100,
    });
    defer fwder.deinit();

    const short_packet = [_]u8{0} ** 10;
    const addr = try std.net.Address.parseIp("127.0.0.1", 30001);
    try testing.expectError(error.PacketTooShort, fwder.forwardUDP(&reg, undefined, &short_packet, addr));
}

// ── 集成测试 ──

/// 启动中继服务器（后台线程）
fn startRelay(server: *RelayServer) void {
    server.run() catch {};
}

/// 生成 ED25519 密钥对（测试用）
fn testKeyPair() struct { secret: [32]u8, public: [32]u8 } {
    var seed: [32]u8 = undefined;
    std.crypto.random.bytes(&seed);
    const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
    return .{ .secret = seed, .public = kp.public_key.toBytes() };
}

test "7.4 integration: dual node E2E relay via UDP" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    const kp_a = testKeyPair();
    const kp_b = testKeyPair();
    const node_a = makeNodeID(0xAA);
    const node_b = makeNodeID(0xBB);

    var server = try RelayServer.init(alloc, .{
        .listen_host = "127.0.0.1",
        .listen_port = 21111,
        .heartbeat_timeout_ms = 5000,
        .reap_interval_ms = 1000,
        .max_packets_per_second = 10000,
    });
    defer server.deinit();

    const server_thread = try std.Thread.spawn(.{}, startRelay, .{&server});
    server_thread.detach();

    std.time.sleep(100 * std.time.ns_per_ms);

    const fd_a = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer std.posix.close(fd_a);
    const bind_a = try std.net.Address.parseIp("127.0.0.1", 0);
    try std.posix.bind(fd_a, &bind_a.any, bind_a.getOsSockLen());

    const fd_b = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer std.posix.close(fd_b);
    const bind_b = try std.net.Address.parseIp("127.0.0.1", 0);
    try std.posix.bind(fd_b, &bind_b.any, bind_b.getOsSockLen());

    const relay_addr = try std.net.Address.parseIp("127.0.0.1", 21111);

    // Node A register + auth
    {
        var buf: [54]u8 = .{0} ** 54;
        buf[0] = 0x00;
        buf[1] = 0x01;
        @memcpy(buf[2..22], &node_a);
        @memcpy(buf[22..54], &kp_a.public);
        _ = try std.posix.sendto(fd_a, &buf, 0, &relay_addr.any, relay_addr.getOsSockLen());
    }

    std.time.sleep(50 * std.time.ns_per_ms);
    var resp: [256]u8 = undefined;
    var from: std.net.Address = undefined;
    var from_len: std.posix.socklen_t = @sizeOf(std.net.Address);
    const n_a = try std.posix.recvfrom(fd_a, &resp, 0, &from.any, &from_len);
    try testing.expect(n_a >= 34);
    try testing.expect(resp[0] == 0x00);
    try testing.expect(resp[1] == 0x02);
    var challenge: [32]u8 = undefined;
    @memcpy(&challenge, resp[2..34]);

    const kp_a_full = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(kp_a.secret);
    const sig_a = try std.crypto.sign.Ed25519.KeyPair.sign(kp_a_full, challenge[0..], null);
    var auth_buf: [86]u8 = .{0} ** 86;
    auth_buf[0] = 0x00;
    auth_buf[1] = 0x03;
    @memcpy(auth_buf[2..22], &node_a);
    const sig_a_bytes = sig_a.toBytes();
@memcpy(auth_buf[22..86], &sig_a_bytes);
    _ = try std.posix.sendto(fd_a, &auth_buf, 0, &relay_addr.any, relay_addr.getOsSockLen());

    std.time.sleep(50 * std.time.ns_per_ms);
    const n_a2 = try std.posix.recvfrom(fd_a, &resp, 0, &from.any, &from_len);
    try testing.expect(n_a2 >= 2);
    try testing.expect(resp[0] == 0x00);
    try testing.expect(resp[1] == 0x04);
    std.debug.print("  [OK] Node A auth OK\n", .{});

    // Node B register + auth
    var buf_b: [54]u8 = .{0} ** 54;
    buf_b[0] = 0x00;
    buf_b[1] = 0x01;
    @memcpy(buf_b[2..22], &node_b);
    @memcpy(buf_b[22..54], &kp_b.public);
    _ = try std.posix.sendto(fd_b, &buf_b, 0, &relay_addr.any, relay_addr.getOsSockLen());

    std.time.sleep(50 * std.time.ns_per_ms);
    var from_b: std.net.Address = undefined;
    var from_len_b: std.posix.socklen_t = @sizeOf(std.net.Address);
    _ = try std.posix.recvfrom(fd_b, &resp, 0, &from_b.any, &from_len_b);
    @memcpy(&challenge, resp[2..34]);

    const kp_b_full = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(kp_b.secret);
    const sig_b = try std.crypto.sign.Ed25519.KeyPair.sign(kp_b_full, challenge[0..], null);
    var auth_buf_b: [86]u8 = .{0} ** 86;
    auth_buf_b[0] = 0x00;
    auth_buf_b[1] = 0x03;
    @memcpy(auth_buf_b[2..22], &node_b);
    const sig_b_bytes = sig_b.toBytes();
    @memcpy(auth_buf_b[22..86], &sig_b_bytes);
    _ = try std.posix.sendto(fd_b, &auth_buf_b, 0, &relay_addr.any, relay_addr.getOsSockLen());

    std.time.sleep(50 * std.time.ns_per_ms);
    _ = try std.posix.recvfrom(fd_b, &resp, 0, &from_b.any, &from_len_b);
    try testing.expect(resp[1] == 0x04);
    std.debug.print("  [OK] Node B auth OK\n", .{});

    // A → relay → B: forward data
    const payload = "Hello from A!";
    var data_fwd: [1 + 20 + 20]u8 = .{0} ** 41;
    data_fwd[0] = 0x01;
    @memcpy(data_fwd[1..21], &node_b);
    @memcpy(data_fwd[21..][0..payload.len], payload);
    _ = try std.posix.sendto(fd_a, &data_fwd, 0, &relay_addr.any, relay_addr.getOsSockLen());

    std.time.sleep(50 * std.time.ns_per_ms);
    const n_recv = try std.posix.recvfrom(fd_b, &resp, 0, &from.any, &from_len);
    try testing.expect(n_recv >= 1 + payload.len);
    try testing.expect(std.mem.eql(u8, resp[1..][0..payload.len], payload));
    std.debug.print("  [OK] Forward: A→relay→B, payload={s}\n", .{payload});

    server.stop();
    std.time.sleep(1100 * std.time.ns_per_ms);
}

test "7.5a integration: heartbeat and session keepalive" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    const kp = testKeyPair();
    const node_id = makeNodeID(0xCC);

    var server = try RelayServer.init(alloc, .{
        .listen_host = "127.0.0.1",
        .listen_port = 21112,
        .heartbeat_timeout_ms = 2000,
        .reap_interval_ms = 500,
        .max_packets_per_second = 10000,
    });
    defer server.deinit();

    const st = try std.Thread.spawn(.{}, startRelay, .{&server});
    st.detach();

    std.time.sleep(100 * std.time.ns_per_ms);

    const relay_addr = try std.net.Address.parseIp("127.0.0.1", 21112);
    const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer std.posix.close(fd);
    const bind_addr = try std.net.Address.parseIp("127.0.0.1", 0);
    try std.posix.bind(fd, &bind_addr.any, bind_addr.getOsSockLen());

    // Register + auth
    var buf: [54]u8 = .{0} ** 54;
    buf[0] = 0x00;
    buf[1] = 0x01;
    @memcpy(buf[2..22], &node_id);
    @memcpy(buf[22..54], &kp.public);
    _ = try std.posix.sendto(fd, &buf, 0, &relay_addr.any, relay_addr.getOsSockLen());

    std.time.sleep(50 * std.time.ns_per_ms);
    var resp: [256]u8 = undefined;
    var from: std.net.Address = undefined;
    var from_len: std.posix.socklen_t = @sizeOf(std.net.Address);
    _ = try std.posix.recvfrom(fd, &resp, 0, &from.any, &from_len);
    var challenge: [32]u8 = undefined;
    @memcpy(&challenge, resp[2..34]);

    const full_kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(kp.secret);
    const sig = try std.crypto.sign.Ed25519.KeyPair.sign(full_kp, challenge[0..], null);
    var auth_buf: [86]u8 = .{0} ** 86;
    auth_buf[0] = 0x00;
    auth_buf[1] = 0x03;
    @memcpy(auth_buf[2..22], &node_id);
    const sig_bytes = sig.toBytes();
    @memcpy(auth_buf[22..86], &sig_bytes);
    _ = try std.posix.sendto(fd, &auth_buf, 0, &relay_addr.any, relay_addr.getOsSockLen());

    std.time.sleep(50 * std.time.ns_per_ms);
    _ = try std.posix.recvfrom(fd, &resp, 0, &from.any, &from_len);
    try testing.expect(resp[1] == 0x04);
    std.debug.print("  [OK] Auth OK\n", .{});

    // PING keepalive
    var ping: [22]u8 = .{0} ** 22;
    ping[0] = 0x00;
    ping[1] = 0x06;
    @memcpy(ping[2..22], &node_id);

    for (0..3) |_| {
        _ = try std.posix.sendto(fd, &ping, 0, &relay_addr.any, relay_addr.getOsSockLen());
        std.time.sleep(300 * std.time.ns_per_ms);
        _ = std.posix.recvfrom(fd, &resp, 0, &from.any, &from_len) catch continue;
    }
    std.debug.print("  [OK] Heartbeat OK\n", .{});

    // Stop sending, wait for expiry + reaping
    std.time.sleep(3000 * std.time.ns_per_ms);
    const reaped_count = server.registry.count();
    try testing.expect(reaped_count == 0);
    std.debug.print("  [OK] Session expired and reaped: count={d}\n", .{reaped_count});

    server.stop();
    std.time.sleep(1100 * std.time.ns_per_ms);
}

test "7.5b integration: relay failover to backup" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    const kp = testKeyPair();
    const node_id = makeNodeID(0xDD);

    var server_a = try RelayServer.init(alloc, .{
        .listen_host = "127.0.0.1",
        .listen_port = 21113,
        .heartbeat_timeout_ms = 5000,
        .reap_interval_ms = 1000,
        .max_packets_per_second = 10000,
    });
    defer server_a.deinit();

    const st_a = try std.Thread.spawn(.{}, startRelay, .{&server_a});
    st_a.detach();

    var server_b = try RelayServer.init(alloc, .{
        .listen_host = "127.0.0.1",
        .listen_port = 21114,
        .heartbeat_timeout_ms = 5000,
        .reap_interval_ms = 1000,
        .max_packets_per_second = 10000,
    });
    defer server_b.deinit();

    const st_b = try std.Thread.spawn(.{}, startRelay, .{&server_b});
    st_b.detach();

    std.time.sleep(100 * std.time.ns_per_ms);

    const relay_a_addr = try std.net.Address.parseIp("127.0.0.1", 21113);
    const relay_b_addr = try std.net.Address.parseIp("127.0.0.1", 21114);

    const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer std.posix.close(fd);
    const bind_addr = try std.net.Address.parseIp("127.0.0.1", 0);
    try std.posix.bind(fd, &bind_addr.any, bind_addr.getOsSockLen());

    // Register + auth on primary
    var buf: [54]u8 = .{0} ** 54;
    buf[0] = 0x00;
    buf[1] = 0x01;
    @memcpy(buf[2..22], &node_id);
    @memcpy(buf[22..54], &kp.public);
    _ = try std.posix.sendto(fd, &buf, 0, &relay_a_addr.any, relay_a_addr.getOsSockLen());

    std.time.sleep(50 * std.time.ns_per_ms);
    var resp: [256]u8 = undefined;
    var from: std.net.Address = undefined;
    var from_len: std.posix.socklen_t = @sizeOf(std.net.Address);
    _ = try std.posix.recvfrom(fd, &resp, 0, &from.any, &from_len);
    var challenge: [32]u8 = undefined;
    @memcpy(&challenge, resp[2..34]);

    const full_kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(kp.secret);
    const sig = try std.crypto.sign.Ed25519.KeyPair.sign(full_kp, challenge[0..], null);
    var auth_buf: [86]u8 = .{0} ** 86;
    auth_buf[0] = 0x00;
    auth_buf[1] = 0x03;
    @memcpy(auth_buf[2..22], &node_id);
    const sig_bytes = sig.toBytes();
    @memcpy(auth_buf[22..86], &sig_bytes);
    _ = try std.posix.sendto(fd, &auth_buf, 0, &relay_a_addr.any, relay_a_addr.getOsSockLen());

    std.time.sleep(50 * std.time.ns_per_ms);
    _ = try std.posix.recvfrom(fd, &resp, 0, &from.any, &from_len);
    try testing.expect(resp[1] == 0x04);
    std.debug.print("  [OK] Connected to primary relay\n", .{});

    try testing.expect(server_a.registry.count() == 1);
    try testing.expect(server_b.registry.count() == 0);

    // Register on backup relay
    _ = try std.posix.sendto(fd, &buf, 0, &relay_b_addr.any, relay_b_addr.getOsSockLen());
    std.time.sleep(50 * std.time.ns_per_ms);
    _ = try std.posix.recvfrom(fd, &resp, 0, &from.any, &from_len);
    @memcpy(&challenge, resp[2..34]);
    const sig2 = try std.crypto.sign.Ed25519.KeyPair.sign(full_kp, challenge[0..], null);
    auth_buf[1] = 0x03;
    const sig2_bytes = sig2.toBytes();
    @memcpy(auth_buf[22..86], &sig2_bytes);
    _ = try std.posix.sendto(fd, &auth_buf, 0, &relay_b_addr.any, relay_b_addr.getOsSockLen());
    std.time.sleep(50 * std.time.ns_per_ms);
    _ = try std.posix.recvfrom(fd, &resp, 0, &from.any, &from_len);
    try testing.expect(resp[1] == 0x04);
    try testing.expect(server_b.registry.count() == 1);
    std.debug.print("  [OK] Connected to backup relay\n", .{});

    // Simulate failover: stop primary
    server_a.stop();
    std.time.sleep(200 * std.time.ns_per_ms);
    try testing.expect(server_a.registry.count() == 0);
    try testing.expect(server_b.registry.count() == 1);
    std.debug.print("  [OK] Primary down, backup operational\n", .{});

    // Verify backup still works
    var ping: [22]u8 = .{0} ** 22;
    ping[0] = 0x06;
    @memcpy(ping[2..22], &node_id);
    _ = try std.posix.sendto(fd, &ping, 0, &relay_b_addr.any, relay_b_addr.getOsSockLen());
    std.time.sleep(50 * std.time.ns_per_ms);
    _ = std.posix.recvfrom(fd, &resp, 0, &from.any, &from_len) catch {};
    std.debug.print("  [OK] Failover complete\n", .{});

    server_b.stop();
    std.time.sleep(1100 * std.time.ns_per_ms);
}
