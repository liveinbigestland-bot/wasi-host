/// 3 副本同步：PUT 后向后继节点复制

const std = @import("std");
const meta_types = @import("types.zig");
const DHTEntry = meta_types.DHTEntry;

/// 副本系数
pub const REPLICA_COUNT = 3;

/// 副本管理器（纯逻辑，网络 I/O 由调用方处理）
pub const ReplicationManager = struct {
    alloc: std.mem.Allocator,
    /// 等待复制的条目队列
    pending: std.ArrayListUnmanaged(PendingReplica) = .{},

    pub const PendingReplica = struct {
        key: []u8,
        value: []u8,
        owner: []u8,
        permission: u8,
        version: u64,
        timestamp: i64,
        /// 已尝试的副本目标数
        attempted: u32 = 0,
    };

    pub fn init(alloc: std.mem.Allocator) ReplicationManager {
        return ReplicationManager{
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *ReplicationManager) void {
        for (self.pending.items) |item| {
            self.alloc.free(item.key);
            self.alloc.free(item.value);
            self.alloc.free(item.owner);
        }
        self.pending.deinit(self.alloc);
    }

    /// 将条目加入复制队列（PUT 成功后调用）
    pub fn enqueue(self: *ReplicationManager, entry: *const DHTEntry) !void {
        const item = PendingReplica{
            .key = try self.alloc.dupe(u8, entry.key),
            .value = try self.alloc.dupe(u8, entry.value),
            .owner = try self.alloc.dupe(u8, entry.owner),
            .permission = @intFromEnum(entry.permission),
            .version = entry.version,
            .timestamp = entry.timestamp,
            .attempted = 0,
        };
        try self.pending.append(self.alloc, item);
    }

    /// 获取下一个待复制的条目（返回 null 表示队列为空）
    pub fn next(self: *ReplicationManager) ?*PendingReplica {
        if (self.pending.items.len == 0) return null;
        return &self.pending.items[0];
    }

    /// 标记当前条目已成功复制到目标
    pub fn markAttempted(self: *ReplicationManager) void {
        if (self.pending.items.len == 0) return;
        self.pending.items[0].attempted += 1;
    }

    /// 当前条目是否已完成足够副本
    pub fn isCurrentDone(self: *ReplicationManager) bool {
        if (self.pending.items.len == 0) return true;
        return self.pending.items[0].attempted >= REPLICA_COUNT;
    }

    /// 完成当前条目（从队列移除）
    pub fn popFront(self: *ReplicationManager) void {
        if (self.pending.items.len == 0) return;
        const item = self.pending.orderedRemove(0);
        self.alloc.free(item.key);
        self.alloc.free(item.value);
        self.alloc.free(item.owner);
    }

    /// 清空队列
    pub fn clear(self: *ReplicationManager) void {
        for (self.pending.items) |item| {
            self.alloc.free(item.key);
            self.alloc.free(item.value);
            self.alloc.free(item.owner);
        }
        self.pending.clearRetainingCapacity();
    }

    /// 队列深度
    pub fn pendingCount(self: *ReplicationManager) usize {
        return self.pending.items.len;
    }
};

test "replication basic flow" {
    const alloc = std.testing.allocator;
    var mgr = ReplicationManager.init(alloc);
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 0), mgr.pendingCount());
    try std.testing.expectEqual(@as(?*ReplicationManager.PendingReplica, null), mgr.next());

    const entry = DHTEntry{
        .key = @constCast("k"),
        .value = @constCast("v"),
        .owner = @constCast("owner"),
        .permission = .public_read,
        .version = 1,
        .timestamp = 100,
    };
    try mgr.enqueue(&entry);
    try std.testing.expectEqual(@as(usize, 1), mgr.pendingCount());

    const item = mgr.next() orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 0), item.attempted);

    try std.testing.expect(!mgr.isCurrentDone());
    mgr.markAttempted();
    mgr.markAttempted();
    mgr.markAttempted();
    try std.testing.expect(mgr.isCurrentDone());

    mgr.popFront();
    try std.testing.expectEqual(@as(usize, 0), mgr.pendingCount());
}

test "replication multiple items FIFO order" {
    const alloc = std.testing.allocator;
    var mgr = ReplicationManager.init(alloc);
    defer mgr.deinit();

    const e1 = DHTEntry{ .key = @constCast("k1"), .value = @constCast("v1"), .owner = @constCast("o"), .permission = .public_read, .version = 1, .timestamp = 0 };
    const e2 = DHTEntry{ .key = @constCast("k2"), .value = @constCast("v2"), .owner = @constCast("o"), .permission = .public_read, .version = 2, .timestamp = 0 };
    const e3 = DHTEntry{ .key = @constCast("k3"), .value = @constCast("v3"), .owner = @constCast("o"), .permission = .public_read, .version = 3, .timestamp = 0 };

    try mgr.enqueue(&e1);
    try mgr.enqueue(&e2);
    try mgr.enqueue(&e3);
    try std.testing.expectEqual(@as(usize, 3), mgr.pendingCount());

    // Check FIFO order: k1, k2, k3
    {
        const item = mgr.next() orelse return error.TestFailed;
        try std.testing.expectEqualStrings("k1", item.key);
        // complete k1
        for (0..3) |_| mgr.markAttempted();
        mgr.popFront();
    }
    {
        const item = mgr.next() orelse return error.TestFailed;
        try std.testing.expectEqualStrings("k2", item.key);
        for (0..3) |_| mgr.markAttempted();
        mgr.popFront();
    }
    {
        const item = mgr.next() orelse return error.TestFailed;
        try std.testing.expectEqualStrings("k3", item.key);
        for (0..3) |_| mgr.markAttempted();
        mgr.popFront();
    }
    try std.testing.expect(mgr.next() == null);
}

test "replication clear empties queue" {
    const alloc = std.testing.allocator;
    var mgr = ReplicationManager.init(alloc);
    defer mgr.deinit();

    const e1 = DHTEntry{ .key = @constCast("k1"), .value = @constCast("v"), .owner = @constCast("o"), .permission = .public_read, .version = 1, .timestamp = 0 };
    const e2 = DHTEntry{ .key = @constCast("k2"), .value = @constCast("v"), .owner = @constCast("o"), .permission = .public_read, .version = 2, .timestamp = 0 };

    try mgr.enqueue(&e1);
    try mgr.enqueue(&e2);
    try std.testing.expectEqual(@as(usize, 2), mgr.pendingCount());

    mgr.clear();
    try std.testing.expectEqual(@as(usize, 0), mgr.pendingCount());
    try std.testing.expect(mgr.next() == null);
}
