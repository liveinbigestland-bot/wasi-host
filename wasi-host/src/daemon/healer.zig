/// 自恢复模块
/// 检测到异常后触发 re-join 或 stabilize
const std = @import("std");
const time = std.time;

const config_mod = @import("config.zig");
const monitor_mod = @import("monitor.zig");
const supervisor_mod = @import("supervisor.zig");

pub const Healer = struct {
    alloc: std.mem.Allocator,
    config: config_mod.DaemonConfig,
    last_rejoin_time: i64 = 0,
    rejoin_in_progress: bool = false,

    pub fn init(alloc: std.mem.Allocator, cfg: config_mod.DaemonConfig) Healer {
        return Healer{
            .alloc = alloc,
            .config = cfg,
        };
    }

    /// 根据健康检查结果决定修复动作
    /// 返回是否触发了修复动作
    pub fn heal(
        self: *Healer,
        health: monitor_mod.HealthStatus,
        consecutive_mismatches: u32,
        _: *supervisor_mod.Supervisor,
    ) !bool {
        if (!self.config.auto_recovery) return false;

        switch (health) {
            .isolated => {
                // 重度异常：孤立节点 → 直接 re-join
                return try self.triggerRejoin();
            },
            .successor_mismatch, .predecessor_mismatch => {
                // 轻度异常：先尝试 stabilize（通过发送 stabilize 消息）
                // 连续多次不一致则升级为 re-join
                if (consecutive_mismatches >= self.config.max_mismatches) {
                    std.debug.print("[healer] 连续 {d} 次不一致，升级为 re-join\n", .{consecutive_mismatches});
                    return try self.triggerRejoin();
                } else {
                    std.debug.print("[healer] 位置不一致（第 {d} 次），尝试温和修复\n", .{consecutive_mismatches});
                    // 温和修复：向本地 wasi-host 发送 stabilize 请求
                    // 简化实现：通过重启触发 stabilize
                    return false;
                }
            },
            .ping_timeout => {
                // 进程无响应，supervisor 会处理重启
                std.debug.print("[healer] 进程无响应，等待 supervisor 处理\n", .{});
                return false;
            },
            .ok, .unknown => {
                // 正常，无需修复
                return false;
            },
        }
    }

    /// 触发 re-join
    pub fn triggerRejoin(self: *Healer) !bool {
        const now = time.timestamp();

        // 检查冷却期
        const cooldown_s = self.config.rejoin_cooldown_ms / 1000;
        if (now - self.last_rejoin_time < @as(i64, @intCast(cooldown_s))) {
            std.debug.print("[healer] re-join 冷却中，跳过\n", .{});
            return false;
        }

        std.debug.print("[healer] 触发 re-join\n", .{});
        self.last_rejoin_time = now;
        self.rejoin_in_progress = true;

        // 实际 re-join 通过向 wasi-host 发送 join 命令实现
        // 通过 Unix Socket 调用 api 的 rejoin 命令
        // 或者在 main.zig 中实现 SIGUSR1 信号处理
        // 这里返回 true，由调用者执行具体操作

        return true;
    }

    /// 检查是否可以开始 stabilize
    pub fn shouldStabilize(self: *Healer) bool {
        _ = self;
        return true;
    }

    /// 获取 re-join 冷却剩余秒数
    pub fn rejoinCooldownRemaining(self: *Healer) i64 {
        const now = time.timestamp();
        const cooldown_s = self.config.rejoin_cooldown_ms / 1000;
        const elapsed = now - self.last_rejoin_time;
        if (elapsed >= @as(i64, @intCast(cooldown_s))) return 0;
        return @as(i64, @intCast(cooldown_s)) - elapsed;
    }
};
