/// 进程监管器
/// fork/exec wasi-host，waitpid 监控，崩溃自动重启，防风暴
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const time = std.time;

const config_mod = @import("config.zig");

pub const SupervisorStatus = struct {
    pid: i32 = 0,
    running: bool = false,
    start_time: i64 = 0,
    crash_count: u32 = 0,
    last_crash_time: i64 = 0,
    penalty_until: i64 = 0, // 时间戳，在此时间之前不重启
    stable_start: i64 = 0,  // 本次稳定运行起始时间（用于判断 stable_period）
    in_penalty: bool = false,
};

pub const Supervisor = struct {
    alloc: std.mem.Allocator,
    config: config_mod.DaemonConfig,
    status: SupervisorStatus,
    wasi_host_path: []const u8,
    wasi_host_args: [][]const u8,
    should_stop: bool,

    pub fn init(alloc: std.mem.Allocator, cfg: config_mod.DaemonConfig, wasi_path: []const u8, args: [][]const u8) Supervisor {
        return Supervisor{
            .alloc = alloc,
            .config = cfg,
            .status = SupervisorStatus{},
            .wasi_host_path = wasi_path,
            .wasi_host_args = args,
            .should_stop = false,
        };
    }

    /// 启动 wasi-host 子进程
    pub fn startChild(self: *Supervisor) !void {
        if (builtin.os.tag != .linux) {
            std.debug.print("[supervisor] 非 Linux 系统，跳过 fork/exec\n", .{});
            return;
        }

        const pid = try posix.fork();
        if (pid == 0) {
            // 子进程：exec wasi-host
            // 转换参数为 C 兼容格式（null-terminated）
            const path_z = try self.alloc.dupeZ(u8, self.wasi_host_path);
            defer self.alloc.free(path_z);

            // 构建 argv（null-terminated 指针数组）
            var argv_z = try self.alloc.alloc(?[*:0]const u8, self.wasi_host_args.len + 1);
            defer self.alloc.free(argv_z);
            for (self.wasi_host_args, 0..) |arg, i| {
                argv_z[i] = try self.alloc.dupeZ(u8, arg);
            }
            argv_z[self.wasi_host_args.len] = null;

            const envp_z = [_]?[*:0]const u8{null};

            posix.execveZ(
                path_z,
                @as([*:null]const ?[*:0]const u8, @ptrCast(argv_z.ptr)),
                @as([*:null]const ?[*:0]const u8, @ptrCast(&envp_z)),
            ) catch {};
            // execve 失败时退出
            posix.exit(1);
        }

        // 父进程：记录子进程信息
        self.status.pid = pid;
        self.status.running = true;
        self.status.start_time = time.timestamp();
        self.status.stable_start = time.timestamp();
        std.debug.print("[supervisor] 启动 wasi-host, PID={d}\n", .{pid});
    }

    /// waitpid 循环，处理子进程退出
    /// 返回 true 表示应该继续运行，false 表示应该停止
    pub fn waitAndHandle(self: *Supervisor) !bool {
        if (builtin.os.tag != .linux) return true;
        if (self.status.pid <= 0) return true;

        const result = posix.waitpid(self.status.pid, posix.W.NOHANG);
        if (result.pid == 0) return true; // 无退出

        if (result.pid != self.status.pid) return true;
        const wstatus = result.status;

        // 子进程退出
        self.status.running = false;
        // 手动解析 waitpid status (POSIX 编码)
        const signaled = (wstatus & 0x7f) != 0 and (wstatus & 0x7f) != 0x7f;
        const exit_code = (wstatus >> 8) & 0xff;
        const exit_signal = if (signaled) @as(u32, wstatus & 0x7f) else 0;
        self.status.last_crash_time = time.timestamp();

        if (exit_signal == 9 or exit_signal == 15) {
            std.debug.print("[supervisor] wasi-host 被信号 {d} 终止\n", .{exit_signal});
        } else {
            std.debug.print("[supervisor] wasi-host 崩溃, exit_code={d}, signal={d}\n", .{ exit_code, exit_signal });
        }

        if (self.should_stop) {
            std.debug.print("[supervisor] 收到停止信号，不重启\n", .{});
            return false;
        }

        // 检查是否需要重启
        try self.handleCrash();
        return true;
    }

    /// 处理崩溃：更新计数器、判定惩罚、重启
    fn handleCrash(self: *Supervisor) !void {
        const now = time.timestamp();

        // 检查是否已过稳定期（计数归零）
        if (self.status.crash_count > 0) {
            const stable_duration = now - self.status.stable_start;
            if (stable_duration >= self.config.stable_period_s) {
                std.debug.print("[supervisor] 已稳定运行 {d}s，崩溃计数清零\n", .{stable_duration});
                self.status.crash_count = 0;
            }
        }

        self.status.crash_count += 1;
        std.debug.print("[supervisor] 崩溃计数: {d}/{d}\n", .{ self.status.crash_count, self.config.max_restarts });

        // 检查是否达到惩罚阈值
        if (self.status.crash_count > self.config.max_restarts) {
            const penalty_s = self.config.penalty_hours * 3600;
            self.status.penalty_until = now + @as(i64, @intCast(penalty_s));
            self.status.in_penalty = true;
            std.debug.print("[supervisor] 超过阈值，惩罚 {d} 小时\n", .{self.config.penalty_hours});
        }

        // 如果处于惩罚期，计算还需等待多久
        if (self.status.in_penalty) {
            const wait_remaining = self.status.penalty_until - now;
            if (wait_remaining > 0) {
                std.debug.print("[supervisor] 惩罚剩余 {d}s，等待后重启\n", .{wait_remaining});
                // 等待惩罚期结束（每秒检查一次 should_stop）
                var waited: i64 = 0;
                while (waited < wait_remaining) {
                    if (self.should_stop) return;
                    time.sleep(1 * time.ns_per_s);
                    waited += 1;
                }
            }
            self.status.in_penalty = false;
        }

        // 等待基础重启延迟
        const delay_ms = self.config.restart_delay_ms;
        std.debug.print("[supervisor] {d}ms 后重启 wasi-host\n", .{delay_ms});
        time.sleep(delay_ms * time.ns_per_ms);

        // 重启
        try self.startChild();
    }

    /// 发送信号给子进程
    pub fn signal(self: *Supervisor, sig: u8) void {
        if (builtin.os.tag != .linux) return;
        if (self.status.pid > 0 and self.status.running) {
            posix.kill(self.status.pid, sig) catch |err| {
                std.debug.print("[supervisor] kill 失败: {}\n", .{err});
            };
        }
    }

    /// 停止子进程
    pub fn stopChild(self: *Supervisor) void {
        self.should_stop = true;
        self.signal(15); // SIGTERM
    }

    /// 强制停止子进程
    pub fn killChild(self: *Supervisor) void {
        self.signal(9); // SIGKILL
    }

    /// 获取 uptime（秒）
    pub fn uptime(self: *Supervisor) i64 {
        if (!self.status.running) return 0;
        return time.timestamp() - self.status.start_time;
    }

    /// 获取当前状态摘要
    pub fn getStatus(self: *Supervisor) SupervisorStatus {
        return self.status;
    }
};
