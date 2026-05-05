/// 跨平台事件循环 — 基于 poll()
///
/// 单线程非阻塞 I/O 驱动：fd 事件注册 + 定时器调度
/// 使用 posix.poll() 实现，兼容 Linux/macOS/Windows
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

pub const EventLoop = struct {
    alloc: std.mem.Allocator,
    fd_entries: std.AutoHashMap(posix.socket_t, FdEntry),
    poll_fds: std.ArrayList(posix.pollfd),
    timers: std.ArrayList(TimerEntry),
    running: bool,

    pub fn init(alloc: std.mem.Allocator) EventLoop {
        return EventLoop{
            .alloc = alloc,
            .fd_entries = std.AutoHashMap(posix.socket_t, FdEntry).init(alloc),
            .poll_fds = std.ArrayList(posix.pollfd).init(alloc),
            .timers = std.ArrayList(TimerEntry).init(alloc),
            .running = false,
        };
    }

    pub fn deinit(self: *EventLoop) void {
        self.fd_entries.deinit();
        self.poll_fds.deinit();
        self.timers.deinit();
    }

    /// 注册 fd 到事件循环
    /// events: posix.POLL.IN | posix.POLL.OUT 等
    pub fn addFd(self: *EventLoop, fd: posix.socket_t, events: u16, ctx: *anyopaque, vtable: *const HandlerVTable) void {
        self.fd_entries.put(fd, .{ .fd = fd, .events = events, .ctx = ctx, .vtable = vtable }) catch {};
    }

    /// 修改 fd 监听事件
    pub fn modFd(self: *EventLoop, fd: posix.socket_t, events: u16) void {
        if (self.fd_entries.getPtr(fd)) |entry| {
            entry.events = events;
        }
    }

    /// 从事件循环移除 fd
    pub fn removeFd(self: *EventLoop, fd: posix.socket_t) void {
        _ = self.fd_entries.remove(fd);
    }

    /// 添加一次性定时器（毫秒后触发）
    pub fn addTimer(self: *EventLoop, after_ms: u64, ctx: *anyopaque, vtable: *const HandlerVTable) void {
        const now = std.time.milliTimestamp();
        const expiry = now + @as(i64, @intCast(after_ms));
        self.timers.append(.{ .expiry_ms = expiry, .ctx = ctx, .vtable = vtable }) catch {};
    }

    /// 运行事件循环（阻塞直到 stop() 被调用）
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
            }

            self.dispatchTimers();
        }
    }

    pub fn stop(self: *EventLoop) void {
        self.running = false;
    }

    /// 当前注册的 fd 数量
    pub fn fdCount(self: *EventLoop) usize {
        return self.fd_entries.count();
    }

    fn rebuildPollFds(self: *EventLoop) void {
        self.poll_fds.clearRetainingCapacity();
        var it = self.fd_entries.valueIterator();
        while (it.next()) |entry| {
            self.poll_fds.append(.{ .fd = entry.fd, .events = @as(i16, @intCast(entry.events)), .revents = 0 }) catch {};
        }
    }

    /// 计算到下一个定时器超时的毫秒数（-1 = 无限等待）
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
    } else {
        const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
        try posix.fcntl(fd, posix.F.SETFL, flags | posix.O.NONBLOCK);
    }
}
