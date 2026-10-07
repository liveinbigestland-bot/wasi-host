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

/// 控制通道 node_status 响应
const NodeStatusResp = struct {
    ok: bool = false,
    node_id: []const u8 = "",
    successor_id: []const u8 = "",
    successor_addr: []const u8 = "",
    predecessor_id: ?[]const u8 = null,
    predecessor_addr: ?[]const u8 = null,
};

/// 将 host 拷贝到固定缓冲（避免引用已释放的 JSON 解析内存）
fn copyHost(buf: *[64]u8, host: []const u8) void {
    const n = @min(host.len, 63);
    @memcpy(buf[0..n], host[0..n]);
}

/// 环视图节点信息（值语义，无堆引用）
pub const RingNodeInfo = struct {
    id_hex: [40]u8 = undefined,
    addr: [64]u8 = undefined,
    addr_len: usize = 0,
};

/// ringWalk 结果
pub const RingWalkResult = struct {
    nodes: []RingNodeInfo,
    closed: bool,
    /// 遍历停滞：连续两跳返回同一节点（该节点自指，环断裂/对方孤立）
    stalled: bool = false,
    err: ?[]const u8 = null,
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
    // node_status 查询结果的固定存储缓冲（host 切片指向这里，避免悬垂）
    succ_addr_buf: [64]u8 = undefined,
    pred_addr_buf: [64]u8 = undefined,

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

        // 1.5 通过控制通道查询节点真实状态（node_id/后继/前驱）
        self.queryNodeStatus(local_port) catch |err| {
            std.debug.print("[monitor] 节点状态查询失败: {}\n", .{err});
        };

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

    /// 通过控制通道查询节点真实状态（node_status action）
    fn queryNodeStatus(self: *Monitor, local_port: u16) !void {
        if (builtin.os.tag != .linux) return error.NotSupported;
        const fd = self.udp_fd;
        if (fd < 0) return error.SocketNotInitialized;

        var msg_buf: [512]u8 = undefined;
        const msg = if (self.config.control_token) |tok|
            try std.fmt.bufPrint(&msg_buf, "{{\"control\":{{\"node_status\":{{}}}},\"token\":\"{s}\"}}", .{tok})
        else
            try std.fmt.bufPrint(&msg_buf, "{{\"control\":{{\"node_status\":{{}}}}}}", .{});

        var target = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, local_port),
            .addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
            .zero = .{0} ** 8,
        };
        const sent = try posix.sendto(fd, msg, 0, @as(*const posix.sockaddr, @ptrCast(&target)), @sizeOf(posix.sockaddr.in));
        if (sent != msg.len) return error.SendFailed;

        var src_addr: posix.sockaddr = undefined;
        var src_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const n = try posix.recvfrom(fd, &self.recv_buf, 0, &src_addr, &src_len);

        const parsed = std.json.parseFromSlice(NodeStatusResp, self.alloc, self.recv_buf[0..n], .{
            .ignore_unknown_fields = true,
        }) catch return error.InvalidResponse;
        defer parsed.deinit();
        const r = parsed.value;
        if (!r.ok or r.node_id.len < 40) return error.InvalidResponse;

        const nid = dht.idFromHex(r.node_id) catch return error.InvalidResponse;
        self.node_status.node_id = nid;

        if (r.successor_id.len >= 40) {
            if (dht.idFromHex(r.successor_id)) |sid| {
                self.node_status.successor_id = sid;
                if (r.successor_addr.len > 0) {
                    if (std.mem.lastIndexOfScalar(u8, r.successor_addr, ':')) |ci| {
                        const host = r.successor_addr[0..ci];
                        const port = std.fmt.parseInt(u16, r.successor_addr[ci + 1 ..], 10) catch 0;
                        copyHost(&self.succ_addr_buf, host);
                        self.node_status.successor_host = self.succ_addr_buf[0..host.len];
                        self.node_status.successor_port = port;
                    }
                }
                // 后继为自身 = 孤立节点
                self.node_status.isolated = (sid == nid);
            } else |_| {}
        } else {
            self.node_status.isolated = true;
        }

        if (r.predecessor_id) |phex| {
            if (phex.len >= 40) {
                if (dht.idFromHex(phex)) |pid| {
                    self.node_status.pred_id = pid;
                    if (r.predecessor_addr) |pa| {
                        if (std.mem.lastIndexOfScalar(u8, pa, ':')) |ci| {
                            const host = pa[0..ci];
                            const port = std.fmt.parseInt(u16, pa[ci + 1 ..], 10) catch 0;
                            copyHost(&self.pred_addr_buf, host);
                            self.node_status.pred_host = self.pred_addr_buf[0..host.len];
                            self.node_status.pred_port = port;
                        }
                    }
                } else |_| {}
            }
        }
    }

    /// 解析 find_successor 响应 JSON（node_id 为 u160 十进制数字字面量）
    fn parseFsResp(alloc: std.mem.Allocator, resp: []const u8) !struct { id: NodeId, info: RingNodeInfo } {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
        defer parsed.deinit();
        const body = (parsed.value.object.get("find_successor_resp") orelse return error.NoBody).object;
        const nid_v = body.get("node_id") orelse return error.NoId;
        const nid: NodeId = switch (nid_v) {
            .number_string => |s| try std.fmt.parseInt(NodeId, s, 10),
            .integer => |i| blk: {
                if (i < 0) return error.NegativeId;
                break :blk @intCast(i);
            },
            else => return error.BadIdType,
        };
        var info = RingNodeInfo{};
        info.id_hex = dht.idToHex(nid);
        if (body.get("node_addr")) |a| {
            if (a == .string) {
                const port: u16 = if (body.get("node_port")) |p| switch (p) {
                    .integer => |x| if (x > 0 and x < 65536) @as(u16, @intCast(x)) else 0,
                    else => 0,
                } else 0;
                const s = std.fmt.bufPrint(&info.addr, "{s}:{d}", .{ a.string, port }) catch "";
                info.addr_len = s.len;
            }
        }
        return .{ .id = nid, .info = info };
    }

    /// 通过本机节点 find_successor 遍历整个环（loopback UDP，供 /api/ring 使用）
    pub fn ringWalk(self: *Monitor, node_udp_port: u16, alloc: std.mem.Allocator, max_nodes: usize) RingWalkResult {
        const my_id = self.node_status.node_id;
        if (builtin.os.tag != .linux or self.udp_fd < 0 or my_id == 0) {
            return .{ .nodes = &.{}, .closed = false, .err = "monitor unavailable" };
        }
        var nodes_list = std.ArrayList(RingNodeInfo).init(alloc);
        var target: NodeId = my_id +% 1;
        var closed = false;
        var stalled = false;
        var err_msg: ?[]const u8 = null;
        var last_id: ?NodeId = null;

        var i: usize = 0;
        while (i < max_nodes) : (i += 1) {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "{{\"find_successor\":{{\"target\":{d}}}}}", .{target}) catch break;
            var resp_buf: [4096]u8 = undefined;
            const n = self.udpSendAndWait("127.0.0.1", node_udp_port, msg, &resp_buf, self.config.lookup_timeout_ms) catch |e| {
                err_msg = @errorName(e);
                break;
            };
            if (n == 0) {
                err_msg = "timeout";
                break;
            }
            const r = parseFsResp(alloc, resp_buf[0..n]) catch |e| {
                err_msg = @errorName(e);
                break;
            };
            nodes_list.append(r.info) catch {
                err_msg = "oom";
                break;
            };
            if (r.id == my_id) {
                closed = true; // 环闭合
                break;
            }
            // 停滞保护：连续两跳拿到同一节点 = 该节点自指（孤立/环断裂），
            // target 无法推进，避免 32 次重复的无效遍历
            if (last_id) |prev| {
                if (prev == r.id) {
                    stalled = true;
                    break;
                }
            }
            last_id = r.id;
            target = r.id +% 1;
        }
        return .{
            .nodes = nodes_list.toOwnedSlice() catch &.{},
            .closed = closed,
            .stalled = stalled,
            .err = err_msg,
        };
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
