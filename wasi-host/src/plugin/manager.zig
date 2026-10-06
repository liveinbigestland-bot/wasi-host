const std = @import("std");

/// 动态插件运行时：注册表 + 取消/暂停控制 + 文件来源。
///
/// 设计要点：
/// - 每个插件分配一个句柄和 ControlBlock，记录常驻注册表直至进程退出。
/// - worker 线程在 m3_Call 前后绑定 tls_control；wasm3 的 m3_Yield
///   （函数调用边界）与 m3_ControlCheck（向后跳转边）在指令边界检查信号，
///   因此纯 CPU 死循环也可在回边被即时拦下，无需 detach/泄漏。
/// - 一个看门狗线程统一执行所有插件的 timeout_ms。
pub const State = enum {
    starting,
    running,
    paused,
    completed,
    failed,
    timeout,
    cancelled,
};

/// 控制信号：0 运行，1 暂停请求，2 取消，3 超时取消
pub const sig_run: u8 = 0;
pub const sig_pause: u8 = 1;
pub const sig_cancel: u8 = 2;
pub const sig_timeout: u8 = 3;

pub const ConfigSnapshot = struct {
    mem_kb: u32 = 512,
    timeout_ms: u32 = 5000,
    network: bool = false,
    write: bool = false,
    allow_host_info: bool = true,
};

pub const ControlBlock = struct {
    signal: std.atomic.Value(u8) = .{ .raw = sig_run },
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    pub fn requestPause(self: *ControlBlock) void {
        self.signal.store(sig_pause, .release);
    }

    pub fn cancel(self: *ControlBlock) void {
        self.mutex.lock();
        self.signal.store(sig_cancel, .release);
        self.cond.broadcast();
        self.mutex.unlock();
    }

    pub fn timeoutCancel(self: *ControlBlock) void {
        self.mutex.lock();
        self.signal.store(sig_timeout, .release);
        self.cond.broadcast();
        self.mutex.unlock();
    }

    pub fn resumeSignal(self: *ControlBlock) void {
        self.mutex.lock();
        self.signal.store(sig_run, .release);
        self.cond.broadcast();
        self.mutex.unlock();
    }
};

pub const Record = struct {
    handle: u64,
    name: []u8,
    state: State,
    config: ConfigSnapshot,
    started_ns: i128,
    finished_ns: ?i128 = null,
    exit_code: i32 = 0,
    duration_ms: u64 = 0,
    error_message: ?[]u8 = null,
    control: *ControlBlock,
};

pub const Info = struct {
    handle: u64,
    name: []const u8,
    state: State,
    config: ConfigSnapshot,
    duration_ms: u64,
    exit_code: i32,
    error_message: ?[]const u8,
};

/// 由宿主（main.zig）注册：管理器读完文件后调用它真正装载字节码
pub const LaunchFn = *const fn (
    ctx: ?*anyopaque,
    name: []const u8,
    bytes: []const u8,
    cfg: ConfigSnapshot,
) anyerror!u64;

/// 当前进程的管理器实例（供 Lua 宿主函数访问）
pub var global_manager: ?*Manager = null;

pub const Manager = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    records: std.AutoHashMap(u64, *Record),
    controls: std.AutoHashMap(u64, *ControlBlock),
    next_handle: std.atomic.Value(u32) = .{ .raw = 1 },

    launcher: ?LaunchFn = null,
    launcher_ctx: ?*anyopaque = null,

    running: std.atomic.Value(bool) = .{ .raw = false },
    watchdog: ?std.Thread = null,

    const max_wasm_bytes: usize = 32 * 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator) !*Manager {
        const m = try allocator.create(Manager);
        m.* = .{
            .allocator = allocator,
            .records = std.AutoHashMap(u64, *Record).init(allocator),
            .controls = std.AutoHashMap(u64, *ControlBlock).init(allocator),
        };
        return m;
    }

    pub fn deinit(self: *Manager) void {
        if (self.running.swap(false, .acq_rel)) {
            if (self.watchdog) |t| {
                t.join();
                self.watchdog = null;
            }
        }

        self.mutex.lock();

        var it = self.records.valueIterator();
        while (it.next()) |rec| {
            self.allocator.free(rec.*.name);
            if (rec.*.error_message) |msg| self.allocator.free(msg);
            self.allocator.destroy(rec.*.control);
            self.allocator.destroy(rec.*);
        }
        self.records.deinit();
        self.controls.deinit();
        self.mutex.unlock();
        self.allocator.destroy(self);
    }

    pub fn setLauncher(self: *Manager, f: LaunchFn, ctx: ?*anyopaque) void {
        self.launcher = f;
        self.launcher_ctx = ctx;
    }

    pub fn allocHandle(self: *Manager) u64 {
        return @intCast(self.next_handle.fetchAdd(1, .monotonic));
    }

    /// 启动期插件登记：返回其 ControlBlock
    pub fn register(
        self: *Manager,
        handle: u64,
        name: []const u8,
        cfg: ConfigSnapshot,
    ) !*ControlBlock {
        const control = try self.allocator.create(ControlBlock);
        control.* = .{};
        errdefer self.allocator.destroy(control);

        const rec = try self.allocator.create(Record);
        rec.* = .{
            .handle = handle,
            .name = try self.allocator.dupe(u8, name),
            .state = .starting,
            .config = cfg,
            .started_ns = std.time.nanoTimestamp(),
            .control = control,
        };
        errdefer {
            self.allocator.free(rec.name);
            self.allocator.destroy(rec);
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.controls.put(handle, control);
        try self.records.put(handle, rec);
        return control;
    }

    pub fn setState(self: *Manager, handle: u64, state: State) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.records.get(handle)) |rec| {
            rec.state = state;
            if (state == .completed or state == .failed or state == .timeout or state == .cancelled) {
                rec.finished_ns = std.time.nanoTimestamp();
            }
        }
    }

    pub fn setResult(
        self: *Manager,
        handle: u64,
        state: State,
        exit_code: i32,
        duration_ms: u64,
        err_msg: ?[]const u8,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const rec = self.records.get(handle) orelse return;
        rec.state = state;
        rec.exit_code = exit_code;
        rec.duration_ms = duration_ms;
        rec.finished_ns = std.time.nanoTimestamp();
        if (err_msg) |msg| {
            if (rec.error_message) |old| self.allocator.free(old);
            rec.error_message = self.allocator.dupe(u8, msg) catch null;
        }
    }

    pub fn isActive(rec: *const Record) bool {
        return rec.state == .starting or rec.state == .running or rec.state == .paused;
    }

    /// 请求取消；插件处于活动态时返回 true
    pub fn cancel(self: *Manager, handle: u64) bool {
        self.mutex.lock();
        const rec = self.records.get(handle);
        const active = if (rec) |r| isActive(r) else false;
        self.mutex.unlock();
        if (active) rec.?.control.cancel();
        return active;
    }

    pub fn pause(self: *Manager, handle: u64) bool {
        self.mutex.lock();
        const rec = self.records.get(handle);
        const can_pause = if (rec) |r| (r.state == .starting or r.state == .running) else false;
        self.mutex.unlock();
        if (can_pause) {
            rec.?.control.requestPause();
            self.setState(handle, .paused);
        }
        return can_pause;
    }

    pub fn resumePlugin(self: *Manager, handle: u64) bool {
        self.mutex.lock();
        const rec = self.records.get(handle);
        const can_resume = if (rec) |r| r.state == .paused else false;
        self.mutex.unlock();
        if (can_resume) {
            rec.?.control.resumeSignal();
            self.setState(handle, .running);
        }
        return can_resume;
    }

    /// 卸载非活动实例记录，释放关联资源；若仍在运行返回 false
    pub fn unload(self: *Manager, handle: u64) bool {
        self.mutex.lock();
        const rec = self.records.get(handle) orelse {
            self.mutex.unlock();
            return false;
        };
        if (isActive(rec)) {
            self.mutex.unlock();
            return false;
        }
        // 移出 records 与 controls
        _ = self.records.remove(handle);
        _ = self.controls.remove(handle);
        self.mutex.unlock();
        self.allocator.free(rec.name);
        if (rec.error_message) |msg| self.allocator.free(msg);
        self.allocator.destroy(rec.control);
        self.allocator.destroy(rec);
        return true;
    }

    /// 拷贝单个记录信息（调用者需用传入分配器释放 name/error_message）
    pub fn snapshot(self: *Manager, allocator: std.mem.Allocator, handle: u64) !?Info {
        self.mutex.lock();
        defer self.mutex.unlock();
        const rec = self.records.get(handle) orelse return null;
        return try copyInfo(allocator, rec);
    }

    pub fn snapshotAll(self: *Manager, allocator: std.mem.Allocator) ![]Info {
        self.mutex.lock();
        defer self.mutex.unlock();
        var list = std.ArrayList(Info).init(allocator);
        errdefer {
            for (list.items) |info| freeInfo(allocator, info);
            list.deinit();
        }
        var it = self.records.valueIterator();
        while (it.next()) |rec| {
            try list.append(try copyInfo(allocator, rec.*));
        }
        return list.toOwnedSlice();
    }

    fn copyInfo(allocator: std.mem.Allocator, rec: *Record) !Info {
        return .{
            .handle = rec.handle,
            .name = try allocator.dupe(u8, rec.name),
            .state = rec.state,
            .config = rec.config,
            .duration_ms = rec.duration_ms,
            .exit_code = rec.exit_code,
            .error_message = if (rec.error_message) |m| try allocator.dupe(u8, m) else null,
        };
    }

    pub fn freeInfo(allocator: std.mem.Allocator, info: Info) void {
        allocator.free(info.name);
        if (info.error_message) |m| allocator.free(m);
    }

    /// 从文件动态装载：ref 以 .wasm 结尾视为路径，否则解析为 plug/<ref>.wasm
    pub fn startFromFile(self: *Manager, ref: []const u8, cfg: ConfigSnapshot) !u64 {
        const path = if (std.mem.endsWith(u8, ref, ".wasm"))
            try self.allocator.dupe(u8, ref)
        else
            try std.fmt.allocPrint(self.allocator, "plug/{s}.wasm", .{ref});
        defer self.allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch return error.PluginFileNotFound;
        defer file.close();
        const bytes = try file.readToEndAlloc(self.allocator, max_wasm_bytes);

        return self.launchOwned(std.fs.path.basename(path), bytes, cfg);
    }

    /// 从已在内存中的字节码装载（DHT 内容拉取后使用）。
    /// 字节码所有权在调用时转交：成功路径由 worker 持有，失败路径由本函数释放。
    pub fn startFromBytes(self: *Manager, name: []const u8, bytes: []const u8, cfg: ConfigSnapshot) !u64 {
        return self.launchOwned(name, bytes, cfg);
    }

    /// 唯一的字节码→launcher 出口（文件/内存两条路径共用）
    fn launchOwned(self: *Manager, name: []const u8, bytes: []const u8, cfg: ConfigSnapshot) !u64 {
        if (self.launcher == null) {
            self.allocator.free(bytes);
            return error.NoLauncher;
        }
        self.ensureWatchdog();
        return self.launcher.?(self.launcher_ctx, name, bytes, cfg) catch |e| {
            self.allocator.free(bytes);
            return e;
        };
    }

    /// 列出 plug/ 目录下的 .wasm 文件名
    pub fn listPluginFiles(self: *Manager, allocator: std.mem.Allocator) ![][]u8 {
        _ = self;
        var names = std.ArrayList([]u8).init(allocator);
        errdefer {
            for (names.items) |n| allocator.free(n);
            names.deinit();
        }
        var dir = std.fs.cwd().openDir("plug", .{ .iterate = true }) catch return names.toOwnedSlice();
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".wasm")) {
                try names.append(try allocator.dupe(u8, entry.name));
            }
        }
        return names.toOwnedSlice();
    }

    fn ensureWatchdog(self: *Manager) void {
        if (self.running.load(.acquire)) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.running.load(.acquire)) return;
        self.running.store(true, .release);
        self.watchdog = std.Thread.spawn(.{}, watchdogRun, .{self}) catch blk: {
            self.running.store(false, .release);
            break :blk null;
        };
    }

    fn watchdogRun(self: *Manager) void {
        const tick_ns: u64 = 20 * std.time.ns_per_ms;
        while (self.running.load(.acquire)) {
            std.time.sleep(tick_ns);

            self.mutex.lock();
            var timed_out = std.ArrayList(u64).init(self.allocator);
            defer timed_out.deinit();
            const now = std.time.nanoTimestamp();
            var it = self.records.valueIterator();
            while (it.next()) |rec| {
                const r = rec.*;
                if (r.config.timeout_ms == 0) continue;
                if (r.state != .starting and r.state != .running) continue;
                const elapsed_ns = now - r.started_ns;
                if (elapsed_ns >= @as(i128, r.config.timeout_ms) * std.time.ns_per_ms) {
                    timed_out.append(r.handle) catch {};
                }
            }
            self.mutex.unlock();

            for (timed_out.items) |handle| {
                if (self.controls.get(handle)) |c| c.timeoutCancel();
            }
        }
    }
};

// ── wasm3 解释器控制钩子 ─────────────────────────────────────────

/// 当前线程正在执行的插件控制块（worker 进入 m3_Call 前设置）
pub threadlocal var tls_control: ?*ControlBlock = null;

const interrupted_str = "interrupted";

fn controlCheck() ?[*:0]const u8 {
    const cb = tls_control orelse return null;
    var s = cb.signal.load(.acquire);
    if (s == sig_cancel or s == sig_timeout) return interrupted_str;
    if (s == sig_pause) {
        cb.mutex.lock();
        while (true) {
            s = cb.signal.load(.acquire);
            if (s != sig_pause) break;
            cb.cond.wait(&cb.mutex);
        }
        cb.mutex.unlock();
        if (s == sig_cancel or s == sig_timeout) return interrupted_str;
    }
    return null;
}

/// 覆盖 wasm3 的 weak m3_Yield：WASM 函数调用边界
export fn m3_Yield() callconv(.C) ?[*:0]const u8 {
    return controlCheck();
}

/// 新增 weak 钩子的强实现：向后跳转（循环回边）边界
export fn m3_ControlCheck() callconv(.C) ?[*:0]const u8 {
    return controlCheck();
}
