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
const socks_relay = @import("src/p2p/socks_relay.zig");
const udp = @import("src/p2p/transport/udp.zig");
const proxy = @import("src/p2p/proxy.zig");
const relay = @import("src/p2p/relay.zig");
const wss = @import("src/p2p/wss.zig");
const net_detect = @import("src/p2p/net_detect.zig");
const p2p_bindings = @import("src/host/p2p_bindings.zig");
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

fn runPlugin(cfg: PlugConfig, wasm_bin: []const u8, maybe_chord: ?*chord_node.ChordNode) void {
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

    const chord_userdata: ?*anyopaque = @ptrCast(maybe_chord);
    const runtime = wasm3.m3_NewRuntime(env, cfg.mem_kb * 1024, chord_userdata) orelse {
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
                    std.debug.print("[警告] {s}: 绑定 {s} 失败 ({s})\n", .{ cfg.name, entry[0], slice });
                }
            }
        }
        std.debug.print("[p2p] 已为 {s} 注册 P2P 宿主函数\n", .{cfg.name});
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

    var p2p_cfg = if (top_cfg) |c| c.value.p2p else null;

    var public_host: ?[]const u8 = null;
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
    var chord_thread: ?std.Thread = null;
    var maybe_proxy_server: ?*proxy.TcpProxyServer = null;
    var proxy_server_thread: ?std.Thread = null;
    var proxy_reader_thread: ?std.Thread = null;
    var maybe_relay_server: ?*relay.RelayServer = null;
    var relay_server_thread: ?std.Thread = null;
    var maybe_relay_client: ?*relay.RelayClient = null;
    var relay_reader_thread: ?std.Thread = null;
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
            // 对于 listen_host 为特定 IP（非 0.0.0.0）的节点直接使用 listen_host，
            // 确保多节点共享同一公网 IP 时 relay 路由键唯一。
            // 对于 0.0.0.0（如 alwaysdata ext），回退到检测到的公网 IP。
            const effective_host = if (std.mem.eql(u8, cfg.listen_host, "0.0.0.0"))
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
                    rs.* = try relay.RelayServer.init(alloc, cfg.proxy.relay_listen_host, cfg.proxy.listen_port, cfg.proxy.max_connections, cfg.proxy.max_per_user, cfg.proxy.bandwidth_limit_kb);
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
                                alloc, cfg.proxy.remote_host, cfg.proxy.remote_port,
                                effective_host, cfg.listen_port, cfg.listen_port,
                                true, cfg.proxy.remote_path,
                            );
                        } else {
                            break :blk relay.RelayClient.init(
                                alloc, cfg.proxy.remote_host, cfg.proxy.remote_port,
                                effective_host, cfg.listen_port, cfg.listen_port,
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
                                std.debug.print("[relay] 级联转发: 本地 client → {s}:{d}\n", .{cfg.proxy.remote_host, cfg.proxy.remote_port});
                            } else {
                                std.debug.print("[relay] 跳过级联: client 连接到 127.0.0.1（本机 loopback）\n", .{});
                            }
                        } else {
                            std.debug.print("[relay] 中继客户端已连接 {s}:{d}\n", .{cfg.proxy.remote_host, cfg.proxy.remote_port});
                        }
                    } else |err| {
                        std.debug.print("[relay] 连接到 {s}:{d} 失败: {}, 跳过 relay client\n", .{cfg.proxy.remote_host, cfg.proxy.remote_port, err});
                        alloc.destroy(rc);
                    }
                }
            }

            // 转换 BootstrapAddr → NodeAddr（兜底重连用）
            // 先从配置的 bootstrap 列表构建
            var boot_list = std.ArrayList(chord_types.NodeAddr).init(alloc);
            for (cfg.bootstrap) |b| {
                try boot_list.append(chord_types.NodeAddr{
                    .id = 0, .host = b.host, .port = b.port, .tcp_port = b.tcp_port,
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
                cfg.transport_mode,
                cfg.tcp_port,
                cfg.external_tcp_port,
                boot_addrs,
            );
            maybe_chord = &chord;

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

            // Bootstrap 加入网络（遍历所有地址，任一成功即可）
            if (cfg.bootstrap.len > 0) {
                for (boot_addrs) |boot_addr| {
                    std.debug.print("[chord] Bootstrap 连接: {s}:{d}\n", .{ boot_addr.host, boot_addr.port });
                    chord.join(boot_addr) catch |err| {
                        std.debug.print("[chord] Bootstrap {s}:{d} 失败: {}\n", .{ boot_addr.host, boot_addr.port, err });
                        continue;
                    };
                    break; // 任一成功就退出循环
                }
            } else {
                std.debug.print("[chord] 无 Bootstrap 配置, 作为孤立节点\n", .{});
            }

            // 启动后台事件循环
            chord_thread = try std.Thread.spawn(.{}, chordEventLoop, .{ &chord });

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
        const thread = try std.Thread.spawn(.{}, runPlugin, .{ plug_cfg, wasm_data, maybe_chord });
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
            .id = 0, .host = try alloc.dupe(u8, b.host),
            .port = b.port, .tcp_port = b.tcp_port,
        });
    }
    return list.toOwnedSlice();
}
