/// 日志管理（轮转）
/// 监控 wasi-host 日志文件大小，超限后轮转
const std = @import("std");
const fs = std.fs;

const config_mod = @import("config.zig");

pub const LogManager = struct {
    alloc: std.mem.Allocator,
    config: config_mod.DaemonConfig,
    last_check_time: i64 = 0,

    pub fn init(alloc: std.mem.Allocator, cfg: config_mod.DaemonConfig) LogManager {
        return LogManager{
            .alloc = alloc,
            .config = cfg,
        };
    }

    /// 检查并轮转日志（启动时 + 每分钟调用）
    pub fn checkAndRotate(self: *LogManager) void {
        const log_path = self.config.log_path;
        if (log_path.len == 0) return; // 没有日志路径，跳过

        const max_size = self.config.log_max_size_mb * 1024 * 1024;
        const keep = self.config.log_keep_files;

        // 检查当前日志文件大小
        const cwd = fs.cwd();
        const file = cwd.openFile(log_path, .{}) catch {
            return; // 文件不存在，跳过
        };
        defer file.close();

        const stat = file.stat() catch return;
        if (stat.size < max_size) return; // 未超限

        // 执行轮转：log → log.1 → log.2 → log.3
        std.debug.print("[logmgr] 日志超限 ({d}MB)，执行轮转\n", .{self.config.log_max_size_mb});

        // 从最老的开始删除/移动
        // 删除最老的备份
        var backup_path_buf: [1024]u8 = undefined;
        const oldest_path = std.fmt.bufPrint(&backup_path_buf, "{s}.{d}", .{ log_path, keep }) catch return;
        cwd.deleteFile(oldest_path) catch {};

        // 向后移动：log.{k} → log.{k+1}
        var k: u32 = keep;
        while (k > 0) : (k -= 1) {
            var old_path_buf: [1024]u8 = undefined;
            const old_name = std.fmt.bufPrint(&old_path_buf, "{s}.{d}", .{ log_path, k }) catch continue;
            var new_path_buf: [1024]u8 = undefined;
            const new_name = std.fmt.bufPrint(&new_path_buf, "{s}.{d}", .{ log_path, k + 1 }) catch continue;

            cwd.rename(old_name, new_name) catch {};
        }

        // log → log.1
        var first_backup_buf: [1024]u8 = undefined;
        const first_backup = std.fmt.bufPrint(&first_backup_buf, "{s}.1", .{log_path}) catch return;
        cwd.rename(log_path, first_backup) catch {};

        std.debug.print("[logmgr] 轮转完成: {s} → {s}.1\n", .{ log_path, log_path });
    }
};
