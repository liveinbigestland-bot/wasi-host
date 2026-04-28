/// AI 推理插件 - 演示宿主硬件信息读取 + WASI 基础能力
///
/// 编译: zig build-exe plugins/ai_plugin.zig -target wasm32-wasi -rdynamic -O ReleaseSmall
const std = @import("std");

// 宿主导入（由 wasi-host 提供）
extern "host" fn cpu_cores() u32;
extern "host" fn cpu_usage() f32;
extern "host" fn mem_total() u64;
extern "host" fn mem_free() u64;
extern "host" fn os_tag() [*:0]const u8;

pub fn main() void {
    std.debug.print("[ai_plugin] 启动\n", .{});

    // 读取宿主机信息
    const cores = cpu_cores();
    const usage = cpu_usage();
    const total = mem_total();
    const free  = mem_free();
    const tag   = os_tag();

    std.debug.print("[ai_plugin] 系统: {s}\n", .{tag});
    std.debug.print("[ai_plugin] CPU 核心数: {d}\n", .{cores});
    std.debug.print("[ai_plugin] CPU 使用率: {d:.1}%\n", .{usage});
    std.debug.print("[ai_plugin] 总内存: {d} MB\n", .{total / (1024 * 1024)});
    std.debug.print("[ai_plugin] 空闲内存: {d} MB\n", .{free / (1024 * 1024)});

    // 模拟 AI 推理计算
    std.debug.print("[ai_plugin] 开始推理...\n", .{});

    // 简单的计算密集型任务
    var result: u64 = 0;
    for (0..100_000) |i| {
        result +%= i *% i;
    }

    std.debug.print("[ai_plugin] 推理结果: {d}\n", .{result});
    std.debug.print("[ai_plugin] 完成\n", .{});
}
