/// 主节点控制器（Controller）
/// TCP 上报服务器：接收各守护进程的上报，存储最新数据，返回待执行任务
/// 仅在 controller_enable=true 时启动（主节点）
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const time = std.time;

const config_mod = @import("config.zig");
const dht = @import("dht_types.zig");
const NodeId = dht.NodeId;

/// 下发任务描述
pub const Task = struct {
    task_id: []u8,
    command: []u8,
    params_json: []u8, // JSON 片段，空表示无参数

    pub fn deinit(self: *Task, alloc: std.mem.Allocator) void {
        alloc.free(self.task_id);
        alloc.free(self.command);
        alloc.free(self.params_json);
    }
};

/// 节点注册信息
pub const NodeInfo = struct {
    node_id: NodeId,
    node_id_hex: []u8,
    last_report_raw: []u8,
    last_seen: i64,
    report_count: u64,
    node_version: []u8,
    daemon_version: []u8,
    pending_tasks: std.ArrayList(Task),

    pub fn deinit(self: *NodeInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.node_id_hex);
        alloc.free(self.last_report_raw);
        alloc.free(self.node_version);
        alloc.free(self.daemon_version);
        for (self.pending_tasks.items) |*t| t.deinit(alloc);
        self.pending_tasks.deinit();
    }
};

pub const Controller = struct {
    alloc: std.mem.Allocator,
    config: config_mod.DaemonConfig,
    sock_fd: i32 = -1,
    running: bool = false,
    nodes: std.StringHashMap(*NodeInfo),
    version: []const u8, // 本机 daemon 版本，用于自动版本对比
    binary_path: []const u8 = "wasi-host", // 可下载的二进制路径

    pub fn init(alloc: std.mem.Allocator, cfg: config_mod.DaemonConfig, version: []const u8) Controller {
        return Controller{
            .alloc = alloc,
            .config = cfg,
            .nodes = std.StringHashMap(*NodeInfo).init(alloc),
            .version = version,
        };
    }

    pub fn deinit(self: *Controller) void {
        self.stop();
        // 释放所有节点数据
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.nodes.deinit();
    }

    /// 启动 TCP 上报服务器
    pub fn start(self: *Controller) !void {
        if (!self.config.controller_enable) return;
        if (builtin.os.tag != .linux) return error.NotSupported;

        const fd = try posix.socket(
            posix.AF.INET,
            posix.SOCK.STREAM,
            0,
        );
        self.sock_fd = @intCast(fd);

        // SO_REUSEADDR
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(i32, 1))) catch {};

        // FD_CLOEXEC: exec 后自动关闭，被子进程继承会干扰 accept
        _ = posix.fcntl(fd, posix.F.SETFD, posix.FD_CLOEXEC) catch 0;

        // 设置非阻塞
        const cur_flags = try posix.fcntl(fd, posix.F.GETFL, @as(usize, 0));
        const nonblock_flag: u32 = @as(u32, @bitCast(std.os.linux.O{ .NONBLOCK = true }));
        _ = try posix.fcntl(fd, posix.F.SETFL, @as(usize, @intCast(cur_flags | nonblock_flag)));

        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, self.config.controller_listen_port),
            .addr = std.mem.nativeToBig(u32, 0), // 0.0.0.0
            .zero = .{0} ** 8,
        };

        try posix.bind(fd, @as(*const posix.sockaddr, @ptrCast(&addr)), @sizeOf(posix.sockaddr.in));
        try posix.listen(fd, 10);

        self.running = true;
        std.debug.print("[controller] TCP 上报服务器启动: 端口 {d}\n", .{self.config.controller_listen_port});
    }

    /// 停止服务器
    pub fn stop(self: *Controller) void {
        self.running = false;
        if (builtin.os.tag == .linux and self.sock_fd >= 0) {
            posix.close(self.sock_fd);
            self.sock_fd = -1;
        }
    }

    /// 接受并处理一个连接（非阻塞）
    /// 自动检测协议：前 4 字节为 "GET " 时走 HTTP 文件服务，否则走上报协议
    pub fn acceptAndHandle(self: *Controller) void {
        if (!self.running) return;
        if (builtin.os.tag != .linux) return;

        var client_addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const client_fd = posix.accept(self.sock_fd, &client_addr, &addr_len, 0) catch |err| {
            //std.debug.print("[ctrl/dbg] accept err: {}\n", .{err});
            if (err == error.WouldBlock) return;
            return;
        };
        std.debug.print("[ctrl/dbg] accept OK fd={d}\n", .{client_fd});
        defer posix.close(client_fd);

        // 设置 10s 接收超时
        const tv = posix.timeval{ .sec = 10, .usec = 0 };
        posix.setsockopt(client_fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(tv)) catch {};

        // 读取前 4 字节检测协议
        var first_bytes: [4]u8 = undefined;
        const n = posix.read(client_fd, &first_bytes) catch |err| {
            if (err == error.WouldBlock) return;
            return;
        };
        if (n != 4) return;

        // 检测 HTTP GET 请求
        if (std.mem.eql(u8, first_bytes[0..4], "GET ")) {
            self.handleFileRequest(client_fd) catch |err| {
                std.debug.print("[controller] 文件请求处理失败: {}\n", .{err});
            };
            return;
        }

        // 上报协议：这 4 字节是长度前缀（大端 u32）
        const payload_len = std.mem.readInt(u32, &first_bytes, .big);
        if (payload_len == 0 or payload_len > 1048576) return; // 上限 1MB

        // 读取 payload
        const payload = self.alloc.alloc(u8, payload_len) catch return;
        defer self.alloc.free(payload);

        var total_read: usize = 0;
        while (total_read < payload_len) {
            const chunk_n = posix.read(client_fd, payload[total_read..]) catch |err| {
                if (err == error.WouldBlock) break;
                return;
            };
            if (chunk_n == 0) return;
            total_read += chunk_n;
        }
        if (total_read < payload_len) return;

        // 处理上报
        const response = self.handleReport(payload[0..payload_len]) catch |err| {
            std.debug.print("[controller] 处理上报失败: {}\n", .{err});
            return;
        };
        defer self.alloc.free(response);

        // 发送响应
        var resp_header: [4]u8 = undefined;
        std.mem.writeInt(u32, &resp_header, @intCast(response.len), .big);
        _ = posix.write(client_fd, &resp_header) catch {};
        _ = posix.write(client_fd, response) catch {};
    }

    /// 处理 HTTP 文件下载请求
    fn handleFileRequest(self: *Controller, client_fd: posix.socket_t) !void {
        // 读取剩余 HTTP 请求头（up to 4KB）
        var buf: [4096]u8 = undefined;
        @memcpy(buf[0..4], "GET "); // restore the first 4 bytes
        var total: usize = 4;
        while (total < buf.len) {
            const n = posix.read(client_fd, buf[total..]) catch |err| {
                if (err == error.WouldBlock) break;
                return;
            };
            if (n == 0) break;
            total += n;
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |_| break;
        }

        const request = buf[0..total];

        // 解析路径 "GET /path HTTP/1.1"
        const after_get = request[4..];
        const path_end = std.mem.indexOfScalar(u8, after_get, ' ') orelse return;
        const path = after_get[0..path_end];

        // 只允许 /download/wasi-host
        if (!std.mem.eql(u8, path, "/download/wasi-host")) {
            _ = posix.write(client_fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n") catch {};
            return;
        }

        // 打开二进制文件
        const file = std.fs.cwd().openFile(self.binary_path, .{}) catch |err| {
            std.debug.print("[controller] 无法打开二进制文件 '{s}': {}\n", .{ self.binary_path, err });
            const resp = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n";
            _ = posix.write(client_fd, resp) catch {};
            return;
        };
        defer file.close();

        const file_size = try file.getEndPos();

        // 发送 HTTP 200 响应头
        var header_buf: [256]u8 = undefined;
        const http_header = try std.fmt.bufPrint(&header_buf,
            "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n",
            .{file_size},
        );
        _ = posix.write(client_fd, http_header) catch {};

        // 发送文件内容（分块）
        var chunk: [8192]u8 = undefined;
        var remaining = file_size;
        while (remaining > 0) {
            const to_read = @min(remaining, chunk.len);
            const bytes_read = try file.readAll(chunk[0..to_read]);
            if (bytes_read == 0) break;
            _ = posix.write(client_fd, chunk[0..bytes_read]) catch break;
            remaining -= bytes_read;
        }

        // 连接在 defer posix.close 中关闭
    }

    /// 处理上报 JSON，返回响应 JSON（含待执行任务）
    pub fn handleReport(self: *Controller, data: []const u8) ![]u8 {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const root = parsed.value;
        const root_obj = root.object;

        // 提取 node_id
        const node_id_val = root_obj.get("node_id") orelse return error.MissingNodeId;
        const node_id_hex = switch (node_id_val) {
            .string => |s| s,
            else => return error.InvalidNodeId,
        };
        const node_id = try dht.idFromHex(node_id_hex);

        // 提取版本
        var node_version: []const u8 = "";
        if (root_obj.get("wasi_host_version")) |v| {
            if (v == .string) node_version = v.string;
        }
        var daemon_version: []const u8 = "";
        if (root_obj.get("daemon_version")) |v| {
            if (v == .string) daemon_version = v.string;
        }

        // 更新节点注册信息
        const existing = self.nodes.get(node_id_hex);
        if (existing) |info| {
            // 更新已有节点
            self.alloc.free(info.last_report_raw);
            info.last_report_raw = try self.alloc.dupe(u8, data);
            info.last_seen = time.timestamp();
            info.report_count += 1;
            // 更新版本
            self.alloc.free(info.node_version);
            info.node_version = try self.alloc.dupe(u8, node_version);
            self.alloc.free(info.daemon_version);
            info.daemon_version = try self.alloc.dupe(u8, daemon_version);
        } else {
            // 创建新节点注册
            const info = try self.alloc.create(NodeInfo);
            info.* = NodeInfo{
                .node_id = node_id,
                .node_id_hex = try self.alloc.dupe(u8, node_id_hex),
                .last_report_raw = try self.alloc.dupe(u8, data),
                .last_seen = time.timestamp(),
                .report_count = 1,
                .node_version = try self.alloc.dupe(u8, node_version),
                .daemon_version = try self.alloc.dupe(u8, daemon_version),
                .pending_tasks = std.ArrayList(Task).init(self.alloc),
            };
            try self.nodes.put(try self.alloc.dupe(u8, node_id_hex), info);
        }

        // 自动版本检查：版本不匹配时下发 update_binary
        if (node_version.len > 0 and !std.mem.eql(u8, node_version, self.version)) {
            if (existing) |info| {
                if (!hasPendingUpdate(info)) {
                    try self.addUpdateTask(node_id_hex);
                }
            } else {
                try self.addUpdateTask(node_id_hex);
            }
        }

        // 构建响应（含待执行任务）
        return self.buildResponse(node_id_hex);
    }

    /// 检查是否已有 pending 的 update_binary 任务
    pub fn hasPendingUpdate(info: *NodeInfo) bool {
        for (info.pending_tasks.items) |*task| {
            if (std.mem.eql(u8, task.command, "update_binary")) return true;
        }
        return false;
    }

    /// 构建响应 JSON，包含待执行任务
    fn buildResponse(self: *Controller, node_id_hex: []const u8) ![]u8 {
        var buf = std.ArrayList(u8).init(self.alloc);
        defer buf.deinit();

        var writer = buf.writer();
        try writer.writeAll("{\n");
        try writer.writeAll("\"status\": \"ok\",\n");

        const info = self.nodes.get(node_id_hex) orelse {
            try writer.writeAll("\"tasks\": []\n}\n");
            return buf.toOwnedSlice();
        };

        if (info.pending_tasks.items.len > 0) {
            try writer.writeAll("\"tasks\": [\n");
            for (info.pending_tasks.items, 0..) |*task, i| {
                if (i > 0) try writer.writeAll(",\n");
                try writer.print("  {{\"task_id\": \"{s}\", \"command\": \"{s}\"", .{ task.task_id, task.command });
                if (task.params_json.len > 0) {
                    try writer.print(", \"params\": {s}", .{task.params_json});
                }
                try writer.writeAll("}");
            }
            try writer.writeAll("\n],\n");
            // 清除已下发的任务
            for (info.pending_tasks.items) |*t| t.deinit(self.alloc);
            info.pending_tasks.clearAndFree();
        } else {
            try writer.writeAll("\"tasks\": []\n");
        }

        try writer.writeAll("}\n");
        return buf.toOwnedSlice();
    }

    /// 自动添加 update_binary 任务（版本不匹配时）
    fn addUpdateTask(self: *Controller, node_id_hex: []const u8) !void {
        const info = self.nodes.get(node_id_hex) orelse return;

        const task_id = try std.fmt.allocPrint(self.alloc, "update-{d}", .{time.timestamp()});
        const command = try self.alloc.dupe(u8, "update_binary");
        // 从 binary_path 提取文件名，例如 "wasi-host" 或 "/usr/local/bin/wasi-host"
        const bin_name = std.fs.path.basename(self.binary_path);
        const ip = try getLocalIP(self.alloc, &self.config);
        defer self.alloc.free(ip);
        const params = try std.fmt.allocPrint(self.alloc,
            \\{{"url":"http://{s}:{d}/download/{s}"}}
        , .{ ip, self.config.controller_listen_port, bin_name });

        try info.pending_tasks.append(Task{
            .task_id = task_id,
            .command = command,
            .params_json = params,
        });

        std.debug.print("[controller] 自动下发 update_binary: node={s} ver={s} expected={s}\n", .{ node_id_hex, info.node_version, self.version });
    }

    /// 向指定节点添加待执行任务（API 调用入口）
    pub fn addTask(self: *Controller, node_id_hex: []const u8, command: []const u8) !bool {
        const info = self.nodes.get(node_id_hex) orelse return false;

        const task_id = try std.fmt.allocPrint(self.alloc, "task-{d}-{d}", .{ time.timestamp(), info.pending_tasks.items.len });
        const cmd_copy = try self.alloc.dupe(u8, command);

        try info.pending_tasks.append(Task{
            .task_id = task_id,
            .command = cmd_copy,
            .params_json = "",
        });

        std.debug.print("[controller] 添加任务: node={s} cmd={s}\n", .{ node_id_hex, command });
        return true;
    }

    /// 广播任务到所有已上报节点
    pub fn broadcastTask(self: *Controller, command: []const u8) !usize {
        var count: usize = 0;
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            const node_id_hex = entry.key_ptr.*;
            if (try self.addTask(node_id_hex, command)) {
                count += 1;
            }
        }
        return count;
    }

    /// 获取所有已上报节点 ID 列表
    pub fn getNodeList(self: *Controller) !std.ArrayList([]const u8) {
        var list = std.ArrayList([]const u8).init(self.alloc);
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            try list.append(entry.key_ptr.*);
        }
        return list;
    }

    /// 获取节点信息
    pub fn getNodeInfo(self: *Controller, node_id_hex: []const u8) ?*NodeInfo {
        return self.nodes.get(node_id_hex);
    }

    /// 已上报节点数量
    pub fn nodeCount(self: *Controller) usize {
        return self.nodes.count();
    }
};

/// 获取本机 IP（用于构建 update_binary URL）
/// 优先级: config.controller_host > 自动检测 > 127.0.0.1
pub fn getLocalIP(alloc: std.mem.Allocator, config: *const config_mod.DaemonConfig) ![]u8 {
    // 1. 配置项优先
    if (config.controller_host.len > 0) {
        return try alloc.dupe(u8, config.controller_host);
    }

    // 2. Linux 上自动检测出站 IP
    if (builtin.os.tag == .linux) {
        return detectOutboundIP(alloc) catch try alloc.dupe(u8, "127.0.0.1");
    }

    // 3. 兜底
    return try alloc.dupe(u8, "127.0.0.1");
}

/// 通过连接外部地址检测本机出站 IP（Linux only）
fn detectOutboundIP(alloc: std.mem.Allocator) ![]u8 {
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(sock);

    // 连接到 8.8.8.8:53，内核会选出合适的本地地址
    const remote = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, 53),
        .addr = std.mem.nativeToBig(u32, 0x08080808), // 8.8.8.8
        .zero = .{0} ** 8,
    };
    posix.connect(sock, @ptrCast(&remote), @sizeOf(posix.sockaddr.in)) catch {
        return error.NetworkUnreachable;
    };

    var local_addr: posix.sockaddr.in = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(sock, @ptrCast(&local_addr), &addr_len);

    const ip_bytes = std.mem.asBytes(&local_addr.addr);
    return try std.fmt.allocPrint(alloc, "{d}.{d}.{d}.{d}", .{
        ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3],
    });
}
