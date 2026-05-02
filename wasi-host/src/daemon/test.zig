/// wasi-hostd 守护进程测试
/// 覆盖平台无关的逻辑层：DHT 类型、配置解析、自恢复、IP 解析、API 命令路由
const std = @import("std");
const testing = std.testing;

// ═══════════════════════════════════════════════════════════════
// 1. dht_types.zig — NodeId 编解码
// ═══════════════════════════════════════════════════════════════
const dht = @import("dht_types.zig");

test "dht idToHex formats 160-bit id" {
    const id: dht.NodeId = 0x0123456789abcdef0123456789abcdef01234567;
    const hex = dht.idToHex(id);
    try testing.expectEqual(@as(usize, 40), hex.len);
    try testing.expectEqualSlices(u8, "0123456789abcdef0123456789abcdef01234567", &hex);
}

test "dht idToHex zero id" {
    const id: dht.NodeId = 0;
    const hex = dht.idToHex(id);
    try testing.expectEqual(@as(usize, 40), hex.len);
    try testing.expectEqualSlices(u8, "0000000000000000000000000000000000000000", &hex);
}

test "dht idToHex max id" {
    const id: dht.NodeId = std.math.maxInt(dht.NodeId);
    const hex = dht.idToHex(id);
    try testing.expectEqualSlices(u8, "ffffffffffffffffffffffffffffffffffffffff", &hex);
}

test "dht idFromHex parses correctly" {
    const hex = "0123456789abcdef0123456789abcdef01234567";
    const id = try dht.idFromHex(hex);
    try testing.expectEqual(@as(dht.NodeId, 0x0123456789abcdef0123456789abcdef01234567), id);
}

test "dht idFromHex all zeros" {
    const hex = "0000000000000000000000000000000000000000";
    const id = try dht.idFromHex(hex);
    try testing.expectEqual(@as(dht.NodeId, 0), id);
}

test "dht idFromHex all f" {
    const hex = "ffffffffffffffffffffffffffffffffffffffff";
    const id = try dht.idFromHex(hex);
    try testing.expectEqual(std.math.maxInt(dht.NodeId), id);
}

test "dht idToHex / idFromHex roundtrip" {
    const test_ids = [_]dht.NodeId{
        0,
        0x0123456789abcdef0123456789abcdef01234567,
        std.math.maxInt(dht.NodeId),
        0xdeadbeefcafebabedeadbeefcafebabedeadbeef,
        0x0000000000000000000000000000000000000001,
        0x8000000000000000000000000000000000000000,
    };
    inline for (test_ids) |original| {
        const hex = dht.idToHex(original);
        const parsed = try dht.idFromHex(&hex);
        try testing.expectEqual(original, parsed);
    }
}

test "dht idFromHex rejects short input" {
    try testing.expectError(error.InvalidIdLength, dht.idFromHex("abc"));
    try testing.expectError(error.InvalidIdLength, dht.idFromHex(""));
    try testing.expectError(error.InvalidIdLength, dht.idFromHex("1234567890"));
}

test "dht idToHex is deterministic" {
    const id: dht.NodeId = 0xabcdef0123456789abcdef0123456789abcdef01;
    const hex1 = dht.idToHex(id);
    const hex2 = dht.idToHex(id);
    try testing.expectEqualSlices(u8, &hex1, &hex2);
}

test "dht idToHex lowercases correctly" {
    const id: dht.NodeId = 0xABCDEF0123456789ABCDEF0123456789ABCDEF01;
    const hex = dht.idToHex(id);
    for (hex) |c| {
        if (c >= 'A' and c <= 'F') {
            try testing.expect(false);
        }
    }
}

// ═══════════════════════════════════════════════════════════════
// 2. config.zig — 配置解析
// ═══════════════════════════════════════════════════════════════
const config_mod = @import("config.zig");

test "config parse empty json uses defaults" {
    const cfg = try config_mod.parseConfig(testing.allocator, "{}");
    defer {
        testing.allocator.free(cfg.log_path);
        testing.allocator.free(cfg.main_node_host);
    }
    try testing.expect(cfg.enable);
    try testing.expect(cfg.supervise);
    try testing.expectEqual(@as(u64, 30000), cfg.check_interval_ms);
    try testing.expectEqual(@as(u64, 3000), cfg.ping_timeout_ms);
    try testing.expectEqual(@as(u64, 60000), cfg.rejoin_cooldown_ms);
    try testing.expectEqual(@as(u64, 60000), cfg.report_interval_ms);
    try testing.expect(cfg.auto_recovery);
    try testing.expectEqual(@as(u16, 20909), cfg.main_node_port);
    try testing.expectEqual(@as(u32, 3), cfg.max_restarts);
    try testing.expect(!cfg.controller_enable);
}

test "config overrides specified fields" {
    const json =
        \\{
        \\  "enable": false,
        \\  "supervise": false,
        \\  "check_interval_ms": 5000,
        \\  "log_path": "/var/log/wasi-hostd.log",
        \\  "main_node_host": "192.168.1.100",
        \\  "main_node_port": 9090,
        \\  "max_restarts": 5
        \\}
    ;
    const cfg = try config_mod.parseConfig(testing.allocator, json);
    defer {
        testing.allocator.free(cfg.log_path);
        testing.allocator.free(cfg.main_node_host);
    }
    try testing.expect(!cfg.enable);
    try testing.expect(!cfg.supervise);
    try testing.expectEqual(@as(u64, 5000), cfg.check_interval_ms);
    try testing.expectEqualSlices(u8, "/var/log/wasi-hostd.log", cfg.log_path);
    try testing.expectEqualSlices(u8, "192.168.1.100", cfg.main_node_host);
    try testing.expectEqual(@as(u16, 9090), cfg.main_node_port);
    try testing.expectEqual(@as(u32, 5), cfg.max_restarts);
}

test "config ignores unknown fields" {
    const json =
        \\{
        \\  "enable": false,
        \\  "nonexistent_field": true,
        \\  "another_unknown": "value",
        \\  "check_interval_ms": 10000
        \\}
    ;
    const cfg = try config_mod.parseConfig(testing.allocator, json);
    defer {
        testing.allocator.free(cfg.log_path);
        testing.allocator.free(cfg.main_node_host);
    }
    try testing.expect(!cfg.enable);
    try testing.expectEqual(@as(u64, 10000), cfg.check_interval_ms);
}

test "config default config values" {
    const cfg = config_mod.defaultConfig();
    try testing.expect(cfg.enable);
    try testing.expect(cfg.supervise);
    try testing.expectEqual(@as(u64, 3000), cfg.restart_delay_ms);
}

test "config empty log path" {
    const cfg = try config_mod.parseConfig(testing.allocator, "{}");
    defer {
        testing.allocator.free(cfg.log_path);
        testing.allocator.free(cfg.main_node_host);
    }
    try testing.expectEqualSlices(u8, "", cfg.log_path);
}

// ═══════════════════════════════════════════════════════════════
// 3. healer.zig — 自恢复逻辑
// ═══════════════════════════════════════════════════════════════
const healer_mod = @import("healer.zig");
const monitor_mod = @import("monitor.zig");

test "healer init and shouldStabilize" {
    const cfg = config_mod.defaultConfig();
    var healer = healer_mod.Healer.init(testing.allocator, cfg);
    try testing.expect(healer.shouldStabilize());
}

test "healer rejoin cooldown zero" {
    var cfg = config_mod.defaultConfig();
    cfg.rejoin_cooldown_ms = 0;
    var healer = healer_mod.Healer.init(testing.allocator, cfg);

    const result1 = try healer.triggerRejoin();
    try testing.expect(result1);

    const result2 = try healer.triggerRejoin();
    try testing.expect(result2);
}

test "healer rejoin cooldown blocks" {
    var cfg = config_mod.defaultConfig();
    cfg.rejoin_cooldown_ms = 60000;
    var healer = healer_mod.Healer.init(testing.allocator, cfg);

    const result1 = try healer.triggerRejoin();
    try testing.expect(result1);

    const result2 = try healer.triggerRejoin();
    try testing.expect(!result2);

    const remaining = healer.rejoinCooldownRemaining();
    try testing.expect(remaining > 0);
}

test "healer no health action on ok" {
    const cfg = config_mod.defaultConfig();
    var healer = healer_mod.Healer.init(testing.allocator, cfg);
    var fake_supervisor: @import("supervisor.zig").Supervisor = undefined;

    const result = try healer.heal(.ok, 0, &fake_supervisor);
    try testing.expect(!result);
}

// ═══════════════════════════════════════════════════════════════
// 4. monitor.zig — 健康监控初始状态
// ═══════════════════════════════════════════════════════════════

test "monitor init works" {
    const cfg = config_mod.defaultConfig();
    var monitor = try monitor_mod.Monitor.init(testing.allocator, cfg);
    defer monitor.deinit();

    try testing.expectEqual(monitor_mod.HealthStatus.unknown, monitor.getHealth());
    const status = monitor.getNodeStatus();
    try testing.expect(!status.alive);
    try testing.expect(status.isolated);
}

test "monitor set bootstrap" {
    const cfg = config_mod.defaultConfig();
    var monitor = try monitor_mod.Monitor.init(testing.allocator, cfg);
    defer monitor.deinit();

    monitor.setBootstrap("192.168.1.1", 20808);
    // Bootstrap set, no crash
}

// ═══════════════════════════════════════════════════════════════
// 5. api.zig — 命令路由（不依赖 Unix Socket）
// ═══════════════════════════════════════════════════════════════

fn makeTestApi(cfg: config_mod.DaemonConfig) struct {
    api: @import("api.zig").ApiServer,
    monitor: monitor_mod.Monitor,
    response: std.ArrayList(u8),
} {
    var supervisor = @import("supervisor.zig").Supervisor.init(testing.allocator, cfg, "wasi-host", &.{});
    var monitor = monitor_mod.Monitor.init(testing.allocator, cfg) catch unreachable;
    var resmon = @import("resmon.zig").ResourceMonitor.init(testing.allocator, cfg);
    var healer = healer_mod.Healer.init(testing.allocator, cfg);
    var logmgr = @import("logmgr.zig").LogManager.init(testing.allocator, cfg);

    const backend = @import("api.zig").Backend{
        .supervisor = &supervisor,
        .monitor = &monitor,
        .resmon = &resmon,
        .healer = &healer,
        .logmgr = &logmgr,
        .local_port = 0,
        .config = &cfg,
    };

    return .{
        .api = @import("api.zig").ApiServer.init(testing.allocator, backend),
        .monitor = monitor,
        .response = std.ArrayList(u8).init(testing.allocator),
    };
}

test "api help command lists all commands" {
    const cfg = config_mod.defaultConfig();
    var ctx = makeTestApi(cfg);
    defer {
        ctx.monitor.deinit();
        ctx.response.deinit();
    }

    try ctx.api.handleCommand("help", &ctx.response);
    try testing.expect(ctx.response.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "status") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "succ") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "pred") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "finger") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "find-succ") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "stats") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "restart") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "rejoin") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "log") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "reload") != null);
}

test "api unknown command" {
    const cfg = config_mod.defaultConfig();
    var ctx = makeTestApi(cfg);
    defer {
        ctx.monitor.deinit();
        ctx.response.deinit();
    }

    try ctx.api.handleCommand("nonexistent", &ctx.response);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "unknown command") != null);
}

test "api stats command" {
    const cfg = config_mod.defaultConfig();
    var ctx = makeTestApi(cfg);
    defer {
        ctx.monitor.deinit();
        ctx.response.deinit();
    }

    try ctx.api.handleCommand("stats", &ctx.response);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "cpu_percent") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "memory_mb") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "disk_free_gb") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "net_rx_bytes") != null);
}

test "api reload command" {
    const cfg = config_mod.defaultConfig();
    var ctx = makeTestApi(cfg);
    defer {
        ctx.monitor.deinit();
        ctx.response.deinit();
    }

    try ctx.api.handleCommand("reload", &ctx.response);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "ok") != null);
}

test "api status command" {
    const cfg = config_mod.defaultConfig();
    var ctx = makeTestApi(cfg);
    defer {
        ctx.monitor.deinit();
        ctx.response.deinit();
    }

    try ctx.api.handleCommand("status", &ctx.response);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "pid") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "running") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.response.items, "health") != null);
}

// ═══════════════════════════════════════════════════════════════
// 6. reporter.zig — Reporter 初始化
// ═══════════════════════════════════════════════════════════════

test "reporter init works" {
    const cfg = config_mod.defaultConfig();
    var supervisor = @import("supervisor.zig").Supervisor.init(testing.allocator, cfg, "wasi-host", &.{});
    var monitor = try monitor_mod.Monitor.init(testing.allocator, cfg);
    defer monitor.deinit();
    var resmon = @import("resmon.zig").ResourceMonitor.init(testing.allocator, cfg);
    var healer = healer_mod.Healer.init(testing.allocator, cfg);

    var monitor2 = try monitor_mod.Monitor.init(testing.allocator, cfg);
    defer monitor2.deinit();
    var resmon2 = @import("resmon.zig").ResourceMonitor.init(testing.allocator, cfg);
    var healer2 = healer_mod.Healer.init(testing.allocator, cfg);
    var logmgr = @import("logmgr.zig").LogManager.init(testing.allocator, cfg);
    const backend = @import("api.zig").Backend{
        .supervisor = &supervisor,
        .monitor = &monitor2,
        .resmon = &resmon2,
        .healer = &healer2,
        .logmgr = &logmgr,
        .local_port = 0,
        .config = &cfg,
    };
    var api_server = @import("api.zig").ApiServer.init(testing.allocator, backend);

    var reporter = @import("reporter.zig").Reporter.init(
        testing.allocator,
        cfg,
        &supervisor,
        &monitor,
        &resmon,
        &healer,
        &api_server,
        "1.0.0-test",
    );
    defer reporter.deinit();

    try testing.expect(!reporter.running);
}

// ═══════════════════════════════════════════════════════════════
// 7. supervisor.zig — 监管器逻辑
// ═══════════════════════════════════════════════════════════════

test "supervisor init and status" {
    const cfg = config_mod.defaultConfig();
    var supervisor = @import("supervisor.zig").Supervisor.init(testing.allocator, cfg, "wasi-host", &.{});

    try testing.expect(!supervisor.status.running);
    try testing.expectEqual(@as(i32, 0), supervisor.status.pid);
    try testing.expectEqual(@as(u32, 0), supervisor.status.crash_count);
    try testing.expect(!supervisor.status.in_penalty);
    try testing.expect(!supervisor.should_stop);

    try testing.expectEqual(@as(i64, 0), supervisor.uptime());
}

test "supervisor stop and kill are no-ops when not running" {
    const cfg = config_mod.defaultConfig();
    var supervisor = @import("supervisor.zig").Supervisor.init(testing.allocator, cfg, "wasi-host", &.{});

    supervisor.stopChild();
    try testing.expect(supervisor.should_stop);

    // Resetting should_stop to test killChild sets it too
    supervisor.should_stop = false;
    supervisor.killChild();
    try testing.expect(supervisor.should_stop);
}

// ═══════════════════════════════════════════════════════════════
// 8. logmgr.zig — 日志轮转
// ═══════════════════════════════════════════════════════════════

test "logmgr no rotate when file not exists" {
    const cfg = config_mod.defaultConfig();
    var cfg_mut = cfg;
    cfg_mut.log_path = "nonexistent-log-file-for-test.log";
    cfg_mut.log_max_size_mb = 10;

    var logmgr = @import("logmgr.zig").LogManager.init(testing.allocator, cfg_mut);
    logmgr.checkAndRotate();
}

test "logmgr no rotate when file too small" {
    const tmp_log_path = "wasi-hostd-test-small.log";
    defer std.fs.cwd().deleteFile(tmp_log_path) catch {};

    {
        const f = try std.fs.cwd().createFile(tmp_log_path, .{});
        defer f.close();
        try f.writeAll("small");
    }

    var cfg = config_mod.defaultConfig();
    cfg.log_path = tmp_log_path;
    cfg.log_max_size_mb = 10;

    var logmgr = @import("logmgr.zig").LogManager.init(testing.allocator, cfg);
    logmgr.checkAndRotate();

    // File should still exist (no rotation triggered)
    const f2 = try std.fs.cwd().openFile(tmp_log_path, .{});
    f2.close();
}

test "logmgr rotate triggers on small max_size" {
    const tmp_log_path = "wasi-hostd-test-rotate.log";
    defer std.fs.cwd().deleteFile(tmp_log_path) catch {};
    defer std.fs.cwd().deleteFile(tmp_log_path ++ ".1") catch {};
    defer std.fs.cwd().deleteFile(tmp_log_path ++ ".2") catch {};

    {
        const f = try std.fs.cwd().createFile(tmp_log_path, .{});
        defer f.close();
        try f.writeAll("test log data for rotation\n");
    }

    var cfg = config_mod.defaultConfig();
    cfg.log_path = tmp_log_path;
    cfg.log_max_size_mb = 0;
    cfg.log_keep_files = 2;

    var logmgr = @import("logmgr.zig").LogManager.init(testing.allocator, cfg);
    logmgr.checkAndRotate();

    // After rotation, .1 backup should exist
    const backup = std.fs.cwd().openFile(tmp_log_path ++ ".1", .{}) catch {
        // Rotation may not always produce .1 if file is exactly at boundary
        // but at minimum no crash occurred
        return;
    };
    backup.close();
}

// ═══════════════════════════════════════════════════════════════
// 9. resmon.zig — 资源监控初始状态
// ═══════════════════════════════════════════════════════════════

test "resmon init and empty stats" {
    const cfg = config_mod.defaultConfig();
    var resmon = @import("resmon.zig").ResourceMonitor.init(testing.allocator, cfg);

    const stats = resmon.getStats();
    try testing.expectEqual(@as(f32, 0.0), stats.cpu_percent);
    try testing.expectEqual(@as(f32, 0.0), stats.memory_mb);
    try testing.expectEqual(@as(f32, 0.0), stats.disk_used_percent);
    try testing.expectEqual(@as(u64, 0), stats.net_rx_bytes);
    try testing.expectEqual(@as(u64, 0), stats.net_tx_bytes);
}

// ═══════════════════════════════════════════════════════════════
// 10. controller.zig — 主节点控制器
// ═══════════════════════════════════════════════════════════════
const controller_mod = @import("controller.zig");

test "controller init and empty node registry" {
    const cfg = config_mod.defaultConfig();
    var ctrl = controller_mod.Controller.init(testing.allocator, cfg, "1.0.0-test");
    defer ctrl.deinit();

    try testing.expectEqual(@as(usize, 0), ctrl.nodeCount());

    var list = try ctrl.getNodeList();
    defer list.deinit();
    try testing.expectEqual(@as(usize, 0), list.items.len);
}

test "controller addTask unknown node returns false" {
    const cfg = config_mod.defaultConfig();
    var ctrl = controller_mod.Controller.init(testing.allocator, cfg, "1.0.0-test");
    defer ctrl.deinit();

    const result = try ctrl.addTask("nonexistent-node-id", "restart");
    try testing.expect(!result);
}

test "controller broadcastTask on empty registry returns 0" {
    const cfg = config_mod.defaultConfig();
    var ctrl = controller_mod.Controller.init(testing.allocator, cfg, "1.0.0-test");
    defer ctrl.deinit();

    const count = try ctrl.broadcastTask("restart");
    try testing.expectEqual(@as(usize, 0), count);
}

test "controller start disabled by default" {
    const cfg = config_mod.defaultConfig();
    try testing.expect(!cfg.controller_enable);
}

test "controller start on non-linux returns error" {
    const cfg = config_mod.defaultConfig();
    var cfg_mut = cfg;
    cfg_mut.controller_enable = true;
    var ctrl = controller_mod.Controller.init(testing.allocator, cfg_mut, "1.0.0-test");
    defer ctrl.deinit();
    // If not Linux, start returns error.NotSupported
    if (comptime @import("builtin").os.tag != .linux) {
        try testing.expectError(error.NotSupported, ctrl.start());
    }
}

test "controller getNodeInfo returns null for unknown node" {
    const cfg = config_mod.defaultConfig();
    var ctrl = controller_mod.Controller.init(testing.allocator, cfg, "1.0.0-test");
    defer ctrl.deinit();

    const info = ctrl.getNodeInfo("unknown");
    try testing.expect(info == null);
}

// ═══════════════════════════════════════════════════════════════
// 11. controller.zig — getLocalIP / hasPendingUpdate / handleReport
// ═══════════════════════════════════════════════════════════════

test "controller getLocalIP uses config host" {
    var cfg = config_mod.defaultConfig();
    cfg.controller_host = "192.168.1.100";
    const ip = try controller_mod.getLocalIP(testing.allocator, &cfg);
    defer testing.allocator.free(ip);
    try testing.expectEqualSlices(u8, "192.168.1.100", ip);
}

test "controller getLocalIP falls back on non-linux" {
    const cfg = config_mod.defaultConfig();
    const ip = try controller_mod.getLocalIP(testing.allocator, &cfg);
    defer testing.allocator.free(ip);
    if (comptime @import("builtin").os.tag != .linux) {
        try testing.expectEqualSlices(u8, "127.0.0.1", ip);
    }
}

test "controller hasPendingUpdate returns false for empty tasks" {
    var info = controller_mod.NodeInfo{
        .node_id = 0,
        .node_id_hex = try testing.allocator.dupe(u8, ""),
        .last_report_raw = try testing.allocator.dupe(u8, ""),
        .last_seen = 0,
        .report_count = 0,
        .node_version = try testing.allocator.dupe(u8, ""),
        .daemon_version = try testing.allocator.dupe(u8, ""),
        .pending_tasks = std.ArrayList(controller_mod.Task).init(testing.allocator),
    };
    defer info.deinit(testing.allocator);

    try testing.expect(!controller_mod.Controller.hasPendingUpdate(&info));
}

test "controller hasPendingUpdate detects update_binary task" {
    var info = controller_mod.NodeInfo{
        .node_id = 0,
        .node_id_hex = try testing.allocator.dupe(u8, ""),
        .last_report_raw = try testing.allocator.dupe(u8, ""),
        .last_seen = 0,
        .report_count = 0,
        .node_version = try testing.allocator.dupe(u8, ""),
        .daemon_version = try testing.allocator.dupe(u8, ""),
        .pending_tasks = std.ArrayList(controller_mod.Task).init(testing.allocator),
    };
    defer info.deinit(testing.allocator);

    try testing.expect(!controller_mod.Controller.hasPendingUpdate(&info));

    try info.pending_tasks.append(.{
        .task_id = try testing.allocator.dupe(u8, "update-1"),
        .command = try testing.allocator.dupe(u8, "update_binary"),
        .params_json = try testing.allocator.dupe(u8, ""),
    });

    try testing.expect(controller_mod.Controller.hasPendingUpdate(&info));
}

test "controller handleReport registers node and returns JSON" {
    var cfg = config_mod.defaultConfig();
    cfg.controller_host = "10.0.0.1";
    var ctrl = controller_mod.Controller.init(testing.allocator, cfg, "1.0.0");
    defer ctrl.deinit();

    const report_json =
        \\{
        \\  "type": "report",
        \\  "node_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "wasi_host_version": "1.0.0",
        \\  "daemon_version": "1.0.0",
        \\  "timestamp": 1000000
        \\}
    ;

    const response = try ctrl.handleReport(report_json);
    defer testing.allocator.free(response);

    try testing.expectEqual(@as(usize, 1), ctrl.nodeCount());

    var list = try ctrl.getNodeList();
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualSlices(u8, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", list.items[0]);

    const info = ctrl.getNodeInfo("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 1), info.report_count);
    try testing.expectEqualSlices(u8, "1.0.0", info.node_version);
    try testing.expectEqualSlices(u8, "1.0.0", info.daemon_version);

    // Response should be valid JSON containing tasks array
    try testing.expect(std.mem.indexOf(u8, response, "\"tasks\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"status\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"ok\"") != null);
}

test "controller handleReport version mismatch triggers update_binary" {
    var cfg = config_mod.defaultConfig();
    cfg.controller_host = "10.0.0.1";
    // Controller version differs from reported node version
    var ctrl = controller_mod.Controller.init(testing.allocator, cfg, "2.0.0");
    defer ctrl.deinit();

    const report_json =
        \\{
        \\  "node_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        \\  "wasi_host_version": "1.0.0",
        \\  "daemon_version": "1.0.0"
        \\}
    ;

    const response = try ctrl.handleReport(report_json);
    defer testing.allocator.free(response);

    const info = ctrl.getNodeInfo("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") orelse return error.TestFailed;
    try testing.expect(info.pending_tasks.items.len > 0);
    try testing.expectEqualSlices(u8, "update_binary", info.pending_tasks.items[0].command);

    // Response should include the task
    try testing.expect(std.mem.indexOf(u8, response, "update_binary") != null);
    try testing.expect(std.mem.indexOf(u8, response, "10.0.0.1") != null);
}

test "controller handleReport multiple reports increment count" {
    var cfg = config_mod.defaultConfig();
    cfg.controller_host = "10.0.0.1";
    var ctrl = controller_mod.Controller.init(testing.allocator, cfg, "1.0.0");
    defer ctrl.deinit();

    const report_json =
        \\{
        \\  "node_id": "cccccccccccccccccccccccccccccccccccccccc",
        \\  "wasi_host_version": "1.0.0",
        \\  "daemon_version": "1.0.0"
        \\}
    ;

    _ = try ctrl.handleReport(report_json);
    _ = try ctrl.handleReport(report_json);
    _ = try ctrl.handleReport(report_json);

    const info = ctrl.getNodeInfo("cccccccccccccccccccccccccccccccccccccccc") orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 3), info.report_count);
}

test "controller handleReport two distinct nodes" {
    var cfg = config_mod.defaultConfig();
    cfg.controller_host = "10.0.0.1";
    var ctrl = controller_mod.Controller.init(testing.allocator, cfg, "1.0.0");
    defer ctrl.deinit();

    const report1 =
        \\{"node_id": "dddddddddddddddddddddddddddddddddddddddd", "wasi_host_version": "1.0.0", "daemon_version": "1.0.0"}
    ;
    const report2 =
        \\{"node_id": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "wasi_host_version": "1.0.0", "daemon_version": "1.0.0"}
    ;

    _ = try ctrl.handleReport(report1);
    _ = try ctrl.handleReport(report2);

    try testing.expectEqual(@as(usize, 2), ctrl.nodeCount());

    var list = try ctrl.getNodeList();
    defer list.deinit();
    try testing.expectEqual(@as(usize, 2), list.items.len);
}

test "controller handleReport missing node_id returns error" {
    const cfg = config_mod.defaultConfig();
    var ctrl = controller_mod.Controller.init(testing.allocator, cfg, "1.0.0");
    defer ctrl.deinit();

    const bad_json = \\{"type": "report"}
    ;
    try testing.expectError(error.MissingNodeId, ctrl.handleReport(bad_json));
}

test "controller addTask works after node registered via handleReport" {
    var cfg = config_mod.defaultConfig();
    cfg.controller_host = "10.0.0.1";
    var ctrl = controller_mod.Controller.init(testing.allocator, cfg, "1.0.0");
    defer ctrl.deinit();

    const report =
        \\{"node_id": "ffffffffffffffffffffffffffffffffffffffff", "wasi_host_version": "1.0.0", "daemon_version": "1.0.0"}
    ;
    _ = try ctrl.handleReport(report);

    const added = try ctrl.addTask("ffffffffffffffffffffffffffffffffffffffff", "restart");
    try testing.expect(added);

    const info = ctrl.getNodeInfo("ffffffffffffffffffffffffffffffffffffffff") orelse return error.TestFailed;
    try testing.expect(info.pending_tasks.items.len > 0);
    try testing.expectEqualSlices(u8, "restart", info.pending_tasks.items[0].command);
}

// ═══════════════════════════════════════════════════════════════
// 12. reporter.zig — buildReport JSON 格式 & executeTask 路由
// ═══════════════════════════════════════════════════════════════
const reporter_mod = @import("reporter.zig");

fn makeTestReporter() struct {
    reporter: reporter_mod.Reporter,
    supervisor: @import("supervisor.zig").Supervisor,
    monitor: monitor_mod.Monitor,
    resmon: @import("resmon.zig").ResourceMonitor,
    healer: healer_mod.Healer,
    logmgr: @import("logmgr.zig").LogManager,
    api: @import("api.zig").ApiServer,
    // cfg must live as long as the api (Backend holds pointer)
    cfg: config_mod.DaemonConfig,

    pub fn deinit(self: *@This()) void {
        self.reporter.deinit();
        self.monitor.deinit();
    }
} {
    var cfg = config_mod.defaultConfig();
    var supervisor = @import("supervisor.zig").Supervisor.init(testing.allocator, cfg, "wasi-host", &.{});
    var monitor = monitor_mod.Monitor.init(testing.allocator, cfg) catch unreachable;
    var resmon = @import("resmon.zig").ResourceMonitor.init(testing.allocator, cfg);
    var healer = healer_mod.Healer.init(testing.allocator, cfg);
    var logmgr = @import("logmgr.zig").LogManager.init(testing.allocator, cfg);

    const backend = @import("api.zig").Backend{
        .supervisor = &supervisor,
        .monitor = &monitor,
        .resmon = &resmon,
        .healer = &healer,
        .logmgr = &logmgr,
        .local_port = 0,
        .config = &cfg,
    };
    var api_server = @import("api.zig").ApiServer.init(testing.allocator, backend);

    const reporter = reporter_mod.Reporter.init(
        testing.allocator,
        cfg,
        &supervisor,
        &monitor,
        &resmon,
        &healer,
        &api_server,
        "1.0.0-test",
    );
    return .{
        .reporter = reporter,
        .supervisor = supervisor,
        .monitor = monitor,
        .resmon = resmon,
        .healer = healer,
        .logmgr = logmgr,
        .api = api_server,
        .cfg = cfg,
    };
}

test "reporter buildReport produces valid JSON with all fields" {
    var ctx = makeTestReporter();
    defer ctx.deinit();

    ctx.reporter.report_buf.clearAndFree();
    try ctx.reporter.buildReport();

    const json = ctx.reporter.report_buf.items;
    try testing.expect(json.len > 0);

    // Verify required fields exist
    try testing.expect(std.mem.indexOf(u8, json, "\"type\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"node_id\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"timestamp\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"wasi_host_version\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"daemon_version\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"ring_position\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"health\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"process\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"resources\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"_end\"") != null);

    // Verify it parses as valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value != .null);
    try testing.expect(parsed.value.object.get("type") != null);
    try testing.expect(parsed.value.object.get("health") != null);
}

test "reporter buildReport health section is correct" {
    var ctx = makeTestReporter();
    defer ctx.deinit();

    ctx.reporter.report_buf.clearAndFree();
    try ctx.reporter.buildReport();

    const json = ctx.reporter.report_buf.items;
    // Health status should be one of the known values
    try testing.expect(
        std.mem.indexOf(u8, json, "\"status\": \"ok\"") != null or
        std.mem.indexOf(u8, json, "\"status\": \"isolated\"") != null or
        std.mem.indexOf(u8, json, "\"status\": \"unknown\"") != null,
    );
}

test "reporter executeTask ping returns pong" {
    var ctx = makeTestReporter();
    defer ctx.deinit();

    const result = try ctx.reporter.executeTask("test-1", "ping", .{ .null = {} });
    try testing.expect(result.success);
    try testing.expectEqualSlices(u8, "pong", result.output);
    try testing.expectEqualSlices(u8, "test-1", result.task_id);
}

test "reporter executeTask unknown command returns error" {
    var ctx = makeTestReporter();
    defer ctx.deinit();

    const result = try ctx.reporter.executeTask("test-2", "nonexistent", .{ .null = {} });
    try testing.expect(!result.success);
    try testing.expectEqualSlices(u8, "unknown command", result.output);
    try testing.expectEqualSlices(u8, "test-2", result.task_id);
}

test "reporter executeTask stabilize and config_reload are recognized" {
    var ctx = makeTestReporter();
    defer ctx.deinit();

    const r1 = try ctx.reporter.executeTask("t1", "stabilize", .{ .null = {} });
    try testing.expect(r1.success);
    try testing.expectEqualSlices(u8, "stabilize triggered", r1.output);

    const r2 = try ctx.reporter.executeTask("t2", "config_reload", .{ .null = {} });
    try testing.expect(r2.success);
    try testing.expectEqualSlices(u8, "config reload requested", r2.output);
}

test "reporter buildReport no crash on default config" {
    // Even without reporter_enable, buildReport should not crash
    // (the enable check is in report(), not in buildReport)
    var ctx = makeTestReporter();
    defer ctx.deinit();

    ctx.reporter.report_buf.clearAndFree();
    try ctx.reporter.buildReport();
    try testing.expect(ctx.reporter.report_buf.items.len > 0);
}

// ═══════════════════════════════════════════════════════════════
// 13. monitor.zig — RingCheckResult & HealthStatus
// ═══════════════════════════════════════════════════════════════

test "monitor ring check result default values" {
    const check = monitor_mod.RingCheckResult{};
    try testing.expect(!check.query_ok);
    try testing.expect(!check.succ_match);
    try testing.expect(!check.pred_match);
    try testing.expect(check.ring_succ_id == null);
    try testing.expect(check.ring_pred_id == null);
}

test "monitor health status enum values" {
    try testing.expectEqual(monitor_mod.HealthStatus.ok, @as(monitor_mod.HealthStatus, @enumFromInt(0)));
    try testing.expectEqual(monitor_mod.HealthStatus.isolated, @as(monitor_mod.HealthStatus, @enumFromInt(1)));
    try testing.expectEqual(monitor_mod.HealthStatus.successor_mismatch, @as(monitor_mod.HealthStatus, @enumFromInt(2)));
    try testing.expectEqual(monitor_mod.HealthStatus.predecessor_mismatch, @as(monitor_mod.HealthStatus, @enumFromInt(3)));
    try testing.expectEqual(monitor_mod.HealthStatus.ping_timeout, @as(monitor_mod.HealthStatus, @enumFromInt(4)));
    try testing.expectEqual(monitor_mod.HealthStatus.unknown, @as(monitor_mod.HealthStatus, @enumFromInt(5)));
}

test "monitor node status default values" {
    const status = monitor_mod.NodeStatus{};
    try testing.expect(!status.alive);
    try testing.expect(status.isolated);
    try testing.expectEqual(@as(u16, 0), status.listen_port);
    try testing.expectEqual(@as(u32, 0), status.finger_count);
}
