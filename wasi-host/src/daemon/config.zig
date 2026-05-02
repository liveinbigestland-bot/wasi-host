/// 守护进程配置定义
const std = @import("std");

pub const DaemonConfig = struct {
    // 进程监管
    enable: bool = true,
    supervise: bool = true,
    restart_delay_ms: u64 = 3000,
    max_restarts: u32 = 3,
    penalty_hours: u64 = 1,
    stable_period_s: u64 = 300,

    // 健康检查
    check_interval_ms: u64 = 30000,
    ping_timeout_ms: u64 = 3000,
    lookup_timeout_ms: u64 = 5000,

    // 自恢复
    auto_recovery: bool = true,
    rejoin_cooldown_ms: u64 = 60000,
    max_mismatches: u32 = 3,

    // 资源监控
    resource_monitor: bool = true,
    collect_interval_ms: u64 = 60000,
    disk_warn_percent: u8 = 90,

    // 日志管理
    log_max_size_mb: u32 = 10,
    log_keep_files: u32 = 3,
    log_path: []const u8 = "",

    // 上报与任务执行
    reporter_enable: bool = true,
    report_interval_ms: u64 = 60000,
    main_node_host: []const u8 = "",
    main_node_port: u16 = 20909,
    connect_timeout_ms: u64 = 5000,
    report_timeout_ms: u64 = 10000,

    // 主节点控制器（仅主节点设为 true）
    controller_enable: bool = false,
    controller_listen_port: u16 = 20909,
    controller_host: []const u8 = "",
    controller_max_peers: u32 = 50,
};

/// 从 JSON 字符串解析守护进程配置
pub fn parseConfig(alloc: std.mem.Allocator, json_text: []const u8) !DaemonConfig {
    var parsed = try std.json.parseFromSlice(DaemonConfig, alloc, json_text, .{
        .ignore_unknown_fields = true,
    });
    var cfg = parsed.value;
    // 深拷贝字符串字段（parsed.deinit 会释放 arena 内存）
    if (cfg.log_path.len > 0) {
        cfg.log_path = try alloc.dupe(u8, cfg.log_path);
    }
    if (cfg.main_node_host.len > 0) {
        cfg.main_node_host = try alloc.dupe(u8, cfg.main_node_host);
    }
    if (cfg.controller_host.len > 0) {
        cfg.controller_host = try alloc.dupe(u8, cfg.controller_host);
    }
    parsed.deinit();
    return cfg;
}

/// 默认配置（用于无配置文件启动）
pub fn defaultConfig() DaemonConfig {
    return DaemonConfig{};
}
