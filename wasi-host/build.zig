const std = @import("std");

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
        .strip = true,
    });
    exe.linkLibC();

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
}
