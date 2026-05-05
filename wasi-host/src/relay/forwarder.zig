/// 密文透传转发引擎
/// 只读目标 NodeID（20 字节）路由字段，其余字节原样透传，零解析。
const std = @import("std");
const posix = std.posix;

const Registry = @import("registry.zig").Registry;
const NodeID = @import("registry.zig").NodeID;

pub const HEADER_LEN: usize = 20;

pub const ForwarderOptions = struct {
    max_packet_size: usize = 1400,
};

pub const Forwarder = struct {
    alloc: std.mem.Allocator,
    max_packet_size: usize,

    pub fn init(alloc: std.mem.Allocator, opts: ForwarderOptions) Forwarder {
        return Forwarder{
            .alloc = alloc,
            .max_packet_size = opts.max_packet_size,
        };
    }

    pub fn deinit(_: *Forwarder) void {}

    /// 转发 UDP 数据报
    /// udp_fd: 中继的 UDP socket（用于 sendto）
    /// data: 收到的完整数据报 [target NodeID 20] + [加密负载]
    /// sender_addr: 发送方的 UDP 地址
    pub fn forwardUDP(self: *Forwarder, registry: *Registry, udp_fd: posix.socket_t, data: []const u8, sender_addr: std.net.Address) !void {
        if (data.len < HEADER_LEN) return error.PacketTooShort;
        if (data.len > self.max_packet_size) return error.PacketTooLarge;

        var target_id: NodeID = undefined;
        @memcpy(&target_id, data[0..HEADER_LEN]);

        const sender = registry.getByUdpAddr(sender_addr) orelse return error.SenderNotRegistered;
        if (sender.state != .active) return error.SenderNotAuthenticated;
        if (!registry.checkRateLimit(sender.node_id)) return error.RateLimited;

        const target = registry.get(target_id) orelse return error.TargetOffline;
        if (target.state != .active) return error.TargetOffline;
        const target_addr = target.udp_addr orelse return error.TargetAddressUnknown;

        std.debug.print("[relay2/fwd] sendto target_port={d}\n", .{target_addr.getPort()});
        _ = posix.sendto(udp_fd, data, 0, &target_addr.any, target_addr.getOsSockLen()) catch |err| {
            std.debug.print("[relay2/fwd] sendto error: {}\n", .{err});
            return err;
        };
    }

    /// 转发 TCP 数据帧
    /// target_fd: 目标节点的 TCP 连接 fd
    /// data: [target NodeID 20] + [加密负载]
    pub fn forwardTCP(self: *Forwarder, registry: *Registry, target_fd: posix.socket_t, data: []const u8) !void {
        if (data.len < HEADER_LEN) return error.PacketTooShort;
        if (data.len > self.max_packet_size) return error.PacketTooLarge;

        var target_id: NodeID = undefined;
        @memcpy(&target_id, data[0..HEADER_LEN]);

        const target = registry.get(target_id) orelse return error.TargetOffline;
        if (target.state != .active) return error.TargetOffline;

        // 原样字节拷贝转发
        _ = try posix.write(target_fd, data[HEADER_LEN..]);
    }
};
