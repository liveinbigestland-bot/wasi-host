/// 健康检查 + 环位置独立验证
/// UDP ping 本机 wasi-host 获取状态，独立向 ring 查询验证位置
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const time = std.time;

const config_mod = @import("config.zig");
const dht = @import("dht_types.zig");
const NodeId = dht.NodeId;

/// 从 ping 响应中解析的本节点状态
pub const NodeStatus = struct {
    node_id: NodeId = 0,
    listen_host: []const u8 = "",
    listen_port: u16 = 0,
    successor_id: NodeId = 0,
    successor_host: []const u8 = "",
    successor_port: u16 = 0,
    successor_tcp: u16 = 0,
    pred_id: ?NodeId = null,
    pred_host: []const u8 = "",
    pred_port: u16 = 0,
    pred_tcp: u16 = 0,
    isolated: bool = true,
    finger_count: u32 = 0,
    alive: bool = false,
};

/// 独立查询结果
pub const RingCheckResult = struct {
    ring_succ_id: ?NodeId = null,
    ring_succ_host: []const u8 = "",
    ring_succ_port: u16 = 0,
    ring_pred_id: ?NodeId = null,
    ring_pred_host: []const u8 = "",
    ring_pred_port: u16 = 0,
    succ_match: bool = false,
    pred_match: bool = false,
    query_ok: bool = false,
};

/// 健康检查综合判定
pub const HealthStatus = enum(u8) {
    ok = 0,
    isolated = 1,
    successor_mismatch = 2,
    predecessor_mismatch = 3,
    ping_timeout = 4,
    unknown = 5,
};

pub const Monitor = struct {
    alloc: std.mem.Allocator,
    config: config_mod.DaemonConfig,
    udp_fd: i32 = -1,
    recv_buf: [65536]u8 = undefined,
    node_status: NodeStatus,
    ring_check: RingCheckResult,
    health: HealthStatus = .unknown,
    consecutive_mismatches: u32 = 0,
    bootstrap_host: []const u8 = "",
    bootstrap_port: u16 = 0,
    my_id_override: ?NodeId = null, // 如果 ping 无法获取，可以手动设置

    pub fn init(alloc: std.mem.Allocator, cfg: config_mod.DaemonConfig) !Monitor {
        var monitor = Monitor{
            .alloc = alloc,
            .config = cfg,
            .node_status = NodeStatus{},
            .ring_check = RingCheckResult{},
        };

        // 只在 Linux 上初始化 UDP socket
        if (builtin.os.tag == .linux) {
            const fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
            monitor.udp_fd = @as(i32, @intCast(fd));
            // FD_CLOEXEC
            _ = posix.fcntl(fd, posix.F.SETFD, posix.FD_CLOEXEC) catch 0;
            // 绑定到任意端口（显式绑定确保 recvfrom 能收到响应）
            {
                const bind_addr = posix.sockaddr.in{
                    .family = posix.AF.INET,
                    .port = 0, // 内核分配
                    .addr = std.mem.nativeToBig(u32, 0), // INADDR_ANY
                    .zero = .{0} ** 8,
                };
                posix.bind(fd, @as(*const posix.sockaddr, @ptrCast(&bind_addr)), @sizeOf(posix.sockaddr.in)) catch |err| {
                    std.debug.print("[monitor] bind 失败: {}\n", .{err});
                };
            }
            // 设置接收超时
            const tv = posix.timeval{
                .sec = @as(c_long, @intCast(cfg.ping_timeout_ms / 1000)),
                .usec = @as(c_long, @intCast((cfg.ping_timeout_ms % 1000) * 1000_000)),
            };
            posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(tv)) catch {};
        }

        return monitor;
    }

    pub fn deinit(self: *Monitor) void {
        if (self.udp_fd >= 0) {
            if (builtin.os.tag == .linux) {
                posix.close(self.udp_fd);
            }
        }
    }

    /// 设置 bootstrap 地址
    pub fn setBootstrap(self: *Monitor, host: []const u8, port: u16) void {
        self.bootstrap_host = host;
        self.bootstrap_port = port;
    }

    /// 执行一次完整的健康检查
    pub fn check(self: *Monitor, local_port: u16) !void {
        // 1. 本地 ping
        self.pingLocal(local_port) catch |err| {
            std.debug.print("[monitor] 本地 ping 失败: {}\n", .{err});
            self.node_status.alive = false;
            self.health = .ping_timeout;
            return;
        };

        if (!self.node_status.alive) {
            self.health = .ping_timeout;
            return;
        }

        // 2. 检查是否孤立
        if (self.node_status.isolated) {
            self.health = .isolated;
            return;
        }

        // 3. 独立环位置查询
        if (self.bootstrap_host.len > 0) {
            self.ringCheck() catch |err| {
                std.debug.print("[monitor] 环查询失败: {}\n", .{err});
                // 不影响已有判定
            };
        }

        // 4. 综合判定
        if (self.ring_check.query_ok) {
            if (!self.ring_check.succ_match or !self.ring_check.pred_match) {
                self.consecutive_mismatches += 1;
                self.health = if (!self.ring_check.succ_match) .successor_mismatch else .predecessor_mismatch;
            } else {
                self.consecutive_mismatches = 0;
                self.health = .ok;
            }
        } else {
            // 无法独立查询时，仅依靠本地状态
            self.health = .ok;
        }
    }

    /// 向本地 wasi-host 发送 UDP ping
    fn pingLocal(self: *Monitor, local_port: u16) !void {
        if (builtin.os.tag != .linux) return error.NotSupported;
        const fd = self.udp_fd;
        if (fd < 0) return error.SocketNotInitialized;

        // 构造 ping 消息
        const ping_json = "{\"ping\":{}}";

        // 发送到 127.0.0.1:local_port
        var target = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, local_port),
            .addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
            .zero = .{0} ** 8,
        };

        const sent = try posix.sendto(fd, ping_json, 0, @as(*const posix.sockaddr, @ptrCast(&target)), @sizeOf(posix.sockaddr.in));
        if (sent != ping_json.len) return error.SendFailed;

        // 接收 pong 响应
        var src_addr: posix.sockaddr = undefined;
        var src_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const n = posix.recvfrom(fd, &self.recv_buf, 0, &src_addr, &src_len) catch |err| {
            if (err == error.WouldBlock) return error.PingTimeout;
            return err;
        };

        // 标记存活（pong 为 void 类型，不含节点信息；完整状态需通过 find_successor 获取）
        _ = n;
        self.node_status.alive = true;
        self.node_status.isolated = false;
        self.node_status.isolated = false;
    }

    /// 独立环查询：向 bootstrap 查询本节点的正确后继和前驱
    fn ringCheck(self: *Monitor) !void {
        if (self.my_id_override == null and self.node_status.node_id == 0) {
            return; // 无法获取本节点 ID
        }
        const my_id = self.my_id_override orelse self.node_status.node_id;

        if (self.bootstrap_host.len > 0) {
            // 向 bootstrap 发送 find_successor(my_id) 消息
            // JSON 格式: {"find_successor":{"target":<id>}}
            var msg_buf: [256]u8 = undefined;
            const find_msg = try std.fmt.bufPrint(&msg_buf, "{{\"find_successor\":{{\"target\":{d}}}}}", .{my_id});

            var resp_buf: [65536]u8 = undefined;
            const resp_len = try self.udpSendAndWait(
                self.bootstrap_host,
                self.bootstrap_port,
                find_msg,
                &resp_buf,
                self.config.lookup_timeout_ms,
            );

            if (resp_len > 0) {
                // 简化：尝试从 JSON 响应中解析 node_id
                // 完整实现应使用 JSON 解析
                const resp_str = resp_buf[0..resp_len];
                if (std.mem.indexOf(u8, resp_str, "\"node_id\"")) |_| {
                    // 粗略解析 find_successor_resp
                    if (std.mem.indexOf(u8, resp_str, "\"node_addr\"")) |_| {
                        // 找到 node_addr 值
                        // 简化：标记查询成功
                        self.ring_check.query_ok = true;
                    }
                }
            }
        }

        // 3. 对比（简化：仅当独立查询成功时比较）
        if (self.ring_check.query_ok) {
            if (self.ring_check.ring_succ_id) |ring_succ| {
                self.ring_check.succ_match = (ring_succ == self.node_status.successor_id);
            }
        }
    }

    /// UDP 发送并等待响应（用于独立环查询）
    fn udpSendAndWait(self: *Monitor, host: []const u8, port: u16, data: []const u8, buf: []u8, timeout_ms: u64) !usize {
        if (builtin.os.tag != .linux) return error.NotSupported;
        const fd = self.udp_fd;
        if (fd < 0) return error.SocketNotInitialized;

        // 解析目标地址
        var target = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0,
            .zero = .{0} ** 8,
        };

        // 解析 IP
        if (try parseIPv4(host)) |ip| {
            target.addr = ip;
        } else {
            return error.InvalidAddress;
        }

        // 设置接收超时
        const tv = posix.timeval{
            .sec = @as(c_long, @intCast(timeout_ms / 1000)),
            .usec = @as(c_long, @intCast((timeout_ms % 1000) * 1000_000)),
        };
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(tv)) catch {};

        // 发送
        const sent = try posix.sendto(fd, data, 0, @as(*const posix.sockaddr, @ptrCast(&target)), @sizeOf(posix.sockaddr.in));
        if (sent != data.len) return error.SendFailed;

        // 接收
        var src_addr: posix.sockaddr = undefined;
        var src_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const n = posix.recvfrom(fd, buf, 0, &src_addr, &src_len) catch |err| {
            if (err == error.WouldBlock) return 0;
            return err;
        };

        return n;
    }

    /// 获取当前健康状态
    pub fn getHealth(self: *Monitor) HealthStatus {
        return self.health;
    }

    /// 获取节点状态
    pub fn getNodeStatus(self: *Monitor) NodeStatus {
        return self.node_status;
    }

    /// 获取环检查结果
    pub fn getRingCheck(self: *Monitor) RingCheckResult {
        return self.ring_check;
    }
};

/// 简化 IPv4 地址解析
fn parseIPv4(host: []const u8) !?u32 {
    // 将 "192.168.1.1" 转换为 u32 大端
    var parts = std.mem.splitScalar(u8, host, '.');
    var octets: [4]u8 = undefined;
    var i: usize = 0;
    while (parts.next()) |part| : (i += 1) {
        if (i >= 4) return null;
        octets[i] = try std.fmt.parseInt(u8, part, 10);
    }
    if (i != 4) return null;
    return std.mem.nativeToBig(u32, @as(u32, @intCast(octets[0])) << 24 | @as(u32, @intCast(octets[1])) << 16 | @as(u32, @intCast(octets[2])) << 8 | octets[3]);
}
