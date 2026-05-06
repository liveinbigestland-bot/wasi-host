/// UDP Echo 调试服务
/// 监听指定 UDP 端口，收到数据后打印日志并原样回复
const std = @import("std");
const posix = std.posix;
const logging = @import("logging");
const log = logging.log;

const BUF_SIZE = 65536;

pub const UdpEchoServer = struct {
    fd: posix.socket_t,
    port: u16,
    running: bool,

    pub fn init(port: u16) !UdpEchoServer {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
        const opt: c_int = 1;
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(opt));

        // 使用 std.net.Address.initIp4 (�?transport/udp.zig 相同方式)
        const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
        try posix.bind(fd, &addr.any, @sizeOf(posix.sockaddr.in));

        return UdpEchoServer{ .fd = fd, .port = port, .running = true };
    }

    pub fn deinit(self: *UdpEchoServer) void {
        self.running = false;
        posix.close(self.fd);
    }

    pub fn run(self: *UdpEchoServer) void {
        var buf: [BUF_SIZE]u8 = undefined;
        var src_addr: posix.sockaddr = undefined;
        log.info("[udpecho] 监听 UDP :{d}", .{self.port});

        while (self.running) {
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            const n = posix.recvfrom(self.fd, &buf, 0, &src_addr, &addr_len) catch |err| {
                if (err == error.WouldBlock or err == error.Timeout) continue;
                log.info("[udpecho] recv 错误: {}", .{err});
                break;
            };
            if (n == 0) continue;

            // 提取 sender IP
            const in_addr = @as(*const posix.sockaddr.in, @alignCast(@ptrCast(&src_addr)));
            const sender_ip = @as(*const [4]u8, @ptrCast(&in_addr.addr));
            const sender_port = std.mem.bigToNative(u16, in_addr.port);

            std.debug.print("[udpecho] 收到 {d} 字节来自 {d}.{d}.{d}.{d}:{d}\n", .{
                n, sender_ip[0], sender_ip[1], sender_ip[2], sender_ip[3], sender_port,
            });

            // 原样回复
            _ = posix.sendto(self.fd, buf[0..n], 0, &src_addr, @sizeOf(posix.sockaddr.in)) catch |err| {
                log.info("[udpecho] 回复失败: {}", .{err});
            };
        }
    }
};

