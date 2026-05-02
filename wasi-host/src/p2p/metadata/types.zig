/// DHT 元数据：权限、条目结构、序列化

const std = @import("std");

/// 三级权限
pub const Permission = enum(u8) {
    private = 0,
    group = 1,
    public_read = 2,

    pub fn canRead(self: Permission, is_owner: bool, is_group_member: bool) bool {
        return switch (self) {
            .private => is_owner,
            .group => is_owner or is_group_member,
            .public_read => true,
        };
    }

    pub fn canWrite(self: Permission, is_owner: bool) bool {
        _ = self;
        return is_owner;
    }

    pub fn fromU8(v: u8) Permission {
        return switch (v) {
            0 => .private,
            1 => .group,
            2 => .public_read,
            else => .private,
        };
    }
};

/// DHT 存储条目
pub const DHTEntry = struct {
    key: []u8,
    value: []u8,
    owner: []u8,
    permission: Permission,
    version: u64,
    timestamp: i64,

    pub fn deinit(self: *DHTEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.key);
        alloc.free(self.value);
        alloc.free(self.owner);
    }

    /// 序列化为 JSON
    pub fn encode(self: DHTEntry, alloc: std.mem.Allocator) ![]u8 {
        return std.json.stringifyAlloc(alloc, self, .{});
    }

    /// 从 JSON 反序列化
    pub fn decode(data: []const u8, alloc: std.mem.Allocator) !DHTEntry {
        return try std.json.parseFromSliceLeaky(DHTEntry, alloc, data, .{ .allocate = .alloc_always });
    }
};

/// 存储持久化格式（JSON 数组）
pub const StoreSnapshot = struct {
    entries: []DHTEntry,
};

test "permission canRead/canWrite" {
    // canRead truth table:
    // permission     is_owner  is_group   → result
    // private       true      any        → true
    // private       false     true       → false
    // private       false     false      → false
    // group         true      any        → true
    // group         false     true       → true
    // group         false     false      → false
    // public_read   any       any        → true
    try std.testing.expect(Permission.private.canRead(true, false));
    try std.testing.expect(Permission.private.canRead(true, true));
    try std.testing.expect(!Permission.private.canRead(false, true));
    try std.testing.expect(!Permission.private.canRead(false, false));

    try std.testing.expect(Permission.group.canRead(true, false));
    try std.testing.expect(Permission.group.canRead(true, true));
    try std.testing.expect(Permission.group.canRead(false, true));
    try std.testing.expect(!Permission.group.canRead(false, false));

    try std.testing.expect(Permission.public_read.canRead(false, false));
    try std.testing.expect(Permission.public_read.canRead(true, false));
    try std.testing.expect(Permission.public_read.canRead(false, true));

    // canWrite: only owner can write, regardless of permission level
    try std.testing.expect(Permission.private.canWrite(true));
    try std.testing.expect(!Permission.private.canWrite(false));
    try std.testing.expect(Permission.group.canWrite(true));
    try std.testing.expect(!Permission.group.canWrite(false));
    try std.testing.expect(Permission.public_read.canWrite(true));
    try std.testing.expect(!Permission.public_read.canWrite(false));
}

test "permission fromU8" {
    try std.testing.expectEqual(Permission.private, Permission.fromU8(0));
    try std.testing.expectEqual(Permission.group, Permission.fromU8(1));
    try std.testing.expectEqual(Permission.public_read, Permission.fromU8(2));
    // invalid values default to private
    try std.testing.expectEqual(Permission.private, Permission.fromU8(99));
    try std.testing.expectEqual(Permission.private, Permission.fromU8(255));
}

test "dhtEntry encode decode roundtrip" {
    const alloc = std.testing.allocator;

    var original = DHTEntry{
        .key = try alloc.dupe(u8, "test-key"),
        .value = try alloc.dupe(u8, "test-value"),
        .owner = try alloc.dupe(u8, "owner-pk-hex"),
        .permission = Permission.public_read,
        .version = 42,
        .timestamp = 1234567890,
    };
    defer original.deinit(alloc);

    const encoded = try original.encode(alloc);
    defer alloc.free(encoded);

    var decoded = try DHTEntry.decode(encoded, alloc);
    defer decoded.deinit(alloc);

    try std.testing.expectEqualStrings(original.key, decoded.key);
    try std.testing.expectEqualStrings(original.value, decoded.value);
    try std.testing.expectEqualStrings(original.owner, decoded.owner);
    try std.testing.expectEqual(original.permission, decoded.permission);
    try std.testing.expectEqual(original.version, decoded.version);
    try std.testing.expectEqual(original.timestamp, decoded.timestamp);
}
