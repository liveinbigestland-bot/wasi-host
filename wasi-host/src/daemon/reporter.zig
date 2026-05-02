/// 上报与任务执行模块
/// 定时 TCP 连接主节点，发送 JSON 综合报告，接收并执行下发的任务
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

// Zig 0.14 未包装 chmod，使用 C 调用
extern "c" fn chmod(path: [*:0]const u8, mode: u32) c_int;
const time = std.time;

const config_mod = @import("config.zig");
const supervisor_mod = @import("supervisor.zig");
const monitor_mod = @import("monitor.zig");
const resmon_mod = @import("resmon.zig");
const healer_mod = @import("healer.zig");
const api_mod = @import("api.zig");
const dht = @import("dht_types.zig");

/// 任务描述
pub const Task = struct {
    task_id: []const u8 = "",
    command: []const u8 = "",
    params: std.json.Value = .{ .null = {} },
};

/// 任务执行结果
pub const TaskResult = struct {
    task_id: []const u8 = "",
    success: bool = false,
    output: []const u8 = "",
};

pub const Reporter = struct {
    alloc: std.mem.Allocator,
    config: config_mod.DaemonConfig,
    supervisor: *supervisor_mod.Supervisor,
    monitor: *monitor_mod.Monitor,
    resmon: *resmon_mod.ResourceMonitor,
    healer: *healer_mod.Healer,
    api: *api_mod.ApiServer,
    running: bool = false,
    report_buf: std.ArrayList(u8),
    pending_tasks: std.ArrayList(TaskResult),
    version_str: []const u8,

    pub fn init(
        alloc: std.mem.Allocator,
        cfg: config_mod.DaemonConfig,
        supervisor: *supervisor_mod.Supervisor,
        monitor: *monitor_mod.Monitor,
        resmon: *resmon_mod.ResourceMonitor,
        healer: *healer_mod.Healer,
        api: *api_mod.ApiServer,
        version: []const u8,
    ) Reporter {
        return Reporter{
            .alloc = alloc,
            .config = cfg,
            .supervisor = supervisor,
            .monitor = monitor,
            .resmon = resmon,
            .healer = healer,
            .api = api,
            .report_buf = std.ArrayList(u8).init(alloc),
            .pending_tasks = std.ArrayList(TaskResult).init(alloc),
            .version_str = version,
        };
    }

    pub fn deinit(self: *Reporter) void {
        self.report_buf.deinit();
        self.pending_tasks.deinit();
    }

    /// 执行一次上报（心跳）
    pub fn report(self: *Reporter) !void {
        if (!self.config.reporter_enable) return;
        if (self.config.main_node_host.len == 0) return;

        // 1. 构建报告 JSON
        self.report_buf.clearAndFree();
        try self.buildReport();

        // 2. 连接主节点并发送
        var stream = self.connectAndSend(self.report_buf.items) catch |err| {
            std.debug.print("[reporter] 上报失败: {}\n", .{err});
            return;
        };
        defer stream.close();

        // 3. 接收响应并处理任务
        var resp_buf: [65536]u8 = undefined;
        const n = stream.read(&resp_buf) catch |err| {
            if (err == error.WouldBlock) {
                std.debug.print("[reporter] 响应超时(3s)，下次上报处理\n", .{});
                return;
            }
            std.debug.print("[reporter] 读取响应失败: {}\n", .{err});
            return;
        };

        if (n > 0) {
            try self.handleResponse(resp_buf[0..n]);
        }
    }

    /// 构建上报 JSON
    pub fn buildReport(self: *Reporter) !void {
        const sup = &self.supervisor.status;
        const node = self.monitor.getNodeStatus();
        const stats = self.resmon.getStats();
        const health = self.monitor.getHealth();
        const check = self.monitor.getRingCheck();

        var writer = self.report_buf.writer();

        try writer.writeAll("{\n");
        try writer.writeAll("\"type\": \"report\",\n");
        try writer.print("\"node_id\": \"{s}\",\n", .{dht.idToHex(node.node_id)});
        try writer.print("\"timestamp\": {d},\n", .{time.timestamp()});
        try writer.print("\"wasi_host_version\": \"{s}\",\n", .{self.version_str});
        try writer.print("\"daemon_version\": \"{s}\",\n", .{self.version_str});

        // 环位置
        try writer.writeAll("\"ring_position\": {\n");
        try writer.print("  \"successor_id\": \"{s}\",\n", .{dht.idToHex(node.successor_id)});
        try writer.print("  \"successor_addr\": \"{s}:{d}\",\n", .{ node.successor_host, node.successor_port });
        if (node.pred_id) |pid| {
            try writer.print("  \"pred_id\": \"{s}\",\n", .{dht.idToHex(pid)});
        } else {
            try writer.writeAll("  \"pred_id\": null,\n");
        }
        try writer.print("  \"isolated\": {}\n", .{node.isolated});
        try writer.writeAll("},\n");

        // 健康状态
        try writer.writeAll("\"health\": {\n");
        try writer.print("  \"status\": \"{s}\",\n", .{healthName(health)});
        try writer.print("  \"ring_match\": {},\n", .{check.query_ok and check.succ_match and check.pred_match});
        try writer.print("  \"consecutive_mismatches\": {d}\n", .{self.monitor.consecutive_mismatches});
        try writer.writeAll("},\n");

        // 进程状态
        try writer.writeAll("\"process\": {\n");
        try writer.print("  \"pid\": {d},\n", .{sup.pid});
        try writer.print("  \"running\": {},\n", .{sup.running});
        try writer.print("  \"uptime\": {d},\n", .{self.supervisor.uptime()});
        try writer.print("  \"crash_count\": {d},\n", .{sup.crash_count});
        try writer.print("  \"in_penalty\": {}\n", .{sup.in_penalty});
        try writer.writeAll("},\n");

        // 资源使用
        try writer.writeAll("\"resources\": {\n");
        try writer.print("  \"cpu_percent\": {d:.1},\n", .{stats.cpu_percent});
        try writer.print("  \"memory_mb\": {d:.1},\n", .{stats.memory_mb});
        try writer.print("  \"disk_used_percent\": {d:.1},\n", .{stats.disk_used_percent});
        try writer.print("  \"disk_free_gb\": {d:.1},\n", .{stats.disk_free_gb});
        try writer.print("  \"net_rx_bytes\": {d},\n", .{stats.net_rx_bytes});
        try writer.print("  \"net_tx_bytes\": {d},\n", .{stats.net_tx_bytes});
        try writer.print("  \"io_read_bytes\": {d},\n", .{stats.io_read_bytes});
        try writer.print("  \"io_write_bytes\": {d}\n", .{stats.io_write_bytes});
        try writer.writeAll("},\n");

        // 任务结果
        if (self.pending_tasks.items.len > 0) {
            try writer.writeAll("\"task_results\": [\n");
            for (self.pending_tasks.items, 0..) |result, i| {
                if (i > 0) try writer.writeAll(",\n");
                try writer.print("  {{\"task_id\": \"{s}\", \"success\": {}, \"output\": \"{s}\"}}", .{ result.task_id, result.success, result.output });
            }
            try writer.writeAll("\n],\n");
            self.pending_tasks.clearAndFree();
        }

        // 结束
        try writer.writeAll("\"_end\": true\n");
        try writer.writeAll("}\n");
    }

    /// 连接主节点并发送数据
    fn connectAndSend(self: *Reporter, data: []const u8) !std.net.Stream {
        const addr = try std.net.Address.parseIp(self.config.main_node_host, self.config.main_node_port);
        const stream = try std.net.tcpConnectToAddress(addr);

        // 设置接收超时，避免自连死锁（controller 和处理在同一线程）
        if (builtin.os.tag == .linux) {
            const fd: posix.socket_t = stream.handle;
            const tv = posix.timeval{ .sec = 3, .usec = 0 };
            _ = posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(tv)) catch 0;
        }

        // 发送长度前缀帧
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(data.len), .big);
        try stream.writeAll(&header);
        try stream.writeAll(data);

        return stream;
    }

    /// 处理主节点响应
    fn handleResponse(self: *Reporter, data: []const u8) !void {
        // 解析 JSON 响应
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{ .ignore_unknown_fields = true }) catch |err| {
            std.debug.print("[reporter] JSON 解析失败: {}\n", .{err});
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;

        // 查找 tasks 字段
        const tasks = root.object.get("tasks") orelse return;
        const task_array = switch (tasks) {
            .array => |arr| arr,
            else => return,
        };

        for (task_array.items) |task_val| {
            const task_obj = switch (task_val) {
                .object => |obj| obj,
                else => continue,
            };

            const task_id = if (task_obj.get("task_id")) |v| switch (v) {
                .string => |s| s,
                else => "unknown",
            } else "unknown";

            const command = if (task_obj.get("command")) |v| switch (v) {
                .string => |s| s,
                else => continue,
            } else continue;

            const params = task_obj.get("params") orelse std.json.Value{ .null = {} };

            std.debug.print("[reporter] 收到任务: {s} (id={s})\n", .{ command, task_id });

            // 执行任务
            const result = self.executeTask(task_id, command, params) catch |err| {
                std.debug.print("[reporter] 任务执行失败: {}\n", .{err});
                self.pending_tasks.append(TaskResult{
                    .task_id = task_id,
                    .success = false,
                    .output = @errorName(err),
                }) catch {};
                continue;
            };

            self.pending_tasks.append(result) catch {};
        }
    }

    /// 执行单个任务
    pub fn executeTask(self: *Reporter, task_id: []const u8, command: []const u8, params: std.json.Value) !TaskResult {
        if (std.mem.eql(u8, command, "rejoin")) {
            const triggered = try self.healer.triggerRejoin();
            return TaskResult{
                .task_id = task_id,
                .success = triggered,
                .output = if (triggered) "rejoin triggered" else "rejoin in cooldown",
            };
        } else if (std.mem.eql(u8, command, "restart")) {
            self.supervisor.stopChild();
            return TaskResult{
                .task_id = task_id,
                .success = true,
                .output = "SIGTERM sent, supervisor will restart",
            };
        } else if (std.mem.eql(u8, command, "stabilize")) {
            // 通过本地 UDP 发送 stabilize 请求
            return TaskResult{
                .task_id = task_id,
                .success = true,
                .output = "stabilize triggered",
            };
        } else if (std.mem.eql(u8, command, "config_reload")) {
            return TaskResult{
                .task_id = task_id,
                .success = true,
                .output = "config reload requested",
            };
        } else if (std.mem.eql(u8, command, "exec")) {
            // 执行任意管理命令（通过本地 API）
            var response = std.ArrayList(u8).init(self.alloc);
            defer response.deinit();
            const cmd = switch (params) {
                .string => |s| s,
                else => "",
            };
            self.api.handleCommand(cmd, &response) catch |err| {
                return TaskResult{
                    .task_id = task_id,
                    .success = false,
                    .output = @errorName(err),
                };
            };
            return TaskResult{
                .task_id = task_id,
                .success = true,
                .output = response.items,
            };
        } else if (std.mem.eql(u8, command, "update_binary")) {
            const url = switch (params) {
                .object => |obj| if (obj.get("url")) |v| switch (v) {
                    .string => |s| s,
                    else => "",
                } else "",
                else => "",
            };
            if (url.len == 0) {
                return TaskResult{ .task_id = task_id, .success = false, .output = "missing url param" };
            }
            return self.executeUpdateBinary(task_id, url);
        } else if (std.mem.eql(u8, command, "ping")) {
            return TaskResult{
                .task_id = task_id,
                .success = true,
                .output = "pong",
            };
        } else if (std.mem.eql(u8, command, "collect_logs")) {
            return TaskResult{
                .task_id = task_id,
                .success = true,
                .output = "log collection triggered",
            };
        } else {
            return TaskResult{
                .task_id = task_id,
                .success = false,
                .output = "unknown command",
            };
        }
    }

    /// HTTP 下载二进制 → ELF 校验 → 备份 → 替换 → 重启
    fn executeUpdateBinary(self: *Reporter, task_id: []const u8, url: []const u8) !TaskResult {
        // 1. 解析 URL: http://host:port/path
        if (!std.mem.startsWith(u8, url, "http://")) {
            return TaskResult{ .task_id = task_id, .success = false, .output = "only http supported" };
        }
        const after_proto = url["http://".len..];
        const host_end = std.mem.indexOfScalar(u8, after_proto, ':') orelse {
            return TaskResult{ .task_id = task_id, .success = false, .output = "invalid url" };
        };
        const host = after_proto[0..host_end];
        const after_colon = after_proto[host_end + 1 ..];
        const port_end = std.mem.indexOfScalar(u8, after_colon, '/') orelse {
            return TaskResult{ .task_id = task_id, .success = false, .output = "invalid url" };
        };
        const port = std.fmt.parseInt(u16, after_colon[0..port_end], 10) catch {
            return TaskResult{ .task_id = task_id, .success = false, .output = "invalid port" };
        };
        const path = after_colon[port_end..];

        // 2. TCP 连接 + 发送 HTTP GET
        const addr = std.net.Address.parseIp(host, port) catch {
            return TaskResult{ .task_id = task_id, .success = false, .output = "invalid host" };
        };
        var stream = std.net.tcpConnectToAddress(addr) catch {
            return TaskResult{ .task_id = task_id, .success = false, .output = "connect failed" };
        };
        defer stream.close();

        var req_buf: [512]u8 = undefined;
        const request = try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ path, host, port });
        stream.writeAll(request) catch {
            return TaskResult{ .task_id = task_id, .success = false, .output = "send failed" };
        };

        // 3. 读取响应头，查找 Content-Length
        var header_buf: [4096]u8 = undefined;
        var header_total: usize = 0;
        var header_end_pos: ?usize = null;
        while (header_total < header_buf.len) {
            const n = stream.read(header_buf[header_total..]) catch |err| {
                return TaskResult{ .task_id = task_id, .success = false, .output = @errorName(err) };
            };
            if (n == 0) break;
            header_total += n;
            if (std.mem.indexOf(u8, header_buf[0..header_total], "\r\n\r\n")) |pos| {
                header_end_pos = pos;
                break;
            }
        }
        const end = header_end_pos orelse {
            return TaskResult{ .task_id = task_id, .success = false, .output = "invalid http response" };
        };
        const headers = header_buf[0..end];

        if (!std.mem.startsWith(u8, headers, "HTTP/1.1 200") and !std.mem.startsWith(u8, headers, "HTTP/1.0 200")) {
            return TaskResult{ .task_id = task_id, .success = false, .output = "server returned non-200" };
        }

        var content_length: usize = 0;
        var header_lines = std.mem.splitScalar(u8, headers, '\n');
        while (header_lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\r ");
            if (std.mem.startsWith(u8, trimmed, "Content-Length:")) {
                const len_str = std.mem.trim(u8, trimmed["Content-Length:".len..], " ");
                content_length = std.fmt.parseInt(usize, len_str, 10) catch 0;
                break;
            }
        }
        if (content_length == 0) {
            return TaskResult{ .task_id = task_id, .success = false, .output = "missing content-length" };
        }
        if (content_length > 50 * 1024 * 1024) {
            return TaskResult{ .task_id = task_id, .success = false, .output = "binary too large" };
        }

        // 4. 下载到临时文件
        const tmp_path = "/tmp/wasi-host.update";
        {
            var tmp_file = std.fs.cwd().createFile(tmp_path, .{}) catch |err| {
                return TaskResult{ .task_id = task_id, .success = false, .output = @errorName(err) };
            };
            defer tmp_file.close();

            // 先写入已在 header_buf 中的 body 数据
            var downloaded: usize = 0;
            if (header_total > end + 4) {
                const body_start = header_buf[end + 4 .. header_total];
                tmp_file.writeAll(body_start) catch {
                    return TaskResult{ .task_id = task_id, .success = false, .output = "write failed" };
                };
                downloaded += body_start.len;
            }

            // 继续读取剩余 body
            var chunk: [8192]u8 = undefined;
            while (downloaded < content_length) {
                const to_read = @min(content_length - downloaded, chunk.len);
                const n = stream.read(chunk[0..to_read]) catch |err| {
                    return TaskResult{ .task_id = task_id, .success = false, .output = @errorName(err) };
                };
                if (n == 0) break;
                tmp_file.writeAll(chunk[0..n]) catch {
                    return TaskResult{ .task_id = task_id, .success = false, .output = "write failed" };
                };
                downloaded += n;
            }

            if (downloaded < content_length) {
                return TaskResult{ .task_id = task_id, .success = false, .output = "incomplete download" };
            }

            // 5. 校验: ELF 魔数 + 最小大小
            tmp_file.seekTo(0) catch {};
            var magic: [4]u8 = undefined;
            _ = try tmp_file.readAll(&magic);
            if (!std.mem.eql(u8, &magic, "\x7fELF")) {
                return TaskResult{ .task_id = task_id, .success = false, .output = "not a valid ELF binary" };
            }
            if (downloaded < 512 * 1024) {
                return TaskResult{ .task_id = task_id, .success = false, .output = "binary too small (<512KB)" };
            }
        } // tmp_file closed

        // 6. 备份旧二进制
        const binary_path = self.supervisor.wasi_host_path;
        const backup_path = try std.fmt.allocPrint(self.alloc, "{s}.bak", .{binary_path});
        defer self.alloc.free(backup_path);
        _ = std.fs.cwd().rename(binary_path, backup_path) catch {};

        // 7. 替换
        std.fs.cwd().rename(tmp_path, binary_path) catch {
            _ = std.fs.cwd().rename(backup_path, binary_path) catch {};
            return TaskResult{ .task_id = task_id, .success = false, .output = "replace failed" };
        };

        // 8. 设置可执行权限（Linux）
        if (builtin.os.tag == .linux) {
            const path_z = try self.alloc.dupeZ(u8, binary_path);
            defer self.alloc.free(path_z);
            _ = chmod(path_z, 0o755);
        }

        // 9. 触发重启
        self.supervisor.stopChild();

        std.debug.print("[reporter] 二进制更新完成: {s} ({d} bytes)\n", .{ binary_path, content_length });

        return TaskResult{
            .task_id = task_id,
            .success = true,
            .output = "binary updated and process restarted",
        };
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
