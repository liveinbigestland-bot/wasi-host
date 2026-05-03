/// SOCKS5 代理 + TCP 隧道中继
/// 监听本地 SOCKS 端口，SOCKS5 CONNECT → 独立 relay 连接 → 外2 relay server → 目标服务器
/// 与 Chord 的 relay client 完全独立，不干扰 Chord 消息
const std = @import("std");
const posix = std.posix;
const relay = @import("relay.zig");
const RelayClient = relay.RelayClient;

const BUF_SIZE = 65536;

/// SOCKS5 代理状态
pub const SocksRelay = struct {
    alloc: std.mem.Allocator,
    relay_client: *RelayClient,
    listen_port: u16,
    conn_map: std.AutoHashMap(u32, ConnState),
    running: bool,

    const ConnState = struct {
        fd: posix.socket_t,
        conn_id: u32,
    };

    /// 初始化并启动 SOCKS5 代理（包含 relay client 连接）
    pub fn start(alloc: std.mem.Allocator, remote_host: []const u8, remote_port: u16, local_host: []const u8, local_port: u16, udp_port: u16, listen_port: u16, ws_mode: bool, ws_path: []const u8) !void {
        // 创建独立的 relay client（连接到外2 relay server）
        const rc = try alloc.create(RelayClient);
        errdefer alloc.destroy(rc);

        rc.* = try RelayClient.initWithOpts(
            alloc, remote_host, remote_port,
            local_host, local_port, udp_port,
            ws_mode, ws_path,
        );

        var self = SocksRelay{
            .alloc = alloc,
            .relay_client = rc,
            .listen_port = listen_port,
            .conn_map = std.AutoHashMap(u32, ConnState).init(alloc),
            .running = true,
        };

        // 注册 TCP 隧道回调
        rc.tcp_callback = tcpDataCallback;

        // 启动 relay client reader 线程
        const reader_thread = try std.Thread.spawn(.{}, RelayClient.readerLoop, .{rc});
        reader_thread.detach();

        // 启动 SOCKS5 监听
        const listen_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer _ = posix.system.close(listen_fd);

        const reuse: u32 = 1;
        _ = posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(reuse)) catch {};

        const addr = try std.net.Address.parseIp("0.0.0.0", listen_port);
        try posix.bind(listen_fd, &addr.any, addr.getOsSockLen());
        try posix.listen(listen_fd, 16);

        std.debug.print("[socks] SOCKS5 代理已启动 :{d} (relay client → {s}:{d})\n", .{ listen_port, remote_host, remote_port });

        var next_conn_id: u32 = 1;

        while (self.running) {
            var client_addr: std.net.Address = undefined;
            var addr_len: posix.socklen_t = @sizeOf(std.net.Address);
            const client_fd = posix.accept(listen_fd, &client_addr.any, &addr_len, 0) catch |err| {
                if (err != error.WouldBlock and err != error.ConnectionAborted) {
                    std.debug.print("[socks] accept 错误: {}\n", .{err});
                }
                continue;
            };

            const conn_id = @atomicRmw(u32, &next_conn_id, .Add, 1, .monotonic);
            const thread = std.Thread.spawn(.{}, handleSocksConnection, .{
                &self, client_fd, conn_id,
            }) catch |err| {
                std.debug.print("[socks] 线程创建失败: {}\n", .{err});
                _ = posix.system.close(client_fd);
                continue;
            };
            thread.detach();
        }
    }

    fn handleSocksConnection(self: *SocksRelay, fd: posix.socket_t, conn_id: u32) void {
        defer _ = posix.system.close(fd);

        var buf: [BUF_SIZE]u8 = undefined;

        // ── SOCKS5 握手 ──
        const n1 = posix.read(fd, &buf) catch return;
        if (n1 < 2 or buf[0] != 0x05) return;
        const no_auth = [_]u8{ 0x05, 0x00 };
        _ = posix.write(fd, &no_auth) catch return;

        const n2 = posix.read(fd, &buf) catch return;
        if (n2 < 4 or buf[0] != 0x05 or buf[1] != 0x01) return;

        // 解析目标地址
        const atyp = buf[3];
        var target_host: []const u8 = undefined;
        var target_port: u16 = undefined;

        switch (atyp) {
            0x01 => {
                if (n2 < 8) return;
                const ip_bytes = buf[4..8];
                var host_buf: [16]u8 = undefined;
                const host = std.fmt.bufPrint(&host_buf, "{d}.{d}.{d}.{d}", .{
                    ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3],
                }) catch return;
                target_host = self.alloc.dupe(u8, host) catch return;
                target_port = std.mem.readInt(u16, buf[8..10], .big);
            },
            0x03 => {
                const domain_len = buf[4];
                if (n2 < 5 + domain_len + 2) return;
                target_host = self.alloc.dupe(u8, buf[5..][0..domain_len]) catch return;
                target_port = std.mem.readInt(u16, buf[5 + domain_len ..][0..2], .big);
            },
            0x04 => {
                std.debug.print("[socks] IPv6 暂不支持\n", .{});
                const resp = [_]u8{ 0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0 };
                _ = posix.write(fd, &resp) catch {};
                return;
            },
            else => return,
        }
        defer self.alloc.free(target_host);

        std.debug.print("[socks] CONNECT {s}:{d} (conn_id={d})\n", .{ target_host, target_port, conn_id });

        // 注册连接状态
        {
            self.conn_map.put(conn_id, .{ .fd = fd, .conn_id = conn_id }) catch {};
        }

        // 通过 relay 发送 TCP CONNECT
        self.relay_client.tcpConnect(conn_id, target_host, target_port) catch |err| {
            std.debug.print("[socks] relay TCP CONNECT 失败: {}\n", .{err});
            const resp = [_]u8{ 0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0 };
            _ = posix.write(fd, &resp) catch {};
            self.conn_map.remove(conn_id);
            return;
        };

        // 回复 SOCKS5 成功
        const resp = [_]u8{ 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 };
        _ = posix.write(fd, &resp) catch {
            self.conn_map.remove(conn_id);
            return;
        };

        // 本地 TCP → relay TCP_DATA 转发
        var read_buf: [BUF_SIZE]u8 = undefined;
        while (true) {
            const n = posix.read(fd, &read_buf) catch |err| {
                if (err == error.WouldBlock or err == error.Timeout) continue;
                break;
            };
            if (n == 0) break;
            self.relay_client.tcpData(conn_id, read_buf[0..n]) catch {
                break;
            };
        }

        // 清理
        self.relay_client.tcpClose(conn_id) catch {};
        self.conn_map.remove(conn_id);
        std.debug.print("[socks] 关闭 conn_id={d}\n", .{conn_id});
    }
};

/// TCP 数据回调，由 relay client 的 readerLoop 调用
/// 通过全局状态查找 conn_id 对应的 local fd
var global_map: ?*std.AutoHashMap(u32, SocksRelay.ConnState) = null;
var global_mutex: std.Thread.Mutex = .{};

fn tcpDataCallback(conn_id: u32, data: ?[]const u8) void {
    global_mutex.lock();
    const map = global_map orelse {
        global_mutex.unlock();
        return;
    };
    const entry = map.get(conn_id) orelse {
        global_mutex.unlock();
        return;
    };
    const fd = entry.fd;
    global_mutex.unlock();

    if (data) |d| {
        _ = posix.write(fd, d) catch {};
    } else {
        _ = posix.system.close(fd);
        global_mutex.lock();
        _ = map.remove(conn_id);
        global_mutex.unlock();
    }
}

/// 启动 SOCKS5 代理的便捷函数（供 main.zig 调用）
pub fn startProxy(alloc: std.mem.Allocator, remote_host: []const u8, remote_port: u16, local_host: []const u8, local_port: u16, udp_port: u16, listen_port: u16) !void {
    // 注册全局 conn_map（用于回调）
    var conn_map = std.AutoHashMap(u32, SocksRelay.ConnState).init(alloc);
    global_map = &conn_map;

    // 创建 relay client（纯 TCP，不经过 WS，注册到外2 relay server）
    const rc = try alloc.create(RelayClient);
    errdefer alloc.destroy(rc);

    rc.* = try RelayClient.initWithOpts(
        alloc, remote_host, remote_port,
        local_host, local_port, udp_port,
        false, "", // no WS mode for ARM→外2 relay
    );

    // 注册 TCP 隧道回调
    rc.tcp_callback = tcpDataCallback;

    // 启动 reader 线程
    const reader_thread = try std.Thread.spawn(.{}, RelayClient.readerLoop, .{rc});
    reader_thread.detach();

    // 启动 SOCKS5 监听
    const listen_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    errdefer _ = posix.system.close(listen_fd);

    const reuse: u32 = 1;
    _ = posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(reuse)) catch {};

    const addr = try std.net.Address.parseIp("0.0.0.0", listen_port);
    try posix.bind(listen_fd, &addr.any, addr.getOsSockLen());
    try posix.listen(listen_fd, 16);

    std.debug.print("[socks] SOCKS5 代理已启动 :{d} (relay → {s}:{d})\n", .{ listen_port, remote_host, remote_port });

    var next_conn_id: u32 = 1;

    while (true) {
        var client_addr: std.net.Address = undefined;
        var addr_len: posix.socklen_t = @sizeOf(std.net.Address);
        const client_fd = posix.accept(listen_fd, &client_addr.any, &addr_len, 0) catch |err| {
            if (err != error.WouldBlock and err != error.ConnectionAborted) {
                std.debug.print("[socks] accept 错误: {}\n", .{err});
            }
            continue;
        };

        const conn_id = @atomicRmw(u32, &next_conn_id, .Add, 1, .monotonic);
        const thread = std.Thread.spawn(.{}, handleConnection, .{ rc, client_fd, conn_id }) catch |err| {
            std.debug.print("[socks] 线程创建失败: {}\n", .{err});
            _ = posix.system.close(client_fd);
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(client: *RelayClient, fd: posix.socket_t, conn_id: u32) void {
    defer _ = posix.system.close(fd);

    var buf: [BUF_SIZE]u8 = undefined;

    // SOCKS5 握手
    const n1 = posix.read(fd, &buf) catch return;
    if (n1 < 2 or buf[0] != 0x05) return;
    const no_auth = [_]u8{ 0x05, 0x00 };
    _ = posix.write(fd, &no_auth) catch return;

    const n2 = posix.read(fd, &buf) catch return;
    if (n2 < 4 or buf[0] != 0x05 or buf[1] != 0x01) return;

    const atyp = buf[3];
    const target_host: []const u8 = blk: {
        switch (atyp) {
            0x01 => {
                if (n2 < 8) return;
                const ip_bytes = buf[4..8];
                var host_buf: [16]u8 = undefined;
                const host = std.fmt.bufPrint(&host_buf, "{d}.{d}.{d}.{d}", .{
                    ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3],
                }) catch return;
                const alloc = std.heap.page_allocator;
                const owned = alloc.dupe(u8, host) catch return;
                break :blk owned;
            },
            0x03 => {
                const domain_len = buf[4];
                if (n2 < 5 + domain_len + 2) return;
                const alloc = std.heap.page_allocator;
                const owned = alloc.dupe(u8, buf[5..][0..domain_len]) catch return;
                break :blk owned;
            },
            else => {
                const resp = [_]u8{ 0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0 };
                _ = posix.write(fd, &resp) catch {};
                return;
            },
        }
    };
    const target_port = switch (atyp) {
        0x01 => std.mem.readInt(u16, buf[8..10], .big),
        0x03 => std.mem.readInt(u16, buf[5 + buf[4] ..][0..2], .big),
        else => return,
    };

    std.debug.print("[socks] CONNECT {s}:{d} (conn_id={d})\n", .{ target_host, target_port, conn_id });

    // 注册到全局 map
    {
        global_mutex.lock();
        defer global_mutex.unlock();
        if (global_map) |map| {
            map.put(conn_id, .{ .fd = fd, .conn_id = conn_id }) catch {};
        }
    }

    // TCP CONNECT via relay
    client.tcpConnect(conn_id, target_host, target_port) catch |err| {
        std.debug.print("[socks] relay TCP CONNECT 失败: {}\n", .{err});
        const resp = [_]u8{ 0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0 };
        _ = posix.write(fd, &resp) catch {};
        global_mutex.lock();
        if (global_map) |map| _ = map.remove(conn_id);
        global_mutex.unlock();
        return;
    };

    // 回复 SOCKS5 成功
    const resp = [_]u8{ 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 };
    _ = posix.write(fd, &resp) catch {
        client.tcpClose(conn_id) catch {};
        global_mutex.lock();
        if (global_map) |map| _ = map.remove(conn_id);
        global_mutex.unlock();
        return;
    };

    // 本地 TCP → relay TCP_DATA
    var read_buf: [BUF_SIZE]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &read_buf) catch |err| {
            if (err == error.WouldBlock or err == error.Timeout) continue;
            break;
        };
        if (n == 0) break;
        client.tcpData(conn_id, read_buf[0..n]) catch {
            break;
        };
    }

    // 清理
    client.tcpClose(conn_id) catch {};
    global_mutex.lock();
    if (global_map) |map| _ = map.remove(conn_id);
    global_mutex.unlock();
    std.debug.print("[socks] 关闭 conn_id={d}\n", .{conn_id});
}
