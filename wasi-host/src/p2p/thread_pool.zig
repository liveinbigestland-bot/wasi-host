/// 线程池 — 管理 N 个 EventLoopWorker
///
/// 每个 Worker 运行一个独立的 EventLoop，支持跨线程任务队列和唤醒。
/// 用于 RelayServer 多线程事件驱动 I/O。
const std = @import("std");
const EventLoop = @import("event_loop.zig").EventLoop;

const Worker = struct {
    id: usize,
    loop: EventLoop,
    thread: ?std.Thread,

    fn run(worker: *Worker) void {
        std.debug.print("[thread_pool] Worker {d} 启动\n", .{worker.id});
        worker.loop.run();
        std.debug.print("[thread_pool] Worker {d} 退出\n", .{worker.id});
    }
};

pub const ThreadPool = struct {
    alloc: std.mem.Allocator,
    workers: []Worker,
    next_worker: usize,
    rr_mutex: std.Thread.Mutex = .{},

    pub fn init(alloc: std.mem.Allocator, num_workers: usize) !ThreadPool {
        const workers = try alloc.alloc(Worker, num_workers);
        errdefer alloc.free(workers);

        for (workers, 0..) |*worker, i| {
            worker.* = Worker{
                .id = i,
                .loop = EventLoop.init(alloc),
                .thread = null,
            };
            worker.loop.initWakeup() catch |err| {
                std.debug.print("[thread_pool] worker {d} wakeup 初始化失败: {}\n", .{ i, err });
            };
        }

        return ThreadPool{ .alloc = alloc, .workers = workers, .next_worker = 0 };
    }

    pub fn deinit(self: *ThreadPool) void {
        for (self.workers) |*worker| {
            worker.loop.deinit();
        }
        self.alloc.free(self.workers);
    }

    /// 启动所有 worker 线程
    pub fn start(self: *ThreadPool) void {
        for (self.workers) |*worker| {
            worker.thread = std.Thread.spawn(.{}, Worker.run, .{worker}) catch |err| blk: {
                std.debug.print("[thread_pool] worker {d} 启动失败: {}\n", .{ worker.id, err });
                break :blk null;
            };
        }
    }

    /// 停止所有 worker 的事件循环
    pub fn stop(self: *ThreadPool) void {
        for (self.workers) |*worker| {
            worker.loop.stop();
            worker.loop.wakeup();
        }
    }

    /// 等待所有 worker 线程退出
    pub fn wait(self: *ThreadPool) void {
        for (self.workers) |*worker| {
            if (worker.thread) |t| {
                t.join();
                worker.thread = null;
            }
        }
    }

    pub fn getWorker(self: *ThreadPool, id: usize) *Worker {
        return &self.workers[id];
    }

    pub fn getLoop(self: *ThreadPool, id: usize) *EventLoop {
        return &self.workers[id].loop;
    }

    pub fn count(self: *ThreadPool) usize {
        return self.workers.len;
    }

    /// Round-robin 选择下一个 worker
    pub fn getNextWorker(self: *ThreadPool) usize {
        self.rr_mutex.lock();
        defer self.rr_mutex.unlock();
        const id = self.next_worker;
        self.next_worker = (self.next_worker + 1) % self.workers.len;
        return id;
    }
};
