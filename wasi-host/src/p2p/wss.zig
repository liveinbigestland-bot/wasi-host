/// WebSocket Secure 服务�?�?原生 WS/WSS 端点
///
/// 架构:
///   Client --wss://host/path--> WssServer --UDP--> ChordNode(:udp_port)
///
/// 支持的传�?
///   - WSS: TLS (OpenSSL) + WebSocket (Linux only)
///   - WS:  �?WebSocket (�?TLS, 跨平�?

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const logging = @import("logging");
const log = logging.log;

const build_options = @import("build_options");

pub const tls_supported = build_options.wss_tls_enabled;

// ── TLS 实现（Linux 使用 OpenSSL, 其他平台 stub）─────────────────

const tls_impl = if (tls_supported) struct {
    const SslCtx = opaque {};
    const Ssl = opaque {};

    extern fn SSL_library_init() c_int;
    extern fn SSL_load_error_strings() void;
    extern fn SSL_CTX_new(method: ?*const anyopaque) ?*SslCtx;
    extern fn SSL_CTX_free(ctx: ?*SslCtx) void;
    extern fn SSL_CTX_use_certificate_file(ctx: ?*SslCtx, file: [*:0]const u8, typ: c_int) c_int;
    extern fn SSL_CTX_use_PrivateKey_file(ctx: ?*SslCtx, file: [*:0]const u8, typ: c_int) c_int;
    extern fn SSL_CTX_check_private_key(ctx: ?*SslCtx) c_int;
    extern fn TLS_server_method() ?*const anyopaque;
    extern fn SSL_new(ctx: ?*SslCtx) ?*Ssl;
    extern fn SSL_free(ssl: ?*Ssl) void;
    extern fn SSL_set_fd(ssl: ?*Ssl, fd: c_int) c_int;
    extern fn SSL_accept(ssl: ?*Ssl) c_int;
    extern fn SSL_read(ssl: ?*Ssl, buf: [*]u8, num: c_int) c_int;
    extern fn SSL_write(ssl: ?*Ssl, buf: [*]const u8, num: c_int) c_int;
    extern fn SSL_shutdown(ssl: ?*Ssl) c_int;

    const SSL_FILETYPE_PEM = 1;

    pub fn initLibrary() void {
        SSL_library_init();
        SSL_load_error_strings();
    }

    pub fn createCtx(cert_path: [:0]const u8, key_path: [:0]const u8) !*anyopaque {
        const method = TLS_server_method() orelse return error.TlsInitFailed;
        const ctx = SSL_CTX_new(method) orelse return error.TlsInitFailed;
        errdefer SSL_CTX_free(ctx);

        if (SSL_CTX_use_certificate_file(ctx, cert_path.ptr, SSL_FILETYPE_PEM) <= 0)
            return error.TlsCertFailed;
        if (SSL_CTX_use_PrivateKey_file(ctx, key_path.ptr, SSL_FILETYPE_PEM) <= 0)
            return error.TlsKeyFailed;
        if (SSL_CTX_check_private_key(ctx) <= 0)
            return error.TlsKeyMismatch;

        return @ptrCast(ctx);
    }

    pub fn sslNew(ctx: *anyopaque, fd: posix.socket_t) !*anyopaque {
        const real_ctx: *SslCtx = @ptrCast(@alignCast(ctx));
        const ssl = SSL_new(real_ctx) orelse return error.TlsInitFailed;
        SSL_set_fd(ssl, fd);
        if (SSL_accept(ssl) <= 0) {
            SSL_free(ssl);
            return error.TlsAcceptFailed;
        }
        return @ptrCast(ssl);
    }

    pub fn sslRead(ssl: *anyopaque, buf: []u8) !usize {
        const real_ssl: *Ssl = @ptrCast(@alignCast(ssl));
        const n = SSL_read(real_ssl, buf.ptr, @intCast(buf.len));
        if (n <= 0) return error.ConnectionClosed;
        return @intCast(n);
    }

    pub fn sslWrite(ssl: *anyopaque, data: []const u8) !usize {
        const real_ssl: *Ssl = @ptrCast(@alignCast(ssl));
        const n = SSL_write(real_ssl, data.ptr, @intCast(data.len));
        if (n <= 0) return error.ConnectionClosed;
        return @intCast(n);
    }

    pub fn sslFree(ssl: *anyopaque) void {
        const real_ssl: *Ssl = @ptrCast(@alignCast(ssl));
        SSL_shutdown(real_ssl);
        SSL_free(real_ssl);
    }

    pub fn ctxFree(ctx: *anyopaque) void {
        const real_ctx: *SslCtx = @ptrCast(@alignCast(ctx));
        SSL_CTX_free(real_ctx);
    }
} else struct {
    pub fn initLibrary() void {}
    pub fn createCtx(_: [:0]const u8, _: [:0]const u8) !*anyopaque {
        return error.TlsNotSupported;
    }
    pub fn sslNew(_: *anyopaque, _: posix.socket_t) !*anyopaque {
        return error.TlsNotSupported;
    }
    pub fn sslRead(_: *anyopaque, _: []u8) !usize {
        return error.TlsNotSupported;
    }
    pub fn sslWrite(_: *anyopaque, _: []const u8) !usize {
        return error.TlsNotSupported;
    }
    pub fn sslFree(_: *anyopaque) void {}
    pub fn ctxFree(_: *anyopaque) void {}
};

// ── WSS 服务�?────────────────────────────────────────────────────

const BUF_SIZE = 65536;

pub const WssServer = struct {
    listen_fd: posix.socket_t,
    port: u16,
    ws_path: []const u8,
    ssl_ctx: ?*anyopaque, // *SslCtx or null (plain WS)
    udp_port: u16,
    /// TCP relay forwarding (0 = UDP mode, non-0 = WS↔TCP relay bridge)
    tcp_host: []const u8,
    tcp_port: u16,
    running: bool,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, listen_host: []const u8, port: u16, ws_path: []const u8, cert_file: []const u8, key_file: []const u8, udp_port: u16) !WssServer {
        const listen_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer closeSocket(listen_fd);

        const reuse: u32 = 1;
        _ = posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(reuse)) catch {};

        const addr = try std.net.Address.parseIp(listen_host, port);
        try posix.bind(listen_fd, &addr.any, addr.getOsSockLen());
        try posix.listen(listen_fd, 16);

        var ssl_ctx: ?*anyopaque = null;
        if (cert_file.len > 0 and key_file.len > 0) {
            tls_impl.initLibrary();
            const path_buf = try alloc.alloc(u8, 512);
            defer alloc.free(path_buf);
            const cert_z = try std.mem.concat(alloc, u8, &.{ cert_file, "\x00" });
            defer alloc.free(cert_z);
            const key_z = try std.mem.concat(alloc, u8, &.{ key_file, "\x00" });
            defer alloc.free(key_z);
            ssl_ctx = tls_impl.createCtx(cert_z[0 .. cert_z.len - 1 :0], key_z[0 .. key_z.len - 1 :0]) catch |err| blk: {
                log.info("[wss] TLS 不可用 ({}), 降级为纯 WS", .{err});
                break :blk null;
            };
        }

        return WssServer{
            .listen_fd = listen_fd,
            .port = port,
            .ws_path = try alloc.dupe(u8, ws_path),
            .ssl_ctx = ssl_ctx,
            .udp_port = udp_port,
            .tcp_host = "",
            .tcp_port = 0,
            .running = false,
            .alloc = alloc,
        };
    }

    /// 初始�?WS↔TCP relay 桥模�?
    pub fn initRelayBridge(alloc: std.mem.Allocator, listen_host: []const u8, port: u16, ws_path: []const u8, cert_file: []const u8, key_file: []const u8, tcp_host: []const u8, tcp_port: u16) !WssServer {
        var server = try init(alloc, listen_host, port, ws_path, cert_file, key_file, 0);
        alloc.free(server.ws_path);
        server.ws_path = try alloc.dupe(u8, ws_path);
        server.tcp_host = try alloc.dupe(u8, tcp_host);
        server.tcp_port = tcp_port;
        return server;
    }

    pub fn deinit(self: *WssServer) void {
        if (self.ssl_ctx) |ctx| tls_impl.ctxFree(ctx);
        self.alloc.free(self.ws_path);
        if (self.tcp_host.len > 0) self.alloc.free(self.tcp_host);
        closeSocket(self.listen_fd);
    }

    pub fn run(self: *WssServer) void {
        self.running = true;
        const transport = if (self.ssl_ctx != null) "WSS" else "WS";
        if (self.tcp_port > 0) {
            log.info("[wss] {s} TCP relay �������� :{d}{s} �� TCP {s}:{d}", .{ transport, self.port, self.ws_path, self.tcp_host, self.tcp_port });
        } else {
            log.info("[wss] {s} ������������ :{d}{s} �� UDP :{d}", .{ transport, self.port, self.ws_path, self.udp_port });
        }

        while (self.running) {
            var client_addr: std.net.Address = undefined;
            var addr_len: posix.socklen_t = @sizeOf(std.net.Address);
            const fd = posix.accept(self.listen_fd, &client_addr.any, &addr_len, 0) catch |err| {
                if (self.running) log.info("[wss] accept 错误: {}", .{err});
                continue;
            };

            if (self.tcp_port > 0) {
                const thread = std.Thread.spawn(.{}, handleTcpBridgeConnection, .{
                    fd, self.ssl_ctx, self.tcp_host, self.tcp_port,
                }) catch |err| {
                    log.info("[wss] 线程创建失败: {}", .{err});
                    closeSocket(fd);
                    continue;
                };
                thread.detach();
            } else {
                const thread = std.Thread.spawn(.{}, handleConnection, .{
                    fd, self.ssl_ctx, self.udp_port,
                }) catch |err| {
                    log.info("[wss] 线程创建失败: {}", .{err});
                    closeSocket(fd);
                    continue;
                };
                thread.detach();
            }
        }
    }

    pub fn stop(self: *WssServer) void {
        self.running = false;
        closeSocket(self.listen_fd);
    }
};

// ── 连接处理 ──────────────────────────────────────────────────────

fn handleConnection(fd: posix.socket_t, ssl_ctx: ?*anyopaque, udp_port: u16) void {
    defer closeSocket(fd);

    // TLS handshake
    const ssl = if (ssl_ctx) |ctx| blk: {
        break :blk tls_impl.sslNew(ctx, fd) catch |err| {
            log.info("[wss] TLS 握手失败: {}", .{err});
            return;
        };
    } else null;
    defer if (ssl) |s| tls_impl.sslFree(s);

    // Read HTTP upgrade request
    var http_buf: [4096]u8 = undefined;
    const http_n = readHttpRequest(ssl, fd, &http_buf) catch |err| {
        if (err != error.ConnectionClosed) {
            log.info("[wss] HTTP 请求读取失败: {}", .{err});
        }
        return;
    };

    // 检查是否为 WebSocket 升级请求
    if (std.mem.indexOf(u8, http_buf[0..http_n], "Upgrade: websocket") == null) {
        // �?WS 请求（如健康检查），回�?200 OK
        const resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Type: text/plain\r\n\r\nOK";
        _ = wsWriteAll(ssl, fd, resp) catch {};
        return;
    }

    // WebSocket 升级握手
    sendWSUpgrade(ssl, fd, http_buf[0..http_n]) catch |err| {
        log.info("[wss] WebSocket 升级失败: {}", .{err});
        return;
    };

    // UDP socket for forwarding to local Chord
    const udp_fd = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP) catch return;
    defer closeSocket(udp_fd);

    const target_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, udp_port);
    var frame_buf: [BUF_SIZE]u8 = undefined;
    var resp_buf: [BUF_SIZE]u8 = undefined;

    log.info("[wss] 客户端已连接", .{});

    // WS �?UDP 桥接循环
    while (true) {
        const n = wsRecvFrame(ssl, fd, &frame_buf) catch |err| {
            if (err != error.ConnectionClosed and err != error.Timeout) {
                log.info("[wss] WS 接收错误: {}", .{err});
            }
            return;
        };

        // UDP 转发到本�?Chord
        _ = posix.sendto(udp_fd, frame_buf[0..n], 0, &target_addr.any, target_addr.getOsSockLen()) catch |err| {
            log.info("[wss] UDP 转发错误: {}", .{err});
            return;
        };

        // 等待 UDP 响应�?s 超时�?
        setRecvTimeout(udp_fd, 5000);
        var resp_addr: std.net.Address = undefined;
        var resp_addr_len: posix.socklen_t = @sizeOf(std.net.Address);
        const resp_n = posix.recvfrom(udp_fd, &resp_buf, 0, &resp_addr.any, &resp_addr_len) catch |err| {
            if (err == error.WouldBlock or err == error.Timeout) {
                // 无响应（notify 等单向消息），继续读取下一�?
                continue;
            }
            log.info("[wss] UDP recv 错误: {}", .{err});
            return;
        };

        // WS 响应回写
        wsSendFrame(ssl, fd, resp_buf[0..resp_n]) catch |err| {
            log.info("[wss] WS 发送错误: {}", .{err});
            return;
        };
    }
}

// ── TCP Relay Bridge (WS �?TCP) ──────────────────────────────────

fn handleTcpBridgeConnection(fd: posix.socket_t, ssl_ctx: ?*anyopaque, tcp_host: []const u8, tcp_port: u16) void {
    defer closeSocket(fd);

    // TLS handshake
    const ssl = if (ssl_ctx) |ctx| blk: {
        break :blk tls_impl.sslNew(ctx, fd) catch |err| {
            log.info("[wss] TLS 握手失败: {}", .{err});
            return;
        };
    } else null;
    defer if (ssl) |s| tls_impl.sslFree(s);

    // Read HTTP upgrade request
    var http_buf: [4096]u8 = undefined;
    const http_n = readHttpRequest(ssl, fd, &http_buf) catch |err| {
        if (err != error.ConnectionClosed) {
            log.info("[wss] HTTP 请求读取失败: {}", .{err});
        }
        return;
    };

    // WebSocket upgrade
    sendWSUpgrade(ssl, fd, http_buf[0..http_n]) catch |err| {
        log.info("[wss] WebSocket 升级失败: {}", .{err});
        return;
    };

    // Connect to local TCP relay server
    const relay_fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return;
    defer closeSocket(relay_fd);

    const relay_addr = std.net.Address.parseIp(tcp_host, tcp_port) catch return;
    posix.connect(relay_fd, &relay_addr.any, relay_addr.getOsSockLen()) catch |err| {
        log.info("[wss] TCP relay 连接失败: {}", .{err});
        return;
    };

    log.info("[wss] WS↔TCP 桥已建立 at {s}:{d}", .{ tcp_host, tcp_port });

    // 双向转发: WS �?TCP
    var running = std.atomic.Value(bool).init(true);

    const t1 = std.Thread.spawn(.{}, bridgeWsToTcp, .{ ssl, fd, relay_fd, &running }) catch return;
    const t2 = std.Thread.spawn(.{}, bridgeTcpToWs, .{ relay_fd, ssl, fd, &running }) catch {
        running.store(false, .release);
        return;
    };

    t1.join();
    t2.join();
    log.info("[wss] WS↔TCP 桥已关闭", .{});
}

fn bridgeWsToTcp(ws_ssl: ?*anyopaque, ws_fd: posix.socket_t, tcp_fd: posix.socket_t, running: *std.atomic.Value(bool)) void {
    var buf: [BUF_SIZE]u8 = undefined;
    while (running.load(.acquire)) {
        const n = wsRecvFrame(ws_ssl, ws_fd, &buf) catch |err| {
            if (err == error.Timeout) continue;
            break;
        };
        if (posix.write(tcp_fd, buf[0..n])) |_| {} else |_| break;
    }
    running.store(false, .release);
}

fn bridgeTcpToWs(tcp_fd: posix.socket_t, ws_ssl: ?*anyopaque, ws_fd: posix.socket_t, running: *std.atomic.Value(bool)) void {
    var buf: [BUF_SIZE]u8 = undefined;
    while (running.load(.acquire)) {
        const n = posix.read(tcp_fd, &buf) catch break;
        wsSendFrame(ws_ssl, ws_fd, buf[0..n]) catch break;
    }
    running.store(false, .release);
}

// ── HTTP Upgrade ──────────────────────────────────────────────────

fn sendWSUpgrade(ssl: ?*anyopaque, fd: posix.socket_t, request: []const u8) !void {
    // �?Sec-WebSocket-Key
    const key_hdr = "Sec-WebSocket-Key: ";
    const key_start = std.mem.indexOf(u8, request, key_hdr) orelse return error.BadRequest;
    const key_start_idx = key_start + key_hdr.len;
    const line_end = std.mem.indexOfScalar(u8, request[key_start_idx..], '\r') orelse return error.BadRequest;
    const key = request[key_start_idx..][0..line_end];

    // SHA1(key + magic GUID)
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update("258EAFA5-E914-47DA-95CA-5AB9DC11B85B");
    var digest: [20]u8 = undefined;
    hasher.final(&digest);

    var accept_buf: [28]u8 = undefined;
    const accept = std.base64.standard.Encoder.encode(&accept_buf, &digest);

    var resp: [256]u8 = undefined;
    const resp_slice = try std.fmt.bufPrint(&resp,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: {s}\r\n" ++
        "\r\n",
        .{accept},
    );

    _ = try wsWriteAll(ssl, fd, resp_slice);
}

// ── WebSocket 帧（服务器端）───────────────────────────────────────

/// 接收客户�?WS 帧（CLIENT→SERVER: 必须掩码�?
fn wsRecvFrame(ssl: ?*anyopaque, fd: posix.socket_t, buf: []u8) !usize {
    var first: [2]u8 = undefined;
    try wsReadExact(ssl, fd, &first);

    const opcode = first[0] & 0x0F;
    const masked = (first[1] & 0x80) != 0;
    var payload_len: usize = first[1] & 0x7F;

    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        try wsReadExact(ssl, fd, &ext);
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        try wsReadExact(ssl, fd, &ext);
        payload_len = @as(usize, @intCast(std.mem.readInt(u64, &ext, .big)));
    }

    if (payload_len > buf.len) return error.MessageTooBig;

    // 先读�?payload（控制帧也需要读取，RFC 6455 §5.5�?
    if (masked) {
        var mk: [4]u8 = undefined;
        try wsReadExact(ssl, fd, &mk);
        if (payload_len > 0) try wsReadExact(ssl, fd, buf[0..payload_len]);
        for (buf[0..payload_len], 0..) |*b, i| {
            b.* ^= mk[i % 4];
        }
    } else {
        if (payload_len > 0) try wsReadExact(ssl, fd, buf[0..payload_len]);
    }

    // Ping
    if (opcode == 0x9) {
        var pong: [2]u8 = .{ 0x8A, @as(u8, @intCast(payload_len)) };
        _ = try wsWriteAll(ssl, fd, &pong);
        if (payload_len > 0) _ = try wsWriteAll(ssl, fd, buf[0..payload_len]);
        return wsRecvFrame(ssl, fd, buf);
    }

    // Close
    if (opcode == 0x8) return error.ConnectionClosed;

    // 跳过�?Binary/Text �?
    if (opcode != 0x2 and opcode != 0x1) {
        return wsRecvFrame(ssl, fd, buf);
    }

    return payload_len;
}

/// 发�?WS 帧到客户端（SERVER→CLIENT: 不掩码）
fn wsSendFrame(ssl: ?*anyopaque, fd: posix.socket_t, data: []const u8) !void {
    var hdr: [10]u8 = undefined;
    var hdr_len: usize = 0;

    hdr[0] = 0x82; // FIN=1, Binary
    if (data.len < 126) {
        hdr[1] = @as(u8, @intCast(data.len));
        hdr_len = 2;
    } else if (data.len < 65536) {
        hdr[1] = 126;
        std.mem.writeInt(u16, hdr[2..4], @as(u16, @intCast(data.len)), .big);
        hdr_len = 4;
    } else {
        hdr[1] = 127;
        std.mem.writeInt(u64, hdr[2..10], @as(u64, @intCast(data.len)), .big);
        hdr_len = 10;
    }

    _ = try wsWriteAll(ssl, fd, hdr[0..hdr_len]);
    if (data.len > 0) _ = try wsWriteAll(ssl, fd, data);
}

// ── I/O 辅助（统一 TLS / �?TCP）──────────────────────────────────

fn wsRead(ssl: ?*anyopaque, fd: posix.socket_t, buf: []u8) !usize {
    if (ssl) |s| return tls_impl.sslRead(s, buf);
    const n = posix.read(fd, buf) catch |err| {
        if (err == error.WouldBlock) return error.Timeout;
        return err;
    };
    if (n == 0) return error.ConnectionClosed;
    return n;
}

fn wsReadExact(ssl: ?*anyopaque, fd: posix.socket_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        off += try wsRead(ssl, fd, buf[off..]);
    }
}

fn wsWriteAll(ssl: ?*anyopaque, fd: posix.socket_t, data: []const u8) !usize {
    var off: usize = 0;
    while (off < data.len) {
        if (ssl) |s| {
            off += try tls_impl.sslWrite(s, data[off..]);
        } else {
            off += try posix.write(fd, data[off..]);
        }
    }
    return off;
}

/// 读取 HTTP 请求直到 \r\n\r\n
fn readHttpRequest(ssl: ?*anyopaque, fd: posix.socket_t, buf: []u8) !usize {
    var pos: usize = 0;
    while (pos < buf.len) {
        const n = try wsRead(ssl, fd, buf[pos..]);
        pos += n;
        if (std.mem.indexOf(u8, buf[0..pos], "\r\n\r\n")) |end| {
            return end + 4;
        }
    }
    return error.RequestTooLarge;
}

// ── Socket 工具 ───────────────────────────────────────────────────

fn closeSocket(fd: posix.socket_t) void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ws2_32.closesocket(fd);
        return;
    }
    if (fd < 0) return;
    _ = posix.system.close(fd);
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

