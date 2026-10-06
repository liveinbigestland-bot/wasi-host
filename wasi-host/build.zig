const std = @import("std");

/// 获取 git describe 版本字符串
fn getGitDescribe(b: *std.Build) ?[]const u8 {
    const result = b.run(&.{ "git", "describe", "--tags", "--dirty", "--always" });
    return std.mem.trim(u8, result, " \n\r");
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    const plugin_step = b.step("plugins", "Compile WASM plugins (wasm32-wasi)");

    inline for (.{ "ai_plugin", "api_plugin" }) |name| {
        const plugin = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(b.fmt("plugins/{s}.zig", .{name})),
            .target = wasm_target,
            .optimize = optimize,
        });
        plugin.rdynamic = true;
        plugin_step.dependOn(&b.addInstallArtifact(plugin, .{
            .dest_dir = .{ .override = .{ .custom = "plugins" } },
        }).step);
    }

    const host_target = b.standardTargetOptions(.{});
    const exe = b.addExecutable(.{
        .name = "wasi-host",
        .root_source_file = b.path("main.zig"),
        .target = host_target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });
    exe.linkLibC();
    exe.linkSystemLibrary("ws2_32"); // Socket functions for UDP

    // Link wasm3 static library (built from wasm3/build.zig)
    const wasm3_lib = b.addStaticLibrary(.{
        .name = "m3",
        .target = host_target,
        .optimize = optimize,
    });
    wasm3_lib.root_module.addCMacro("d_m3HasWASI", "");
    wasm3_lib.addIncludePath(b.path("wasm3/source"));
    wasm3_lib.addCSourceFiles(.{
        .root = b.path("wasm3/source"),
        .files = &.{
            "m3_api_libc.c",
            "extensions/m3_extensions.c",
            "m3_api_meta_wasi.c",
            "m3_api_tracer.c",
            "m3_api_uvwasi.c",
            "m3_api_wasi.c",
            "m3_bind.c",
            "m3_code.c",
            "m3_compile.c",
            "m3_core.c",
            "m3_env.c",
            "m3_exec.c",
            "m3_function.c",
            "m3_info.c",
            "m3_module.c",
            "m3_parse.c",
        },
        .flags = &.{"-std=c11"},
    });
    wasm3_lib.linkLibC();
    exe.linkLibrary(wasm3_lib);

    // 检测是否本机编译（不是交叉编译）
    const native_target = b.resolveTargetQuery(.{});
    const building_natively = host_target.result.cpu.arch == native_target.result.cpu.arch and
        host_target.result.os.tag == native_target.result.os.tag;

    std.debug.print("[build] Platform: {s}, Arch: {s}, Building natively: {}\n", .{
        @tagName(host_target.result.os.tag),
        @tagName(host_target.result.cpu.arch),
        building_natively,
    });

    // WSS TLS 支持需要 OpenSSL（仅本机 Linux 编译）
    const wss_tls_enabled = building_natively and host_target.result.os.tag == .linux;
    if (wss_tls_enabled) {
        exe.linkSystemLibrary("ssl");
        exe.linkSystemLibrary("crypto");
    }

    // Lua 5.4 支持 - 根据平台加载不同库
    const lua_enabled = true;
    std.debug.print("[build] Lua support enabled: {}\n", .{lua_enabled});
    if (lua_enabled) {
        // 检测平台
        const target_os = host_target.result.os.tag;
        const target_arch = host_target.result.cpu.arch;
        std.debug.print("[build] Target OS: {s}, Arch: {s}\n", .{ @tagName(target_os), @tagName(target_arch) });

        // 根据平台选择 Lua 库
        if (target_os == .linux and target_arch == .x86_64) {
            // Linux x86_64 - 使用系统库
            exe.linkSystemLibrary("lua5.4");
            std.debug.print("[build] Linking system lua5.4 (Linux x86_64)\n", .{});
        } else if (target_os == .linux and target_arch == .arm) {
            // Linux ARM - 使用系统库
            exe.linkSystemLibrary("lua5.4");
            std.debug.print("[build] Linking system lua5.4 (Linux ARM)\n", .{});
        } else {
            // Windows / 其他平台 - 使用本地静态库 lua-libs/liblua54.a
            exe.addLibraryPath(.{ .cwd_relative = "lua-libs" });
            exe.linkSystemLibrary("lua54");
            exe.addIncludePath(.{ .cwd_relative = "lua-libs/include" });
            std.debug.print("[build] Linking local liblua54.a (Windows)\n", .{});
        }
    } else {
        std.debug.print("[build] Lua disabled\n", .{});
    }
    const options = b.addOptions();
    options.addOption(bool, "wss_tls_enabled", wss_tls_enabled);
    exe.root_module.addOptions("build_options", options);

    // Add logging module
    const logging_module = b.createModule(.{
        .root_source_file = b.path("src/logging/index.zig"),
    });
    exe.root_module.addImport("logging", logging_module);

    exe.step.dependOn(plugin_step);

    b.installArtifact(exe);

    // ── Encrypted Relay Server 独立二进制 ──
    const relay_server = b.addExecutable(.{
        .name = "relay-server",
        .root_source_file = b.path("src/relay/main.zig"),
        .target = host_target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });
    relay_server.linkLibC();
    relay_server.root_module.addImport("logging", logging_module);
    b.installArtifact(relay_server);

    // ── wasi-hostd 守护进程 ──
    const daemon = b.addExecutable(.{
        .name = "wasi-hostd",
        .root_source_file = b.path("src/daemon/main.zig"),
        .target = host_target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });
    daemon.linkLibC();
    daemon.root_module.addImport("logging", logging_module);

    const version_str = getGitDescribe(b) orelse "0.0.0";
    const daemon_opts = b.addOptions();
    daemon_opts.addOption([]const u8, "version", version_str);
    daemon.root_module.addOptions("build_options", daemon_opts);

    b.installArtifact(daemon);

    // ── Lua 5.4 依赖 ──
    // 跳过 lua 依赖（临时方案）
    std.debug.print("[build] Lua dependency skipped for daemon\n", .{});

    // ── 单元测试 ──
    const test_step = b.step("test", "Run unit tests");
    inline for (.{
        "src/p2p/metadata/types.zig",
        "src/p2p/metadata/store.zig",
        "src/p2p/metadata/permission.zig",
        "src/p2p/metadata/replication.zig",
    }) |path| {
        const test_obj = b.addTest(.{
            .root_source_file = b.path(path),
            .target = host_target,
            .optimize = optimize,
        });
        const run_test = b.addRunArtifact(test_obj);
        test_step.dependOn(&run_test.step);
    }

    // relay-server 测试需要 linkLibC（posix.recvfrom 需要 libc）
    {
        const relay_test = b.addTest(.{
            .root_source_file = b.path("src/relay/main.zig"),
            .target = host_target,
            .optimize = optimize,
        });
        relay_test.linkLibC();
        const run_relay_test = b.addRunArtifact(relay_test);
        test_step.dependOn(&run_relay_test.step);
    }

    const daemon_test = b.addTest(.{
        .root_source_file = b.path("src/daemon/test.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    daemon_test.linkLibC();
    const run_daemon_test = b.addRunArtifact(daemon_test);
    test_step.dependOn(&run_daemon_test.step);
}
