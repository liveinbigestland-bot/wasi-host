const std = @import("std");
const json = std.json;
const builtin = @import("builtin");

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
const udp = @import("src/p2p/transport/udp.zig");
const proxy = @import("src/p2p/proxy.zig");
const posix = std.posix;

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

const TopConfig = struct {
    p2p: ?p2p_config_mod.P2PConfig = null,
    plugins: ?[]PlugConfig = null,
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

/// Chord 事件循环（在后台线程中运行）
fn chordEventLoop(node: *chord_node.ChordNode) void {
    std.debug.print("[chord] 事件循环已启动\n", .{});
    node.running = true;
    while (node.running) {
        node.tick() catch |err| {
            std.debug.print("[chord] tick 错误: {}\n", .{err});
        };
        std.time.sleep(100 * std.time.ns_per_ms); // 100ms tick 间隔
    }
    std.debug.print("[chord] 事件循环已停止\n", .{});
}

pub fn main() !void {
    initOsNameBuf();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

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

    const p2p_cfg = if (top_cfg) |c| c.value.p2p else null;

    // ── P2P 网络初始化 ───────────────────────────────────────
    var maybe_chord: ?*chord_node.ChordNode = null;
    var chord_thread: ?std.Thread = null;
    var maybe_proxy_server: ?*proxy.TcpProxyServer = null;
    var proxy_server_thread: ?std.Thread = null;
    var proxy_reader_thread: ?std.Thread = null;

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

            var chord = try chord_node.ChordNode.init(
                alloc,
                node_id,
                cfg.listen_host,
                cfg.listen_port,
                cfg.stabilize_interval_ms,
                cfg.proxy.transport,
                cfg.proxy.remote_host,
                cfg.proxy.remote_port,
                cfg.proxy.remote_path,
                cfg.proxy.route_host,
                cfg.proxy.route_port,
            );
            maybe_chord = &chord;

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
                    } else {
                        std.debug.print("[p2p] WebSocket 服务器模式由外部 index.js 提供\n", .{});
                    }
                } else if (std.mem.eql(u8, cfg.proxy.mode, "client")) {
                    // ── 客户端模式 ──
                    if (std.mem.eql(u8, cfg.proxy.transport, "websocket")) {
                        // WebSocket reader 线程: 持久 WS → 本地 UDP
                        proxy_reader_thread = try std.Thread.spawn(.{}, proxy.runWSReader, .{
                            alloc, cfg.proxy.remote_host, cfg.proxy.remote_port,
                            cfg.proxy.remote_path, cfg.listen_port, cfg.listen_host, cfg.listen_port,
                        });
                        std.debug.print("[p2p] 代理客户端(WS): {s}:{d}{s} → route {s}:{d} (listener {s}:{d})\n", .{
                            cfg.proxy.remote_host, cfg.proxy.remote_port, cfg.proxy.remote_path,
                            cfg.proxy.route_host, cfg.proxy.route_port,
                            cfg.listen_host, cfg.listen_port,
                        });
                    } else {
                        std.debug.print("[p2p] 代理客户端(TCP): 按需连接 {s}:{d}\n", .{
                            cfg.proxy.remote_host, cfg.proxy.remote_port,
                        });
                    }
                }
            }

            // Bootstrap 加入网络
            if (cfg.bootstrap.len > 0) {
                const boot_cfg = cfg.bootstrap[0];
                const boot_addr = chord_types.NodeAddr{
                    .id = 0, .host = boot_cfg.host, .port = boot_cfg.port,
                };
                std.debug.print("[chord] Bootstrap 连接: {s}:{d}\n", .{ boot_cfg.host, boot_cfg.port });
                chord.join(boot_addr) catch |err| {
                    std.debug.print("[chord] Bootstrap 失败: {}, 以孤立节点运行\n", .{err});
                };
            } else {
                std.debug.print("[chord] 无 Bootstrap 配置, 作为孤立节点\n", .{});
            }

            // 启动后台事件循环
            chord_thread = try std.Thread.spawn(.{}, chordEventLoop, .{ &chord });
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
    threads.clearRetainingCapacity();
    std.debug.print("\nAll plugins executed.\n", .{});

    // P2P 保活：给 stabilize 协议足够时间运行
    if (p2p_cfg != null and p2p_cfg.?.enabled) {
        const run_duration = p2p_cfg.?.run_duration_s;
        std.debug.print("[chord] 保持运行 {d}s 以完成 stabilize...\n", .{run_duration});
        var elapsed: u64 = 0;
        const print_interval = if (run_duration > 20) run_duration / 4 else run_duration;
        while (elapsed < run_duration) {
            std.time.sleep(1 * std.time.ns_per_s);
            elapsed += 1;
            if (maybe_chord) |chord| {
                if (elapsed % print_interval == 0 or elapsed == run_duration) {
                    chord.printState();
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
