/// P2P 宿主函数：给 WASM 插件调用 DHT 能力

const std = @import("std");
const wasm3 = @cImport({
    @cInclude("wasm3.h");
});

const chord_node = @import("../p2p/chord/node.zig");
const chord_types = @import("../p2p/chord/types.zig");
const meta_types = @import("../p2p/metadata/types.zig");
const Permission = meta_types.Permission;

const ChordNode = chord_node.ChordNode;
const Message = chord_types.Message;

/// 从 wasm3 运行时获取 Chord 节点指针
fn getChordNode(runtime: wasm3.IM3Runtime) ?*ChordNode {
    const userdata = wasm3.m3_GetUserData(runtime);
    return @as(?*ChordNode, @ptrCast(@alignCast(userdata)));
}

/// 从 WASM 线性内存读取字符串
fn readWasmMem(runtime: wasm3.IM3Runtime, ptr: u32, len: u32) []const u8 {
    var mem_size: u32 = 0;
    const mem = wasm3.m3_GetMemory(runtime, &mem_size, 0) orelse return "";
    if (ptr + len > mem_size) return "";
    return mem[ptr .. ptr + len];
}

/// 向 WASM 线性内存写入数据，返回写入的指针
/// 使用 64KB 偏移处，避免与 WASM 数据段（<16KB）和栈（顶部）冲突
fn writeWasmMem(runtime: wasm3.IM3Runtime, data: []const u8) u32 {
    var mem_size: u32 = 0;
    const mem = wasm3.m3_GetMemory(runtime, &mem_size, 0) orelse return 0;
    const offset = 64 * 1024;
    if (data.len == 0 or offset + data.len > mem_size) return 0;
    @memcpy(mem[offset..][0..data.len], data);
    return @intCast(offset);
}

/// wasm3 原始调用栈访问：sp[0]=返回值槽, sp[1]=第1个参数, sp[2]=第2个参数, ...
fn spParam(sp: ?*u64, index: usize) u64 {
    const arr = @as([*]u64, @ptrCast(@alignCast(sp.?)));
    return arr[index];
}

fn setRet(sp: ?*u64, val: i32) void {
    @as(*i32, @ptrCast(@alignCast(sp.?))).* = val;
}

/// 计算 key 的 SHA-1 哈希（与 Chord ID 生成一致）
fn hashKey(key: []const u8) [20]u8 {
    var ctx = std.crypto.hash.Sha1.init(.{});
    ctx.update(key);
    return ctx.finalResult();
}

/// dht_get(key_ptr: i32, key_len: i32) → value_ptr: i32
/// 从 DHT 获取值，返回指向 WASM 内存中 JSON 字符串的指针（0=未找到）
pub fn host_dht_get(rt: ?*anyopaque, _: ?*anyopaque, sp: ?*u64, _: ?*anyopaque) callconv(.C) ?*const anyopaque {
    const runtime = @as(wasm3.IM3Runtime, @ptrCast(rt));
    const chord = getChordNode(runtime) orelse {
        setRet(sp, 0);
        return null;
    };

    const key_ptr = @as(u32, @truncate(spParam(sp, 1)));
    const key_len = @as(u32, @truncate(spParam(sp, 2)));
    const key = readWasmMem(runtime, key_ptr, key_len);
    if (key.len == 0) {
        setRet(sp, 0);
        return null;
    }

    const key_id = hashKey(key);
    const target = chord.routing.findSuccessor(std.mem.readInt(u160, &key_id, .big));

    // 本地查询
    const is_local = target.id == chord.own_id or
        (std.mem.eql(u8, target.host, chord.own_host) and target.port == chord.own_port);

    if (is_local) {
        if (chord.store.get(key)) |entry| {
            if (entry.permission == .public_read or entry.permission == .group) {
                const json = std.json.stringifyAlloc(std.heap.page_allocator, .{
                    .found = true,
                    .key = entry.key,
                    .value = entry.value,
                    .owner = entry.owner,
                    .permission = @intFromEnum(entry.permission),
                    .version = entry.version,
                }, .{}) catch {
                    setRet(sp, 0);
                    return null;
                };
                defer std.heap.page_allocator.free(json);
                setRet(sp, @intCast(writeWasmMem(runtime, json)));
                return null;
            }
        }
        setRet(sp, 0);
        return null;
    }

    // 远程查询
    const resp = chord.sendAndWait(Message{ .dht_get = .{ .key = key } }, .dht_get_resp, target, 5000) catch {
        setRet(sp, 0);
        return null;
    };

    switch (resp) {
        .dht_get_resp => |body| {
            if (body.found) {
                const json = std.json.stringifyAlloc(std.heap.page_allocator, .{
                    .found = true,
                    .key = body.key,
                    .value = body.value,
                    .owner = body.owner,
                    .permission = body.permission,
                    .version = body.version,
                }, .{}) catch {
                    setRet(sp, 0);
                    return null;
                };
                defer std.heap.page_allocator.free(json);
                setRet(sp, @intCast(writeWasmMem(runtime, json)));
            } else {
                setRet(sp, 0);
            }
        },
        else => setRet(sp, 0),
    }
    return null;
}

/// dht_put(key_ptr, key_len, value_ptr, value_len, permission) → i32(0=ok, 1=err)
pub fn host_dht_put(rt: ?*anyopaque, _: ?*anyopaque, sp: ?*u64, _: ?*anyopaque) callconv(.C) ?*const anyopaque {
    const runtime = @as(wasm3.IM3Runtime, @ptrCast(rt));
    const chord = getChordNode(runtime) orelse {
        setRet(sp, 1);
        return null;
    };

    const key_ptr = @as(u32, @truncate(spParam(sp, 1)));
    const key_len = @as(u32, @truncate(spParam(sp, 2)));
    const value_ptr = @as(u32, @truncate(spParam(sp, 3)));
    const value_len = @as(u32, @truncate(spParam(sp, 4)));
    const permission = @as(u32, @truncate(spParam(sp, 5)));

    const key = readWasmMem(runtime, key_ptr, key_len);
    const value = readWasmMem(runtime, value_ptr, value_len);

    if (key.len == 0 or value.len == 0) {
        setRet(sp, 1);
        return null;
    }

    const perm = Permission.fromU8(@as(u8, @truncate(permission)));
    const key_id = hashKey(key);
    const target = chord.routing.findSuccessor(std.mem.readInt(u160, &key_id, .big));

    const is_local = target.id == chord.own_id or
        (std.mem.eql(u8, target.host, chord.own_host) and target.port == chord.own_port);

    if (is_local) {
        _ = chord.store.put(key, value, chord.own_pk_hex, perm) catch {
            setRet(sp, 1);
            return null;
        };
        if (chord.store.get(key)) |entry| {
            chord.replication_mgr.enqueue(&entry) catch {};
        }
        std.debug.print("[p2p_bindings] dht_put: key={s} 已存储\n", .{key});
        setRet(sp, 0);
        return null;
    }

    const resp = chord.sendAndWait(Message{ .dht_put = .{
        .key = key, .value = value, .owner = chord.own_pk_hex,
        .permission = @intFromEnum(perm), .version = 0,
        .timestamp = std.time.milliTimestamp(),
    } }, .dht_put_resp, target, 5000) catch {
        setRet(sp, 1);
        return null;
    };

    switch (resp) {
        .dht_put_resp => |body| setRet(sp, if (body.ok) 0 else 1),
        else => setRet(sp, 1),
    }
    return null;
}

/// node_info() → ptr: i32
pub fn host_node_info(rt: ?*anyopaque, _: ?*anyopaque, sp: ?*u64, _: ?*anyopaque) callconv(.C) ?*const anyopaque {
    const runtime = @as(wasm3.IM3Runtime, @ptrCast(rt));
    const chord = getChordNode(runtime) orelse {
        setRet(sp, 0);
        return null;
    };

    const info = std.json.stringifyAlloc(std.heap.page_allocator, .{
        .id = std.fmt.fmtSliceHexLower(&std.mem.toBytes(chord.own_id)),
        .host = chord.own_host,
        .port = chord.own_port,
        .successor = if (chord.routing.successor) |s| .{
            .id = std.fmt.fmtSliceHexLower(&std.mem.toBytes(s.id)),
            .host = s.host, .port = s.port,
        } else null,
        .predecessor = if (chord.routing.predecessor) |p| .{
            .id = std.fmt.fmtSliceHexLower(&std.mem.toBytes(p.id)),
            .host = p.host, .port = p.port,
        } else null,
        .store_count = chord.store.count(),
    }, .{}) catch {
        setRet(sp, 0);
        return null;
    };
    defer std.heap.page_allocator.free(info);

    setRet(sp, @intCast(writeWasmMem(runtime, info)));
    return null;
}
