const std = @import("std");
const json = std.json;
const builtin = @import("builtin");
const logging = @import("logging");

const wasm3 = @cImport({
    @cInclude("wasm3.h");
    @cInclude("m3_env.h");
    @cInclude("m3_api_wasi.h");
});

const p2p_identity = @import("src/p2p/crypto/identity.zig");
const p2p_config_mod = @import("src/p2p/config.zig");
const chord_ring = @import("src/p2p/chord/ring.zig");
const chord_node = @import("src/p2p/chord/node.zig");
const chord_types = @import("src/p2p/chord/types.zig");
const socks_relay = @import("src/p2p/socks_relay.zig");
const udp = @import("src/p2p/transport/udp.zig");
const proxy = @import("src/p2p/proxy.zig");
const relay = @import("src/p2p/relay_v2.zig");
const encrypted_relay_mod = @import("src/p2p/encrypted_relay_adapter.zig");
const wss = @import("src/p2p/wss.zig");
const net_detect = @import("src/p2p/net_detect.zig");
const p2p_bindings = @import("src/host/p2p_bindings.zig");
const posix = std.posix;
const plugin_mod = @import("src/plugin/manager.zig");
const content_mod = @import("src/plugin/content.zig");

/// 进程级分配器（runPlugin 作为线程入口时无法通过参数获得）
var g_alloc: std.mem.Allocator = undefined;
/// 动态插件运行时管理器（worker 完成时回写结果）
var g_plugin_manager: ?*plugin_mod.Manager = null;
/// 当前 Chord 节点（动态插件 network=true 时使用）
var g_chord: ?*chord_node.ChordNode = null;

const plug_ai = @embedFile("plug/ai_plugin.wasm");
const plug_api = @embedFile("plug/api_plugin.wasm");
const EmbeddedPlug = struct {
    path: []const u8,
    data: []const u8,
};

const embedded_list = [_]EmbeddedPlug{
    .{ .path = "plug/ai_plugin.wasm", .data = plug_ai },
    .{ .path = "plug/api_plugin.wasm", .data = plug_api },
};

const PlugConfig = struct {
    name: []const u8,
    embed_path: []const u8,
    mem_kb: u32,
    timeout_ms: u32,
    network: bool,
    write: bool,
    allow_host_info: bool,
};

const AppConfig = struct {
    plugins: []PlugConfig,
};

const TopConfig = struct {
    p2p: ?p2p_config_mod.P2PConfig = null,
    plugins: ?[]PlugConfig = null,
    control_token: ?[]const u8 = null,
};

fn readCpuUsage() f32 {
    if (builtin.os.tag != .linux) return 0.0;
    const f = std.fs.openFileAbsolute("/proc/stat", .{}) catch return 0.0;
    defer f.close();
    var buf: [512]u8 = undefined;
    const n = f.read(&buf) catch return 0.0;
    const content = buf[0..n];
    var iter = std.mem.tokenizeAny(u8, content, " \n");
    var sum: u64 = 0;
    var idle: u64 = 0;
    var idx: u8 = 0;
    while (iter.next()) |tok| {
        const val = std.fmt.parseUnsigned(u64, tok, 10) catch {
            idx += 1;
            if (idx > 8) break;
            continue;
        };
        sum += val;
        if (idx == 4) idle = val;
        idx += 1;
        if (idx > 8) break;
    }
    if (sum == 0) return 0.0;
    return 100.0 - (@as(f32, @floatFromInt(idle)) / @as(f32, @floatFromInt(sum)) * 100.0);
}

fn getCpuCores() u32 {
    return @intCast(std.Thread.getCpuCount() catch @as(usize, 1));
}

var os_name_buf: [32]u8 = undefined;

fn initOsNameBuf() void {
    const name = @tagName(builtin.os.tag);
    @memcpy(os_name_buf[0..name.len], name);
    os_name_buf[name.len] = 0;
}

fn readFreeMemory() u64 {
    if (builtin.os.tag != .linux) return 0;
    const file = std.fs.openFileAbsoluteZ("/proc/meminfo", .{}) catch return 0;
    defer file.close();
    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return 0;
    const content = buf[0..n];
    var iter = std.mem.tokenizeAny(u8, content, " \n");
    while (iter.next()) |label| {
        if (std.mem.eql(u8, label, "MemFree:")) {
            if (iter.next()) |val_str| {
                return std.fmt.parseUnsigned(u64, val_str, 10) catch 0;
            }
        }
    }
    return 0;
}

fn lookupEmbedded(path: []const u8) ?[]const u8 {
    for (&embedded_list) |e| {
        if (std.mem.eql(u8, e.path, path)) return e.data;
    }
    return null;
}

// ── M3RawCall host functions ──────────────────────────────────────
// wasm3 M3RawCall signature:
//   const void* (*)(IM3Runtime, IM3ImportContext, uint64_t* _sp, void* _mem)
//
// Return NULL (= m3Err_none) for success.
// Write return value: *((type*)_sp) = value

// WASI errno: __WASI_ERRNO_ACCES = 2 (Permission denied)
// 用于沙箱 stub：当 cfg.write=false 时阻止 WASM 写文件能力。
const WASI_ERRNO_ACCES: u32 = 2;

/// 沙箱 stub：始终返回 WASI EACCES（Permission denied），用于覆盖
/// m3_LinkWASI 已链接的 fd_write/path_open/fd_fdstat_set_flags，
/// 在 cfg.write=false 时强制阻断 WASM 对宿主文件系统的写入/打开能力。
fn wasi_stub_denied(
    _: ?*anyopaque,
    _: ?*anyopaque,
    sp: ?*u64,
    _: ?*anyopaque,
) callconv(.C) ?*const anyopaque {
    if (sp) |s| {
        // 返回值写入 sp[0] 低 32 位（WASI errno 为 u16/u32 都兼容）
        @as(*u32, @ptrCast(@alignCast(s))).* = WASI_ERRNO_ACCES;
    }
    return null; // m3Err_none：分发成功，errno 由 WASM 读取
}

/// 在 m3_LinkWASI 之后链接沙箱 stub，覆盖写能力相关函数。
/// 链接顺序：m3_LinkWASI 在前，本函数在后 — wasm3 的 FindAndLinkFunction
/// 对每个匹配 import 调用 CompileRawFunction，后调用覆盖前绑定。
fn linkWriteBlockingStubs(mod: ?*wasm3.M3Module) void {
    const stub: wasm3.M3RawCall = @ptrCast(&wasi_stub_denied);
    // fd_write: i(i*i*) — 阻断所有 fd 写入（含 stdout/stderr，配置 write=false 即不允许）
    _ = wasm3.m3_LinkRawFunction(mod, "wasi_unstable", "fd_write", "i(i*i*)", stub);
    _ = wasm3.m3_LinkRawFunction(mod, "wasi_snapshot_preview1", "fd_write", "i(i*i*)", stub);
    // fd_fdstat_set_flags: i(ii) — 阻止把 fd 改为可写
    _ = wasm3.m3_LinkRawFunction(mod, "wasi_unstable", "fd_fdstat_set_flags", "i(ii)", stub);
    _ = wasm3.m3_LinkRawFunction(mod, "wasi_snapshot_preview1", "fd_fdstat_set_flags", "i(ii)", stub);
    // path_open: i(ii*iiIIi*) — 阻止打开任何路径（含只读打开，避免探测沙箱边界）
    _ = wasm3.m3_LinkRawFunction(mod, "wasi_unstable", "path_open", "i(ii*iiIIi*)", stub);
    _ = wasm3.m3_LinkRawFunction(mod, "wasi_snapshot_preview1", "path_open", "i(ii*iiIIi*)", stub);
}

fn host_cpu_cores(_: ?*anyopaque, _: ?*anyopaque, sp: ?*u64, _: ?*anyopaque) callconv(.C) ?*const anyopaque {
    @as(*u32, @ptrCast(@alignCast(sp))).* = getCpuCores();
    return null;
}

fn host_cpu_usage(_: ?*anyopaque, _: ?*anyopaque, sp: ?*u64, _: ?*anyopaque) callconv(.C) ?*const anyopaque {
    @as(*f32, @ptrCast(@alignCast(sp))).* = readCpuUsage();
    return null;
}

fn host_mem_total(_: ?*anyopaque, _: ?*anyopaque, sp: ?*u64, _: ?*anyopaque) callconv(.C) ?*const anyopaque {
    sp.?.* = std.process.totalSystemMemory() catch 0;
    return null;
}

fn host_mem_free(_: ?*anyopaque, _: ?*anyopaque, sp: ?*u64, _: ?*anyopaque) callconv(.C) ?*const anyopaque {
    sp.?.* = readFreeMemory();
    return null;
}

fn host_os_tag(runtime: ?*anyopaque, _: ?*anyopaque, sp: ?*u64, _: ?*anyopaque) callconv(.C) ?*const anyopaque {
    var mem_len: u32 = 0;
    const i3runtime = @as(wasm3.IM3Runtime, @ptrCast(@alignCast(runtime)));
    const mem_base = wasm3.m3_GetMemory(i3runtime, &mem_len, 0);

    const name_len = std.mem.indexOfScalar(u8, &os_name_buf, 0) orelse @min(@as(usize, 31), os_name_buf.len);
    const safe_offset = if (mem_len > 128) mem_len - 128 else 0;

    if (mem_base) |base| {
        const dest = base + safe_offset;
        @memcpy(dest[0..name_len], os_name_buf[0..name_len]);
        dest[name_len] = 0;
    }
    @as(*u32, @ptrCast(@alignCast(sp))).* = safe_offset;
    return null;
}

const TimeoutGuard = struct {
    timer: std.time.Timer,
    timeout_ns: u64,
    expired: bool,
    fn start(timeout_ms: u64) !TimeoutGuard {
        return TimeoutGuard{
            .timer = try std.time.Timer.start(),
            .timeout_ns = timeout_ms * std.time.ns_per_ms,
            .expired = false,
        };
    }
    fn check(self: *TimeoutGuard) bool {
        if (self.expired) return true;
        if (self.timer.read() >= self.timeout_ns) {
            self.expired = true;
            return true;
        }
        return false;
    }
};

/// WASM 执行 worker 上下文。
/// launchPlugin 在堆上分配 work；worker 接管 env/runtime，完成 m3_Call、
/// 事件上报、结果回写和资源释放。控制信号（取消/超时）通过 m3_Yield 与
/// 循环回边钩子在指令边界生效，worker 因此总能正常退出并释放资源；
/// 仅当卡在原生宿主调用（如阻塞 socket）时才由等待方 detach。
const PluginCallWork = struct {
    cfg: PlugConfig,
    env: *wasm3.M3Environment,
    runtime: *wasm3.M3Runtime,
    entry_fn: *wasm3.M3Function,
    mgr: ?*plugin_mod.Manager,
    plugin_handle: u64,
    start_time: i128,
    control: *plugin_mod.ControlBlock,
    /// 模块字节码（wasm3 不拷贝，worker 结束后释放）
    owned_bytes: []const u8,
    /// 动态模式 cfg.name 由 worker 释放
    name_owned: bool,
    /// 异步模式：worker 自行释放 work；同步模式由等待方 join 后释放
    self_free: bool,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .{ .raw = false },

    fn durationMs(self: *PluginCallWork) u64 {
        const duration_ns = std.time.nanoTimestamp() - self.start_time;
        if (duration_ns >= 0) {
            return @intCast(@divTrunc(@as(u128, @intCast(duration_ns)), @as(u128, std.time.ns_per_ms)));
        }
        return 0;
    }

    fn postComplete(self: *PluginCallWork, dur_ms: u64) void {
        std.debug.print("=== [完成] {s} ===\n", .{self.cfg.name});
        if (self.mgr) |pm| pm.setResult(self.plugin_handle, .completed, 0, dur_ms, null);
    }

    fn run(self: *PluginCallWork) void {
        defer self.done.store(true, .release);
        plugin_mod.tls_control = self.control;
        defer plugin_mod.tls_control = null;

        const call_result = wasm3.m3_Call(self.entry_fn, 0, null);
        const dur_ms = self.durationMs();
        const sig = self.control.signal.load(.acquire);

        if (sig == plugin_mod.sig_timeout) {
            std.debug.print("[超时] {s}: 执行超时 {d}ms\n", .{ self.cfg.name, self.cfg.timeout_ms });
            if (self.mgr) |pm| pm.setResult(self.plugin_handle, .timeout, -1, dur_ms, "execution timeout");
        } else if (sig == plugin_mod.sig_cancel) {
            std.debug.print("[取消] {s}: 已被请求终止\n", .{self.cfg.name});
            if (self.mgr) |pm| pm.setResult(self.plugin_handle, .cancelled, -7, dur_ms, "cancelled");
        } else if (call_result) |msg| {
            const slice = std.mem.sliceTo(msg, 0);
            if (std.mem.indexOf(u8, slice, "exit") != null) {
                self.postComplete(dur_ms);
            } else {
                std.debug.print("[错误] {s}: 执行失败 ({s})\n", .{ self.cfg.name, slice });
                if (self.mgr) |pm| pm.setResult(self.plugin_handle, .failed, -5, dur_ms, slice);
            }
        } else {
            self.postComplete(dur_ms);
        }

        // 释放运行时与环境（worker 接管的所有权）
        wasm3.m3_FreeRuntime(self.runtime);
        wasm3.m3_FreeEnvironment(self.env);
        g_alloc.free(self.owned_bytes);
        if (self.name_owned) g_alloc.free(self.cfg.name);
        if (self.self_free) g_alloc.destroy(self);
    }
};

fn reportPluginError(handle: u64, code: i32, msg: []const u8) void {
    if (g_plugin_manager) |pm| pm.setResult(handle, .failed, code, 0, msg);
}

/// 启动期入口：复制字节码后同步执行（保持原有调用方式）
fn runPlugin(cfg: PlugConfig, wasm_bin: []const u8, maybe_chord: ?*chord_node.ChordNode) void {
    const bytes = g_alloc.dupe(u8, wasm_bin) catch {
        std.debug.print("[错误] {s}: 内存不足，无法复制字节码\n", .{cfg.name});
        return;
    };
    _ = launchPlugin(cfg, bytes, maybe_chord, true) catch return;
}

/// 动态装载入口（控制通道触发）：fire-and-forget，立即返回句柄
fn dynamicLaunch(
    ctx: ?*anyopaque,
    name: []const u8,
    bytes: []const u8,
    snap: plugin_mod.ConfigSnapshot,
) !u64 {
    _ = ctx;
    // name 来自 Manager 的临时缓冲，这里独立复制并交由 worker 释放
    const owned_name = g_alloc.dupe(u8, name) catch return error.OutOfMemory;
    errdefer g_alloc.free(owned_name);
    const cfg = PlugConfig{
        .name = owned_name,
        .embed_path = owned_name,
        .mem_kb = snap.mem_kb,
        .timeout_ms = snap.timeout_ms,
        .network = snap.network,
        .write = snap.write,
        .allow_host_info = snap.allow_host_info,
    };
    return launchPlugin(cfg, bytes, g_chord, false);
}

// ── 本地控制通道（daemon API 经 127.0.0.1 UDP 调用）──

const control_info_json = struct {
    handle: u64,
    name: []const u8,
    state: []const u8,
    duration_ms: u64,
    exit_code: i32,
    error_message: ?[]const u8,
    config: plugin_mod.ConfigSnapshot,
};

fn infoToJson(arena: std.mem.Allocator, info: anytype) !control_info_json {
    return .{
        .handle = info.handle,
        .name = try arena.dupe(u8, info.name),
        .state = @tagName(info.state),
        .duration_ms = info.duration_ms,
        .exit_code = info.exit_code,
        .error_message = if (info.error_message) |m| try arena.dupe(u8, m) else null,
        .config = info.config,
    };
}

/// 控制通道处理器；所有临时分配都在 arena 中，由 node.zig 在发送响应后释放
fn pluginControlHandler(
    action: []const u8,
    params: std.json.Value,
    arena: std.mem.Allocator,
) ?[]u8 {
    // 节点状态查询（不依赖 plugin manager）
    if (std.mem.eql(u8, action, "node_status")) {
        const chord = g_chord orelse {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "chord unavailable" }, .{}) catch null;
        };
        const nid_hex = arena.dupe(u8, &chord_ring.idToHex(chord.own_id)) catch return null;
        const succ = chord.routing.successor;
        const pred = chord.routing.predecessor;
        const succ_hex = if (succ) |s| (arena.dupe(u8, &chord_ring.idToHex(s.id)) catch return null) else "";
        const pred_hex = if (pred) |p| (arena.dupe(u8, &chord_ring.idToHex(p.id)) catch return null) else "";
        const succ_addr = if (succ) |s| (std.fmt.allocPrint(arena, "{s}:{d}", .{ s.host, s.port }) catch return null) else "";
        const pred_addr = if (pred) |p| (std.fmt.allocPrint(arena, "{s}:{d}", .{ p.host, p.port }) catch return null) else "";
        return std.json.stringifyAlloc(arena, .{
            .ok = true,
            .node_id = nid_hex,
            .successor_id = succ_hex,
            .successor_addr = succ_addr,
            .predecessor_id = pred_hex,
            .predecessor_addr = pred_addr,
        }, .{}) catch null;
    }

    const pm = g_plugin_manager orelse {
        return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "plugin manager unavailable" }, .{}) catch null;
    };

    if (std.mem.eql(u8, action, "plugin_load")) {
        const p = if (params == .object) params.object else {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "params must be object" }, .{}) catch null;
        };
        const ref = p.get("ref") orelse {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "missing ref" }, .{}) catch null;
        };
        if (ref != .string) {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "ref must be string" }, .{}) catch null;
        }
        const cfg = if (p.get("config")) |c| configFromControlJson(c) else plugin_mod.ConfigSnapshot{};
        const handle = pm.startFromFile(ref.string, cfg) catch |err| {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = @errorName(err) }, .{}) catch null;
        };
        return std.json.stringifyAlloc(arena, .{ .ok = true, .handle = handle }, .{}) catch null;
    }

    if (std.mem.eql(u8, action, "plugin_publish")) {
        const p = if (params == .object) params.object else {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "params must be object" }, .{}) catch null;
        };
        const ref = p.get("ref") orelse {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "missing ref" }, .{}) catch null;
        };
        if (ref != .string) {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "ref must be string" }, .{}) catch null;
        }
        const chord = g_chord orelse {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "p2p unavailable" }, .{}) catch null;
        };

        const local_bytes = readLocalPluginBytes(arena, ref.string) catch |err| {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = @errorName(err) }, .{}) catch null;
        };

        const hex = content_mod.publish(chord, arena, local_bytes) catch |err| {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = @errorName(err) }, .{}) catch null;
        };
        return std.json.stringifyAlloc(arena, .{
            .ok = true,
            .hash = @as([]const u8, &hex),
            .size = local_bytes.len,
        }, .{}) catch null;
    }

    if (std.mem.eql(u8, action, "plugin_fetch")) {
        const p = if (params == .object) params.object else {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "params must be object" }, .{}) catch null;
        };
        const hash_val = p.get("hash") orelse {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "missing hash" }, .{}) catch null;
        };
        if (hash_val != .string) {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "hash must be string" }, .{}) catch null;
        }
        const hex = content_mod.normalizeHash(hash_val.string) catch |err| {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = @errorName(err) }, .{}) catch null;
        };
        const want_load = if (p.get("load")) |v| (if (v == .bool) v.bool else true) else true;
        const cfg = if (p.get("config")) |c| configFromControlJson(c) else plugin_mod.ConfigSnapshot{};

        // 1. 本地缓存优先
        var source: []const u8 = "cache";
        var bytes: []u8 = blk: {
            if (content_mod.readCache(arena, &hex) catch null) |b| break :blk b;
            const chord = g_chord orelse {
                return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "p2p unavailable" }, .{}) catch null;
            };
            const fetched = content_mod.fetch(chord, arena, &hex) catch |err| {
                return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = @errorName(err) }, .{}) catch null;
            };
            content_mod.writeCache(&hex, fetched) catch |err| {
                std.debug.print("[content] 缓存写入失败: {}\n", .{err});
            };
            source = "dht";
            break :blk fetched;
        };

        var response_info = FetchResponse{
            .ok = true,
            .hash = &hex,
            .size = bytes.len,
            .source = source,
            .handle = null,
        };

        if (want_load) {
            // worker 以 g_alloc 释放字节码：独立复制一份，使其脱离 arena 生命周期
            const launch_bytes = g_alloc.dupe(u8, bytes) catch {
                return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "out of memory" }, .{}) catch null;
            };
            bytes = launch_bytes;
            const display_name = std.fmt.allocPrint(arena, "{s}.wasm", .{hex[0..16]}) catch return null;
            const handle = pm.startFromBytes(display_name, launch_bytes, cfg) catch |err| {
                return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = @errorName(err) }, .{}) catch null;
            };
            response_info.handle = handle;
        }

        return std.json.stringifyAlloc(arena, response_info, .{}) catch null;
    }

    if (std.mem.eql(u8, action, "plugin_list")) {
        const files = pm.listPluginFiles(arena) catch |err| {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = @errorName(err) }, .{}) catch null;
        };
        const names = arena.alloc([]const u8, files.len) catch return null;
        for (files, 0..) |f, i| names[i] = f;
        return std.json.stringifyAlloc(arena, .{ .ok = true, .plugins = names }, .{}) catch null;
    }

    if (std.mem.eql(u8, action, "plugin_active")) {
        const infos = pm.snapshotAll(arena) catch |err| {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = @errorName(err) }, .{}) catch null;
        };
        const out = arena.alloc(control_info_json, infos.len) catch return null;
        for (infos, 0..) |info, i| {
            out[i] = infoToJson(arena, info) catch return null;
        }
        return std.json.stringifyAlloc(arena, .{ .ok = true, .active = out }, .{}) catch null;
    }

    // 以下动作都需要整数 handle
    if (std.mem.eql(u8, action, "plugin_stop") or
        std.mem.eql(u8, action, "plugin_pause") or
        std.mem.eql(u8, action, "plugin_resume") or
        std.mem.eql(u8, action, "plugin_info"))
    {
        const handle = controlHandleParam(params) orelse {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "missing/invalid handle" }, .{}) catch null;
        };

        if (std.mem.eql(u8, action, "plugin_info")) {
            const maybe_info = pm.snapshot(arena, handle) catch |err| {
                return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = @errorName(err) }, .{}) catch null;
            };
            const info = maybe_info orelse {
                return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "handle not found" }, .{}) catch null;
            };
            const out = infoToJson(arena, info) catch return null;
            return std.json.stringifyAlloc(arena, .{ .ok = true, .info = out }, .{}) catch null;
        }

        const changed = if (std.mem.eql(u8, action, "plugin_stop"))
            pm.cancel(handle)
        else if (std.mem.eql(u8, action, "plugin_pause"))
            pm.pause(handle)
        else
            pm.resumePlugin(handle);

        return std.json.stringifyAlloc(arena, .{ .ok = changed }, .{}) catch null;
    }

    if (std.mem.eql(u8, action, "plugin_unload")) {
        const handle = controlHandleParam(params) orelse {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "missing/invalid handle" }, .{}) catch null;
        };
        const ok = pm.unload(handle);
        return std.json.stringifyAlloc(arena, .{ .ok = ok }, .{}) catch null;
    }

    // 热更新：取消旧实例 → 按 hash 拉取新字节码 → 以原配置重新装载
    if (std.mem.eql(u8, action, "plugin_update")) {
        const p = if (params == .object) params.object else {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "params must be object" }, .{}) catch null;
        };
        const handle = controlHandleParam(params) orelse {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "missing/invalid handle" }, .{}) catch null;
        };
        const hash_val = p.get("hash") orelse {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "missing hash" }, .{}) catch null;
        };
        if (hash_val != .string) {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "hash must be string" }, .{}) catch null;
        }
        const hex = content_mod.normalizeHash(hash_val.string) catch |err| {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = @errorName(err) }, .{}) catch null;
        };

        // 读取旧实例配置快照
        const maybe_info = pm.snapshot(arena, handle) catch |err| {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = @errorName(err) }, .{}) catch null;
        };
        const old_info = maybe_info orelse {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "handle not found" }, .{}) catch null;
        };
        const cfg = old_info.config;

        // 取消旧实例并等待其结束
        _ = pm.cancel(handle);
        var wait_ms: u32 = 0;
        while (wait_ms < 3000) : (wait_ms += 20) {
            const s = (pm.snapshot(arena, handle) catch null) orelse break;
            const st = s.state;
            if (st != .starting and st != .running and st != .paused) break;
            std.time.sleep(20 * std.time.ns_per_ms);
        }

        // 拉取新字节码（缓存优先，缺失则 DHT）
        var source: []const u8 = "cache";
        const bytes: []u8 = blk: {
            if (content_mod.readCache(arena, &hex) catch null) |b| break :blk b;
            const chord = g_chord orelse {
                return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "p2p unavailable" }, .{}) catch null;
            };
            const fetched = content_mod.fetch(chord, arena, &hex) catch |err| {
                return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = @errorName(err) }, .{}) catch null;
            };
            content_mod.writeCache(&hex, fetched) catch {};
            source = "dht";
            break :blk fetched;
        };

        // 复制字节码脱离 arena，并构造展示名
        const launch_bytes = g_alloc.dupe(u8, bytes) catch {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "out of memory" }, .{}) catch null;
        };
        const display_name = std.fmt.allocPrint(arena, "{s}.wasm", .{hex[0..16]}) catch return null;
        const new_handle = pm.startFromBytes(display_name, launch_bytes, cfg) catch |err| {
            return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = @errorName(err) }, .{}) catch null;
        };
        return std.json.stringifyAlloc(arena, .{ .ok = true, .old_handle = handle, .handle = new_handle, .source = source }, .{}) catch null;
    }

    return std.json.stringifyAlloc(arena, .{ .ok = false, .@"error" = "unknown action" }, .{}) catch null;
}

/// fetch 动作响应
const FetchResponse = struct {
    ok: bool,
    hash: []const u8,
    size: usize,
    source: []const u8,
    handle: ?u64,
};

/// 按 manager 相同约定读取本地插件：.wasm 结尾视为路径，否则解析为 plug/<ref>.wasm
fn readLocalPluginBytes(arena: std.mem.Allocator, ref: []const u8) ![]u8 {
    const path = if (std.mem.endsWith(u8, ref, ".wasm"))
        try arena.dupe(u8, ref)
    else
        try std.fmt.allocPrint(arena, "plug/{s}.wasm", .{ref});

    const file = std.fs.cwd().openFile(path, .{}) catch return error.PluginFileNotFound;
    defer file.close();
    return try file.readToEndAlloc(arena, 32 * 1024 * 1024);
}

fn controlHandleParam(params: std.json.Value) ?u64 {
    if (params != .object) return null;
    const h = params.object.get("handle") orelse return null;
    return switch (h) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .float => |f| if (f >= 0) @intFromFloat(f) else null,
        else => null,
    };
}

fn configFromControlJson(v: std.json.Value) plugin_mod.ConfigSnapshot {
    var cfg = plugin_mod.ConfigSnapshot{};
    if (v != .object) return cfg;
    if (v.object.get("mem_kb")) |x| {
        if (x == .integer and x.integer > 0) cfg.mem_kb = @intCast(x.integer);
    }
    if (v.object.get("timeout_ms")) |x| {
        if (x == .integer and x.integer > 0) cfg.timeout_ms = @intCast(x.integer);
    }
    if (v.object.get("network")) |x| {
        if (x == .bool) cfg.network = x.bool;
    }
    if (v.object.get("write")) |x| {
        if (x == .bool) cfg.write = x.bool;
    }
    if (v.object.get("allow_host_info")) |x| {
        if (x == .bool) cfg.allow_host_info = x.bool;
    }
    return cfg;
}

/// 装载核心。owned_bytes 所有权在本函数终止时统一释放（解析已复制数据）。
/// wait=true：阻塞至完成/超时（启动期语义）；wait=false：立即返回（动态语义）。
fn launchPlugin(
    cfg: PlugConfig,
    owned_bytes: []const u8,
    maybe_chord: ?*chord_node.ChordNode,
    wait: bool,
) !u64 {
    // wasm3 不拷贝字节码：早期错误路径这里释放，成功路径转交 worker
    var bytes_owned: bool = true;
    defer if (bytes_owned) g_alloc.free(owned_bytes);

    const name = if (cfg.name.len > 0) cfg.name else cfg.embed_path;

    const handle = if (g_plugin_manager) |pm| pm.allocHandle() else 0;
    const start_time = std.time.nanoTimestamp();

    std.debug.print("\n=== [启动] {s} (mem={d}KB, timeout={d}ms, net={}, write={}, host_info={}) ===\n", .{
        name, cfg.mem_kb, cfg.timeout_ms, cfg.network, cfg.write, cfg.allow_host_info,
    });

    // 登记注册表，获取控制块（取消/暂停/超时）
    const control = if (g_plugin_manager) |pm|
        pm.register(handle, name, .{
            .mem_kb = cfg.mem_kb,
            .timeout_ms = cfg.timeout_ms,
            .network = cfg.network,
            .write = cfg.write,
            .allow_host_info = cfg.allow_host_info,
        }) catch |e| {
            std.debug.print("[错误] {s}: 注册表登记失败 ({})\n", .{ name, e });
            reportPluginError(handle, -8, "Failed to register plugin");
            return e;
        }
    else blk: {
        const c = try g_alloc.create(plugin_mod.ControlBlock);
        c.* = .{};
        break :blk c;
    };

    var guard = TimeoutGuard.start(cfg.timeout_ms) catch {
        std.debug.print("[错误] {s}: 无法创建定时器\n", .{name});
        reportPluginError(handle, -1, "Failed to create timer");
        return error.PluginLaunchFailed;
    };

    const env = wasm3.m3_NewEnvironment() orelse {
        std.debug.print("[错误] {s}: 创建环境失败\n", .{name});
        reportPluginError(handle, -1, "Failed to create WASM environment");
        return error.PluginLaunchFailed;
    };
    // 资源所有权标志：早期错误路径由 defer 释放；成功路径转交给 worker。
    var env_owned: bool = true;
    defer if (env_owned) wasm3.m3_FreeEnvironment(env);

    const chord_userdata: ?*anyopaque = @ptrCast(maybe_chord);
    const runtime = wasm3.m3_NewRuntime(env, cfg.mem_kb * 1024, chord_userdata) orelse {
        std.debug.print("[错误] {s}: 创建运行时失败\n", .{name});
        reportPluginError(handle, -1, "Failed to create WASM runtime");
        return error.PluginLaunchFailed;
    };
    var runtime_owned: bool = true;
    defer if (runtime_owned) wasm3.m3_FreeRuntime(runtime);

    if (guard.check()) {
        std.debug.print("[超时] {s}: 初始化超时\n", .{name});
        reportPluginError(handle, -1, "Initialization timeout");
        return error.PluginLaunchFailed;
    }

    var mod: ?*wasm3.M3Module = null;
    if (wasm3.m3_ParseModule(env, &mod, owned_bytes.ptr, @intCast(owned_bytes.len)) != 0) {
        std.debug.print("[错误] {s}: 模块解析失败\n", .{name});
        reportPluginError(handle, -2, "Failed to parse WASM module");
        return error.PluginLaunchFailed;
    }
    if (guard.check()) {
        reportPluginError(handle, -2, "Parse timeout");
        return error.PluginLaunchFailed;
    }

    if (wasm3.m3_LoadModule(runtime, mod) != 0) {
        std.debug.print("[错误] {s}: 模块加载失败\n", .{name});
        reportPluginError(handle, -3, "Failed to load WASM module");
        return error.PluginLaunchFailed;
    }
    if (guard.check()) {
        reportPluginError(handle, -3, "Load timeout");
        return error.PluginLaunchFailed;
    }

    _ = wasm3.m3_LinkWASI(mod);
    // P0-2 沙箱强制：在 m3_LinkWASI 之后覆盖 fd_write/path_open/fd_fdstat_set_flags，
    // 使 cfg.write=false 时 WASM 无法绕过配置直接调用 WASI 写入或打开文件。
    if (!cfg.write) {
        linkWriteBlockingStubs(mod);
        std.debug.print("[沙箱] {s}: write=false → 已阻断 WASI fd_write/path_open/fd_fdstat_set_flags\n", .{name});
    }
    if (guard.check()) {
        reportPluginError(handle, -3, "Link timeout");
        return error.PluginLaunchFailed;
    }

    if (cfg.allow_host_info) {
        inline for (.{
            .{ "cpu_cores", "i()", &host_cpu_cores },
            .{ "cpu_usage", "f()", &host_cpu_usage },
            .{ "mem_total", "I()", &host_mem_total },
            .{ "mem_free", "I()", &host_mem_free },
            .{ "os_tag", "*()", &host_os_tag },
        }) |entry| {
            const result = wasm3.m3_LinkRawFunction(mod, "host", entry[0], entry[1], @ptrCast(entry[2]));
            if (result) |msg| {
                const slice = std.mem.sliceTo(msg, 0);
                if (std.mem.indexOf(u8, slice, "function lookup") == null) {
                    std.debug.print("[警告] {s}: 绑定 {s} 失败 ({s})\n", .{ name, entry[0], slice });
                }
            }
        }
    }

    // 注册 P2P 宿主函数（如果 P2P 网络已启用）
    if (maybe_chord != null and cfg.network) {
        inline for (.{
            .{ "dht_get", "i(ii)", &p2p_bindings.host_dht_get },
            .{ "dht_put", "i(iiiii)", &p2p_bindings.host_dht_put },
            .{ "node_info", "i()", &p2p_bindings.host_node_info },
        }) |entry| {
            const result = wasm3.m3_LinkRawFunction(mod, "host", entry[0], entry[1], @ptrCast(entry[2]));
            if (result) |msg| {
                const slice = std.mem.sliceTo(msg, 0);
                if (std.mem.indexOf(u8, slice, "function lookup") == null) {
                    std.debug.print("[警告] {s}: 绑定 {s} 失败 ({s})\n", .{ name, entry[0], slice });
                }
            }
        }
        std.debug.print("[p2p] 已为 {s} 注册 P2P 宿主函数\n", .{name});
    }
    if (guard.check()) {
        reportPluginError(handle, -3, "Binding timeout");
        return error.PluginLaunchFailed;
    }

    var entry_fn: ?*wasm3.M3Function = null;
    if (wasm3.m3_FindFunction(&entry_fn, runtime, "_start") != 0) {
        std.debug.print("[警告] {s}: 未找到 _start 入口\n", .{name});
        reportPluginError(handle, -4, "Failed to find _start entry point");
        return error.PluginLaunchFailed;
    }
    if (entry_fn == null) {
        reportPluginError(handle, -4, "Missing _start entry point");
        return error.PluginLaunchFailed;
    }

    const work = try g_alloc.create(PluginCallWork);
    errdefer g_alloc.destroy(work);
    work.* = .{
        .cfg = cfg,
        .env = env,
        .runtime = runtime,
        .entry_fn = entry_fn.?,
        .mgr = g_plugin_manager,
        .plugin_handle = handle,
        .start_time = start_time,
        .control = control,
        .owned_bytes = owned_bytes,
        .name_owned = !wait,
        .self_free = !wait,
    };
    env_owned = false;
    runtime_owned = false;
    bytes_owned = false;

    work.thread = std.Thread.spawn(.{}, PluginCallWork.run, .{work}) catch |e| {
        std.debug.print("[错误] {s}: 无法创建执行线程 ({})\n", .{ name, e });
        reportPluginError(handle, -6, "Failed to spawn worker thread");
        g_alloc.destroy(work);
        env_owned = true;
        runtime_owned = true;
        return e;
    };

    if (!wait) {
        // 动态模式：立即返回句柄，worker 自行释放 work；完成事件经事件队列通知
        return handle;
    }

    // 同步模式：等待 worker，最长 cfg.timeout_ms（10ms 步长轮询）
    var waited: u64 = 0;
    const step_ms: u64 = 10;
    while (waited < cfg.timeout_ms) {
        if (work.done.load(.acquire)) break;
        std.time.sleep(step_ms * std.time.ns_per_ms);
        waited += step_ms;
    }

    if (work.done.load(.acquire)) {
        work.thread.?.join();
        g_alloc.destroy(work);
        return handle;
    }

    // 超时：先发取消信号，worker 应在指令边界退出；给予 200ms 宽限
    control.timeoutCancel();
    var grace: u64 = 0;
    while (grace < 200) {
        if (work.done.load(.acquire)) break;
        std.time.sleep(10 * std.time.ns_per_ms);
        grace += 10;
    }

    if (work.done.load(.acquire)) {
        work.thread.?.join();
        g_alloc.destroy(work);
    } else {
        // 卡在原生宿主调用（如阻塞 socket）：无法中断，detach 兜底
        std.debug.print("[超时] {s}: 执行超时 {d}ms（worker 已 detach）\n", .{ name, cfg.timeout_ms });
        work.thread.?.detach();
    }
    return handle;
}

/// 初始化 P2P 身份：加载或生成 ED25519 密钥
fn initP2PIdentity(cfg: ?p2p_config_mod.P2PConfig) !p2p_identity.Identity {
    const key_path = if (cfg) |c| c.key_file else "p2p_key.bin";

    // 尝试从文件加载密钥种子
    const file = std.fs.cwd().openFile(key_path, .{}) catch |err| {
        std.debug.print("[p2p] 密钥文件 '{s}' 不存在 ({}), 生成新密钥\n", .{ key_path, @as(@TypeOf(err), err) });
        const id = p2p_identity.Identity.generate();
        // 保存密钥种子
        const seed = id.seed();
        const f = std.fs.cwd().createFile(key_path, .{}) catch |e| {
            std.debug.print("[p2p] 警告: 无法保存密钥文件: {}\n", .{e});
            return id;
        };
        defer f.close();
        f.writeAll(&seed) catch |e| {
            std.debug.print("[p2p] 警告: 密钥文件写入失败: {}\n", .{e});
        };
        std.debug.print("[p2p] 密钥已保存到 '{s}'\n", .{key_path});
        return id;
    };
    defer file.close();

    var seed: p2p_identity.Seed = undefined;
    const n = try file.readAll(&seed);
    if (n != seed.len) {
        std.debug.print("[p2p] 密钥文件无效 (size={d}), 生成新密钥\n", .{n});
        return p2p_identity.Identity.generate();
    }
    const id = try p2p_identity.Identity.fromSeed(seed);
    std.debug.print("[p2p] 从 '{s}' 加载密钥\n", .{key_path});
    return id;
}

pub fn main() !void {
    initOsNameBuf();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    g_alloc = alloc;

    // ── CLI args ───────────────────────────────────────────────
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    const config_path = if (args.len > 1) args[1] else "config.json";

    // ── 加载配置 ─────────────────────────────────────────────
    const cfg_text = blk: {
        const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
            std.debug.print("[info] {s} not found ({}), using defaults\n", .{ config_path, err });
            break :blk null;
        };
        defer file.close();
        break :blk try file.readToEndAlloc(alloc, 1024 * 64);
    };
    defer if (cfg_text) |t| alloc.free(t);

    const top_cfg = if (cfg_text) |text|
        try json.parseFromSlice(TopConfig, alloc, text, .{ .ignore_unknown_fields = true })
    else
        null;
    defer if (top_cfg) |p| p.deinit();

    var p2p_cfg = if (top_cfg) |c| c.value.p2p else null;

    var public_host: ?[]const u8 = null;

    // ── 动态插件运行时 ───────────────────────────────────────
    const plugin_manager = try plugin_mod.Manager.init(alloc);
    defer plugin_manager.deinit();
    g_plugin_manager = plugin_manager;
    defer g_plugin_manager = null;
    plugin_mod.global_manager = plugin_manager;
    defer plugin_mod.global_manager = null;
    plugin_manager.setLauncher(dynamicLaunch, null);

    // ── 自动网络检测（覆盖 transport_mode） ──────────────────
    if (p2p_cfg) |_| {
        if (builtin.os.tag == .linux) {
            std.debug.print("\n[net_detect] 正在检测网络环境 (port {d})...\n", .{p2p_cfg.?.listen_port});
            const detect_result = net_detect.fullNetDetect(alloc, p2p_cfg.?.listen_port, p2p_cfg.?.listen_host, p2p_cfg.?.prefer_ipv4);
            if (detect_result) |result| {
                if (result.public_ip) |ip| {
                    public_host = ip; // 直接取走所有权，不额外 dupe
                    std.debug.print("[net_detect] 公网 IP: {s}\n", .{ip});
                }
                const new_mode: p2p_config_mod.TransportMode = switch (result.level) {
                    .full_public => .dual,
                    .lan_only => .udp,
                    .strict_limit => .tcp,
                };
                if (new_mode != p2p_cfg.?.transport_mode) {
                    std.debug.print("[net_detect] 传输模式: {s} → {s} (检测覆盖)\n", .{
                        @tagName(p2p_cfg.?.transport_mode), @tagName(new_mode),
                    });
                    p2p_cfg.?.transport_mode = new_mode;
                } else {
                    std.debug.print("[net_detect] 传输模式: {s} (与配置一致)\n", .{@tagName(p2p_cfg.?.transport_mode)});
                }
            } else |err| {
                std.debug.print("[net_detect] 检测失败: {}, 使用配置默认值\n", .{err});
            }
        } else {
            std.debug.print("[net_detect] 非 Linux 平台, 跳过自动检测\n", .{});
        }
    }

    // ── P2P 网络初始化 ───────────────────────────────────────
    var maybe_chord: ?*chord_node.ChordNode = null;
    const chord_thread: ?std.Thread = null; // Temporarily disabled
    var maybe_proxy_server: ?*proxy.TcpProxyServer = null;
    var proxy_server_thread: ?std.Thread = null;
    var proxy_reader_thread: ?std.Thread = null;
    var maybe_relay_server: ?*relay.RelayServer = null;
    var relay_server_thread: ?std.Thread = null;
    var maybe_relay_client: ?*relay.RelayClient = null;
    var relay_reader_thread: ?std.Thread = null;
    var maybe_encrypted_relay: ?*encrypted_relay_mod.EncryptedRelayAdapter = null;
    var erc_reader_thread: ?std.Thread = null;
    var maybe_wss_server: ?*wss.WssServer = null;
    var wss_server_thread: ?std.Thread = null;

    if (p2p_cfg) |cfg| {
        if (cfg.enabled) {
            std.debug.print("\n=== [P2P] 初始化 P2P 网络 ===\n", .{});
            std.debug.print("[p2p] 监听端口: {d}\n", .{cfg.listen_port});
            std.debug.print("[p2p] Bootstrap 节点数: {d}\n", .{cfg.bootstrap.len});
            std.debug.print("[p2p] Stabilize 间隔: {d}ms\n", .{cfg.stabilize_interval_ms});
            if (cfg.proxy.enabled) {
                std.debug.print("[p2p] 代理服务: mode={s} transport={s}\n", .{ cfg.proxy.mode, cfg.proxy.transport });
            }

            const identity = try initP2PIdentity(p2p_cfg);
            const pk_hex = std.fmt.bytesToHex(&identity.publicKeyBytes(), .lower);
            const chord_id_hex = std.fmt.bytesToHex(&identity.chordId(), .lower);
            std.debug.print("[p2p] 节点公钥: {s}\n", .{pk_hex});
            std.debug.print("[p2p] Chord ID:  {s}\n", .{chord_id_hex});

            // 初始化 Chord 节点
            const node_id = chord_ring.idFromBytes(identity.chordId());

            // 端口冲突检查
            {
                var test_socket = udp.UdpSocket.bind(cfg.listen_port) catch |err| {
                    if (err == error.AddressInUse) {
                        std.debug.print("[错误] 端口 {d} 已被占用！请检查是否有其他进程在运行\n", .{cfg.listen_port});
                        std.debug.print("[提示] CMD: netstat -ano | findstr :{d}\n", .{cfg.listen_port});
                    }
                    return err;
                };
                test_socket.close();
            }

            // ── 确定用于 Chord 通告和 relay 注册的地址 ──
            // 优先级：advertise_host 显式指定 > 特定 listen_host 直接用 > 0.0.0.0 用检测到的公网 IP
            const effective_host = if (cfg.advertise_host.len > 0)
                cfg.advertise_host
            else if (std.mem.eql(u8, cfg.listen_host, "0.0.0.0"))
                (public_host orelse cfg.listen_host)
            else
                cfg.listen_host;
            // public_host 已转移所有权到 effective_host，或未使用。不再单独管理生命周期。
            if (public_host != null and !std.mem.eql(u8, cfg.listen_host, "0.0.0.0")) {
                alloc.free(public_host.?);
                public_host = null;
            }

            // ── 原生 TCP Relay 初始化（必须在 ChordNode 之前，因为 ChordNode 需要 relay_client 引用）──
            //   relay server: 监听 listen_port 接受其他节点的连接
            //   relay client: 连接 remote_host:remote_port
            //   两者可同时存在（级联 relay）
            if (cfg.proxy.enabled and std.mem.eql(u8, cfg.proxy.transport, "relay")) {
                // 启动 relay server（如果配置了 listen_port）
                if (cfg.proxy.listen_port > 0) {
                    const rs = try alloc.create(relay.RelayServer);
                    rs.* = try relay.RelayServer.init(alloc, cfg.proxy.relay_listen_host, cfg.proxy.listen_port, cfg.proxy.max_connections, cfg.proxy.max_per_user, 0, null);
                    maybe_relay_server = rs;
                    relay_server_thread = try std.Thread.spawn(.{}, relay.RelayServer.run, .{rs});
                    std.debug.print("[relay] 中继服务器已启动 :{d}\n", .{cfg.proxy.listen_port});
                }
                // 启动 relay client（如果配置了 remote_host）
                if (cfg.proxy.remote_host.len > 0) {
                    const rc = try alloc.create(relay.RelayClient);
                    const init_result = blk: {
                        if (cfg.proxy.relay_ws) {
                            break :blk relay.RelayClient.initWithOpts(
                                alloc,
                                cfg.proxy.remote_host,
                                cfg.proxy.remote_port,
                                effective_host,
                                cfg.listen_port,
                                cfg.listen_port,
                                true,
                                cfg.proxy.remote_path,
                            );
                        } else {
                            break :blk relay.RelayClient.init(
                                alloc,
                                cfg.proxy.remote_host,
                                cfg.proxy.remote_port,
                                effective_host,
                                cfg.listen_port,
                                cfg.listen_port,
                            );
                        }
                    };
                    if (init_result) |client| {
                        rc.* = client;
                        maybe_relay_client = rc;
                        relay_reader_thread = try std.Thread.spawn(.{}, relay.RelayClient.readerLoop, .{rc});
                        // 如果同时有 relay server，把 client 设为 server 的上游（级联转发）
                        // 注意：如果 relay client 连接到 127.0.0.1（本机 loopback），跳过上游设置
                        // 否则会形成路由环（upstream_client 把请求发回自身 relay server）
                        if (maybe_relay_server) |rs| {
                            if (!std.mem.eql(u8, cfg.proxy.remote_host, "127.0.0.1")) {
                                rs.upstream_client = rc;
                                std.debug.print("[relay] 级联转发: 本地 client → {s}:{d}\n", .{ cfg.proxy.remote_host, cfg.proxy.remote_port });
                            } else {
                                std.debug.print("[relay] 跳过级联: client 连接到 127.0.0.1（本机 loopback）\n", .{});
                            }
                        } else {
                            std.debug.print("[relay] 中继客户端已连接 {s}:{d}\n", .{ cfg.proxy.remote_host, cfg.proxy.remote_port });
                        }
                    } else |err| {
                        std.debug.print("[relay] 连接到 {s}:{d} 失败: {}, 跳过 relay client\n", .{ cfg.proxy.remote_host, cfg.proxy.remote_port, err });
                        alloc.destroy(rc);
                    }
                }
            }

            // ── 加密中继客户端初始化（在 ChordNode 之前） ──
            if (cfg.encrypted_relay.enabled and cfg.encrypted_relay.relays.len > 0) {
                // 转换 RelayAddr 类型（config.EncryptedRelayAddr → relay_client.RelayAddr）
                var relay_buf: [8]encrypted_relay_mod.RelayAddr = undefined;
                const count = @min(cfg.encrypted_relay.relays.len, relay_buf.len);
                for (cfg.encrypted_relay.relays[0..count], 0..) |r, i| {
                    relay_buf[i] = .{ .host = r.host, .port = r.port };
                }
                const er_relays = relay_buf[0..count];

                const erc = try alloc.create(encrypted_relay_mod.EncryptedRelayAdapter);
                erc.* = try encrypted_relay_mod.EncryptedRelayAdapter.init(
                    alloc,
                    .{
                        .relays = er_relays,
                        .use_tcp = cfg.encrypted_relay.use_tcp,
                        .heartbeat_interval_ms = cfg.encrypted_relay.heartbeat_interval_ms,
                        .timeout_ms = cfg.encrypted_relay.timeout_ms,
                        .listen_port = cfg.listen_port,
                    },
                    identity.chordId(),
                    identity.seed(),
                    identity.publicKeyBytes(),
                );
                // 连接到中继（失败不阻塞，sendRequest 时自动重连）
                erc.connect() catch |err| {
                    std.debug.print("[encrypted_relay] 连接失败: {}, 延迟重连\n", .{err});
                };
                maybe_encrypted_relay = erc;
                std.debug.print("[encrypted_relay] 适配器已初始化 ({} relays)\n", .{cfg.encrypted_relay.relays.len});
            }

            // 转换 BootstrapAddr → NodeAddr（兜底重连用）
            // 先从配置的 bootstrap 列表构建
            var boot_list = std.ArrayList(chord_types.NodeAddr).init(alloc);
            for (cfg.bootstrap) |b| {
                try boot_list.append(chord_types.NodeAddr{
                    .id = 0,
                    .host = b.host,
                    .port = b.port,
                    .tcp_port = b.tcp_port,
                });
            }

            // 从 dns_seeds URL 获取种子节点（HTTP JSON: [{"host":"...","port":...,"tcp_port":...}]）
            for (cfg.dns_seeds) |seed_url| {
                std.debug.print("[p2p] 从 DNS 种子获取节点: {s}\n", .{seed_url});
                const fetched = fetchBootstrapFromUrl(alloc, seed_url) catch |err| {
                    std.debug.print("[p2p] DNS 种子 {s} 获取失败: {}\n", .{ seed_url, err });
                    continue;
                };
                defer alloc.free(fetched);
                for (fetched) |addr| {
                    try boot_list.append(addr);
                    std.debug.print("[p2p] DNS 种子发现节点: {s}:{d} tcp={d}\n", .{ addr.host, addr.port, addr.tcp_port });
                }
            }

            const boot_addrs = try boot_list.toOwnedSlice();

            var chord = try chord_node.ChordNode.init(
                alloc,
                node_id,
                effective_host,
                cfg.listen_port,
                cfg.stabilize_interval_ms,
                cfg.proxy.transport,
                cfg.proxy.remote_host,
                cfg.proxy.remote_port,
                cfg.proxy.remote_path,
                cfg.proxy.route_host,
                cfg.proxy.route_port,
                cfg.data_dir,
                pk_hex[0..],
                maybe_relay_client,
                maybe_encrypted_relay,
                cfg.transport_mode,
                cfg.tcp_port,
                cfg.external_tcp_port,
                boot_addrs,
            );
            maybe_chord = &chord;
            g_chord = &chord;
            content_mod.setChord(&chord);
            chord.control_handler = pluginControlHandler;
            if (top_cfg) |c| {
                if (c.value.control_token) |tok| chord.control_token = tok;
            }

            // 启动加密中继 readerLoop（接收其他节点转发来的数据）
            if (maybe_encrypted_relay) |erc| {
                erc_reader_thread = erc.startReaderLoop() catch |err| blk: {
                    std.debug.print("[encrypted_relay] readerLoop 启动失败: {}\n", .{err});
                    break :blk null;
                };
            }

            // 启动 TCP 监听器（transport_mode == tcp 或 dual 时）
            if (cfg.transport_mode != .udp) {
                chord.startTcpListener(cfg.tcp_port) catch |err| {
                    std.debug.print("[chord] TCP 监听器启动失败: {}\n", .{err});
                };
            }

            // ── SOCKS5 代理（通过独立 relay TCP 隧道） ──
            if (cfg.socks_proxy_port > 0 and cfg.socks_relay_host.len > 0) {
                const socks_thread = try std.Thread.spawn(.{}, socks_relay.startProxy, .{
                    alloc,
                    cfg.socks_relay_host,
                    cfg.socks_relay_port,
                    effective_host,
                    cfg.socks_proxy_port, // 用 SOCKS 端口注册，避免与 Chord relay client 冲突
                    cfg.listen_port,
                    cfg.socks_proxy_port,
                });
                socks_thread.detach();
                std.debug.print("[p2p] SOCKS5 代理已启动 :{d} (独立 relay → {s}:{d})\n", .{
                    cfg.socks_proxy_port, cfg.socks_relay_host, cfg.socks_relay_port,
                });
            }

            // ── WSS 服务器初始化 ──
            if (cfg.proxy.enabled and cfg.proxy.wss_enabled) {
                const ws = try alloc.create(wss.WssServer);
                if (cfg.proxy.wss_tcp_bridge) {
                    ws.* = try wss.WssServer.initRelayBridge(
                        alloc,
                        "0.0.0.0",
                        cfg.proxy.wss_port,
                        cfg.proxy.wss_path,
                        cfg.proxy.wss_cert_file,
                        cfg.proxy.wss_key_file,
                        "127.0.0.1",
                        cfg.proxy.listen_port,
                    );
                } else {
                    ws.* = try wss.WssServer.init(
                        alloc,
                        "0.0.0.0",
                        cfg.proxy.wss_port,
                        cfg.proxy.wss_path,
                        cfg.proxy.wss_cert_file,
                        cfg.proxy.wss_key_file,
                        cfg.listen_port,
                    );
                }
                maybe_wss_server = ws;
                wss_server_thread = try std.Thread.spawn(.{}, wss.WssServer.run, .{ws});
            }

            // 代理线程初始化
            if (cfg.proxy.enabled) {
                if (std.mem.eql(u8, cfg.proxy.mode, "server")) {
                    // ── 服务器模式: TCP ProxyServer ──
                    if (std.mem.eql(u8, cfg.proxy.transport, "tcp")) {
                        const ps_ptr = try alloc.create(proxy.TcpProxyServer);
                        ps_ptr.* = try proxy.TcpProxyServer.init(alloc, cfg.listen_port, cfg.proxy.listen_port);
                        maybe_proxy_server = ps_ptr;
                        proxy_server_thread = try std.Thread.spawn(.{}, proxy.TcpProxyServer.run, .{ps_ptr});
                        std.debug.print("[p2p] 代理服务器(TCP): :{d} → UDP :{d}\n", .{ cfg.proxy.listen_port, cfg.listen_port });
                    }
                } else if (std.mem.eql(u8, cfg.proxy.mode, "client")) {
                    // ── 客户端模式 ──
                    if (std.mem.eql(u8, cfg.proxy.transport, "websocket")) {
                        // WebSocket reader 线程: 持久 WS → 本地 UDP
                        proxy_reader_thread = try std.Thread.spawn(.{}, proxy.runWSReader, .{
                            alloc,                 cfg.proxy.remote_host, cfg.proxy.remote_port,
                            cfg.proxy.remote_path, cfg.listen_port,       cfg.listen_host,
                            cfg.listen_port,
                        });
                        std.debug.print("[p2p] 代理客户端(WS): {s}:{d}{s} → route {s}:{d} (listener {s}:{d})\n", .{
                            cfg.proxy.remote_host, cfg.proxy.remote_port, cfg.proxy.remote_path,
                            cfg.proxy.route_host,  cfg.proxy.route_port,  cfg.listen_host,
                            cfg.listen_port,
                        });
                    } else {
                        std.debug.print("[p2p] 代理客户端(TCP): 按需连接 {s}:{d}\n", .{
                            cfg.proxy.remote_host, cfg.proxy.remote_port,
                        });
                    }
                }
            }

            // Bootstrap 加入网络：多引导节点学习（跨环融合）
            if (boot_addrs.len > 0) {
                for (boot_addrs) |boot_addr| {
                    std.debug.print("[chord] Bootstrap 节点: {s}:{d}\n", .{ boot_addr.host, boot_addr.port });
                }
                chord.joinMulti(boot_addrs) catch |err| {
                    std.debug.print("[chord] Bootstrap 全部失败: {}\n", .{err});
                };
            } else {
                std.debug.print("[chord] 无 Bootstrap 配置, 作为孤立节点\n", .{});
            }

            // UDP Echo 调试服务（仅当配置了端口时启动）
            if (cfg.proxy.udp_echo_port > 0) {
                const echo_server = try alloc.create(@import("src/p2p/udpecho.zig").UdpEchoServer);
                echo_server.* = try @import("src/p2p/udpecho.zig").UdpEchoServer.init(cfg.proxy.udp_echo_port);
                _ = try std.Thread.spawn(.{}, struct {
                    fn run(server: *@import("src/p2p/udpecho.zig").UdpEchoServer) void {
                        server.run();
                    }
                }.run, .{echo_server});
            }

            std.debug.print("=== [P2P] 初始化完成 ===\n\n", .{});
        } else {
            std.debug.print("[p2p] P2P 网络已禁用\n", .{});
        }
    } else {
        std.debug.print("[p2p] 无 P2P 配置, 跳过\n", .{});
    }

    // ── WASM 插件执行 ────────────────────────────────────────
    const configs: []PlugConfig = if (top_cfg) |c| c.value.plugins orelse blk: {
        break :blk &[_]PlugConfig{};
    } else blk: {
        var defaults: [embedded_list.len]PlugConfig = undefined;
        for (&defaults, 0..) |*d, i| {
            d.* = .{
                .name = &.{},
                .embed_path = embedded_list[i].path,
                .mem_kb = 512,
                .timeout_ms = 5000,
                .network = false,
                .write = false,
                .allow_host_info = true,
            };
        }
        break :blk &defaults;
    };

    // runPlugin 内部已将 m3_Call 移至 worker 线程并带超时熔断；
    // 外层仍按插件并发执行，join 等待全部返回（超时的 worker 已 detach）。
    var threads = std.ArrayList(std.Thread).init(alloc);
    defer {
        for (threads.items) |t| t.join();
        threads.deinit();
    }

    for (configs) |plug_cfg| {
        const name = if (plug_cfg.name.len > 0) plug_cfg.name else plug_cfg.embed_path;
        const wasm_data = lookupEmbedded(plug_cfg.embed_path) orelse {
            std.debug.print("[skip] {s}: embedded file {s} not found\n", .{ name, plug_cfg.embed_path });
            continue;
        };
        const thread = std.Thread.spawn(.{}, runPlugin, .{ plug_cfg, wasm_data, maybe_chord }) catch |err| {
            std.debug.print("[error] 无法启动插件线程 {s}: {}\n", .{ name, err });
            continue;
        };
        try threads.append(thread);
    }

    for (threads.items) |t| t.join();
    threads.clearRetainingCapacity();
    std.debug.print("\nAll plugins executed.\n", .{});

    // P2P 保活：给 stabilize 协议足够时间运行
    if (p2p_cfg != null and p2p_cfg.?.enabled) {
        const run_duration = p2p_cfg.?.run_duration_s;
        std.debug.print("[chord] 保持运行 {d}s 以完成 stabilize...\n", .{run_duration});
        const print_interval = if (run_duration > 20) run_duration / 4 else run_duration;
        var elapsed_s: u64 = 0;
        var ticks_this_s: u32 = 0;
        while (elapsed_s < run_duration) {
            // 持续驱动事件循环（收消息/stabilize/看门狗/控制通道），100ms 一拍
            if (maybe_chord) |chord| {
                chord.tick() catch |err| {
                    std.debug.print("[chord] tick 错误: {}\n", .{err});
                };
            }
            std.time.sleep(100 * std.time.ns_per_ms);
            ticks_this_s += 1;
            if (ticks_this_s >= 10) {
                ticks_this_s = 0;
                elapsed_s += 1;
                if (maybe_chord) |chord| {
                    if (elapsed_s % print_interval == 0 or elapsed_s == run_duration) {
                        chord.printState();
                    }
                }
            }
        }
    }

    // ── 关闭代理服务器 ────────────────────────────────────
    if (proxy_server_thread) |t| {
        if (maybe_proxy_server) |ps| {
            std.debug.print("[proxy] 正在关闭代理服务器...\n", .{});
            ps.deinit();
        }
        t.join();
        std.debug.print("[proxy] 代理服务器已关闭\n", .{});
    }
    if (maybe_proxy_server) |ps| {
        alloc.destroy(ps);
    }

    // ── 关闭代理 Reader ────────────────────────────────────
    if (proxy_reader_thread) |t| {
        std.debug.print("[proxy] 正在关闭代理 reader...\n", .{});
        t.join();
        std.debug.print("[proxy] 代理 reader 已关闭\n", .{});
    }

    // ── 关闭 Relay Reader ────────────────────────────────────
    if (relay_reader_thread) |t| {
        if (maybe_relay_client) |rc| {
            rc.running = false;
        }
        t.join();
        std.debug.print("[relay] reader 已关闭\n", .{});
    }
    if (maybe_relay_client) |rc| {
        rc.deinit();
        alloc.destroy(rc);
    }

    // ── 关闭加密中继客户端 ──────────────────────────────
    if (maybe_encrypted_relay) |erc| {
        erc.deinit();
        alloc.destroy(erc);
        std.debug.print("[encrypted_relay] 适配器已关闭\n", .{});
    }

    // ── 关闭 Relay Server ────────────────────────────────────
    if (relay_server_thread) |t| {
        if (maybe_relay_server) |rs| {
            rs.stop();
        }
        t.join();
        std.debug.print("[relay] 服务器已关闭\n", .{});
    }
    if (maybe_relay_server) |rs| {
        rs.deinit();
        alloc.destroy(rs);
    }

    // ── 关闭 WSS 服务器 ────────────────────────────────────
    if (wss_server_thread) |t| {
        if (maybe_wss_server) |ws| {
            ws.stop();
        }
        t.join();
        std.debug.print("[wss] 服务器已关闭\n", .{});
    }
    if (maybe_wss_server) |ws| {
        ws.deinit();
        alloc.destroy(ws);
    }

    // ── 关闭 P2P 网络 ────────────────────────────────────────
    if (chord_thread) |ct| {
        if (maybe_chord) |chord| {
            std.debug.print("[chord] 正在关闭 P2P 网络...\n", .{});
            chord.running = false;
        }
        ct.join();
        std.debug.print("[chord] 已关闭\n", .{});
    }
    if (maybe_chord) |chord| {
        chord.deinit();
    }
}

/// 从 HTTP URL 获取 Bootstrap 节点列表
/// 期望响应格式: [{"host":"...","port":...,"tcp_port":...}]
fn fetchBootstrapFromUrl(alloc: std.mem.Allocator, url: []const u8) ![]chord_types.NodeAddr {
    if (!std.mem.startsWith(u8, url, "http://")) return error.UnsupportedProtocol;
    const rest = url["http://".len..];
    const slash_pos = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..slash_pos];
    const path = if (slash_pos < rest.len) rest[slash_pos..] else "/";

    const colon = std.mem.indexOfScalar(u8, host_port, ':') orelse return error.InvalidUrl;
    const host = host_port[0..colon];
    const port = try std.fmt.parseInt(u16, host_port[colon + 1 ..], 10);

    const addr = try std.net.Address.parseIp(host, port);
    const stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();

    var req = std.ArrayList(u8).init(alloc);
    defer req.deinit();
    try req.writer().print("GET {s} HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ path, host });
    try stream.writeAll(req.items);

    var resp: [8192]u8 = undefined;
    const n = try stream.readAll(&resp);
    if (n == 0) return error.EmptyResponse;

    const body_start = std.mem.indexOf(u8, resp[0..n], "\r\n\r\n") orelse return error.InvalidResponse;
    const body = resp[body_start + 4 .. n];

    const parsed = try std.json.parseFromSlice([]const p2p_config_mod.BootstrapAddr, alloc, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var list = std.ArrayList(chord_types.NodeAddr).init(alloc);
    for (parsed.value) |b| {
        try list.append(chord_types.NodeAddr{
            .id = 0,
            .host = try alloc.dupe(u8, b.host),
            .port = b.port,
            .tcp_port = b.tcp_port,
        });
    }
    return list.toOwnedSlice();
}
