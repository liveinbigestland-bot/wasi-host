/// 守护进程使用的 DHT 类型（独立于 p2p 模块，避免编译依赖）
const std = @import("std");

/// 160-bit 节点 ID
pub const NodeId = u160;

/// 将 NodeId 格式化为 40 字符十六进制字符串
pub fn idToHex(id: NodeId) [40]u8 {
    var bytes: [20]u8 = undefined;
    std.mem.writeInt(NodeId, &bytes, id, .big);
    return std.fmt.bytesToHex(&bytes, .lower);
}

/// 将十六进制字符串解析为 NodeId
pub fn idFromHex(hex: []const u8) !NodeId {
    if (hex.len < 40) return error.InvalidIdLength;
    var bytes: [20]u8 = undefined;
    for (0..20) |i| {
        bytes[i] = try std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16);
    }
    return std.mem.readInt(NodeId, &bytes, .big);
}
