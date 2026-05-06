const std = @import("std");
const time = std.time;

const Metrics = struct {
    total_logs: u64 = 0,
    start_time: i64,

    pub fn init() Metrics {
        return .{
            .start_time = time.timestamp(),
        };
    }

    pub fn logWritten(metrics: *Metrics) void {
        metrics.total_logs += 1;
    }

    pub fn getLogsPerSecond(metrics: *const Metrics) f64 {
        const elapsed = @as(f64, @floatFromInt(time.timestamp() - metrics.start_time));
        if (elapsed <= 0) return 0;
        return @as(f64, @floatFromInt(metrics.total_logs)) / elapsed;
    }
};

var metrics_mutex = std.Thread.Mutex{};
var global_metrics: ?Metrics = null;
var latency_samples: std.ArrayList(i64) = undefined;
var latency_samples_initialized = false;
var latency_mutex = std.Thread.Mutex{};

pub fn initMetrics() !*Metrics {
    metrics_mutex.lock();
    defer metrics_mutex.unlock();

    if (global_metrics == null) {
        global_metrics = Metrics.init();
    }

    return global_metrics.?;
}

pub fn recordLog() void {
    const start_time = time.microTimestamp();

    metrics_mutex.lock();
    defer metrics_mutex.unlock();

    if (global_metrics) |*m| {
        m.logWritten();
    }

    const end_time = time.microTimestamp();
    const latency = end_time - start_time;

    latency_mutex.lock();
    defer latency_mutex.unlock();

    if (!latency_samples_initialized) {
        latency_samples = std.ArrayList(i64).init(std.heap.page_allocator);
        latency_samples_initialized = true;
    }
    latency_samples.append(latency) catch {};
    // Keep only last 1000 samples
    if (latency_samples.items.len > 1000) {
        _ = latency_samples.orderedRemove(0);
    }
}

pub fn getLogsPerSecond() f64 {
    metrics_mutex.lock();
    defer metrics_mutex.unlock();

    if (global_metrics) |m| {
        return m.getLogsPerSecond();
    }
    return 0;
}

pub fn getLatencyPercentile(p: f64) ?i64 {
    latency_mutex.lock();
    defer latency_mutex.unlock();

    if (latency_samples.items.len == 0) return null;

    const sorted = latency_samples.toOwnedSlice() catch return null;
    defer std.heap.free(sorted);

    std.sort.sort(i64, sorted, {}, std.sort.asc(i64));

    const index = @as(usize, @intFromFloat(@as(f64, @floatFromInt(sorted.len)) * p));
    if (index >= sorted.len) return null;

    return sorted[index];
}

pub fn setSampleSize(size: usize) void {
    latency_mutex.lock();
    defer latency_mutex.unlock();

    while (latency_samples.items.len > size) {
        _ = latency_samples.orderedRemove(0);
    }
}