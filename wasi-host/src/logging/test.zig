const std = @import("std");
const init = @import("init.zig");
const logger = @import("logger.zig");
const time = std.time;

test "file output test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test configuration with file output
    const config = init.Config{
        .enable_console = false,
        .enable_file = true,
        .file_path = "test.log",
        .level = .info,
    };

    // Initialize logging
    try init.init(allocator, "test_module", config);

    // Write some logs
    init.log.info("Test info message", .{});
    init.log.err("Test error message", .{});

    // Check if file was created and has content
    const file = std.fs.cwd().openFile("test.log", .{}) catch |err| {
        std.debug.print("Failed to open test log: {}\n", .{err});
        return;
    };
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 1024) catch |err| {
        std.debug.print("Failed to read test log: {}\n", .{err});
        return;
    };
    defer allocator.free(contents);

    std.debug.print("Log contents: {s}\n", .{contents});

    // Clean up
    std.fs.cwd().deleteFile("test.log") catch {};

    // Test with very small size to trigger rotation
    const small_config = init.Config{
        .enable_console = false,
        .enable_file = true,
        .file_path = "test_small.log",
        .max_file_size = 100, // Very small for testing
        .max_files = 3,
        .level = .info,
    };

    try init.init(allocator, "test_small", small_config);

    // Write many small messages to trigger rotation
    for (0..20) |i| {
        init.log.info("Message {}", .{i});
    }

    // Clean up
    std.fs.cwd().deleteFile("test_small.log") catch {};
    std.fs.cwd().deleteFile("test_small.log.1") catch {};
    std.fs.cwd().deleteFile("test_small.log.2") catch {};

    // Test log level validation
    std.debug.print("Testing log level validation...\n", .{});
    init.setLogLevel(.debug);
    init.log.debug("This debug message should appear", .{});
    init.log.trace("This trace message should be filtered", .{});

    // Test module-specific levels
    init.setModuleLogLevel("chord", logger.Level.err);
    init.log.info("Chord info message (should be filtered)", .{});
    init.log.err("Chord error message (should appear)", .{});

    // Test high volume logging
    std.debug.print("Testing high volume logging...\n", .{});
    const start = time.milliTimestamp();
    var count: u32 = 0;
    while (count < 1000) : (count += 1) {
        init.log.info("Message {}", .{count});
    }
    const end = time.milliTimestamp();
    const elapsed = end - start;
    const lps = @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(elapsed)) / 1000.0);

    std.debug.print("Logged {} messages in {} ms ({:.1} LPS)\n", .{ count, elapsed, lps });
}