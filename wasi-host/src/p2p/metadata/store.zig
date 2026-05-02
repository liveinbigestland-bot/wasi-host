/// DHT KV 存储：内存 HashMap + 文件持久化

const std = @import("std");
const meta_types = @import("types.zig");
const DHTEntry = meta_types.DHTEntry;
const Permission = meta_types.Permission;

/// 最大条目大小（64KB）
pub const MAX_ENTRY_SIZE = 64 * 1024;

/// DHT KV 存储
pub const KVStore = struct {
    alloc: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(DHTEntry),
    data_dir: []const u8,
    dirty: bool,
    next_version: u64,

    pub fn init(alloc: std.mem.Allocator, data_dir: []const u8) KVStore {
        return KVStore{
            .alloc = alloc,
            .map = .{},
            .data_dir = data_dir,
            .dirty = false,
            .next_version = 1,
        };
    }

    pub fn deinit(self: *KVStore) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.alloc);
        }
        self.map.deinit(self.alloc);
        if (self.data_dir.len > 0) {
            self.alloc.free(self.data_dir);
        }
    }

    /// 加载持久化数据
    pub fn load(self: *KVStore) !void {
        if (self.data_dir.len == 0) return;
        const path = try std.fs.path.join(self.alloc, &.{ self.data_dir, "dht_store.json" });
        defer self.alloc.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        const data = try file.readToEndAlloc(self.alloc, 1024 * 1024);
        defer self.alloc.free(data);

        if (data.len == 0) return;

        const snapshot = try std.json.parseFromSliceLeaky(meta_types.StoreSnapshot, self.alloc, data, .{ .allocate = .alloc_always });
        for (snapshot.entries) |entry| {
            const key_copy = try self.alloc.dupe(u8, entry.key);
            errdefer self.alloc.free(key_copy);
            try self.map.put(self.alloc, key_copy, entry);
            if (entry.version >= self.next_version) {
                self.next_version = entry.version + 1;
            }
        }
        std.debug.print("[store] 已加载 {d} 条记录\n", .{snapshot.entries.len});
    }

    /// 持久化到磁盘
    pub fn save(self: *KVStore) !void {
        if (!self.dirty or self.data_dir.len == 0) return;
        self.dirty = false;

        // 确保目录存在
        std.fs.cwd().makeDir(self.data_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // 收集所有条目
        var entries = std.ArrayList(DHTEntry).init(self.alloc);
        defer entries.deinit();

        var it = self.map.iterator();
        while (it.next()) |entry| {
            try entries.append(entry.value_ptr.*);
        }

        const snapshot = meta_types.StoreSnapshot{ .entries = entries.items };
        const json_bytes = try std.json.stringifyAlloc(self.alloc, snapshot, .{});
        defer self.alloc.free(json_bytes);

        const path = try std.fs.path.join(self.alloc, &.{ self.data_dir, "dht_store.json" });
        defer self.alloc.free(path);

        const tmp_path = try std.fs.path.join(self.alloc, &.{ self.data_dir, "dht_store.json.tmp" });
        defer self.alloc.free(tmp_path);

        var file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();

        try file.writeAll(json_bytes);
        try file.sync();

        std.fs.cwd().rename(tmp_path, path) catch |err| {
            std.debug.print("[store] 重命名持久化文件失败: {}\n", .{err});
        };
    }

    /// PUT 条目
    pub fn put(self: *KVStore, key: []const u8, value: []const u8, owner: []const u8, permission: Permission) !DHTEntry {
        if (key.len == 0 or key.len > MAX_ENTRY_SIZE) return error.InvalidKey;
        if (value.len > MAX_ENTRY_SIZE) return error.ValueTooLarge;

        const version = self.next_version;
        self.next_version += 1;

        // 如果已存在，释放旧内存
        if (self.map.getPtr(key)) |old| {
            old.deinit(self.alloc);
        }

        const entry = DHTEntry{
            .key = try self.alloc.dupe(u8, key),
            .value = try self.alloc.dupe(u8, value),
            .owner = try self.alloc.dupe(u8, owner),
            .permission = permission,
            .version = version,
            .timestamp = std.time.milliTimestamp(),
        };

        try self.map.put(self.alloc, try self.alloc.dupe(u8, key), entry);
        self.dirty = true;

        return entry;
    }

    /// GET 条目
    pub fn get(self: *KVStore, key: []const u8) ?DHTEntry {
        const entry = self.map.get(key) orelse return null;
        // 返回副本以保证调用方可以安全使用
        return entry;
    }

    /// DELETE 条目
    pub fn delete(self: *KVStore, key: []const u8) bool {
        if (self.map.fetchRemove(key)) |kv| {
            var entry = kv.value;
            entry.deinit(self.alloc);
            self.alloc.free(kv.key);
            self.dirty = true;
            return true;
        }
        return false;
    }

    /// 检查键是否存在
    pub fn exists(self: *KVStore, key: []const u8) bool {
        return self.map.contains(key);
    }

    /// 获取条目数
    pub fn count(self: *KVStore) usize {
        return self.map.count();
    }

    /// 获取所有键（用于调试）
    pub fn keys(self: *KVStore, alloc: std.mem.Allocator) ![][]const u8 {
        var list = std.ArrayList([]const u8).init(alloc);
        var it = self.map.iterator();
        while (it.next()) |entry| {
            try list.append(entry.key_ptr.*);
        }
        return list.items;
    }
};

test "kvstore put get delete" {
    const alloc = std.testing.allocator;
    var store = KVStore.init(alloc, "");
    defer store.deinit();

    const entry = try store.put("key1", "value1", "owner1", Permission.public_read);
    try std.testing.expectEqual(@as(u64, 1), entry.version);

    const got = store.get("key1") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("key1", got.key);
    try std.testing.expectEqualStrings("value1", got.value);
    try std.testing.expectEqualStrings("owner1", got.owner);
    try std.testing.expectEqual(Permission.public_read, got.permission);

    const deleted = store.delete("key1");
    try std.testing.expect(deleted);
    try std.testing.expectEqual(@as(?DHTEntry, null), store.get("key1"));

    try std.testing.expect(!store.delete("nonexistent"));
}

test "kvstore exists count" {
    const alloc = std.testing.allocator;
    var store = KVStore.init(alloc, "");
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 0), store.count());
    try std.testing.expect(!store.exists("key1"));

    _ = try store.put("key1", "v1", "owner", Permission.private);
    _ = try store.put("key2", "v2", "owner", Permission.group);

    try std.testing.expectEqual(@as(usize, 2), store.count());
    try std.testing.expect(store.exists("key1"));
    try std.testing.expect(store.exists("key2"));
    try std.testing.expect(!store.exists("key3"));
}

test "kvstore replace same key" {
    const alloc = std.testing.allocator;
    var store = KVStore.init(alloc, "");
    defer store.deinit();

    const e1 = try store.put("k", "v1", "owner", Permission.public_read);
    try std.testing.expectEqual(@as(u64, 1), e1.version);

    const e2 = try store.put("k", "v2", "owner", Permission.private);
    try std.testing.expectEqual(@as(u64, 2), e2.version);

    const got = store.get("k") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("v2", got.value);
    try std.testing.expectEqual(Permission.private, got.permission);
    try std.testing.expectEqual(@as(u64, 2), got.version);
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "kvstore persistence save load" {
    const alloc = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data_dir = tmp_dir.dir.realpathAlloc(alloc, ".") catch return error.SkipZigTest;
    defer alloc.free(data_dir);

    // Save phase
    {
        var store = KVStore.init(alloc, data_dir);
        defer store.deinit();

        _ = try store.put("k1", "v1", "owner", Permission.public_read);
        _ = try store.put("k2", "v2", "owner", Permission.private);
        store.dirty = true;
        try store.save();
    }

    // Load phase — verify data survived
    {
        var store = KVStore.init(alloc, data_dir);
        defer store.deinit();
        try store.load();

        try std.testing.expectEqual(@as(usize, 2), store.count());

        const g1 = store.get("k1") orelse return error.TestFailed;
        try std.testing.expectEqualStrings("v1", g1.value);
        try std.testing.expectEqual(Permission.public_read, g1.permission);

        const g2 = store.get("k2") orelse return error.TestFailed;
        try std.testing.expectEqualStrings("v2", g2.value);
        try std.testing.expectEqual(Permission.private, g2.permission);
    }
}

test "kvstore version tracking across saves" {
    const alloc = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data_dir = tmp_dir.dir.realpathAlloc(alloc, ".") catch return error.SkipZigTest;
    defer alloc.free(data_dir);

    {
        var store = KVStore.init(alloc, data_dir);
        defer store.deinit();
        _ = try store.put("k1", "v1", "owner", Permission.public_read);
        _ = try store.put("k2", "v2", "owner", Permission.public_read);
        store.dirty = true;
        try store.save();
    }
    // next_version should continue from where it left off
    {
        var store = KVStore.init(alloc, data_dir);
        defer store.deinit();
        try store.load();

        const e = try store.put("k3", "v3", "owner", Permission.public_read);
        // After 2 entries, next_version should be 3
        try std.testing.expectEqual(@as(u64, 3), e.version);
    }
}
