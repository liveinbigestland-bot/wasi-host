/// 代理转发（TCP 中继 / WebSocket 双模）
///
/// 架构:
///   TCP 模式:  LAN 节点 --TCP--> ProxyServer --UDP--> 外网 wasi-host
///   WS  模式:  LAN 节点 --WebSocket :80/chord--> index.js --UDP--> 外网 wasi-host
///
/// 通过配置选择传输方式:
///   "proxy.transport": "tcp"      使用 ProxyServer/ProxyClient
///   "proxy.transport": "websocket" 使用 WebSocketClient

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const logging = @import("logging");
const log = logging.log;

fn closeSocket(fd: posix.socket_t) void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ws2_32.closesocket(fd);
    } else {
        posix.close(fd);
    }
}

fn setRecvTimeout(fd: posix.socket_t, timeout_ms: u64) void {
    if (builtin.os.tag == .windows) {
        const ms: u32 = @intCast(@min(timeout_ms, std.math.maxInt(u32)));
        _ = posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(ms)) catch {};
    } else {
        const tv = posix.timeval{
            .sec = @as(isize, @intCast(timeout_ms / 1000)),
            .usec = @as(isize, @intCast((timeout_ms % 1000) * 1000)),
        };
        _ = posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(tv)) catch {};
    }
}

fn readExact(fd: posix.socket_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = posix.read(fd, buf[off..]) catch |err| {
            if (err == error.WouldBlock) return error.Timeout;
            return err;
        };
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}

fn readUntil(fd: posix.socket_t, buf: []u8, delimiter: []const u8) !usize {
    var pos: usize = 0;
    while (pos < buf.len) {
        const n = posix.read(fd, buf[pos..]) catch |err| {
            if (err == error.WouldBlock) return error.Timeout;
            return err;
        };
        if (n == 0) return error.ConnectionClosed;
        pos += n;
        if (std.mem.indexOf(u8, buf[0..pos], delimiter)) |end| {
            return end + delimiter.len;
        }
    }
    return error.ResponseTooLarge;
}

// ── TCP 代理客户端 ─────────────────────────────────────────────

/// TCP 代理客户端：连接远程 ProxyServer，发送数据和接收响应
pub const TcpProxyClient = struct {
    fd: posix.socket_t,

    /// 建立 TCP 连接（DNS 解析 + 直连）
    pub fn init(alloc: std.mem.Allocator, host: []const u8, port: u16) !TcpProxyClient {
        const addr_list = try std.net.getAddressList(alloc, host, port);
        defer addr_list.deinit();

        var last_err: anyerror = error.UnknownHostName;
        var fd: posix.socket_t = undefined;
        var connected = false;

        for (addr_list.addrs) |addr| {
            fd = try posix.socket(addr.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
            errdefer closeSocket(fd);
            if (posix.connect(fd, &addr.any, addr.getOsSockLen())) {
                connected = true;
                break;
            } else |err| {
                last_err = err;
                closeSocket(fd);
            }
        }
        if (!connected) return last_err;
        return TcpProxyClient{ .fd = fd };
    }

    /// 发送数据并等待响应
    /// TCP 帧格式: [payload_len(4) BE][payload]
    pub fn sendViaProxy(self: *TcpProxyClient, data: []const u8, recv_buf: []u8, timeout_ms: u64) !usize {
        setRecvTimeout(self.fd, timeout_ms);

        // 发送 [len(4)][data]
        const be_len = std.mem.nativeToBig(u32, @as(u32, @intCast(data.len)));
        _ = try posix.write(self.fd, std.mem.asBytes(&be_len));
        _ = try posix.write(self.fd, data);

        // 读取响应 [len(4)][data]
        var raw_len: [4]u8 = undefined;
        try readExact(self.fd, &raw_len);
        const resp_len = std.mem.bigToNative(u32, @as(u32, @bitCast(raw_len)));
        if (resp_len > recv_buf.len) return error.MessageTooBig;
        try readExact(self.fd, recv_buf[0..resp_len]);
        return resp_len;
    }

    pub fn deinit(self: *TcpProxyClient) void {
        closeSocket(self.fd);
    }
};

// ── TCP 代理服务器（外网机器运行）───────────────────────────────

/// TCP 代理服务器：TCP 监听 → UDP 转发到本地 wasi-host
pub const TcpProxyServer = struct {
    alloc: std.mem.Allocator,
    udp_target_port: u16,
    listener: std.net.Server,
    running: bool,

    /// 创建 TCP 监听
    pub fn init(alloc: std.mem.Allocator, udp_target_port: u16, listen_port: u16) !TcpProxyServer {
        const local_addr = try std.net.Address.parseIp("0.0.0.0", listen_port);
        const listener = try local_addr.listen(.{ .reuse_port = true });
        return TcpProxyServer{
            .alloc = alloc,
            .udp_target_port = udp_target_port,
            .listener = listener,
            .running = false,
        };
    }

    /// 运行代理服务器（阻塞，在后台线程中调用）
    pub fn run(self: *TcpProxyServer) void {
        self.running = true;
        std.debug.print("[proxy/server] TCP ↔ UDP :{d}\n", .{self.udp_target_port});

        while (self.running) {
            const conn = self.listener.accept() catch |err| {
                if (self.running) {
                    std.debug.print("[proxy/server] accept err: {}\n", .{err});
                }
                continue;
            };
            const thread = std.Thread.spawn(.{}, handleConnection, .{
                self.alloc, conn, self.udp_target_port,
            }) catch |err| {
                std.debug.print("[proxy/server] 线程创建失败: {}\n", .{err});
                conn.stream.close();
                continue;
            };
            thread.detach();
        }
    }

    pub fn deinit(self: *TcpProxyServer) void {
        self.running = false;
        self.listener.deinit();
    }
};

fn handleConnection(_: std.mem.Allocator, conn: std.net.Server.Connection, udp_target_port: u16) void {
    defer conn.stream.close();
    const fd = conn.stream.handle;

    const udp_fd = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP) catch return;
    defer closeSocket(udp_fd);

    const target_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, udp_target_port);
    var buf: [65536]u8 = undefined;
    var resp_buf: [65536]u8 = undefined;

    while (true) {
        // 读帧: [payload_len(4) BE]
        var raw_len: [4]u8 = undefined;
        _ = readExact(fd, &raw_len) catch |err| {
            if (err != error.ConnectionClosed) {
                std.debug.print("[proxy/server] 读帧头 err: {}\n", .{err});
            }
            return;
        };
        const payload_len = std.mem.bigToNative(u32, @as(u32, @bitCast(raw_len)));
        if (payload_len > buf.len) return;

        // 读 payload
        readExact(fd, buf[0..payload_len]) catch return;

        // UDP 转发到本地 wasi-host
        _ = posix.sendto(udp_fd, buf[0..payload_len], 0, &target_addr.any, target_addr.getOsSockLen()) catch return;

        // 读 UDP 响应（带超时）
        setRecvTimeout(udp_fd, 5000);
        var addr: std.net.Address = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        const resp_n = posix.recvfrom(udp_fd, &resp_buf, 0, &addr.any, &addr_len) catch |err| {
            if (err == error.WouldBlock or err == error.Timeout) {
                // 无响应，发空响应
                const be_zero: u32 = 0;
                _ = posix.write(fd, std.mem.asBytes(&be_zero)) catch {};
                continue;
            }
            return;
        };

        // TCP 写回: [resp_len(4) BE][resp]
        const be_resp_len = std.mem.nativeToBig(u32, @as(u32, @intCast(resp_n)));
        _ = posix.write(fd, std.mem.asBytes(&be_resp_len)) catch return;
        _ = posix.write(fd, resp_buf[0..resp_n]) catch return;
    }
}

// ── WebSocket 客户端 ─────────────────────────────────────────────

pub const WebSocketClient = struct {
    fd: posix.socket_t,

    /// 建立 WebSocket 连接（DNS 解析 + TCP + HTTP 升级）
    pub fn connect(alloc: std.mem.Allocator, host: []const u8, port: u16, path: []const u8) !WebSocketClient {
        const addr_list = try std.net.getAddressList(alloc, host, port);
        defer addr_list.deinit();

        var last_err: anyerror = error.UnknownHostName;
        var fd: posix.socket_t = undefined;
        var connected = false;

        for (addr_list.addrs) |addr| {
            fd = try posix.socket(addr.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
            errdefer closeSocket(fd);
            if (posix.connect(fd, &addr.any, addr.getOsSockLen())) {
                connected = true;
                break;
            } else |err| {
                last_err = err;
                closeSocket(fd);
            }
        }
        if (!connected) return last_err;

        // HTTP 升级请求（RFC 6455: key = base64(16随机字节)）
        var key_buf: [16]u8 = undefined;
        std.crypto.random.bytes(&key_buf);
        var b64_buf: [24]u8 = undefined;
        const b64_key = std.base64.standard.Encoder.encode(&b64_buf, &key_buf);

        var req: [512]u8 = undefined;
        const req_slice = try std.fmt.bufPrint(&req,
            "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}:{d}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
            .{ path, host, port, b64_key },
        );

        _ = try posix.write(fd, req_slice);

        // 读取 HTTP 响应头
        var resp: [1024]u8 = undefined;
        const hdr_end = try readUntil(fd, &resp, "\r\n\r\n");

        const status_line = resp[0..std.mem.indexOf(u8, resp[0..hdr_end], "\r\n").?];
        if (std.mem.indexOf(u8, status_line, "101") == null) {
            closeSocket(fd);
            return error.WebSocketHandshakeFailed;
        }

        return WebSocketClient{ .fd = fd };
    }

    /// 发送二进制帧（client→server: 必须掩码）
    pub fn sendFrame(self: *WebSocketClient, data: []const u8) !void {
        var hdr: [10]u8 = undefined;
        var hdr_len: usize = 0;

        hdr[0] = 0x82; // FIN=1, opcode=0x2 (binary)
        if (data.len < 126) {
            hdr[1] = 0x80 | @as(u8, @intCast(data.len));
            hdr_len = 2;
        } else if (data.len < 65536) {
            hdr[1] = 0x80 | 126;
            const be_len = std.mem.nativeToBig(u16, @as(u16, @intCast(data.len)));
            @memcpy(hdr[2..4], std.mem.asBytes(&be_len));
            hdr_len = 4;
        } else {
            hdr[1] = 0x80 | 127;
            const be_len = std.mem.nativeToBig(u64, @as(u64, @intCast(data.len)));
            @memcpy(hdr[2..10], std.mem.asBytes(&be_len));
            hdr_len = 10;
        }

        _ = try posix.write(self.fd, hdr[0..hdr_len]);

        // 掩码
        var mask: [4]u8 = undefined;
        std.crypto.random.bytes(&mask);
        _ = try posix.write(self.fd, &mask);

        var masked_buf: [4096]u8 = undefined;
        var off: usize = 0;
        while (off < data.len) {
            const chunk_len = @min(data.len - off, masked_buf.len);
            for (masked_buf[0..chunk_len], 0..) |*b, i| {
                b.* = data[off + i] ^ mask[(off + i) % 4];
            }
            _ = try posix.write(self.fd, masked_buf[0..chunk_len]);
            off += chunk_len;
        }
    }

    /// 接收二进制帧（server→client: 无掩码）
    pub fn recvFrame(self: *WebSocketClient, buf: []u8) !usize {
        var first: [2]u8 = undefined;
        try readExact(self.fd, &first);

        const opcode = first[0] & 0x0F;
        const masked = (first[1] & 0x80) != 0;
        var payload_len = @as(usize, first[1] & 0x7F);

        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try readExact(self.fd, &ext);
            payload_len = std.mem.bigToNative(u16, @as(u16, @bitCast(ext)));
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try readExact(self.fd, &ext);
            payload_len = @as(usize, @intCast(std.mem.bigToNative(u64, @as(u64, @bitCast(ext)))));
        }

        if (payload_len > buf.len) return error.MessageTooBig;

        // Ping 帧
        if (opcode == 0x9) {
            var ping: [125]u8 = undefined;
            const n = @min(payload_len, ping.len);
            try readExact(self.fd, ping[0..n]);
            _ = posix.write(self.fd, &[_]u8{ 0x8A, @as(u8, @intCast(n)) }) catch {};
            _ = posix.write(self.fd, ping[0..n]) catch {};
            return self.recvFrame(buf);
        }

        // Close 帧
        if (opcode == 0x8) return error.ConnectionClosed;

        // 只处理 Binary/Text 帧
        if (opcode != 0x2 and opcode != 0x1) {
            if (payload_len > 0) {
                var skip: [4096]u8 = undefined;
                var remaining = payload_len;
                while (remaining > 0) {
                    const n = @min(remaining, skip.len);
                    try readExact(self.fd, skip[0..n]);
                    remaining -= n;
                }
            }
            return self.recvFrame(buf);
        }

        if (masked) {
            var mk: [4]u8 = undefined;
            try readExact(self.fd, &mk);
            try readExact(self.fd, buf[0..payload_len]);
            for (buf[0..payload_len], 0..) |*b, i| {
                b.* ^= mk[i % 4];
            }
        } else {
            try readExact(self.fd, buf[0..payload_len]);
        }

        return payload_len;
    }

    pub fn deinit(self: *WebSocketClient) void {
        _ = posix.write(self.fd, &[_]u8{ 0x88, 0x80, 0, 0, 0, 0 }) catch {};
        closeSocket(self.fd);
    }
};

// ── WebSocket 传输函数 ─────────────────────────────────────────

/// 通过 WebSocket 发送数据并等待响应（每次调用创建新连接）
///
/// WebSocket 帧格式: [target_ip(4) BE][target_port(2) BE][payload]
/// index.js 解析此头后通过 UDP 转发 payload 到 target_ip:target_port
pub fn sendViaWS(alloc: std.mem.Allocator, host: []const u8, port: u16, path: []const u8, target_ip_be: u32, target_port: u16, data: []const u8, recv_buf: []u8, timeout_ms: u64) !usize {
    var ws = try WebSocketClient.connect(alloc, host, port, path);
    defer ws.deinit();
    setRecvTimeout(ws.fd, timeout_ms);

    // 构建 WebSocket 帧: [target_ip(4) BE][target_port(2) BE][data]
    const header_len = 6;
    var frame = try alloc.alloc(u8, header_len + data.len);
    defer alloc.free(frame);

    @memcpy(frame[0..4], std.mem.asBytes(&target_ip_be));
    const be_port = std.mem.nativeToBig(u16, target_port);
    @memcpy(frame[4..6], std.mem.asBytes(&be_port));
    @memcpy(frame[6..], data);

    try ws.sendFrame(frame);
    return ws.recvFrame(recv_buf);
}

/// Reader 线程：持久 WebSocket，全双工（WS ↔ UDP）
/// 发送注册帧后循环：接收 WS → 转 UDP → 等待响应 → 回写 WS
pub fn runWSReader(alloc: std.mem.Allocator, host: []const u8, port: u16, path: []const u8, own_udp_port: u16, listen_host: []const u8, listen_port: u16) void {
    while (true) {
        var ws = WebSocketClient.connect(alloc, host, port, path) catch |err| {
            std.debug.print("[proxy/reader] WS 连接失败: {}, 5s 后重试\n", .{err});
            std.time.sleep(5 * std.time.ns_per_s);
            continue;
        };
        defer ws.deinit();

        // 发送注册帧: [0,0,0,0, 0,0] + "listen_host:listen_port"
        {
            const reg_addr = std.fmt.allocPrint(alloc, "{s}:{d}", .{ listen_host, listen_port }) catch {
                std.debug.print("[proxy/reader] 注册地址格式化失败\n", .{});
                std.time.sleep(5 * std.time.ns_per_s);
                continue;
            };
            defer alloc.free(reg_addr);
            var reg_frame = alloc.alloc(u8, 6 + reg_addr.len) catch {
                std.time.sleep(5 * std.time.ns_per_s);
                continue;
            };
            defer alloc.free(reg_frame);
            @memset(reg_frame[0..6], 0); // target_ip = 0.0.0.0:0 → 注册标记
            @memcpy(reg_frame[6..], reg_addr);
            ws.sendFrame(reg_frame) catch |err| {
                std.debug.print("[proxy/reader] 注册帧发送失败: {}, 重连\n", .{err});
                std.time.sleep(1 * std.time.ns_per_s);
                continue;
            };
        }

        const udp_fd = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP) catch |err| {
            std.debug.print("[proxy/reader] UDP socket 创建失败: {}\n", .{err});
            return;
        };
        defer closeSocket(udp_fd);

        // 绑定 UDP socket 以接收响应
        const bind_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        posix.bind(udp_fd, &bind_addr.any, bind_addr.getOsSockLen()) catch |err| {
            std.debug.print("[proxy/reader] UDP bind 失败: {}\n", .{err});
            return;
        };

        const target_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, own_udp_port);
        var buf: [65536]u8 = undefined;
        var resp_buf: [65536]u8 = undefined;

        std.debug.print("[proxy/reader] 全双工 | WS ↔ UDP :{d} (node={s}:{d})\n", .{ own_udp_port, listen_host, listen_port });

        while (true) {
            // 1. 读取 WS 帧（来自 index.js 的转发消息）
            const n = ws.recvFrame(&buf) catch |err| {
                if (err == error.Timeout) continue;
                std.debug.print("[proxy/reader] 接收错误: {}, 重连中...\n", .{err});
                break;
            };

            // 2. 转发到本地 wasi-host
            _ = posix.sendto(udp_fd, buf[0..n], 0, &target_addr.any, @sizeOf(posix.sockaddr.in)) catch |err| {
                std.debug.print("[proxy/reader] UDP 转发错误: {}\n", .{err});
                continue;
            };

            // 3. 等待 wasi-host 响应（超时 5s）
            setRecvTimeout(udp_fd, 5000);
            var resp_addr: std.net.Address = undefined;
            var resp_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            const resp_n = posix.recvfrom(udp_fd, &resp_buf, 0, &resp_addr.any, &resp_addr_len) catch |err| {
                if (err == error.WouldBlock or err == error.Timeout) {
                    // 无响应（如 notify 等单向消息）— 继续读取下一帧
                    continue;
                }
                std.debug.print("[proxy/reader] UDP recv 错误: {}\n", .{err});
                break;
            };

            // 4. 将响应通过 WS 发回 index.js
            ws.sendFrame(resp_buf[0..resp_n]) catch |err| {
                std.debug.print("[proxy/reader] WS 响应发送失败: {}\n", .{err});
                break;
            };
        }
    }
}

// ── 统一发送函数（根据传输方式选择）──────────────────────────────

/// 根据传输方式选择 TCP 或 WebSocket 发送，并等待响应
pub fn sendViaProxy(
    alloc: std.mem.Allocator,
    transport: []const u8,
    remote_host: []const u8,
    remote_port: u16,
    remote_path: []const u8,
    target_ip_be: u32,
    target_port: u16,
    data: []const u8,
    recv_buf: []u8,
    timeout_ms: u64,
) !usize {
    if (std.mem.eql(u8, transport, "tcp")) {
        var pc = try TcpProxyClient.init(alloc, remote_host, remote_port);
        defer pc.deinit();
        return pc.sendViaProxy(data, recv_buf, timeout_ms);
    } else {
        return sendViaWS(alloc, remote_host, remote_port, remote_path, target_ip_be, target_port, data, recv_buf, timeout_ms);
    }
}

test "web socket basic handshake" {
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const expected = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";

    var hasher = std.crypto.hash.Sha1.init();
    hasher.update(key);
    hasher.update("258EAFA5-E914-47DA-95CA-5AB9DC11B85B");
    var digest: [20]u8 = undefined;
    hasher.final(&digest);

    var accept_buf: [28]u8 = undefined;
    const accept = std.base64.standard.Encoder.encode(&accept_buf, &digest);
    try std.testing.expectEqualStrings(expected, accept);
}
