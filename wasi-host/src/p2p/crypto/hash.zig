/// 哈希工具：SHA-1（Chord 环 ID）和 SHA-256（大库完整性）

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha1 = std.crypto.hash.Sha1;

pub const Sha1Digest = [Sha1.digest_length]u8;
pub const Sha256Digest = [Sha256.digest_length]u8;

/// 计算 SHA-1 哈希（用于 Chord 节点 ID）
pub fn sha1(data: []const u8) Sha1Digest {
    var h = Sha1.init(.{});
    h.update(data);
    var out: Sha1Digest = undefined;
    h.final(&out);
    return out;
}

/// 计算 SHA-256 哈希
pub fn sha256(data: []const u8) Sha256Digest {
    var h = Sha256.init(.{});
    h.update(data);
    var out: Sha256Digest = undefined;
    h.final(&out);
    return out;
}

/// 流式 SHA-256 计算器（用于大文件分块校验）
pub fn Sha256Stream() Sha256 {
    return Sha256.init(.{});
}

test "sha1 basic" {
    const result = sha1("hello");
    try std.testing.expectEqual(@as(usize, 20), result.len);
}

test "sha256 basic" {
    const result = sha256("hello");
    try std.testing.expectEqual(@as(usize, 32), result.len);
}

test "sha256 stream" {
    var stream = Sha256Stream();
    stream.update("hello ");
    stream.update("world");
    var out: Sha256Digest = undefined;
    stream.final(&out);
    const expected = sha256("hello world");
    try std.testing.expectEqualSlices(u8, &expected, &out);
}
