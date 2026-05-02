/// UDP 传输层（基于 posix socket API / WinSock）

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const UdpSocket = struct {
    fd: posix.socket_t,

    pub fn bind(port: u16) !UdpSocket {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);

        const opt: c_int = 1;
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(opt));

        const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
        try posix.bind(fd, &addr.any, @sizeOf(posix.sockaddr.in));

        // 设置非阻塞模式
        setNonblocking(fd, true) catch {};

        return UdpSocket{ .fd = fd };
    }

    fn setNonblocking(fd: posix.socket_t, nonblocking: bool) !void {
        if (builtin.os.tag == .windows) {
            var mode: u32 = if (nonblocking) 1 else 0;
            const rc = std.os.windows.ws2_32.ioctlsocket(fd, std.os.windows.ws2_32.FIONBIO, &mode);
            if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
                return error.SetNonblockingFailed;
            }
        } else if (comptime builtin.os.tag == .linux) {
            const flags = try posix.fcntl(fd, posix.F.GETFL, @as(usize, 0));
            const nonblock_flag: u32 = @as(u32, @bitCast(std.os.linux.O{ .NONBLOCK = true }));
            const new_flags = if (nonblocking) flags | nonblock_flag else flags & ~nonblock_flag;
            _ = try posix.fcntl(fd, posix.F.SETFL, @as(usize, @intCast(new_flags)));
        } else {
            // macOS/其他 POSIX: O_NONBLOCK 作为 c_int 可用
            const flags = try posix.fcntl(fd, posix.F.GETFL, @as(usize, 0));
            const nonblock_flag: u32 = @as(u32, @bitCast(@as(i32, posix.O.NONBLOCK)));
            const new_flags = if (nonblocking) flags | nonblock_flag else flags & ~nonblock_flag;
            _ = try posix.fcntl(fd, posix.F.SETFL, @as(usize, @intCast(new_flags)));
        }
    }

    pub fn sendTo(self: *UdpSocket, addr: std.net.Address, data: []const u8) !void {
        _ = try posix.sendto(self.fd, data, 0, &addr.any, @sizeOf(posix.sockaddr.in));
    }

    pub fn recvFrom(self: *UdpSocket, buf: []u8) !struct { n: usize, addr: std.net.Address } {
        var src_addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

        const n = try posix.recvfrom(self.fd, buf, 0, &src_addr, &addr_len);

        // 从 sockaddr 构造 Address
        const in_addr = @as(*const posix.sockaddr.in, @alignCast(@ptrCast(&src_addr)));
        const address = std.net.Address.initIp4(
            @bitCast(in_addr.addr),
            std.mem.bigToNative(u16, in_addr.port),
        );
        return .{ .n = n, .addr = address };
    }

    pub fn setRecvTimeout(self: *UdpSocket, timeout_ms: u64) !void {
        if (builtin.os.tag == .windows) {
            // Windows: SO_RCVTIMEO 需要 DWORD（毫秒），不是 timeval
            const ms: u32 = @intCast(@min(timeout_ms, std.math.maxInt(u32)));
            try posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(ms));
        } else {
            const tv = posix.timeval{
                .sec = @as(isize, @intCast(timeout_ms / 1000)),
                .usec = @as(isize, @intCast((timeout_ms % 1000) * 1000)),
            };
            try posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(tv));
        }
    }

    pub fn localPort(self: UdpSocket) u16 {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        posix.getsockname(self.fd, &addr, &addr_len) catch return 0;
        const in_addr = @as(*posix.sockaddr.in, @alignCast(@ptrCast(&addr)));
        return std.mem.bigToNative(u16, in_addr.port);
    }

    pub fn close(self: *UdpSocket) void {
        if (builtin.os.tag == .windows) {
            _ = std.os.windows.ws2_32.closesocket(self.fd);
        } else {
            posix.close(self.fd);
        }
    }
};
