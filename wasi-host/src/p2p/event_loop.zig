/// 跨平台事件循环 — 基于 poll()
///
/// 单线程非阻塞 I/O 驱动：fd 事件注册 + 定时器调度
/// 支持跨线程唤醒和任务队列 (initWakeup / execute)
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Handler 虚表 — 事件回调接口
pub const HandlerVTable = struct {
    onReadable: ?*const fn (ctx: *anyopaque, fd: posix.socket_t, loop: *EventLoop) void = null,
    onWritable: ?*const fn (ctx: *anyopaque, fd: posix.socket_t, loop: *EventLoop) void = null,
    onHup: ?*const fn (ctx: *anyopaque, fd: posix.socket_t, loop: *EventLoop) void = null,
    onTimer: ?*const fn (ctx: *anyopaque, loop: *EventLoop) void = null,
};

const FdEntry = struct {
    fd: posix.socket_t,
    events: u16,
    ctx: *anyopaque,
    vtable: *const HandlerVTable,
};

const TimerEntry = struct {
    expiry_ms: i64,
    ctx: *anyopaque,
    vtable: *const HandlerVTable,
};

fn closeSocket(fd: posix.socket_t) void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ws2_32.closesocket(fd);
        return;
    }
    if (fd < 0) return;
    _ = posix.system.close(fd);
}

pub const EventLoop = struct {
    alloc: std.mem.Allocator,
    fd_entries: std.AutoHashMap(posix.socket_t, FdEntry),
    poll_fds: std.ArrayList(posix.pollfd),
    timers: std.ArrayList(TimerEntry),
    running: bool,

    /// 多线程支持：跨线程唤醒 TCP loopback pair
    has_wakeup: bool,
    wakeup_read: posix.socket_t,
    wakeup_write: posix.socket_t,
    job_mutex: std.Thread.Mutex,
    job_queue: std.ArrayList(Job),

    pub const Job = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, loop: *EventLoop) void,
    };

    pub fn init(alloc: std.mem.Allocator) EventLoop {
        return EventLoop{
            .alloc = alloc,
            .fd_entries = std.AutoHashMap(posix.socket_t, FdEntry).init(alloc),
            .poll_fds = std.ArrayList(posix.pollfd).init(alloc),
            .timers = std.ArrayList(TimerEntry).init(alloc),
            .running = false,
            .has_wakeup = false,
            .wakeup_read = undefined,
            .wakeup_write = undefined,
            .job_mutex = .{},
            .job_queue = std.ArrayList(Job).init(alloc),
        };
    }

    pub fn deinit(self: *EventLoop) void {
        self.deinitWakeup();
        self.fd_entries.deinit();
        self.poll_fds.deinit();
        self.timers.deinit();
        self.job_queue.deinit();
    }

    /// 初始化跨线程唤醒（TCP loopback pair）
    pub fn initWakeup(self: *EventLoop) !void {
        const listen_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer closeSocket(listen_fd);

        const reuse: u32 = 1;
        _ = posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(reuse)) catch {};

        const bind_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        try posix.bind(listen_fd, &bind_addr.any, bind_addr.getOsSockLen());
        try posix.listen(listen_fd, 1);

        var actual_addr: std.net.Address = undefined;
        var addr_len: posix.socklen_t = @sizeOf(std.net.Address);
        try posix.getsockname(listen_fd, &actual_addr.any, &addr_len);

        const write_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer closeSocket(write_fd);
        try posix.connect(write_fd, &actual_addr.any, actual_addr.getOsSockLen());

        var client_addr: std.net.Address = undefined;
        var client_len: posix.socklen_t = @sizeOf(std.net.Address);
        const read_fd = try posix.accept(listen_fd, &client_addr.any, &client_len, 0);

        closeSocket(listen_fd);

        setNonblocking(read_fd) catch {};
        setNonblocking(write_fd) catch {};

        self.wakeup_read = read_fd;
        self.wakeup_write = write_fd;
        self.has_wakeup = true;
    }

    fn deinitWakeup(self: *EventLoop) void {
        if (self.has_wakeup) {
            closeSocket(self.wakeup_read);
            closeSocket(self.wakeup_write);
            self.has_wakeup = false;
        }
    }

    /// 从其他线程唤醒事件循环（写入 wakeup pipe）
    pub fn wakeup(self: *EventLoop) void {
        if (!self.has_wakeup) return;
        const byte: [1]u8 = .{0};
        _ = posix.write(self.wakeup_write, &byte) catch {};
    }

    /// 排队工作到事件循环线程执行（跨线程安全）
    pub fn execute(self: *EventLoop, ctx: *anyopaque, func: *const fn (ctx: *anyopaque, loop: *EventLoop) void) void {
        self.job_mutex.lock();
        self.job_queue.append(.{ .ctx = ctx, .func = func }) catch {};
        self.job_mutex.unlock();
        self.wakeup();
    }

    /// 处理唤醒数据和排队工作
    fn processJobs(self: *EventLoop) void {
        var dummy: [64]u8 = undefined;
        _ = posix.read(self.wakeup_read, &dummy) catch {};

        self.job_mutex.lock();
        var jobs = self.job_queue;
        self.job_queue = std.ArrayList(Job).init(self.alloc);
        self.job_mutex.unlock();

        for (jobs.items) |job| {
            job.func(job.ctx, self);
        }
        jobs.deinit();
    }

    pub fn addFd(self: *EventLoop, fd: posix.socket_t, events: u16, ctx: *anyopaque, vtable: *const HandlerVTable) void {
        self.fd_entries.put(fd, .{ .fd = fd, .events = events, .ctx = ctx, .vtable = vtable }) catch {};
    }

    pub fn modFd(self: *EventLoop, fd: posix.socket_t, events: u16) void {
        if (self.fd_entries.getPtr(fd)) |entry| {
            entry.events = events;
        }
    }

    pub fn removeFd(self: *EventLoop, fd: posix.socket_t) void {
        _ = self.fd_entries.remove(fd);
    }

    pub fn addTimer(self: *EventLoop, after_ms: u64, ctx: *anyopaque, vtable: *const HandlerVTable) void {
        const now = std.time.milliTimestamp();
        const expiry = now + @as(i64, @intCast(after_ms));
        self.timers.append(.{ .expiry_ms = expiry, .ctx = ctx, .vtable = vtable }) catch {};
    }

    pub fn run(self: *EventLoop) void {
        self.running = true;
        var need_rebuild = true;

        while (self.running) {
            if (need_rebuild) {
                self.rebuildPollFds();
                need_rebuild = false;
            }

            const timeout_ms = self.nextTimerTimeout();

            const ready = posix.poll(self.poll_fds.items, timeout_ms) catch |err| {
                if (err == error.Interrupted) continue;
                std.debug.print("[event_loop] poll 错误: {}\n", .{err});
                break;
            };

            if (ready > 0) {
                for (self.poll_fds.items) |pfd| {
                    if (pfd.revents == 0) continue;

                    // 唤醒 fd — 处理跨线程任务队列
                    if (self.has_wakeup and pfd.fd == self.wakeup_read) {
                        self.processJobs();
                        continue;
                    }

                    const entry = self.fd_entries.get(pfd.fd) orelse continue;

                    if (pfd.revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
                        if (entry.vtable.onHup) |cb| {
                            cb(entry.ctx, pfd.fd, self);
                            continue;
                        }
                    }

                    if (pfd.revents & posix.POLL.IN != 0) {
                        if (entry.vtable.onReadable) |cb| {
                            need_rebuild = true;
                            cb(entry.ctx, pfd.fd, self);
                        }
                    }

                    if (pfd.revents & posix.POLL.OUT != 0) {
                        if (entry.vtable.onWritable) |cb| {
                            need_rebuild = true;
                            cb(entry.ctx, pfd.fd, self);
                        }
                    }
                }
            } else if (ready == 0 and self.has_wakeup and self.job_queue.items.len > 0) {
                // poll 超时但还有未处理任务
                self.processJobs();
            }

            self.dispatchTimers();
        }
    }

    pub fn stop(self: *EventLoop) void {
        self.running = false;
    }

    pub fn fdCount(self: *EventLoop) usize {
        return self.fd_entries.count();
    }

    fn rebuildPollFds(self: *EventLoop) void {
        self.poll_fds.clearRetainingCapacity();
        var it = self.fd_entries.valueIterator();
        while (it.next()) |entry| {
            self.poll_fds.append(.{ .fd = entry.fd, .events = @as(i16, @intCast(entry.events)), .revents = 0 }) catch {};
        }
        if (self.has_wakeup) {
            self.poll_fds.append(.{ .fd = self.wakeup_read, .events = posix.POLL.IN, .revents = 0 }) catch {};
        }
    }

    fn nextTimerTimeout(self: *EventLoop) i32 {
        if (self.timers.items.len == 0) return -1;
        const now = std.time.milliTimestamp();
        var min_expiry: i64 = std.math.maxInt(i64);
        for (self.timers.items) |t| {
            if (t.expiry_ms < min_expiry) min_expiry = t.expiry_ms;
        }
        const diff = min_expiry - now;
        if (diff <= 0) return 0;
        return @as(i32, @intCast(@min(diff, @as(i64, std.math.maxInt(i32)))));
    }

    fn dispatchTimers(self: *EventLoop) void {
        const now = std.time.milliTimestamp();
        var i: usize = 0;
        while (i < self.timers.items.len) {
            if (self.timers.items[i].expiry_ms <= now) {
                const timer = self.timers.items[i];
                _ = self.timers.swapRemove(i);
                if (timer.vtable.onTimer) |cb| cb(timer.ctx, self);
            } else {
                i += 1;
            }
        }
    }
};

/// 将 fd 设为非阻塞模式
pub fn setNonblocking(fd: posix.socket_t) !void {
    if (builtin.os.tag == .windows) {
        var mode: u32 = 1;
        const rc = std.os.windows.ws2_32.ioctlsocket(fd, std.os.windows.ws2_32.FIONBIO, &mode);
        if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
            return error.SetNonblockingFailed;
        }
    } else if (builtin.os.tag == .linux) {
        // Linux: O_NONBLOCK via raw value (0o2000) since posix.O.NONBLOCK
        // may not exist in the x86_64 Linux kernel struct
        const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
        _ = try posix.fcntl(fd, posix.F.SETFL, flags | 0o2000);
    } else {
        const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
        _ = try posix.fcntl(fd, posix.F.SETFL, flags | posix.O.NONBLOCK);
    }
}

comptime {
    _ = HandlerVTable;
    _ = EventLoop;
}
