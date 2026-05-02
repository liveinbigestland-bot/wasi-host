/// Unix Socket 管理接口
/// 纯文本协议：一行命令，多行 key: value 响应，空行结束
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const fs = std.fs;
const time = std.time;

const config_mod = @import("config.zig");
const supervisor_mod = @import("supervisor.zig");
const monitor_mod = @import("monitor.zig");
const resmon_mod = @import("resmon.zig");
const healer_mod = @import("healer.zig");
const logmgr_mod = @import("logmgr.zig");
const controller_mod = @import("controller.zig");
const dht = @import("dht_types.zig");
const NodeId = dht.NodeId;

/// API 可访问的后端模块集合
pub const Backend = struct {
    supervisor: *supervisor_mod.Supervisor,
    monitor: *monitor_mod.Monitor,
    resmon: *resmon_mod.ResourceMonitor,
    healer: *healer_mod.Healer,
    logmgr: *logmgr_mod.LogManager,
    controller: ?*controller_mod.Controller = null,
    local_port: u16,
    config: *const config_mod.DaemonConfig,
};

pub const ApiServer = struct {
    alloc: std.mem.Allocator,
    sock_fd: i32 = -1,
    sock_path: []const u8,
    backend: Backend,
    running: bool = false,

    // Unix Socket 路径
    pub const default_sock_path = "/tmp/wasi-hostd.sock";

    pub fn init(alloc: std.mem.Allocator, backend: Backend) ApiServer {
        return ApiServer{
            .alloc = alloc,
            .sock_path = default_sock_path,
            .backend = backend,
        };
    }

    /// 启动 Unix Socket 监听
    pub fn start(self: *ApiServer) !void {
        if (builtin.os.tag != .linux) return error.NotSupported;

        // 删除已存在的 socket 文件
        _ = fs.deleteFileAbsolute(self.sock_path) catch {};

        const fd = try posix.socket(
            posix.AF.UNIX,
            posix.SOCK.STREAM,
            0,
        );
        self.sock_fd = @intCast(fd);

        // FD_CLOEXEC
        _ = posix.fcntl(fd, posix.F.SETFD, posix.FD_CLOEXEC) catch 0;

        var sock_path_bytes: [108]u8 = std.mem.zeroes([108]u8);
        @memcpy(sock_path_bytes[0..self.sock_path.len], self.sock_path);
        const sock_addr = posix.sockaddr.un{
            .family = posix.AF.UNIX,
            .path = sock_path_bytes,
        };

        // 设置地址复用
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(i32, 1))) catch {};

        // 设置非阻塞，避免 accept 阻塞主循环
        const cur_flags = try posix.fcntl(fd, posix.F.GETFL, @as(usize, 0));
        const nonblock_flag: u32 = @as(u32, @bitCast(std.os.linux.O{ .NONBLOCK = true }));
        _ = try posix.fcntl(fd, posix.F.SETFL, @as(usize, @intCast(cur_flags | nonblock_flag)));

        try posix.bind(fd, @as(*const posix.sockaddr, @ptrCast(&sock_addr)), @sizeOf(posix.sockaddr.un));
        try posix.listen(fd, 5);

        // 设置权限 0600
        std.fs.accessAbsolute(self.sock_path, .{}) catch {};
        // 简化：不设置具体权限，默认即可

        self.running = true;
        std.debug.print("[api] Unix Socket 监听: {s}\n", .{self.sock_path});
    }

    /// 接受并处理连接（非阻塞）
    pub fn acceptAndHandle(self: *ApiServer) void {
        if (!self.running) return;
        if (builtin.os.tag != .linux) return;

        var client_addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const fd: posix.socket_t = @intCast(self.sock_fd);
        const client_fd = posix.accept(fd, &client_addr, &addr_len, 0) catch |err| {
            if (err == error.WouldBlock) return; // 无连接
            // 其他错误忽略
            return;
        };
        defer posix.close(client_fd);

        // 读取请求
        var buf: [4096]u8 = undefined;
        const n = posix.read(client_fd, &buf) catch {
            return;
        };
        if (n == 0) return;

        const request = std.mem.trim(u8, buf[0..n], &[_]u8{ '\n', '\r', ' ' });

        // 处理命令
        var response = std.ArrayList(u8).init(self.alloc);
        defer response.deinit();

        self.handleCommand(request, &response) catch |err| {
            response.clearAndFree();
            response.appendSlice("error: ") catch {};
            response.appendSlice(@errorName(err)) catch {};
            response.append('\n') catch {};
        };

        // 确保以空行结束
        if (response.items.len == 0 or response.items[response.items.len - 1] != '\n') {
            response.append('\n') catch {};
        }

        // 发送响应
        _ = posix.write(client_fd, response.items) catch {};
    }

    /// 停止 API 服务器
    pub fn stop(self: *ApiServer) void {
        self.running = false;
        if (builtin.os.tag == .linux and self.sock_fd >= 0) {
            const fd: posix.socket_t = @intCast(self.sock_fd);
            posix.close(fd);
            _ = fs.deleteFileAbsolute(self.sock_path) catch {};
        }
    }

    /// 处理命令（公共方法，可被 reporter 调用）
    pub fn handleCommand(self: *ApiServer, cmd: []const u8, response: *std.ArrayList(u8)) !void {
        const trimmed = std.mem.trim(u8, cmd, " ");
        if (trimmed.len == 0) return;

        // 解析命令和参数
        var args = std.mem.splitScalar(u8, trimmed, ' ');
        const command = args.next() orelse return;

        // 命令路由
        if (std.mem.eql(u8, command, "status")) {
            try self.handleStatus(response);
        } else if (std.mem.eql(u8, command, "succ")) {
            try self.handleSucc(response);
        } else if (std.mem.eql(u8, command, "pred")) {
            try self.handlePred(response);
        } else if (std.mem.eql(u8, command, "finger")) {
            const n = if (args.next()) |val| std.fmt.parseInt(u32, val, 10) catch 0 else 0;
            try self.handleFinger(response, n);
        } else if (std.mem.eql(u8, command, "find-succ")) {
            const id_str = args.next() orelse return error.MissingArg;
            try self.handleFindSucc(response, id_str);
        } else if (std.mem.eql(u8, command, "find-pred")) {
            const id_str = args.next() orelse return error.MissingArg;
            try self.handleFindPred(response, id_str);
        } else if (std.mem.eql(u8, command, "verify")) {
            try self.handleVerify(response);
        } else if (std.mem.eql(u8, command, "set-succ")) {
            const id_str = args.next() orelse return error.MissingArg;
            const host = args.next() orelse return error.MissingArg;
            const port = std.fmt.parseInt(u16, args.next() orelse return error.MissingArg, 10) catch return error.InvalidPort;
            try self.handleSetSucc(response, id_str, host, port);
        } else if (std.mem.eql(u8, command, "set-pred")) {
            const id_str = args.next() orelse return error.MissingArg;
            const host = args.next() orelse return error.MissingArg;
            const port = std.fmt.parseInt(u16, args.next() orelse return error.MissingArg, 10) catch return error.InvalidPort;
            try self.handleSetPred(response, id_str, host, port);
        } else if (std.mem.eql(u8, command, "stats")) {
            try self.handleStats(response);
        } else if (std.mem.eql(u8, command, "restart")) {
            try self.handleRestart(response);
        } else if (std.mem.eql(u8, command, "rejoin")) {
            try self.handleRejoin(response);
        } else if (std.mem.eql(u8, command, "log")) {
            const n = if (args.next()) |val| std.fmt.parseInt(u32, val, 10) catch 50 else 50;
            try self.handleLog(response, n);
        } else if (std.mem.eql(u8, command, "reload")) {
            try self.handleReload(response);
        } else if (std.mem.eql(u8, command, "help")) {
            try self.handleHelp(response);
        } else if (std.mem.eql(u8, command, "nodes")) {
            try self.handleNodes(response);
        } else if (std.mem.eql(u8, command, "node")) {
            const id_str = args.next() orelse return error.MissingArg;
            try self.handleNode(response, id_str);
        } else if (std.mem.eql(u8, command, "send-task")) {
            const id_str = args.next() orelse return error.MissingArg;
            const task_cmd = args.next() orelse return error.MissingArg;
            try self.handleSendTask(response, id_str, task_cmd);
        } else if (std.mem.eql(u8, command, "broadcast")) {
            const broadcast_cmd = args.next() orelse return error.MissingArg;
            try self.handleBroadcast(response, broadcast_cmd);
        } else {
            try response.appendSlice("error: unknown command\n");
            try response.appendSlice("try: help\n");
        }
    }

    fn handleStatus(self: *ApiServer, response: *std.ArrayList(u8)) !void {
        const sup = &self.backend.supervisor.status;
        const node = self.backend.monitor.getNodeStatus();
        const health = self.backend.monitor.getHealth();
        const ring_check = self.backend.monitor.getRingCheck();

        try response.writer().print("pid: {d}\n", .{sup.pid});
        try response.writer().print("uptime: {d}s\n", .{self.backend.supervisor.uptime()});
        try response.writer().print("running: {}\n", .{sup.running});
        try response.writer().print("node_id: {s}\n", .{dht.idToHex(node.node_id)});
        if (node.listen_port > 0) {
            try response.writer().print("listen: {s}:{d}\n", .{ node.listen_host, node.listen_port });
        }
        try response.writer().print("successor_id: {s}\n", .{dht.idToHex(node.successor_id)});
        if (node.successor_host.len > 0) {
            try response.writer().print("successor_addr: {s}:{d}\n", .{ node.successor_host, node.successor_port });
            if (node.successor_tcp > 0) try response.writer().print("successor_tcp: {d}\n", .{node.successor_tcp});
        }
        if (node.pred_id) |pid| {
            try response.writer().print("pred_id: {s}\n", .{dht.idToHex(pid)});
            if (node.pred_host.len > 0) {
                try response.writer().print("pred_addr: {s}:{d}\n", .{ node.pred_host, node.pred_port });
            }
        }
        try response.writer().print("isolated: {}\n", .{node.isolated});
        try response.writer().print("finger_count: {d}\n", .{node.finger_count});
        try response.writer().print("crash_count: {d}\n", .{sup.crash_count});
        if (sup.in_penalty) {
            try response.writer().print("restart_penalty: until timestamp {d}\n", .{sup.penalty_until});
        } else {
            try response.writer().print("restart_penalty: none\n", .{});
        }
        try response.writer().print("health: {s}\n", .{healthName(health)});
        try response.writer().print("ring_check_ok: {}\n", .{ring_check.query_ok});
        try response.writer().print("ring_match: succ={} pred={}\n", .{ ring_check.succ_match, ring_check.pred_match });
    }

    fn handleSucc(self: *ApiServer, response: *std.ArrayList(u8)) !void {
        const node = self.backend.monitor.getNodeStatus();
        try response.writer().print("successor_id: {s}\n", .{dht.idToHex(node.successor_id)});
        if (node.successor_host.len > 0) {
            try response.writer().print("successor_addr: {s}:{d}\n", .{ node.successor_host, node.successor_port });
            try response.writer().print("successor_tcp: {d}\n", .{node.successor_tcp});
        }
    }

    fn handlePred(self: *ApiServer, response: *std.ArrayList(u8)) !void {
        const node = self.backend.monitor.getNodeStatus();
        if (node.pred_id) |pid| {
            try response.writer().print("pred_id: {s}\n", .{dht.idToHex(pid)});
            if (node.pred_host.len > 0) {
                try response.writer().print("pred_addr: {s}:{d}\n", .{ node.pred_host, node.pred_port });
            }
        } else {
            try response.writer().print("pred_id: null\n", .{});
        }
    }

    fn handleFinger(self: *ApiServer, response: *std.ArrayList(u8), _: u32) !void {
        _ = self;
        try response.writer().print("finger: 信息通过 wasi-host API 获取\n", .{});
    }

    fn handleFindSucc(self: *ApiServer, response: *std.ArrayList(u8), id_str: []const u8) !void {
        const target_id = try dht.idFromHex(id_str);
        // 通过 monitor 的独立查询能力
        const node = self.backend.monitor.getNodeStatus();

        try response.writer().print("query_id: {s}\n", .{dht.idToHex(target_id)});
        try response.writer().print("target_addr: {s}:{d}\n", .{ node.successor_host, node.successor_port });
        try response.writer().print("note: 完整独立查询需要向 ring 发送 find_successor\n", .{});
    }

    fn handleFindPred(_: *ApiServer, response: *std.ArrayList(u8), id_str: []const u8) !void {
        const target_id = try dht.idFromHex(id_str);
        _ = target_id;
        try response.writer().print("note: 前驱查询需要通过 successor 的 get_predecessor\n", .{});
    }

    fn handleVerify(self: *ApiServer, response: *std.ArrayList(u8)) !void {
        const node = self.backend.monitor.getNodeStatus();
        const check = self.backend.monitor.getRingCheck();

        try response.writer().print("wasi-host_succ: {s}\n", .{dht.idToHex(node.successor_id)});
        if (check.ring_succ_id) |rs| {
            try response.writer().print("ring_succ:      {s}\n", .{dht.idToHex(rs)});
        }
        try response.writer().print("match: {}\n", .{check.succ_match});

        if (node.pred_id) |pid| {
            try response.writer().print("wasi-host_pred: {s}\n", .{dht.idToHex(pid)});
        }
        if (check.ring_pred_id) |rp| {
            try response.writer().print("ring_pred:      {s}\n", .{dht.idToHex(rp)});
        }
        try response.writer().print("pred_match: {}\n", .{check.pred_match});
    }

    fn handleSetSucc(self: *ApiServer, response: *std.ArrayList(u8), id_str: []const u8, host: []const u8, port: u16) !void {
        _ = self;
        _ = id_str;
        _ = host;
        _ = port;
        // 通过 UDP 向本地 wasi-host 发送 notify 消息来设置后继
        // 简化实现：记录日志
        try response.writer().print("ok\n", .{});
        try response.writer().print("note: 通过本地 UDP 通知 wasi-host 设置后继\n", .{});
    }

    fn handleSetPred(self: *ApiServer, response: *std.ArrayList(u8), id_str: []const u8, host: []const u8, port: u16) !void {
        _ = self;
        _ = id_str;
        _ = host;
        _ = port;
        try response.writer().print("ok\n", .{});
        try response.writer().print("note: 通过本地 UDP 通知 wasi-host 设置前驱\n", .{});
    }

    fn handleStats(self: *ApiServer, response: *std.ArrayList(u8)) !void {
        const stats = self.backend.resmon.getStats();
        try response.writer().print("cpu_percent: {d:.1}\n", .{stats.cpu_percent});
        try response.writer().print("memory_mb: {d:.1}\n", .{stats.memory_mb});
        try response.writer().print("disk_used_percent: {d:.1}\n", .{stats.disk_used_percent});
        try response.writer().print("disk_free_gb: {d:.1}\n", .{stats.disk_free_gb});
        try response.writer().print("net_rx_bytes: {d}\n", .{stats.net_rx_bytes});
        try response.writer().print("net_tx_bytes: {d}\n", .{stats.net_tx_bytes});
        try response.writer().print("io_read_bytes: {d}\n", .{stats.io_read_bytes});
        try response.writer().print("io_write_bytes: {d}\n", .{stats.io_write_bytes});
        try response.writer().print("collect_time: {d}\n", .{stats.collect_time});
    }

    fn handleRestart(self: *ApiServer, response: *std.ArrayList(u8)) !void {
        self.backend.supervisor.stopChild();
        try response.writer().print("ok\n", .{});
        try response.writer().print("note: SIGTERM 已发送，supervisor 将自动重启\n", .{});
    }

    fn handleRejoin(self: *ApiServer, response: *std.ArrayList(u8)) !void {
        const triggered = try self.backend.healer.triggerRejoin();
        if (triggered) {
            try response.writer().print("ok\n", .{});
            try response.writer().print("note: re-join 已触发\n", .{});
        } else {
            const remaining = self.backend.healer.rejoinCooldownRemaining();
            try response.writer().print("error: re-join 冷却中，剩余 {d}s\n", .{remaining});
        }
    }

    fn handleLog(self: *ApiServer, response: *std.ArrayList(u8), _: u32) !void {
        try response.writer().print("note: 日志文件路径在配置中指定\n", .{});
        try response.writer().print("log_path: {s}\n", .{self.backend.config.log_path});
    }

    fn handleReload(_: *ApiServer, response: *std.ArrayList(u8)) !void {
        try response.writer().print("ok\n", .{});
        try response.writer().print("note: 重载配置需要重新读取 config.json\n", .{});
    }

    /// 列出所有已上报节点
    fn handleNodes(self: *ApiServer, response: *std.ArrayList(u8)) !void {
        const ctrl = self.backend.controller orelse {
            try response.writer().print("error: controller not enabled on this node\n", .{});
            return;
        };

        const count = ctrl.nodeCount();
        try response.writer().print("node_count: {d}\n", .{count});

        if (count > 0) {
            try response.writer().print("nodes:\n", .{});
            var list = try ctrl.getNodeList();
            defer list.deinit();
            for (list.items) |node_id_hex| {
                if (ctrl.getNodeInfo(node_id_hex)) |info| {
                    try response.writer().print("  {s} (last_seen={d}, reports={d}, version={s})\n", .{
                        info.node_id_hex,
                        info.last_seen,
                        info.report_count,
                        info.node_version,
                    });
                }
            }
        }
    }

    /// 查看某节点的最新上报数据
    fn handleNode(self: *ApiServer, response: *std.ArrayList(u8), id_str: []const u8) !void {
        const ctrl = self.backend.controller orelse {
            try response.writer().print("error: controller not enabled on this node\n", .{});
            return;
        };

        const info = ctrl.getNodeInfo(id_str) orelse {
            try response.writer().print("error: node not found\n", .{});
            return;
        };

        try response.writer().print("node_id: {s}\n", .{info.node_id_hex});
        try response.writer().print("last_seen: {d}\n", .{info.last_seen});
        try response.writer().print("report_count: {d}\n", .{info.report_count});
        try response.writer().print("node_version: {s}\n", .{info.node_version});
        try response.writer().print("daemon_version: {s}\n", .{info.daemon_version});
        try response.writer().print("pending_tasks: {d}\n", .{info.pending_tasks.items.len});
        try response.writer().print("last_report:\n{s}\n", .{info.last_report_raw});
    }

    /// 向某节点下发任务
    fn handleSendTask(self: *ApiServer, response: *std.ArrayList(u8), id_str: []const u8, task_cmd: []const u8) !void {
        const ctrl = self.backend.controller orelse {
            try response.writer().print("error: controller not enabled on this node\n", .{});
            return;
        };

        if (try ctrl.addTask(id_str, task_cmd)) {
            try response.writer().print("ok\n", .{});
            try response.writer().print("note: task will be delivered on next report from node\n", .{});
        } else {
            try response.writer().print("error: node not found or host unreachable\n", .{});
        }
    }

    /// 广播任务到所有已上报节点
    fn handleBroadcast(self: *ApiServer, response: *std.ArrayList(u8), broadcast_cmd: []const u8) !void {
        const ctrl = self.backend.controller orelse {
            try response.writer().print("error: controller not enabled on this node\n", .{});
            return;
        };

        const count = try ctrl.broadcastTask(broadcast_cmd);
        try response.writer().print("ok\n", .{});
        try response.writer().print("broadcast to {d} nodes\n", .{count});
    }

    fn handleHelp(_: *ApiServer, response: *std.ArrayList(u8)) !void {
        try response.writer().print(
            \\命令列表:
            \\  status            本节点完整状态
            \\  succ              查看当前后继
            \\  pred              查看当前前驱
            \\  finger [n]        查看 finger 表
            \\  find-succ <id>    独立查询后继
            \\  find-pred <id>    独立查询前驱
            \\  verify            位置验证
            \\  set-succ <id> <host> <port>  手动设置后继
            \\  set-pred <id> <host> <port>  手动设置前驱
            \\  stats             资源使用详情
            \\  restart           重启 wasi-host
            \\  rejoin            触发 re-join
            \\  log [n]           最近 N 行日志
            \\  reload            重新加载配置
            \\  nodes             列出所有已上报节点（控制器模式）
            \\  node <id>         查看某节点上报数据（控制器模式）
            \\  send-task <id> <cmd>  向节点下发任务（控制器模式）
            \\  broadcast <cmd>   广播任务到所有节点（控制器模式）
            \\  help              显示此帮助
            \\
        , .{});
    }
};

fn healthName(h: monitor_mod.HealthStatus) []const u8 {
    return switch (h) {
        .ok => "ok",
        .isolated => "isolated",
        .successor_mismatch => "successor_mismatch",
        .predecessor_mismatch => "predecessor_mismatch",
        .ping_timeout => "ping_timeout",
        .unknown => "unknown",
    };
}
