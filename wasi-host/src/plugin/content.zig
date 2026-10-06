/// 插件内容寻址：字节码 ↔ SHA256 内容身份 ↔ DHT 分发/拉取。
///
/// 唯一归一化模块——Lua 宿主函数、控制通道 handler 都只消费本模块，
/// 不各自实现哈希/编码/校验约定。
///
/// 约定：
/// - 内容身份：SHA256(字节码) 的 64 字符小写十六进制
/// - DHT 键：  wasm/v1/<hex>
/// - 环位置：  SHA256(键字符串) 的前 20 字节（u160 大端）
/// - DHT 值：  标准 Base64(字节码)（JSON 只能承载文本）
/// - 所有者：  sha256/<hex>（内容派生，任何人发布相同字节码 owner 一致）
/// - 权限：    public_read
/// - 本地缓存：wasm-cache/<hex>.wasm
const std = @import("std");

const chord_node = @import("../p2p/chord/node.zig");
const ring = @import("../p2p/chord/ring.zig");
const meta_types = @import("../p2p/metadata/types.zig");
const Permission = meta_types.Permission;

pub const NodeId = ring.NodeId;

pub const HASH_HEX_LEN: usize = 64;

/// 单次可发布的最大原始字节：base64 膨胀 + JSON 信封须在单个 UDP 数据报（~65.5KB）内
pub const max_plugin_bytes: usize = 40 * 1024;

pub const cache_dir = "wasm-cache";

/// 进程内 ChordNode 引用（由 main 设置），供 Lua 宿主函数等无参路径取用
var global_chord: ?*chord_node.ChordNode = null;

pub fn setChord(c: ?*chord_node.ChordNode) void {
    global_chord = c;
}

pub fn getChord() ?*chord_node.ChordNode {
    return global_chord;
}

const b64_enc = std.base64.standard.Encoder;
const b64_dec = std.base64.standard.Decoder;

// ── 哈希 ─────────────────────────────────────────

pub fn hashBytes(bytes: []const u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(bytes);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

pub fn hashHex(bytes: []const u8) [HASH_HEX_LEN]u8 {
    return std.fmt.bytesToHex(&hashBytes(bytes), .lower);
}

pub fn isValidHash(s: []const u8) bool {
    if (s.len != HASH_HEX_LEN) return false;
    for (s) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        }
    }
    return true;
}

/// 接受大小写 hex，归一化为小写定长数组
pub fn normalizeHash(s: []const u8) ![HASH_HEX_LEN]u8 {
    if (!isValidHash(s)) return error.InvalidHash;
    var out: [HASH_HEX_LEN]u8 = undefined;
    for (s, 0..) |c, i| {
        out[i] = std.ascii.toLower(c);
    }
    return out;
}

// ── 键 / 环位置 ───────────────────────────────────

pub fn contentKey(alloc: std.mem.Allocator, hex: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "wasm/v1/{s}", .{hex});
}

pub fn contentOwner(alloc: std.mem.Allocator, hex: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "sha256/{s}", .{hex});
}

/// DHT 键字符串 → 环位置（SHA256 前 20 字节，大端）
pub fn keyToId(key: []const u8) NodeId {
    const h = hashBytes(key);
    var bytes: [20]u8 = undefined;
    @memcpy(&bytes, h[0..20]);
    return ring.idFromBytes(bytes);
}

// ── Base64 ────────────────────────────────────────

pub fn b64Encode(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, b64_enc.calcSize(bytes.len));
    _ = b64_enc.encode(out, bytes);
    return out;
}

pub fn b64Decode(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const decoded_len = b64_dec.calcSizeForSlice(trimmed) catch return error.InvalidBase64;
    const out = try alloc.alloc(u8, decoded_len);
    b64_dec.decode(out, trimmed) catch {
        alloc.free(out);
        return error.InvalidBase64;
    };
    return out;
}

// ── 本地磁盘缓存 ──────────────────────────────────

fn cachePath(alloc: std.mem.Allocator, hex: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}.wasm", .{ cache_dir, hex });
}

/// 读取本地缓存。返回 null 表示无缓存；若缓存内容与文件名哈希不符
/// （被篡改/截断）返回 error.CorruptCache，调用方应回退到 DHT 拉取。
pub fn readCache(alloc: std.mem.Allocator, hex: []const u8) !?[]u8 {
    const path = try cachePath(alloc, hex);
    defer alloc.free(path);
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();
    const bytes = try file.readToEndAlloc(alloc, max_plugin_bytes);

    // 缓存同样不可信：重算内容哈希比对
    const actual = hashHex(bytes);
    if (!std.mem.eql(u8, &actual, hex)) {
        alloc.free(bytes);
        return error.CorruptCache;
    }
    return bytes;
}

pub fn writeCache(hex: []const u8, bytes: []const u8) !void {
    std.fs.cwd().makePath(cache_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    const path = try cachePath(std.heap.page_allocator, hex);
    defer std.heap.page_allocator.free(path);

    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(bytes);
}

// ── DHT 发布 / 拉取 ───────────────────────────────

/// 发布字节码到内容键；返回内容 hash
pub fn publish(chord: *chord_node.ChordNode, alloc: std.mem.Allocator, bytes: []const u8) ![HASH_HEX_LEN]u8 {
    if (bytes.len == 0) return error.EmptyPlugin;
    if (bytes.len > max_plugin_bytes) return error.PluginTooLarge;

    const hex = hashHex(bytes);

    const key = try contentKey(alloc, &hex);
    defer alloc.free(key);
    const owner = try contentOwner(alloc, &hex);
    defer alloc.free(owner);
    const value_b64 = try b64Encode(alloc, bytes);
    defer alloc.free(value_b64);

    const target = try chord.locateKey(keyToId(key));

    const resp = try chord.sendAndWait(.{
        .dht_put = .{
            .key = key,
            .value = value_b64,
            .owner = owner,
            .permission = @intFromEnum(Permission.public_read),
            .version = 0,
            .timestamp = std.time.milliTimestamp(),
        },
    }, .dht_put_resp, target, 10_000);

    switch (resp) {
        .dht_put_resp => |body| {
            if (!body.ok) return error.PublishRejected;
        },
        else => return error.UnexpectedResponse,
    }
    return hex;
}

/// 从 DHT 拉取并验证；hash 不匹配即拒绝（防止持有节点以假内容应答）
pub fn fetch(chord: *chord_node.ChordNode, alloc: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (!isValidHash(hex)) return error.InvalidHash;

    const key = try contentKey(alloc, hex);
    defer alloc.free(key);

    const target = try chord.locateKey(keyToId(key));

    const resp = try chord.sendAndWait(.{
        .dht_get = .{ .key = key },
    }, .dht_get_resp, target, 10_000);

    const body = switch (resp) {
        .dht_get_resp => |b| b,
        else => return error.UnexpectedResponse,
    };
    if (!body.found) return error.NotFound;

    const bytes = try b64Decode(alloc, body.value);
    errdefer alloc.free(bytes);

    const got = hashHex(bytes);
    if (!std.mem.eql(u8, &got, hex)) return error.HashMismatch;

    return bytes;
}

test "hash hex roundtrip stable" {
    const hex = hashHex("hello");
    try std.testing.expect(isValidHash(&hex));
    // sha256("hello") 已知值
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", &hex);
}

test "normalize hash upper to lower" {
    const out = try normalizeHash("2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824");
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", &out);
}

test "b64 encode decode" {
    const alloc = std.testing.allocator;
    const data = "plugin bytes \x00\x01\x02\xff";
    const enc = try b64Encode(alloc, data);
    defer alloc.free(enc);
    const dec = try b64Decode(alloc, enc);
    defer alloc.free(dec);
    try std.testing.expectEqualStrings(data, dec);
}
