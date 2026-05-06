const std = @import("std");
const time = std.time;
const logger = @import("logger.zig");

pub const LogRotator = struct {
    allocator: std.mem.Allocator,
    config: *logger.Config,
    current_size: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: *logger.Config) LogRotator {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn checkAndRotate(rotator: *LogRotator, entry_size: u64) !void {
        if (!rotator.config.enable_rotation) {
            return;
        }

        // Check time-based rotation
        const now = time.timestamp();
        if (rotator.config.last_rotation_time == 0) {
            rotator.config.last_rotation_time = now;
        }

        if (now - rotator.config.last_rotation_time >= rotator.config.time_rotation_interval) {
            try rotator.rotate();
            rotator.config.last_rotation_time = now;
            return;
        }

        // Check size-based rotation
        rotator.current_size += entry_size + 1; // +1 for newline

        if (rotator.current_size >= rotator.config.max_file_size) {
            try rotator.rotate();
        }
    }

    fn rotate(rotator: *LogRotator) !void {
        const file_path = rotator.config.file_path;

        // Check if file exists and get its size
        const file = std.fs.cwd().openFile(file_path, .{}) catch {
            // File doesn't exist, nothing to rotate
            rotator.current_size = 0;
            return;
        };
        defer file.close();

        _ = file.stat() catch {
            rotator.current_size = 0;
            return;
        };

        // Remove oldest file if we've reached max files
        if (rotator.config.max_files > 0) {
            const oldest_path = std.fmt.allocPrint(rotator.allocator, "{s}.{d}", .{
                file_path,
                rotator.config.max_files - 1
            }) catch return;
            defer rotator.allocator.free(oldest_path);

            std.fs.cwd().deleteFile(oldest_path) catch {};
        }

        // Rotate existing files
        var i: usize = rotator.config.max_files - 1;
        while (i >= 1) : (i -= 1) {
            const old_path = std.fmt.allocPrint(rotator.allocator, "{s}.{d}", .{ file_path, i - 1 }) catch return;
            defer rotator.allocator.free(old_path);

            const new_path = std.fmt.allocPrint(rotator.allocator, "{s}.{d}", .{ file_path, i }) catch return;
            defer rotator.allocator.free(new_path);

            // Rename file
            std.fs.cwd().rename(old_path, new_path) catch {};
        }

        // Current file becomes .1
        const rotated_path = std.fmt.allocPrint(rotator.allocator, "{s}.1", .{file_path}) catch return;
        defer rotator.allocator.free(rotated_path);

        std.fs.cwd().rename(file_path, rotated_path) catch {};

        // Reset current size
        rotator.current_size = 0;
    }
};