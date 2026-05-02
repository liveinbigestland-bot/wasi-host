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

    // 检测是否本机编译（不是交叉编译）
    const native_target = b.resolveTargetQuery(.{});
    const building_natively = host_target.result.cpu.arch == native_target.result.cpu.arch and
        host_target.result.os.tag == native_target.result.os.tag;

    // WSS TLS 支持需要 OpenSSL（仅本机 Linux 编译）
    // 交叉编译时不链接 OpenSSL，WSS 降级为纯 WS
    const wss_tls_enabled = building_natively and host_target.result.os.tag == .linux;
    if (wss_tls_enabled) {
        exe.linkSystemLibrary("ssl");
        exe.linkSystemLibrary("crypto");
    }
    const options = b.addOptions();
    options.addOption(bool, "wss_tls_enabled", wss_tls_enabled);
    exe.root_module.addOptions("build_options", options);

    exe.addCSourceFiles(.{
        .root = b.path("wasm3/source"),
        .files = &.{
            "m3_core.c",
            "m3_env.c",
            "m3_exec.c",
            "m3_compile.c",
            "m3_parse.c",
            "m3_bind.c",
            "m3_code.c",
            "m3_module.c",
            "m3_function.c",
            "m3_info.c",
            "m3_api_wasi.c",
            "m3_api_libc.c",
            "extensions/m3_extensions.c",
        },
        .flags = &.{"-DM3_ENABLE_WASI=1", "-Dd_m3HasWASI=1", "-DM3_HAS_TAIL_CALL=0", "-std=gnu11"},
    });
    exe.addIncludePath(b.path("wasm3/source"));

    exe.step.dependOn(plugin_step);

    b.installArtifact(exe);

    // ── Phase 5: wasi-hostd 守护进程 ──
    const daemon = b.addExecutable(.{
        .name = "wasi-hostd",
        .root_source_file = b.path("src/daemon/main.zig"),
        .target = host_target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });
    daemon.linkLibC();

    // 注：daemon 使用自己的类型定义，不依赖 p2p 模块

    // 尝试获取 git 版本
    const version_str = getGitDescribe(b) orelse "0.0.0";
    const daemon_opts = b.addOptions();
    daemon_opts.addOption([]const u8, "version", version_str);
    daemon.root_module.addOptions("build_options", daemon_opts);

    b.installArtifact(daemon);

    // ── Phase 3 单元测试 ──
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
        test_step.dependOn(&test_obj.step);
    }

    // ── Phase 5: wasi-hostd 单元测试 ──
    const daemon_test = b.addTest(.{
        .root_source_file = b.path("src/daemon/test.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    daemon_test.linkLibC();
    test_step.dependOn(&daemon_test.step);
}
