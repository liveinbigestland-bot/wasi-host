/// wasi-hostd — 守护进程入口
/// 进程监管 + 健康检查 + 资源监控 + 自恢复 + 管理接口 + 上报
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const time = std.time;
const fs = std.fs;

const config_mod = @import("config.zig");
const supervisor_mod = @import("supervisor.zig");
const monitor_mod = @import("monitor.zig");
const resmon_mod = @import("resmon.zig");
const healer_mod = @import("healer.zig");
const api_mod = @import("api.zig");
const reporter_mod = @import("reporter.zig");
const logmgr_mod = @import("logmgr.zig");
const controller_mod = @import("controller.zig");
const web_mod = @import("web.zig");

/// 编译时版本（由 build.zig 注入）
const build_options = @import("build_options");
const VERSION = build_options.version;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    // ── CLI 参数解析 ──
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.debug.print("用法: {s} <config-path>\n", .{args[0]});
        std.process.exit(1);
    }

    const config_path = args[1];

    // ── 读取配置 ──
    const config_file = fs.cwd().openFile(config_path, .{}) catch |err| {
        std.debug.print("无法打开配置文件: {}\n", .{err});
        std.process.exit(1);
    };
    defer config_file.close();

    const config_text = try config_file.readToEndAlloc(alloc, 65536);
    defer alloc.free(config_text);

    var config = try config_mod.parseConfig(alloc, config_text);
    std.debug.print("[main] 守护进程启动, config={s}\n", .{config_path});

    // ── 从配置中提取 wasi-host 监听端口（p2p.listen_port）──
    var wasi_host_port: u16 = 0;
    {
        const raw_parsed = try std.json.parseFromSlice(std.json.Value, alloc, config_text, .{ .ignore_unknown_fields = true });
        defer raw_parsed.deinit();
        if (raw_parsed.value.object.get("p2p")) |p2p_val| {
            if (p2p_val == .object) {
                if (p2p_val.object.get("listen_port")) |port_val| {
                    if (port_val == .integer) {
                        wasi_host_port = @intCast(port_val.integer);
                        std.debug.print("[main] 检测到 wasi-host 监听端口: {d}\n", .{wasi_host_port});
                    }
                }
            }
        }
    }
    if (wasi_host_port == 0) {
        std.debug.print("[main] 警告: 无法从配置中获取 p2p.listen_port，使用默认值 20808\n", .{});
        wasi_host_port = 20808;
    }

    // ── 状态管理 ──
    var supervisor = supervisor_mod.Supervisor.init(alloc, config, args[1], &.{});
    var monitor = try monitor_mod.Monitor.init(alloc, config);
    defer monitor.deinit();
    var resmon = resmon_mod.ResourceMonitor.init(alloc, config);
    var healer = healer_mod.Healer.init(alloc, config);
    var logmgr = logmgr_mod.LogManager.init(alloc, config);

    // ── 提取 wasi-host 路径和参数 ──
    // 配置文件路径同时也是 wasi-host 的配置路径
    // 默认 wasi-host 二进制在同一目录或 PATH 中
    const wasi_host_path = if (args.len > 2) args[2] else "wasi-host";
    var wasi_host_args = std.ArrayList([]const u8).init(alloc);
    defer wasi_host_args.deinit();
    try wasi_host_args.append(wasi_host_path);
    try wasi_host_args.append(config_path);

    supervisor.wasi_host_path = wasi_host_path;
    supervisor.wasi_host_args = wasi_host_args.items;

    // ── 控制器（主节点模式下启用） ──
    var controller = controller_mod.Controller.init(alloc, config, VERSION);
    controller.binary_path = wasi_host_path; // 提供同路径二进制供下载
    if (config.controller_enable) {
        controller.start() catch |err| {
            std.debug.print("[main] 控制器启动失败: {}\n", .{err});
        };
    }

    // ── Web API 服务器（主节点模式下启用） ──
    var web_server = web_mod.WebServer.init(alloc, web_mod.Backend{
        .controller = &controller,
        .config = &config,
        .version = VERSION,
    });
    if (config.web_api_enable) {
        web_server.start() catch |err| {
            std.debug.print("[main] Web API 服务器启动失败: {}\n", .{err});
        };
    }

    const api_backend = api_mod.Backend{
        .supervisor = &supervisor,
        .monitor = &monitor,
        .resmon = &resmon,
        .healer = &healer,
        .logmgr = &logmgr,
        .controller = &controller,
        .local_port = wasi_host_port,
        .config = &config,
    };

    var api_server = api_mod.ApiServer.init(alloc, api_backend);
    var reporter = reporter_mod.Reporter.init(alloc, config, &supervisor, &monitor, &resmon, &healer, &api_server, VERSION);

    // ── 启动 API 服务器 ──
    if (config.enable) {
        api_server.start() catch |err| {
            std.debug.print("[main] API 服务器启动失败: {}\n", .{err});
        };
    }
    defer api_server.stop();
    defer web_server.stop();

    // ── 启动 wasi-host ──
    if (config.supervise) {
        supervisor.startChild() catch |err| {
            std.debug.print("[main] 启动 wasi-host 失败: {}\n", .{err});
        };
    }

    // ── 主循环 ──
    const start_time_ms: u64 = @as(u64, @intCast(time.timestamp())) * 1000;
    var last_check_time_ms: u64 = start_time_ms; // 首次延迟 check_interval_ms，等子进程就绪
    var last_report_time_ms: u64 = 0;
    var last_collect_time_ms: u64 = 0;
    var last_log_check: i64 = 0;

    std.debug.print("[main] 进入主循环\n", .{});

    while (!supervisor.should_stop) {
        const now = time.timestamp();
        const now_u64 = @as(u64, @intCast(now));
        const now_ms = now_u64 * 1000;

        // 1. Supervisor: waitpid 检查（非阻塞）
        // [DBG] step=1
        if (config.supervise and supervisor.status.running) {
            _ = supervisor.waitAndHandle() catch |err| {
                std.debug.print("[main] waitpid 错误: {}\n", .{err});
            };
        }

        // 2. 健康检查
        // [DBG] step=2
        if (config.check_interval_ms > 0 and now_ms - last_check_time_ms >= config.check_interval_ms) {
            last_check_time_ms = now_ms;
            monitor.check(api_backend.local_port) catch |err| {
                std.debug.print("[main] 健康检查失败: {}\n", .{err});
            };

            // 自恢复
            if (config.auto_recovery) {
                const health = monitor.getHealth();
                const mismatches = monitor.consecutive_mismatches;
                _ = healer.heal(health, mismatches, &supervisor) catch |err| {
                    std.debug.print("[main] 自恢复失败: {}\n", .{err});
                };
            }
        }

        // 3. 资源采集
        // [DBG] step=3
        if (config.resource_monitor and config.collect_interval_ms > 0 and now_ms - last_collect_time_ms >= config.collect_interval_ms) {
            last_collect_time_ms = now_ms;
            resmon.collect(supervisor.status.pid);
        }

        // 4. 控制器连接处理（仅主节点）—— 必须在上报之前处理，避免自连死锁
        // [DBG] step=4
        controller.acceptAndHandle();

        // 5. 上报心跳
        // [DBG] step=5
        if (config.reporter_enable and config.report_interval_ms > 0 and now_ms - last_report_time_ms >= config.report_interval_ms) {
            last_report_time_ms = now_ms;
            reporter.report() catch |err| {
                // 上报失败不阻塞主循环
                std.debug.print("[main] 上报失败: {}\n", .{err});
            };
        }

        // 6. 日志轮转检查
        // [DBG] step=6
        if (now - last_log_check >= 60) {
            last_log_check = now;
            logmgr.checkAndRotate();
        }

        // 7. API 连接处理
        // [DBG] step=7
        api_server.acceptAndHandle();

        // 7b. Web API 连接处理（仅主节点）
        // [DBG] step=7b
        web_server.acceptAndHandle();

        // 8. 睡眠一小段时间，避免忙等
        // [DBG] step=8
        time.sleep(100 * time.ns_per_ms);
    }

    // ── 清理 ──
    std.debug.print("[main] 守护进程退出\n", .{});
    controller.deinit();
    if (config.supervise) {
        supervisor.stopChild();
        // 等待子进程退出
        if (builtin.os.tag == .linux and supervisor.status.pid > 0) {
            _ = posix.waitpid(supervisor.status.pid, 0);
        }
    }
}
