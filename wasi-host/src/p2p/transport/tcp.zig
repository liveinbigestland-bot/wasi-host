/// TCP 传输层
/// 提供 TCP 客户端（sendAndWait）和服务器（acceptLoop）功能
/// 使用长度前缀帧格式: [payload_len: u32 BE][payload]
const std = @import("std");
const posix = std.posix;

pub const BUF_SIZE = 65536;

/// TCP 连接封装
pub const TcpConnection = struct {
    stream: std.net.Stream,
    address: std.net.Address,

    pub fn read(self: *TcpConnection, buf: []u8) !usize {
        return self.stream.read(buf);
    }

    pub fn write(self: *TcpConnection, data: []const u8) !usize {
        return self.stream.write(data);
    }

    pub fn close(self: *TcpConnection) void {
        self.stream.close();
    }
};

/// TCP 监听器
pub const TcpListener = struct {
    server: std.net.Server,

    pub fn listen(addr: std.net.Address) !TcpListener {
        const server = try addr.listen(.{
            .reuse_port = true,
            .reuse_address = true,
        });
        return TcpListener{ .server = server };
    }

    pub fn accept(self: *TcpListener) !TcpConnection {
        const conn = try self.server.accept();
        return TcpConnection{
            .stream = conn.stream,
            .address = conn.address,
        };
    }

    pub fn localPort(self: TcpListener) u16 {
        return self.server.listen_address.getPort();
    }

    pub fn deinit(self: *TcpListener) void {
        self.server.deinit();
    }
};

/// 主动连接远程节点
pub fn connect(host: []const u8, port: u16) !TcpConnection {
    const addr = try std.net.Address.parseIp(host, port);
    const stream = try std.net.tcpConnectToAddress(addr);
    return TcpConnection{ .stream = stream, .address = addr };
}

// ════════════════════════════════════════════════════════════════
//  Chord TCP 传输层
// ════════════════════════════════════════════════════════════════

/// TCP 传输 (Chord 用)
pub const TcpTransport = struct {
    listener: std.net.Server,
    port: u16,
    running: bool,

    pub fn init(port: u16) !TcpTransport {
        return initBind("0.0.0.0", port);
    }

    pub fn initBind(host: []const u8, port: u16) !TcpTransport {
        const addr = try std.net.Address.parseIp(host, port);
        const server = try addr.listen(.{
            .reuse_address = true,
            .reuse_port = true,
            .kernel_backlog = 16,
        });
        const actual_port = server.listen_address.getPort();
        std.debug.print("[tcp] TCP 监听 {s}:{d}\n", .{ host, actual_port });
        return TcpTransport{
            .listener = server,
            .port = actual_port,
            .running = true,
        };
    }

    pub fn deinit(self: *TcpTransport) void {
        self.running = false;
        self.listener.deinit();
    }

    /// TCP 发送消息并等待响应（新建连接 → 发帧 → 读响应 → 关闭）
    pub fn sendAndWait(host: []const u8, port: u16, data: []const u8, buf: []u8, timeout_ms: u64) !usize {
        const target = try std.net.Address.parseIp(host, port);
        const stream = try std.net.tcpConnectToAddress(target);
        defer stream.close();

        // 设置接收超时
        const tv = posix.timeval{
            .sec = @as(c_long, @intCast(timeout_ms / 1000)),
            .usec = @as(c_long, @intCast((timeout_ms % 1000) * 1000)),
        };
        posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(tv)) catch {};

        // 发送长度前缀帧: [4BE 长度][payload]
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(data.len), .big);
        try stream.writeAll(&header);
        try stream.writeAll(data);

        // 读取响应长度头
        const n = try stream.readAll(buf[0..4]);
        if (n < 4) return error.ConnectionReset;
        const resp_len = std.mem.readInt(u32, buf[0..4], .big);
        if (resp_len > buf.len) return error.MessageTooLarge;

        // 读取响应 payload
        const m = try stream.readAll(buf[0..resp_len]);
        if (m < resp_len) return error.ConnectionReset;
        return resp_len;
    }

    /// Accept 循环：接收 TCP 连接 → 帧解码 → UDP 注入本地 Chord → TCP 回复
    pub fn acceptLoop(self: *TcpTransport, udp_port: u16) void {
        std.debug.print("[tcp] accept 循环启动, UDP 目标 127.0.0.1:{d}\n", .{udp_port});
        while (self.running) {
            const conn = self.listener.accept() catch |err| {
                if (!self.running) break;
                std.debug.print("[tcp] accept 错误: {}\n", .{err});
                continue;
            };
            std.debug.print("[tcp] 接受连接: {}\n", .{conn.address});
            self.handleConnection(conn, udp_port);
            std.debug.print("[tcp] 连接处理完成: {}\n", .{conn.address});
        }
    }

    fn handleConnection(self: *TcpTransport, conn: std.net.Server.Connection, udp_port: u16) void {
        _ = self;
        var buf: [BUF_SIZE]u8 = undefined;
        defer conn.stream.close();

        // ── 1. 读取帧长度 ──
        const n = conn.stream.readAll(buf[0..4]) catch |err| {
            if (err != error.ConnectionReset and err != error.EndOfStream) {
                std.debug.print("[tcp] 读长度失败: {}\n", .{err});
            }
            return;
        };
        if (n < 4) return;
        const msg_len = std.mem.readInt(u32, buf[0..4], .big);
        if (msg_len > BUF_SIZE) {
            std.debug.print("[tcp] 消息过大: {d} > {d}\n", .{ msg_len, BUF_SIZE });
            return;
        }

        // ── 2. 读取消息 payload ──
        const m = conn.stream.readAll(buf[0..msg_len]) catch |err| {
            std.debug.print("[tcp] 读消息失败: {}\n", .{err});
            return;
        };
        if (m < msg_len) return;

        // ── 3. 通过 UDP 注入本地 Chord ──
        const udp_fd = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP) catch return;
        defer posix.close(udp_fd);

        // 连接到 127.0.0.1:udp_port
        var target = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, udp_port),
            .addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
            .zero = .{0} ** 8,
        };
        posix.connect(udp_fd, @as(*const posix.sockaddr, @ptrCast(&target)), @sizeOf(posix.sockaddr.in)) catch |err| {
            std.debug.print("[tcp] UDP connect 127.0.0.1:{d} 失败: {}\n", .{ udp_port, err });
            return;
        };

        // 注入消息到本地 Chord
        _ = posix.send(udp_fd, buf[0..msg_len], 0) catch |err| {
            std.debug.print("[tcp] UDP 注入失败: {}\n", .{err});
            return;
        };

        // ── 4. 等待 Chord 回复（5秒超时） ──
        var recv_buf: [BUF_SIZE]u8 = undefined;
        var resp_len: usize = 0;

        // 设置 UDP 接收超时
        const recv_tv = posix.timeval{
            .sec = @as(c_long, @intCast(5)),
            .usec = 0,
        };
        posix.setsockopt(udp_fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(recv_tv)) catch {};

        const r = posix.recv(udp_fd, &recv_buf, 0) catch |err| {
            if (err == error.WouldBlock) {
                std.debug.print("[tcp] UDP 回复超时\n", .{});
            } else {
                std.debug.print("[tcp] UDP 接收错误: {}\n", .{err});
            }
            return;
        };
        resp_len = r;

        // ── 5. TCP 回复: [4BE 响应长度][响应] ──
        var resp_header: [4]u8 = undefined;
        std.mem.writeInt(u32, &resp_header, @intCast(resp_len), .big);
        conn.stream.writeAll(&resp_header) catch return;
        conn.stream.writeAll(recv_buf[0..resp_len]) catch |err| {
            std.debug.print("[tcp] TCP 回复失败: {}\n", .{err});
        };
    }
};
