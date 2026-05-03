/// Chord DHT 协议消息类型与编解码

const std = @import("std");
const ring = @import("ring.zig");
const NodeId = ring.NodeId;

/// Chord 协议消息类型
pub const MsgType = enum(u8) {
    ping = 1,
    pong = 2,
    find_successor = 3,
    find_successor_resp = 4,
    get_predecessor = 5,
    get_predecessor_resp = 6,
    notify = 7,
    notify_ok = 8,
    ping_req = 9,
    ping_resp = 10,
    dht_put = 11,
    dht_put_resp = 12,
    dht_get = 13,
    dht_get_resp = 14,
    dht_delete = 15,
    dht_delete_resp = 16,
    dht_replicate = 17,
    dht_replicate_resp = 18,
    get_identity = 19,
    identity_resp = 20,

    pub fn name(self: MsgType) []const u8 {
        return switch (self) {
            .ping => "ping",
            .pong => "pong",
            .find_successor => "find_successor",
            .find_successor_resp => "find_successor_resp",
            .get_predecessor => "get_predecessor",
            .get_predecessor_resp => "get_predecessor_resp",
            .notify => "notify",
            .notify_ok => "notify_ok",
            .ping_req => "ping_req",
            .ping_resp => "ping_resp",
            .dht_put => "dht_put",
            .dht_put_resp => "dht_put_resp",
            .dht_get => "dht_get",
            .dht_get_resp => "dht_get_resp",
            .dht_delete => "dht_delete",
            .dht_delete_resp => "dht_delete_resp",
            .dht_replicate => "dht_replicate",
            .dht_replicate_resp => "dht_replicate_resp",
            .get_identity => "get_identity",
            .identity_resp => "identity_resp",
        };
    }
};

/// Chord 协议消息（tagged union）
pub const Message = union(MsgType) {
    ping: void,
    pong: void,
    find_successor: struct { target: NodeId },
    find_successor_resp: struct { node_id: NodeId, node_addr: []const u8, node_port: u16, node_tcp_port: u16 = 0 },
    get_predecessor: void,
    get_predecessor_resp: struct { node_id: ?NodeId, node_addr: []const u8, node_port: u16, node_tcp_port: u16 = 0 },
    notify: struct { node_id: NodeId, node_addr: []const u8, node_port: u16, node_tcp_port: u16 = 0 },
    notify_ok: void,
    ping_req: void,
    ping_resp: void,
    dht_put: DhtPutReq,
    dht_put_resp: DhtPutResp,
    dht_get: DhtGetReq,
    dht_get_resp: DhtGetResp,
    dht_delete: DhtDeleteReq,
    dht_delete_resp: DhtDeleteResp,
    dht_replicate: DhtReplicateReq,
    dht_replicate_resp: DhtReplicateResp,
    get_identity: void,
    identity_resp: struct { node_id: NodeId, node_addr: []const u8, node_port: u16, node_tcp_port: u16 = 0 },

    pub fn encode(self: Message, alloc: std.mem.Allocator) ![]u8 {
        return std.json.stringifyAlloc(alloc, self, .{});
    }

    pub fn decode(data: []const u8, alloc: std.mem.Allocator) !Message {
        return try std.json.parseFromSliceLeaky(Message, alloc, data, .{ .allocate = .alloc_always });
    }
};

/// 网络地址信息
pub const NodeAddr = struct {
    id: NodeId,
    host: []const u8,
    port: u16,
    /// TCP 监听端口（0 = 不支持 TCP）
    tcp_port: u16 = 0,

    pub fn format(self: NodeAddr, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}:{d} (id={s})", .{
            self.host, self.port, ring.idToHex(self.id),
        });
    }
};

/// DHT PUT 请求
pub const DhtPutReq = struct {
    key: []const u8,
    value: []const u8,
    owner: []const u8,
    permission: u8,
    version: u64,
    timestamp: i64,
};

/// DHT PUT 响应
pub const DhtPutResp = struct {
    ok: bool,
    version: u64,
};

/// DHT GET 请求
pub const DhtGetReq = struct {
    key: []const u8,
};

/// DHT GET 响应
pub const DhtGetResp = struct {
    found: bool,
    key: []const u8,
    value: []const u8,
    owner: []const u8,
    permission: u8,
    version: u64,
    timestamp: i64,
};

/// DHT DELETE 请求
pub const DhtDeleteReq = struct {
    key: []const u8,
    owner: []const u8,
    signature: []const u8,
};

/// DHT DELETE 响应
pub const DhtDeleteResp = struct {
    ok: bool,
};

/// DHT 副本同步请求
pub const DhtReplicateReq = struct {
    key: []const u8,
    value: []const u8,
    owner: []const u8,
    permission: u8,
    version: u64,
    timestamp: i64,
};

/// DHT 副本同步响应
pub const DhtReplicateResp = struct {
    ok: bool,
};

/// 已知节点信息（用于路由表、缓存）
pub const PeerInfo = struct {
    id: NodeId,
    host: []const u8,
    port: u16,
    tcp_port: u16 = 0,
    last_seen: i64, // 毫秒时间戳
    fail_count: u32,

    pub fn addr(self: PeerInfo) NodeAddr {
        return .{ .id = self.id, .host = self.host, .port = self.port, .tcp_port = self.tcp_port };
    }
};

test "message encode decode roundtrip" {
    const alloc = std.testing.allocator;
    const msg = Message{ .find_successor = .{ .target = 0xabc } };
    const encoded = try msg.encode(alloc);
    defer alloc.free(encoded);

    const decoded = try Message.decode(encoded, alloc);
    try std.testing.expectEqual(MsgType.find_successor, decoded);
    switch (decoded) {
        .find_successor => |body| try std.testing.expectEqual(@as(NodeId, 0xabc), body.target),
        else => unreachable,
    }
}
