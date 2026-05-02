/// 网络能力与端口可达性自动检测
/// 启动时检测当前节点的网络受限等级，自动选择传输模式
///
/// 检测原理:
///   1. 本地监听 TCP 测试端口
///   2. 获取公网出口 IP（api.ipify.org）
///   3. 调用公网探测服务回连本机（验证端口公网可达性）
///   4. 本地环回探测（验证端口本地可用性）
///   5. 综合判定等级
///
/// 等级映射:
///   full_public  → dual 模式（种子节点/超级节点）
///   lan_only     → udp 模式（内网互通，外网走中继）
///   strict_limit → tcp 模式（仅出站 TCP，强制中继）
const std = @import("std");
const posix = std.posix;

/// 网络能力受限等级
pub const NetLimitLevel = enum {
    /// 公网端口完全可达，可被外部主动连接
    full_public,
    /// 仅内网可达，外网无法入站
    lan_only,
    /// 严格受限：NAT/容器/防火墙，完全无法被外部访问
    strict_limit,
};

/// 端口外网可达性检测结果
pub const PortReachResult = struct {
    public_ip: ?[]const u8,
    test_port: u16,
    external_reachable: bool,
    lan_reachable: bool,
    level: NetLimitLevel,
};

/// 执行全套网络能力检测
/// 使用 TCP 监听 + 公网探测服务验证端口可达性
/// test_port: 用于检测的端口号（通常使用 listen_port）
/// listen_host: 配置的监听地址（用于判断是否为内网 IP）
/// prefer_ipv4: 如果为 true，获取公网 IP 时优先使用 IPv4（relay 协议不支持 IPv6）
pub fn fullNetDetect(alloc: std.mem.Allocator, test_port: u16, listen_host: []const u8, prefer_ipv4: bool) !PortReachResult {
    // ── 1. 创建 TCP 监听（尝试端口、+1、+2） ──
    var actual_port: u16 = test_port;
    const fd = blk: {
        for ([_]u16{ test_port, test_port + 1, test_port + 2 }) |try_port| {
            const s = posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP) catch continue;
            posix.setsockopt(s, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};
            const bind_addr = posix.sockaddr.in{
                .family = posix.AF.INET,
                .port = std.mem.nativeToBig(u16, try_port),
                .addr = std.mem.nativeToBig(u32, 0),
                .zero = .{0} ** 8,
            };
            if (posix.bind(s, @as(*const posix.sockaddr, @ptrCast(&bind_addr)), @sizeOf(posix.sockaddr.in))) {
                posix.listen(s, 1) catch {
                    posix.close(s);
                    continue;
                };
                actual_port = try_port;
                break :blk s;
            } else |_| {
                posix.close(s);
                continue;
            }
        }
        return error.AddressInUse;
    };
    errdefer posix.close(fd);

    // ── 2. 获取公网出口 IP ──
    const pub_ip = getPublicIP(alloc, prefer_ipv4) catch null;
    if (pub_ip) |ip| {
        std.debug.print("[net_detect] 公网 IP: {s}\n", .{ip});
    } else {
        std.debug.print("[net_detect] 无法获取公网 IP（可能无外网连接）\n", .{});
    }

    // ── 3. 并发执行外网/内网探测 ──
    var ext_ok = false;
    var lan_ok = false;

    const thread_ext = try std.Thread.spawn(.{}, waitConn, .{ fd, &ext_ok, 7000 });
    errdefer thread_ext.join();

    const thread_lan = try std.Thread.spawn(.{}, lanProbe, .{ actual_port, &lan_ok });
    errdefer thread_lan.join();

    // ── 4. 触发公网探测服务（在独立线程中运行，避免服务不可用阻塞 detection） ──
    if (pub_ip) |ip| {
        const ip_copy = alloc.dupe(u8, ip) catch null;
        if (ip_copy) |ipc| {
            const probe_thread = std.Thread.spawn(.{}, probeBg, .{ alloc, ipc, actual_port }) catch null;
            if (probe_thread) |pt| pt.detach();
        }
    }

    // ── 5. 等待检测完成（lanProbe 很快完成；ext 等待 7s） ──
    thread_lan.join();
    // waitConn 内部会忽略 lanProbe 的环回连接，继续等待真正的外网连接
    thread_ext.join();
    posix.close(fd);

    // ── 6. 判定网络等级 ──
    //    full_public: 外网回连成功 → 公网可达
    //    full_public: listen_host == 公网 IP → VPS（如 外2 listen_host=192.140.185.171）
    //    strict_limit: 有公网 IP 但不匹配 listen_host → NAT/防火墙（如 ext on alwaysdata）
    //    lan_only:    监听私网 IP → 内网节点（如 59/60）
    //    strict_limit: 0.0.0.0 + 无公网 IP → 无法判定，保守受限
    const is_private = isPrivateIP(listen_host);
    const pub_ip_matches_listen = if (pub_ip) |ip| std.mem.eql(u8, ip, listen_host) else false;
    const level: NetLimitLevel = if (ext_ok)
        .full_public
    else if (pub_ip_matches_listen)
        .full_public // listen_host 与公网 IP 一致 → VPS，端口开放
    else if (is_private)
        .lan_only // 监听私网 IP → 内网节点
    else if (pub_ip != null)
        .strict_limit // 有公网 IP 但 inbound 被屏蔽
    else if (lan_ok)
        .strict_limit // 监听 0.0.0.0，无公网 IP → 严格受限
    else
        .strict_limit;

    // 打印检测结果
    std.debug.print("[net_detect] 检测完成: port={d} ext={} lan={} level={s}\n", .{
        actual_port, ext_ok, lan_ok, @tagName(level),
    });

    return PortReachResult{
        .public_ip = pub_ip,
        .test_port = actual_port,
        .external_reachable = ext_ok,
        .lan_reachable = lan_ok,
        .level = level,
    };
}

/// 等待外部入站连接（忽略环回连接，避免 lanProbe 干扰）
/// 使用 poll 实现超时控制
fn waitConn(fd: posix.socket_t, ok: *bool, timeout_ms: u64) void {
    var poll_fds = [1]posix.pollfd{
        .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
    };

    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

    while (true) {
        const now = std.time.milliTimestamp();
        const remaining = deadline - now;
        if (remaining <= 0) {
            ok.* = false; // 超时，无外部连接
            return;
        }

        const ready = posix.poll(&poll_fds, @intCast(@min(remaining, @as(i64, 1000)))) catch {
            ok.* = false;
            return;
        };

        if (ready == 0) continue; // poll 超时，继续循环

        // 有连接到达，accept 并检查来源
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const client_fd = posix.accept(fd, &addr, &addr_len, 0) catch {
            ok.* = false;
            return;
        };
        posix.close(client_fd);

        // 检查是否来自 127.0.0.1（lanProbe）：忽略并继续等待
        const addr_in = @as(*const posix.sockaddr.in, @alignCast(@ptrCast(&addr)));
        if (addr_in.addr == std.mem.nativeToBig(u32, 0x7f000001)) continue;

        ok.* = true; // 收到非环回连接 → 外网可达
        return;
    }
}

/// 尝试通过 IPv4-only 连接获取公网 IP
/// 当 prefer_ipv4 时，手动将 hostname 解析为 IPv4 地址并连接
fn getPublicIPViaIPv4(alloc: std.mem.Allocator, hostname: []const u8, port: u16) !?[]const u8 {
    // 解析 hostname 的 DNS 记录
    const addr_list = try std.net.getAddressList(alloc, hostname, port);
    defer addr_list.deinit();

    // 遍历所有解析到的地址，只尝试 IPv4
    for (addr_list.addrs) |addr| {
        if (addr.any.family != posix.AF.INET) continue;

        var stream = std.net.tcpConnectToAddress(addr) catch continue;
        defer stream.close();

        const request = "GET / HTTP/1.0\r\nHost: icanhazip.com\r\nConnection: close\r\n\r\n";
        stream.writeAll(request) catch continue;

        var buf: [2048]u8 = undefined;
        const n = stream.readAll(&buf) catch continue;
        if (n == 0) continue;

        const response = buf[0..n];
        const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse continue;
        const body = std.mem.trim(u8, response[header_end + 4 .. n], " \n\r\t");
        if (body.len == 0) continue;

        return alloc.dupe(u8, body) catch null;
    }
    return null;
}

/// 获取公网出口 IP
/// 使用原始 TCP 连接（避免 std.http.Client 在某些平台上的断言 bug）
/// 注: api.ipify.org 被 Cloudflare 保护，部分 VPS 连接受阻，改用 icanhazip.com
/// prefer_ipv4: 如果为 true，强制使用 IPv4 连接（返回 IPv4 地址）
pub fn getPublicIP(alloc: std.mem.Allocator, prefer_ipv4: bool) !?[]const u8 {
    // 优先使用 IPv4 连接
    if (prefer_ipv4) {
        if (try getPublicIPViaIPv4(alloc, "icanhazip.com", 80)) |ip| {
            return ip;
        }
        std.debug.print("[net_detect] IPv4 连接失败，回退到默认 DNS 解析\n", .{});
    }

    // 默认：使用系统 DNS 解析
    var stream = std.net.tcpConnectToHost(alloc, "icanhazip.com", 80) catch return null;
    defer stream.close();

    const request = "GET / HTTP/1.0\r\nHost: icanhazip.com\r\nConnection: close\r\n\r\n";
    stream.writeAll(request) catch return null;

    var buf: [2048]u8 = undefined;
    const n = stream.readAll(&buf) catch return null;
    if (n == 0) return null;

    const response = buf[0..n];
    const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return null;
    const body = std.mem.trim(u8, response[header_end + 4 .. n], " \n\r\t");
    if (body.len == 0) return null;

    return alloc.dupe(u8, body) catch null;
}

/// 请求外网探测服务主动回拨本机端口
/// 使用原始 TCP 请求（避免 std.http.Client 断言 bug）
fn probeExternalConnect(alloc: std.mem.Allocator, pub_ip: []const u8, port: u16) !bool {
    var stream = std.net.tcpConnectToHost(alloc, "portcheck.tcpiputils.com", 80) catch return false;
    defer stream.close();

    const path = try std.fmt.allocPrint(alloc, "GET /check?ip={s}&port={d} HTTP/1.0\r\nHost: portcheck.tcpiputils.com\r\nConnection: close\r\n\r\n", .{ pub_ip, port });
    defer alloc.free(path);
    stream.writeAll(path) catch return false;

    var buf: [512]u8 = undefined;
    _ = stream.readAll(&buf) catch return false;
    return true;
}

/// 后台运行 probeExternalConnect（用于独立线程，避免阻塞主检测流程）
fn probeBg(alloc: std.mem.Allocator, pub_ip: []const u8, port: u16) void {
    _ = probeExternalConnect(alloc, pub_ip, port) catch {
        // 探测服务不可用不影响主流程
    };
    alloc.free(pub_ip);
}

/// 内网自探测：判断端口是否能本地连通
fn lanProbe(port: u16, ok: *bool) void {
    const addr = std.net.Address.parseIp("127.0.0.1", port) catch {
        ok.* = false;
        return;
    };
    var sock = std.net.tcpConnectToAddress(addr) catch {
        ok.* = false;
        return;
    };
    sock.close();
    ok.* = true;
}

/// 判断是否为私有 IP 地址（RFC 1918）
/// 用于区分内网节点（59/60）与公网受限节点（ext 监听 0.0.0.0）
fn isPrivateIP(host: []const u8) bool {
    // 10.0.0.0/8
    if (std.mem.startsWith(u8, host, "10.")) return true;
    // 172.16.0.0/12 ~ 172.31.0.0/12
    if (std.mem.startsWith(u8, host, "172.")) {
        const second = std.fmt.parseInt(u16, host[4..6], 10) catch return false;
        if (second >= 16 and second <= 31) return true;
    }
    // 192.168.0.0/16
    if (std.mem.startsWith(u8, host, "192.168.")) return true;
    // 127.0.0.0/8（环回地址）
    if (std.mem.startsWith(u8, host, "127.")) return true;
    return false;
}

/// 快速判断是否有外网连接
pub fn hasInternet() bool {
    const addr = std.net.Address.parseIp("1.1.1.1", 443) catch return false;
    var sock = std.net.tcpConnectToAddress(addr) catch return false;
    sock.close();
    return true;
}
