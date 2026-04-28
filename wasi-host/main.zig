const std = @import("std");
const json = std.json;
const builtin = @import("builtin");

const wasm3 = @cImport({
    @cInclude("wasm3.h");
    @cInclude("m3_env.h");
    @cInclude("m3_api_wasi.h");
});

const plug_ai  = @embedFile("plug/ai_plugin.wasm");
const plug_api = @embedFile("plug/api_plugin.wasm");

const EmbeddedPlug = struct {
    path: []const u8,
    data: []const u8,
};

const embedded_list = [_]EmbeddedPlug{
    .{ .path = "plug/ai_plugin.wasm",  .data = plug_ai },
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

fn runPlugin(cfg: PlugConfig, wasm_bin: []const u8) void {
    std.debug.print("\n=== [启动] {s} (mem={d}KB, timeout={d}ms, net={}, write={}, host_info={}) ===\n", .{
        cfg.name, cfg.mem_kb, cfg.timeout_ms, cfg.network, cfg.write, cfg.allow_host_info,
    });

    var guard = TimeoutGuard.start(cfg.timeout_ms) catch {
        std.debug.print("[错误] {s}: 无法创建定时器\n", .{cfg.name});
        return;
    };

    const env = wasm3.m3_NewEnvironment() orelse {
        std.debug.print("[错误] {s}: 创建环境失败\n", .{cfg.name});
        return;
    };
    defer wasm3.m3_FreeEnvironment(env);

    const runtime = wasm3.m3_NewRuntime(env, cfg.mem_kb * 1024, null) orelse {
        std.debug.print("[错误] {s}: 创建运行时失败\n", .{cfg.name});
        return;
    };
    defer wasm3.m3_FreeRuntime(runtime);

    if (guard.check()) {
        std.debug.print("[超时] {s}: 初始化超时\n", .{cfg.name});
        return;
    }

    var mod: ?*wasm3.M3Module = null;
    if (wasm3.m3_ParseModule(env, &mod, wasm_bin.ptr, @intCast(wasm_bin.len)) != 0) {
        std.debug.print("[错误] {s}: 模块解析失败\n", .{cfg.name});
        return;
    }
    if (guard.check()) return;

    if (wasm3.m3_LoadModule(runtime, mod) != 0) {
        std.debug.print("[错误] {s}: 模块加载失败\n", .{cfg.name});
        return;
    }
    if (guard.check()) return;

    _ = wasm3.m3_LinkWASI(mod);
    if (guard.check()) return;

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
                    std.debug.print("[警告] {s}: 绑定 {s} 失败 ({s})\n", .{ cfg.name, entry[0], slice });
                }
            }
        }
    }
    if (guard.check()) return;

    var entry_fn: ?*wasm3.M3Function = null;
    if (wasm3.m3_FindFunction(&entry_fn, runtime, "_start") != 0) {
        std.debug.print("[警告] {s}: 未找到 _start 入口\n", .{cfg.name});
        return;
    }
    if (entry_fn == null) return;

    const call_result = wasm3.m3_Call(entry_fn, 0, null);
    if (call_result) |msg| {
        const slice = std.mem.sliceTo(msg, 0);
        if (std.mem.indexOf(u8, slice, "exit") == null) {
            std.debug.print("[错误] {s}: 执行失败 ({s})\n", .{ cfg.name, slice });
        }
    }
    std.debug.print("=== [完成] {s} ===\n", .{cfg.name});
}

pub fn main() !void {
    initOsNameBuf();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const cfg_text = blk: {
        const file = std.fs.cwd().openFile("config.json", .{}) catch |err| {
            std.debug.print("[info] config.json not found ({}), using defaults\n", .{err});
            break :blk null;
        };
        defer file.close();
        break :blk try file.readToEndAlloc(alloc, 1024 * 64);
    };
    defer if (cfg_text) |t| alloc.free(t);

    const app_cfg = if (cfg_text) |text| try json.parseFromSlice(AppConfig, alloc, text, .{}) else null;
    defer if (app_cfg) |p| p.deinit();

    const configs = if (app_cfg) |c| c.value.plugins else blk: {
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
        const thread = try std.Thread.spawn(.{}, runPlugin, .{ plug_cfg, wasm_data });
        try threads.append(thread);
    }

    for (threads.items) |t| t.join();
    std.debug.print("\nAll plugins executed.\n", .{});
}
