/// Chord 160bit 哈希环基础类型与操作

const std = @import("std");

/// Chord 环节点 / 数据 Key 的 ID 类型（SHA-1, 160bit）
pub const NodeId = u160;

/// Chord 环的位数
pub const M: u8 = 160;

/// 将 [20]u8（大端）转换为 NodeId
pub fn idFromBytes(bytes: [20]u8) NodeId {
    return std.mem.readInt(NodeId, &bytes, .big);
}

/// 将 NodeId 转换为 [20]u8（大端）
pub fn idToBytes(id: NodeId) [20]u8 {
    var bytes: [20]u8 = undefined;
    std.mem.writeInt(NodeId, &bytes, id, .big);
    return bytes;
}

/// 将 NodeId 格式化为 40 字符十六进制字符串
pub fn idToHex(id: NodeId) [40]u8 {
    const bytes = idToBytes(id);
    return std.fmt.bytesToHex(&bytes, .lower);
}

/// 将十六进制字符串解析为 NodeId
pub fn idFromHex(hex: []const u8) !NodeId {
    if (hex.len < 40) return error.InvalidIdLength;
    var bytes: [20]u8 = undefined;
    for (0..20) |i| {
        bytes[i] = try std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16);
    }
    return idFromBytes(bytes);
}

/// 顺时针距离：(b - a) mod 2^160
pub fn distance(a: NodeId, b: NodeId) NodeId {
    return b -% a;
}

/// 判断 x 是否属于 (left, right] 顺时针区间
pub fn between(x: NodeId, left: NodeId, right: NodeId) bool {
    if (left == right) return x == left;
    if (left < right) return left < x and x <= right;
    return left < x or x <= right; // 环回绕
}

/// 判断 x 是否属于 [left, right)
pub fn betweenLeftInclusive(x: NodeId, left: NodeId, right: NodeId) bool {
    if (left == right) return x == left;
    if (left < right) return left <= x and x < right;
    return left <= x or x < right;
}

/// 计算 finger[i].start = (id + 2^i) mod 2^160, i ∈ [0, 160)
pub fn fingerStart(id: NodeId, index: u8) NodeId {
    const shift: u7 = @truncate(index);
    const power = @as(NodeId, 1) << @as(std.math.Log2Int(NodeId), shift);
    return id +% power;
}

test "idFromBytes idToBytes roundtrip" {
    const original: NodeId = 0xabcdef1234567890abcdef1234567890abcdef12;
    const bytes = idToBytes(original);
    const recovered = idFromBytes(bytes);
    try std.testing.expectEqual(original, recovered);
}

test "idToHex" {
    const id: NodeId = 0xab;
    const hex = idToHex(id);
    try std.testing.expectEqual(40, hex.len);
    // first byte 0xab → "ab", rest are 0x00 → "00"
    try std.testing.expectEqual('a', hex[0]);
    try std.testing.expectEqual('b', hex[1]);
    try std.testing.expectEqual('0', hex[2]);
}

test "between no wrap" {
    // 正常区间：50 ∈ (40, 100]
    try std.testing.expect(between(50, 40, 100));
    try std.testing.expect(!between(30, 40, 100));
    try std.testing.expect(!between(120, 40, 100));
}

test "between wrap around" {
    // 回绕区间：200 ∈ (250, 100]
    try std.testing.expect(between(200, 250, 100));
    try std.testing.expect(!between(150, 250, 100));
}

test "between equal bounds" {
    try std.testing.expect(between(42, 42, 42));
    try std.testing.expect(!between(43, 42, 42));
}

test "fingerStart" {
    const id: NodeId = 100;
    // finger[0].start = (100 + 1) % 2^160
    try std.testing.expectEqual(@as(NodeId, 101), fingerStart(id, 0));
    // finger[1].start = (100 + 2) % 2^160
    try std.testing.expectEqual(@as(NodeId, 102), fingerStart(id, 1));
    // finger[2].start = (100 + 4) % 2^160
    try std.testing.expectEqual(@as(NodeId, 104), fingerStart(id, 2));
}

test "distance" {
    try std.testing.expectEqual(@as(NodeId, 50), distance(100, 150));
    try std.testing.expectEqual(@as(NodeId, 30), distance(200, 30)); // wrap: (30 + 2^160 - 200)
}
