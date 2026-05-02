/// 三级权限校验

const std = @import("std");
const meta_types = @import("types.zig");
const DHTEntry = meta_types.DHTEntry;
const Permission = meta_types.Permission;

/// 权限校验结果
pub const PermissionResult = enum {
    allowed,
    denied_private,
    denied_not_owner,
};

/// 检查是否可读
pub fn checkRead(entry: *const DHTEntry, caller_pk: []const u8) PermissionResult {
    const is_owner = std.mem.eql(u8, entry.owner, caller_pk);
    if (entry.permission.canRead(is_owner, false)) {
        return .allowed;
    }
    return if (entry.permission == .private) .denied_private else .denied_not_owner;
}

/// 检查是否可写
pub fn checkWrite(entry: *const DHTEntry, caller_pk: []const u8) PermissionResult {
    const is_owner = std.mem.eql(u8, entry.owner, caller_pk);
    if (entry.permission.canWrite(is_owner)) {
        return .allowed;
    }
    return .denied_not_owner;
}

/// 为新 PUT 检查写入权限（条目不存在时始终允许创建）
pub fn checkPutNew(caller_pk: []const u8) PermissionResult {
    _ = caller_pk;
    // 任何人都可以创建新条目（成为 owner）
    return .allowed;
}

/// 验证 owner 身份是否匹配公钥
pub fn verifyOwnership(entry_owner: []const u8, claimed_pk: []const u8) bool {
    return std.mem.eql(u8, entry_owner, claimed_pk);
}

test "checkRead checkWrite for owner vs non-owner" {
    const owner_pk = "pk-owner";
    const other_pk = "pk-other";

    // Setup: owner creates a private entry
    var entry = DHTEntry{
        .key = @constCast("k"),
        .value = @constCast("v"),
        .owner = @constCast(owner_pk),
        .permission = Permission.private,
        .version = 1,
        .timestamp = 0,
    };
    defer entry.deinit(std.testing.allocator);

    // Owner can always read/write
    try std.testing.expectEqual(PermissionResult.allowed, checkRead(&entry, owner_pk));
    try std.testing.expectEqual(PermissionResult.allowed, checkWrite(&entry, owner_pk));

    // Non-owner read blocked on private
    try std.testing.expectEqual(PermissionResult.denied_private, checkRead(&entry, other_pk));
    try std.testing.expectEqual(PermissionResult.denied_not_owner, checkWrite(&entry, other_pk));

    // public_read: non-owner can read, but still cannot write
    entry.permission = Permission.public_read;
    try std.testing.expectEqual(PermissionResult.allowed, checkRead(&entry, other_pk));
    try std.testing.expectEqual(PermissionResult.denied_not_owner, checkWrite(&entry, other_pk));

    // group: non-owner non-group-member blocked
    entry.permission = Permission.group;
    try std.testing.expectEqual(PermissionResult.denied_not_owner, checkRead(&entry, other_pk));
    try std.testing.expectEqual(PermissionResult.denied_not_owner, checkWrite(&entry, other_pk));
}

test "checkPutNew always allowed" {
    try std.testing.expectEqual(PermissionResult.allowed, checkPutNew("anyone"));
    try std.testing.expectEqual(PermissionResult.allowed, checkPutNew(""));
}

test "verifyOwnership" {
    try std.testing.expect(verifyOwnership("pk1", "pk1"));
    try std.testing.expect(!verifyOwnership("pk1", "pk2"));
    try std.testing.expect(!verifyOwnership("pk1", ""));
}
