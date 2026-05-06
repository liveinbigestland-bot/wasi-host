const std = @import("std");
const init = @import("init.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Logging Integration Test ===\n", .{});

    // Test 1: Console output only
    std.debug.print("\n--- Test 1: Console Output Only ---\n", .{});
    const console_config = init.Config{
        .level = .info,
        .enable_console = true,
        .enable_file = false,
        .file_path = "test_console.log",
    };
    try init.init(allocator, "console_test", console_config);

    init.log.info("Console test: This should appear in console", .{});
    init.log.warn("Console test: Warning message", .{}); // Debug level, should be filtered with .info level
    init.setLogLevel(.debug);
    init.log.debug("Console test: Debug message (visible with debug level)", .{});
    init.setLogLevel(.info);

    // Test 2: File output only
    std.debug.print("\n--- Test 2: File Output Only ---\n", .{});
    const file_config = init.Config{
        .level = .debug,
        .enable_console = false,
        .enable_file = true,
        .file_path = "test_file.log",
    };
    try init.init(allocator, "file_test", file_config);

    init.log.info("File test: Info message will be written to file", .{});
    init.log.warn("File test: Warning message will be written", .{}); // Info level, so this shows

    // Verify file exists and has content
    const file = std.fs.cwd().openFile("test_file.log", .{}) catch {
        std.debug.print("ERROR: Failed to open test_file.log\n", .{});
        return error.FileOpenFailed;
    };
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 4096) catch {
        return error.FileReadFailed;
    };
    defer allocator.free(contents);

    std.debug.print("File contents ({d} bytes):\n", .{contents.len});
    std.debug.print("{s}\n", .{contents});

    // Check if both expected messages are in the file
    const has_info = std.mem.indexOf(u8, contents, "File test: Info message") != null;
    const has_warn = std.mem.indexOf(u8, contents, "File test: Warning message") != null;

    std.debug.print("File contains info message: {}\n", .{has_info});
    std.debug.print("File contains warning message: {}\n", .{has_warn});

    if (!has_info or !has_warn) {
        std.debug.print("ERROR: Expected messages not found in file\n", .{});
    }

    // Test 3: Both console and file output
    std.debug.print("\n--- Test 3: Console + File Output ---\n", .{});
    const dual_config = init.Config{
        .level = .debug,
        .enable_console = true,
        .enable_file = true,
        .file_path = "test_dual.log",
    };
    try init.init(allocator, "dual_test", dual_config);

    init.log.info("Dual test: This should appear in both console and file", .{});
    init.log.warn("Dual test: Warning message", .{}); // Debug level, so both show

    // Clean up test files
    std.debug.print("\n--- Cleanup ---\n", .{});
    std.fs.cwd().deleteFile("test_console.log") catch {};
    std.fs.cwd().deleteFile("test_file.log") catch {};
    std.fs.cwd().deleteFile("test_dual.log") catch {};

    std.debug.print("\n=== Integration Test Complete ===\n", .{});
    std.debug.print("If you see JSON logs above, console output is working.\n", .{});
    std.debug.print("If test_file.log was created and contains log entries,\n", .{});
    std.debug.print("file output is working correctly.\n", .{});
}
