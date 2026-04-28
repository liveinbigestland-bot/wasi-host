/// API 网关插件 - 演示网络+文件写入权限
///
/// 编译: zig build-exe plugins/api_plugin.zig -target wasm32-wasi -rdynamic -O ReleaseSmall
const std = @import("std");

extern "host" fn cpu_cores() u32;
extern "host" fn cpu_usage() f32;
extern "host" fn os_tag() [*:0]const u8;

pub fn main() void {
    std.debug.print("[api_plugin] 启动\n", .{});

    // 读取宿主机概览
    const cores = cpu_cores();
    const usage = cpu_usage();
    const tag   = os_tag();

    std.debug.print("[api_plugin] 宿主: {s} | CPU {d} 核 | 使用率 {d:.1}%\n", .{ tag, cores, usage });

    // 尝试写文件（如果 write=true 则允许）
    const cwd = std.fs.cwd();
    if (cwd.createFile("api_response.txt", .{})) |file| {
        defer file.close();
        file.writer().writeAll("API 插件执行成功\n") catch {};
        std.debug.print("[api_plugin] 文件写入成功\n", .{});
    } else |_| {
        std.debug.print("[api_plugin] 文件写入被拒绝（沙箱限制）\n", .{});
    }

    std.debug.print("[api_plugin] 完成\n", .{});
}
