/// Web 管理 API — REST API + HTML 仪表盘
///
/// 在主节点（controller_enable=true）上提供 HTTP 接口：
///   GET  /api/nodes          节点列表
///   GET  /api/node/<hex-id>  单节点详情
///   GET  /api/stats          集群统计
///   GET  /api/health         控制节点健康
///   POST /api/task/<hex-id>  下发任务
///   POST /api/broadcast      广播任务
///   GET  /                   简易仪表盘
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const time = std.time;

const config_mod = @import("config.zig");
const controller_mod = @import("controller.zig");
const dht = @import("dht_types.zig");

/// Web 服务器可访问的后端
pub const Backend = struct {
    controller: *controller_mod.Controller,
    config: *const config_mod.DaemonConfig,
    version: []const u8,
};

/// Web API 服务器
pub const WebServer = struct {
    alloc: std.mem.Allocator,
    sock_fd: i32 = -1,
    backend: Backend,
    running: bool = false,

    pub fn init(alloc: std.mem.Allocator, backend: Backend) WebServer {
        return WebServer{ .alloc = alloc, .backend = backend };
    }

    pub fn start(self: *WebServer) !void {
        if (builtin.os.tag != .linux) return error.NotSupported;

        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        self.sock_fd = @intCast(fd);

        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(i32, 1))) catch {};
        _ = posix.fcntl(fd, posix.F.SETFD, posix.FD_CLOEXEC) catch 0;

        // 非阻塞 accept
        const cur_flags = try posix.fcntl(fd, posix.F.GETFL, @as(usize, 0));
        const nonblock_flag: u32 = @as(u32, @bitCast(std.os.linux.O{ .NONBLOCK = true }));
        _ = try posix.fcntl(fd, posix.F.SETFL, @as(usize, @intCast(cur_flags | nonblock_flag)));

        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, self.backend.config.web_api_port),
            .addr = std.mem.nativeToBig(u32, 0), // 0.0.0.0
            .zero = .{0} ** 8,
        };

        try posix.bind(fd, @as(*const posix.sockaddr, @ptrCast(&addr)), @sizeOf(posix.sockaddr.in));
        try posix.listen(fd, 10);

        self.running = true;
        std.debug.print("[web] HTTP 服务器启动: 端口 {d}\n", .{self.backend.config.web_api_port});
    }

    pub fn stop(self: *WebServer) void {
        self.running = false;
        if (builtin.os.tag == .linux and self.sock_fd >= 0) {
            posix.close(self.sock_fd);
            self.sock_fd = -1;
        }
    }

    /// 非阻塞 accept 并处理一个 HTTP 请求
    pub fn acceptAndHandle(self: *WebServer) void {
        if (!self.running) return;
        if (builtin.os.tag != .linux) return;

        var client_addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const client_fd = posix.accept(self.sock_fd, &client_addr, &addr_len, 0) catch |err| {
            if (err == error.WouldBlock) return;
            return;
        };
        defer posix.close(client_fd);

        // 5s 接收超时
        const tv = posix.timeval{ .sec = 5, .usec = 0 };
        posix.setsockopt(client_fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(tv)) catch {};

        // 读取请求
        var buf: [8192]u8 = undefined;
        const n = posix.read(client_fd, &buf) catch |err| {
            if (err == error.WouldBlock) return;
            return;
        };
        if (n < 4) return;

        const request = buf[0..n];

        // 解析请求行 "METHOD /path HTTP/1.1"
        const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse return;
        const first_line = request[0..first_line_end];

        const method_end = std.mem.indexOfScalar(u8, first_line, ' ') orelse return;
        const method = first_line[0..method_end];
        const after_method = first_line[method_end + 1 ..];
        const path_end = std.mem.indexOfScalar(u8, after_method, ' ') orelse return;
        const path = after_method[0..path_end];

        // 构建响应
        var response = std.ArrayList(u8).init(self.alloc);
        defer response.deinit();

        self.route(method, path, request, &response) catch {
            response.clearAndFree();
            buildJsonError(&response, 500, "internal error") catch {};
            // wrap in HTTP 500
            var wrapped = std.ArrayList(u8).init(self.alloc);
            defer wrapped.deinit();
            buildHttpResponse(&wrapped, 500, "application/json", response.items) catch {};
            _ = posix.write(client_fd, wrapped.items) catch {};
            return;
        };

        _ = posix.write(client_fd, response.items) catch {};
    }

    fn route(self: *WebServer, method: []const u8, path: []const u8, request: []const u8, response: *std.ArrayList(u8)) !void {
        // GET / → HTML 仪表盘
        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/")) {
            return self.handleIndex(response);
        }
        // GET /api/nodes → 节点列表
        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/nodes")) {
            return self.handleApiNodes(response);
        }
        // GET /api/node/<hex-id> → 单节点详情
        if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, "/api/node/")) {
            const node_id = path["/api/node/".len..];
            if (node_id.len == 0) return self.send404(response);
            return self.handleApiNode(response, node_id);
        }
        // GET /api/stats → 集群统计
        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/stats")) {
            return self.handleApiStats(response);
        }
        // GET /api/health → 控制节点健康
        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/health")) {
            return self.handleApiHealth(response);
        }
        // POST /api/task/<hex-id> → 下发任务
        if (std.mem.eql(u8, method, "POST") and std.mem.startsWith(u8, path, "/api/task/")) {
            const node_id = path["/api/task/".len..];
            if (node_id.len == 0) return self.send404(response);
            return self.handleApiTask(response, request, node_id);
        }
        // POST /api/broadcast → 广播任务
        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/broadcast")) {
            return self.handleApiBroadcast(response, request);
        }
        return self.send404(response);
    }

    // ─── HTML 仪表盘 ──────────────────────────────────────────

    fn handleIndex(self: *WebServer, response: *std.ArrayList(u8)) !void {
        _ = self;
        const html = indexHtml();
        try buildHttpResponse(response, 200, "text/html; charset=utf-8", html);
    }

    // ─── GET /api/nodes ───────────────────────────────────────

    fn handleApiNodes(self: *WebServer, response: *std.ArrayList(u8)) !void {
        var buf = std.ArrayList(u8).init(self.alloc);
        defer buf.deinit();
        var w = buf.writer();

        try w.writeAll("{\n\"nodes\": [\n");
        var list = try self.backend.controller.getNodeList();
        defer list.deinit();

        for (list.items, 0..) |node_id_hex, i| {
            if (i > 0) try w.writeAll(",\n");
            const info = self.backend.controller.getNodeInfo(node_id_hex) orelse continue;
            try w.print("  {{\"id\": \"{s}\", \"last_seen\": {d}, \"reports\": {d}, \"version\": \"{s}\"}}", .{
                node_id_hex, info.last_seen, info.report_count, info.node_version,
            });
        }
        try w.writeAll("\n],\n");
        try w.print("\"count\": {d}\n", .{self.backend.controller.nodeCount()});
        try w.writeAll("}\n");

        try buildJsonResponse(response, buf.items);
    }

    // ─── GET /api/node/<id> ───────────────────────────────────

    fn handleApiNode(self: *WebServer, response: *std.ArrayList(u8), node_id: []const u8) !void {
        const info = self.backend.controller.getNodeInfo(node_id) orelse {
            var buf = std.ArrayList(u8).init(self.alloc);
            defer buf.deinit();
            try buf.writer().print("{{\"error\": \"node not found\", \"id\": \"{s}\"}}", .{node_id});
            try buildJsonResponse(response, buf.items);
            return;
        };

        var buf = std.ArrayList(u8).init(self.alloc);
        defer buf.deinit();
        var w = buf.writer();

        try w.writeAll("{\n");
        try w.print("\"id\": \"{s}\",\n", .{info.node_id_hex});
        try w.print("\"last_seen\": {d},\n", .{info.last_seen});
        try w.print("\"reports\": {d},\n", .{info.report_count});
        try w.print("\"node_version\": \"{s}\",\n", .{info.node_version});
        try w.print("\"daemon_version\": \"{s}\",\n", .{info.daemon_version});
        try w.print("\"pending_tasks\": {d},\n", .{info.pending_tasks.items.len});

        // 解析最近上报的 JSON 以提取关键字段
        if (info.last_report_raw.len > 0) {
            const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, info.last_report_raw, .{ .ignore_unknown_fields = true }) catch {
                try w.writeAll("\"last_report\": {}\n");
                try w.writeAll("}\n");
                try buildJsonResponse(response, buf.items);
                return;
            };
            defer parsed.deinit();
            const root = parsed.value;

            // ring_position
            if (root.object.get("ring_position")) |rp| {
                try w.writeAll("\"ring_position\": ");
                try std.json.stringify(rp, .{}, w);
                try w.writeAll(",\n");
            }
            // health
            if (root.object.get("health")) |h| {
                try w.writeAll("\"health\": ");
                try std.json.stringify(h, .{}, w);
                try w.writeAll(",\n");
            }
            // resources
            if (root.object.get("resources")) |r| {
                try w.writeAll("\"resources\": ");
                try std.json.stringify(r, .{}, w);
                try w.writeAll(",\n");
            }
        }

        try w.writeAll("\"_end\": true\n");
        try w.writeAll("}\n");

        try buildJsonResponse(response, buf.items);
    }

    // ─── GET /api/stats ───────────────────────────────────────

    fn handleApiStats(self: *WebServer, response: *std.ArrayList(u8)) !void {
        const ctrl = self.backend.controller;
        const now = time.timestamp();
        _ = now;

        var buf = std.ArrayList(u8).init(self.alloc);
        defer buf.deinit();
        var w = buf.writer();

        try w.writeAll("{\n");
        try w.print("\"total_nodes\": {d},\n", .{ctrl.nodeCount()});

        // 统计版本分布和在线状态
        var version_counts = std.StringHashMap(u32).init(self.alloc);
        defer {
            var it = version_counts.iterator();
            while (it.next()) |entry| {
                self.alloc.free(entry.key_ptr.*);
            }
            version_counts.deinit();
        }

        var list = try ctrl.getNodeList();
        defer list.deinit();

        for (list.items) |node_id| {
            const info = ctrl.getNodeInfo(node_id) orelse continue;
            if (info.node_version.len > 0) {
                const gop = try version_counts.getOrPut(try self.alloc.dupe(u8, info.node_version));
                if (gop.found_existing) {
                    gop.value_ptr.* += 1;
                } else {
                    gop.value_ptr.* = 1;
                }
            }
        }

        try w.writeAll("\"versions\": {\n");
        var first_ver = true;
        var ver_it = version_counts.iterator();
        while (ver_it.next()) |entry| {
            if (!first_ver) try w.writeAll(",\n");
            first_ver = false;
            try w.print("  \"{s}\": {d}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try w.writeAll("\n},\n");

        try w.print("\"controller_version\": \"{s}\"\n", .{self.backend.version});
        try w.writeAll("}\n");

        try buildJsonResponse(response, buf.items);
    }

    // ─── GET /api/health ──────────────────────────────────────

    fn handleApiHealth(self: *WebServer, response: *std.ArrayList(u8)) !void {
        var buf = std.ArrayList(u8).init(self.alloc);
        defer buf.deinit();
        var w = buf.writer();

        try w.writeAll("{\n");
        try w.print("\"status\": \"ok\",\n");
        try w.print("\"node_count\": {d},\n", .{self.backend.controller.nodeCount()});
        try w.print("\"version\": \"{s}\",\n", .{self.backend.version});
        try w.print("\"uptime\": {d}\n", .{time.timestamp()});
        try w.writeAll("}\n");

        try buildJsonResponse(response, buf.items);
    }

    // ─── POST /api/task/<id> ──────────────────────────────────

    fn handleApiTask(self: *WebServer, response: *std.ArrayList(u8), request: []const u8, node_id: []const u8) !void {
        // 解析请求体获取 command
        const command = try extractPostCommand(self.alloc, request);
        defer self.alloc.free(command);

        const ok = try self.backend.controller.addTask(node_id, command);

        var buf = std.ArrayList(u8).init(self.alloc);
        defer buf.deinit();
        var w = buf.writer();

        if (ok) {
            try w.writeAll("{\"status\": \"ok\", \"message\": \"task queued\"}\n");
        } else {
            try w.print("{{\"status\": \"error\", \"message\": \"node not found: {s}\"}}\n", .{node_id});
        }

        try buildJsonResponse(response, buf.items);
    }

    // ─── POST /api/broadcast ──────────────────────────────────

    fn handleApiBroadcast(self: *WebServer, response: *std.ArrayList(u8), request: []const u8) !void {
        const command = try extractPostCommand(self.alloc, request);
        defer self.alloc.free(command);

        const count = try self.backend.controller.broadcastTask(command);

        var buf = std.ArrayList(u8).init(self.alloc);
        defer buf.deinit();
        try buf.writer().print("{{\"status\": \"ok\", \"nodes\": {d}}}\n", .{count});

        try buildJsonResponse(response, buf.items);
    }

    // ─── 404 ──────────────────────────────────────────────────

    fn send404(self: *WebServer, response: *std.ArrayList(u8)) !void {
        _ = self;
        const body = "{\"error\": \"not found\"}\n";
        try buildHttpResponse(response, 404, "application/json", body);
    }
};

// ═══════════════════════════════════════════════════════════════
// HTTP 工具函数
// ═══════════════════════════════════════════════════════════════

/// 构建 HTTP 响应（含状态行 + 头部）
fn buildHttpResponse(buf: *std.ArrayList(u8), status: u16, content_type: []const u8, body: []const u8) !void {
    const status_text = if (status == 200) "OK" else if (status == 404) "Not Found" else "Internal Server Error";
    try buf.writer().print("HTTP/1.1 {d} {s}\r\n", .{ status, status_text });
    try buf.writer().print("Content-Type: {s}\r\n", .{content_type});
    try buf.writer().print("Content-Length: {d}\r\n", .{body.len});
    try buf.writer().print("Connection: close\r\n", .{});
    try buf.writer().writeAll("Access-Control-Allow-Origin: *\r\n");
    try buf.writer().writeAll("\r\n");
    try buf.writer().writeAll(body);
}

/// 构建 JSON 响应（200 OK）
fn buildJsonResponse(buf: *std.ArrayList(u8), json_body: []const u8) !void {
    try buildHttpResponse(buf, 200, "application/json", json_body);
}

/// 构建 JSON 错误响应
fn buildJsonError(buf: *std.ArrayList(u8), status: u16, message: []const u8) !void {
    var body = std.ArrayList(u8).init(buf.allocator);
    defer body.deinit();
    try body.writer().print("{{\"error\": \"{s}\", \"status\": {d}}}\n", .{ message, status });
    try buildHttpResponse(buf, status, "application/json", body.items);
}

/// 从 HTTP 请求中提取 POST body 的 "command" 字段
fn extractPostCommand(alloc: std.mem.Allocator, request: []const u8) ![]u8 {
    const header_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return error.MissingBody;
    const body_start = header_end + 4;
    if (body_start >= request.len) return error.MissingBody;
    const body = request[body_start..];

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = parsed.value;
    const command_val = root.object.get("command") orelse return error.MissingCommand;
    const command = switch (command_val) {
        .string => |s| s,
        else => return error.InvalidCommand,
    };
    return try alloc.dupe(u8, command);
}

/// 嵌入式 HTML 仪表盘
fn indexHtml() []const u8 {
    return @embedFile("web_dashboard.html");
}
