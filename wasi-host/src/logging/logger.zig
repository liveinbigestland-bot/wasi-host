const std = @import("std");
const rotate = @import("rotate.zig");
const perf = @import("performance.zig");

/// Log levels
pub const Level = enum {
    trace,
    debug,
    info,
    warn,
    err,

    pub fn format(level: Level, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll(@tagName(level));
    }
};

/// Log configuration
pub const Config = struct {
    level: Level = .info,
    enable_console: bool = true,
    enable_file: bool = false,
    file_path: []const u8 = "wasi-host.log",
    max_file_size: u64 = 10 * 1024 * 1024, // 10MB
    max_files: usize = 7,
    enable_rotation: bool = true,
    time_rotation_interval: u64 = 24 * 60 * 60, // 24 hours in seconds
    last_rotation_time: i64 = 0,
};

/// Global logger instance
var global_logger: ?*Logger = null;
var config_mutex = std.Thread.Mutex{};
var current_config = Config{};
var module_levels: std.StringHashMap(Level) = undefined;
var module_levels_initialized = false;
var module_levels_mutex = std.Thread.Mutex{};

/// Logger struct
pub const Logger = struct {
    allocator: std.mem.Allocator,
    module_name: []const u8,
    config: *Config,
    rotator: ?*rotate.LogRotator = null,

    pub fn init(allocator: std.mem.Allocator, module_name: []const u8, config: *Config) Logger {
        var rot: ?*rotate.LogRotator = null;
        if (config.enable_file) {
            rot = allocator.create(rotate.LogRotator) catch null;
            if (rot) |r| {
                r.* = rotate.LogRotator.init(allocator, config);
            }
        }

        return .{
            .allocator = allocator,
            .module_name = module_name,
            .config = config,
            .rotator = rot,
        };
    }

    pub fn log(logger: *Logger, level: Level, comptime format: []const u8, args: anytype) void {
        const effective_level = getEffectiveLevel(logger.module_name, logger.config.level);
        if (@intFromEnum(level) < @intFromEnum(effective_level)) {
            return;
        }

        const timestamp = std.time.timestamp();
        const pid = if (@import("builtin").os.tag == .windows) std.os.windows.GetCurrentProcessId() else std.os.linux.getpid();

        var buffer: [1024]u8 = undefined;
        const formatted_message = std.fmt.bufPrint(&buffer, format, args) catch return;

        const json_entry = std.json.stringifyAlloc(logger.allocator, .{
            .timestamp = timestamp,
            .level = level,
            .module = logger.module_name,
            .pid = pid,
            .message = formatted_message,
        }, .{ .whitespace = .minified }) catch return;

        defer logger.allocator.free(json_entry);

        if (logger.config.enable_console) {
            std.debug.print("{s}\n", .{json_entry});
        }

        if (logger.config.enable_file) {
            logger.writeToFile(json_entry);
        }
    }

    fn writeToFile(logger: *Logger, entry: []const u8) void {
        const file = std.fs.cwd().openFile(logger.config.file_path, .{ .mode = .read_write }) catch return;
        defer file.close();

        // Seek to end for append
        file.seekFromEnd(0) catch return;

        file.writeAll(entry) catch return;
        file.writeAll("\n") catch return;

        // Check and rotate if needed
        if (logger.rotator) |rot| {
            rot.checkAndRotate(@intCast(entry.len + 1)) catch {};
        }
    }

    // Convenience methods
    pub fn trace(logger: *Logger, comptime format: []const u8, args: anytype) void {
        logger.log(.trace, format, args);
    }

    pub fn debug(logger: *Logger, comptime format: []const u8, args: anytype) void {
        logger.log(.debug, format, args);
    }

    pub fn info(logger: *Logger, comptime format: []const u8, args: anytype) void {
        logger.log(.info, format, args);
    }

    pub fn warn(logger: *Logger, comptime format: []const u8, args: anytype) void {
        logger.log(.warn, format, args);
    }

    pub fn err(logger: *Logger, comptime format: []const u8, args: anytype) void {
        logger.log(.err, format, args);
    }
};

/// Global logger functions
pub fn initGlobal(allocator: std.mem.Allocator, module_name: []const u8) !*Logger {
    config_mutex.lock();
    defer config_mutex.unlock();

    if (global_logger == null) {
        global_logger = try allocator.create(Logger);
        global_logger.?.* = Logger.init(allocator, module_name, &current_config);
    }

    return global_logger.?;
}

pub fn setConfig(config: Config) void {
    config_mutex.lock();
    defer config_mutex.unlock();

    current_config = config;

    if (global_logger) |logger| {
        // Update logger configuration
        const new_logger = Logger.init(logger.allocator, logger.module_name, &current_config);
        logger.* = new_logger;
    }
}

pub fn setModuleLevel(module_name: []const u8, level: Level) void {
    module_levels_mutex.lock();
    defer module_levels_mutex.unlock();

    if (!module_levels_initialized) {
        module_levels = std.StringHashMap(Level).init(std.heap.page_allocator);
        module_levels_initialized = true;
    }
    module_levels.put(module_name, level) catch {};
}

fn getEffectiveLevel(module_name: []const u8, default_level: Level) Level {
    module_levels_mutex.lock();
    defer module_levels_mutex.unlock();

    if (module_levels.get(module_name)) |level| {
        return level;
    }
    return default_level;
}

pub fn getGlobal() ?*Logger {
    return global_logger;
}