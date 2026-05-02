/// 资源监控（CPU/内存/磁盘/网络/IO）
/// 通过 /proc 文件系统读取，不侵入 wasi-host
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const config_mod = @import("config.zig");

/// C statvfs struct — matches sys/statvfs.h layout
/// unsigned long is 64-bit on x86_64, 32-bit on ARM
const Statvfs = if (builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .x86_64)
    extern struct {
        f_bsize: u64,
        f_frsize: u64,
        f_blocks: u64,
        f_bfree: u64,
        f_bavail: u64,
        f_files: u64,
        f_ffree: u64,
        f_favail: u64,
        f_fsid: u64,
        f_flag: u64,
        f_namemax: u64,
    }
else
    extern struct {
        f_bsize: u32,
        f_frsize: u32,
        f_blocks: u64,
        f_bfree: u64,
        f_bavail: u64,
        f_files: u64,
        f_ffree: u64,
        f_favail: u64,
        f_fsid: u32,
        f_flag: u32,
        f_namemax: u32,
    };

extern "c" fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;

pub const ResourceStats = struct {
    cpu_percent: f32 = 0.0,
    memory_mb: f32 = 0.0,
    disk_used_percent: f32 = 0.0,
    disk_free_gb: f32 = 0.0,
    net_rx_bytes: u64 = 0,
    net_tx_bytes: u64 = 0,
    io_read_bytes: u64 = 0,
    io_write_bytes: u64 = 0,
    collect_time: i64 = 0,
};

pub const ResourceMonitor = struct {
    alloc: std.mem.Allocator,
    config: config_mod.DaemonConfig,
    stats: ResourceStats,
    prev_rx: u64 = 0,
    prev_tx: u64 = 0,
    prev_cpu_total: u64 = 0,
    prev_cpu_process: u64 = 0,
    prev_read_bytes: u64 = 0,
    prev_write_bytes: u64 = 0,
    clock_ticks: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, cfg: config_mod.DaemonConfig) ResourceMonitor {
        return ResourceMonitor{
            .alloc = alloc,
            .config = cfg,
            .stats = ResourceStats{},
            .clock_ticks = 100,
        };
    }

    /// 采集一次资源数据
    pub fn collect(self: *ResourceMonitor, pid: i32) void {
        if (builtin.os.tag != .linux) {
            // 非 Linux 系统返回空数据
            self.stats = ResourceStats{};
            return;
        }

        if (pid <= 0) return;

        self.collectCpu(pid) catch {};
        self.collectMemory(pid) catch {};
        self.collectDisk() catch {};
        self.collectNetwork(pid) catch {};
        self.collectIO(pid) catch {};
        self.stats.collect_time = std.time.timestamp();
    }

    /// CPU 使用率
    fn collectCpu(self: *ResourceMonitor, pid: i32) !void {
        // 读取 /proc/<pid>/stat 获取进程 CPU 时间
        var stat_path_buf: [64]u8 = undefined;
        const stat_path = std.fmt.bufPrint(&stat_path_buf, "/proc/{d}/stat", .{pid}) catch return;

        const content = try readFile(self.alloc, stat_path);
        defer self.alloc.free(content);

        // 解析 stat 文件：第 14 个字段是 utime（用户态 jiffies）
        // cutime+13, cstime+14, starttime+21
        // 格式: pid (comm) state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime cutime cstime ...
        var fields = std.mem.splitScalar(u8, content, ' ');
        var field_idx: u32 = 0;
        var utime: u64 = 0;
        var stime: u64 = 0;
        var cutime: u64 = 0;
        var cstime: u64 = 0;

        while (fields.next()) |field| : (field_idx += 1) {
            if (field_idx == 0) continue; // pid
            if (field_idx == 1) continue; // comm (may contain spaces)
            if (field_idx == 2) { // state - skip
                // 实际 field 1 是 comm 可能包含空格，简化处理
                continue;
            }
            if (field_idx == 11) { // utime (field index 13 in 1-indexed /proc/stat)
                utime = std.fmt.parseInt(u64, field, 10) catch 0;
            } else if (field_idx == 12) {
                stime = std.fmt.parseInt(u64, field, 10) catch 0;
            } else if (field_idx == 13) {
                cutime = std.fmt.parseInt(u64, field, 10) catch 0;
            } else if (field_idx == 14) {
                cstime = std.fmt.parseInt(u64, field, 10) catch 0;
                break;
            }
        }

        const process_total = utime + stime + cutime + cstime;

        // 读取 /proc/stat 获取系统总 CPU 时间
        const sys_stat = try readFile(self.alloc, "/proc/stat");
        defer self.alloc.free(sys_stat);

        var sys_total: u64 = 0;
        if (std.mem.startsWith(u8, sys_stat, "cpu ")) {
            var sys_fields = std.mem.splitScalar(u8, sys_stat[4..], ' ');
            var i: u32 = 0;
            while (sys_fields.next()) |val| : (i += 1) {
                if (i >= 10) break;
                if (val.len == 0) continue;
                sys_total += std.fmt.parseInt(u64, val, 10) catch 0;
            }
        }

        // 计算 CPU 百分比
        if (self.prev_cpu_total > 0 and self.prev_cpu_process > 0) {
            const total_diff = sys_total - self.prev_cpu_total;
            const process_diff = process_total - self.prev_cpu_process;
            if (total_diff > 0) {
                self.stats.cpu_percent = @as(f32, @floatFromInt(process_diff)) / @as(f32, @floatFromInt(total_diff)) * 100.0;
            }
        }

        self.prev_cpu_total = sys_total;
        self.prev_cpu_process = process_total;
    }

    /// 内存使用（VmRSS）
    fn collectMemory(self: *ResourceMonitor, pid: i32) !void {
        var status_path_buf: [64]u8 = undefined;
        const status_path = std.fmt.bufPrint(&status_path_buf, "/proc/{d}/status", .{pid}) catch return;

        const content = try readFile(self.alloc, status_path);
        defer self.alloc.free(content);

        // 查找 VmRSS 行
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "VmRSS:")) {
                // "VmRSS:   12345 kB"
                var parts = std.mem.splitScalar(u8, line, ' ');
                while (parts.next()) |part| {
                    if (part.len == 0) continue;
                    const val = std.fmt.parseInt(u64, part, 10) catch continue;
                    self.stats.memory_mb = @as(f32, @floatFromInt(val)) / 1024.0;
                    break;
                }
                break;
            }
        }
    }

    /// 磁盘空间（statvfs）
    fn collectDisk(self: *ResourceMonitor) !void {
        // 使用 statvfs 检查当前工作目录所在分区的磁盘使用率
        var statvfs_buf: Statvfs = undefined;
        // 需要确定 wasi-host 所在的目录，这里用当前目录
        // 实际应用应使用配置的数据目录
        if (statvfs("/root", &statvfs_buf) != 0) {
            // 尝试用 "." 作为 fallback
            if (statvfs(".", &statvfs_buf) != 0) {
                return; // 无法获取，跳过
            }
        }
        const total = statvfs_buf.f_blocks * statvfs_buf.f_frsize;
        const free = statvfs_buf.f_bfree * statvfs_buf.f_frsize;
        const avail = statvfs_buf.f_bavail * statvfs_buf.f_frsize;

        if (total > 0) {
            self.stats.disk_used_percent = @as(f32, @floatFromInt(total - free)) / @as(f32, @floatFromInt(total)) * 100.0;
        }
        self.stats.disk_free_gb = @as(f32, @floatFromInt(avail)) / (1024.0 * 1024.0 * 1024.0);

        // 磁盘告警
        if (self.stats.disk_used_percent > @as(f32, @floatFromInt(self.config.disk_warn_percent))) {
            std.debug.print("[resmon] 磁盘使用率 {d:.1}% 超过阈值 {d}%\n", .{ self.stats.disk_used_percent, self.config.disk_warn_percent });
        }
    }

    /// 网络流量（/proc/<pid>/net/dev）
    fn collectNetwork(self: *ResourceMonitor, pid: i32) !void {
        var net_path_buf: [64]u8 = undefined;
        const net_path = std.fmt.bufPrint(&net_path_buf, "/proc/{d}/net/dev", .{pid}) catch return;

        const content = try readFile(self.alloc, net_path);
        defer self.alloc.free(content);

        var total_rx: u64 = 0;
        var total_tx: u64 = 0;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            // 跳过标题行
            if (std.mem.indexOf(u8, line, ":") == null) continue;
            if (std.mem.startsWith(u8, line, "  lo:")) continue; // 忽略 loopback

            // 格式: eth0: rx_bytes rx_packets ... tx_bytes ...
            var parts = std.mem.splitScalar(u8, line, ':');
            const interface_part = parts.next() orelse continue;
            _ = interface_part;
            const data_part = parts.next() orelse continue;

            var data_fields = std.mem.splitScalar(u8, std.mem.trim(u8, data_part, " "), ' ');
            var field_idx: u32 = 0;
            while (data_fields.next()) |field| {
                if (field.len == 0) continue;
                const val = std.fmt.parseInt(u64, field, 10) catch continue;
                if (field_idx == 0) {
                    total_rx += val;
                } else if (field_idx == 8) {
                    total_tx += val;
                }
                field_idx += 1;
                if (field_idx > 16) break;
            }
        }

        self.stats.net_rx_bytes = total_rx;
        self.stats.net_tx_bytes = total_tx;
    }

    /// 进程 IO（/proc/<pid>/io）
    fn collectIO(self: *ResourceMonitor, pid: i32) !void {
        var io_path_buf: [64]u8 = undefined;
        const io_path = std.fmt.bufPrint(&io_path_buf, "/proc/{d}/io", .{pid}) catch return;

        const content = readFile(self.alloc, io_path) catch {
            return; // 可能没有权限
        };
        defer self.alloc.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "read_bytes:")) {
                const val_str = std.mem.trim(u8, line["read_bytes:".len..], " ");
                self.stats.io_read_bytes = std.fmt.parseInt(u64, val_str, 10) catch 0;
            } else if (std.mem.startsWith(u8, line, "write_bytes:")) {
                const val_str = std.mem.trim(u8, line["write_bytes:".len..], " ");
                self.stats.io_write_bytes = std.fmt.parseInt(u64, val_str, 10) catch 0;
            }
        }
    }

    /// 获取当前统计数据
    pub fn getStats(self: *ResourceMonitor) ResourceStats {
        return self.stats;
    }
};

/// 读取文件全部内容（辅助函数）
fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(alloc, 65536);
    return content;
}
