const std = @import("std");
const logger = @import("logger.zig");
const rotate = @import("rotate.zig");
const perf = @import("performance.zig");

pub const LogLevel = logger.Level;
pub const Config = logger.Config;

pub fn init(allocator: std.mem.Allocator, module_name: []const u8, config: Config) !void {
    // Initialize performance metrics
    _ = try perf.initMetrics();

    // Set global configuration
    logger.setConfig(config);

    // Initialize global logger for the module
    _ = try logger.initGlobal(allocator, module_name);
}

pub fn getLogger(module_name: []const u8) !*logger.Logger {
    _ = module_name;
    const global = logger.getGlobal() orelse return error.LoggerNotInitialized;

    // Create a new logger instance for the module
    return global.allocator.create(logger.Logger);
}

pub fn setLogLevel(level: LogLevel) void {
    // Validate log level
    const valid_levels = [_]logger.Level{ .trace, .debug, .info, .warn, .err };
    const valid = for (valid_levels) |valid_level| {
        if (valid_level == level) {
            break true;
        }
    } else false;

    if (!valid) {
        // Fallback to info level and log warning
        std.debug.print("Invalid log level: {}, falling back to info\n", .{@tagName(level)});
        var config = logger.current_config;
        config.level = .info;
        logger.setConfig(config);
        return;
    }

    var config = logger.current_config;
    config.level = level;
    logger.setConfig(config);
}

pub fn setModuleLogLevel(module_name: []const u8, level: LogLevel) void {
    logger.setModuleLevel(module_name, level);
}

pub fn getLogsPerSecond() f64 {
    return perf.getLogsPerSecond();
}

pub fn getLatencyPercentile(p: f64) ?i64 {
    return perf.getLatencyPercentile(p);
}

pub fn setPerformanceSampleSize(size: usize) void {
    perf.setSampleSize(size);
}

/// Convenience macros for easy logging
pub const log = struct {
    pub fn trace(comptime format: []const u8, args: anytype) void {
        if (logger.getGlobal()) |global_logger| {
            global_logger.trace(format, args);
            perf.recordLog();
        }
    }

    pub fn debug(comptime format: []const u8, args: anytype) void {
        if (logger.getGlobal()) |global_logger| {
            global_logger.debug(format, args);
            perf.recordLog();
        }
    }

    pub fn info(comptime format: []const u8, args: anytype) void {
        if (logger.getGlobal()) |global_logger| {
            global_logger.info(format, args);
            perf.recordLog();
        }
    }

    pub fn warn(comptime format: []const u8, args: anytype) void {
        if (logger.getGlobal()) |global_logger| {
            global_logger.warn(format, args);
            perf.recordLog();
        }
    }

    pub fn err(comptime format: []const u8, args: anytype) void {
        if (logger.getGlobal()) |global_logger| {
            global_logger.err(format, args);
            perf.recordLog();
        }
    }
};