/// Bootstrap 模块：多地址连接策略、指数退避、failover
///
/// 职责：负责 Chord 节点加入环时的引导连接策略
/// 封装了多地址重试和指数退避的逻辑。
///
/// 典型用法：
/// ```zig
/// const client = bootstrap.Client{
///     .sendFn = mySendFunc,
///     .ctx = @ptrCast(myContext),
/// };
/// const result = client.findSuccessor(own_id, &addrs, .{}) catch ...;
/// ```

const std = @import("std");
const ring = @import("../chord/ring.zig");
const types = @import("../chord/types.zig");

const NodeId = ring.NodeId;

/// 发送消息回调
/// ctx: 上下文指针（通常为 *ChordNode）
/// 返回 anyerror!Message 以兼容各种 sendAndWait 的实现
pub const SendFn = *const fn (ctx: *anyopaque, msg: types.Message, expected_type: types.MsgType, target: types.NodeAddr, timeout_ms: u64) anyerror!types.Message;

/// Bootstrap 错误
pub const Error = error{
    /// 地址列表为空
    NoAddresses,
    /// 所有 Bootstrap 节点都不可达
    AllFailed,
    /// 响应类型不匹配
    InvalidResponse,
};

/// Bootstrap 策略配置
pub const Config = struct {
    /// 单次尝试超时（毫秒），默认 3000
    timeout_ms: u64 = 3000,
    /// 对地址列表整体重试次数（首次尝试不计入），默认 2
    max_retries: u32 = 2,
    /// 指数退避基础超时（毫秒），设为 0 则每次重试使用固定 timeout_ms
    backoff_base_ms: u64 = 1000,
};

/// Bootstrap 查询结果
pub const Result = struct {
    /// 目标节点的后继节点
    successor: types.NodeAddr,
    /// 实际成功连接的 Bootstrap 地址（可用于日志/监控）
    used_addr: types.NodeAddr,
};

/// Bootstrap 客户端
pub const Client = struct {
    sendFn: SendFn,
    ctx: *anyopaque,

    /// 向单个地址发送 find_successor 查询
    fn querySuccessor(self: Client, own_id: NodeId, addr: types.NodeAddr, timeout_ms: u64) !types.NodeAddr {
        const resp = try self.sendFn(
            self.ctx,
            types.Message{ .find_successor = .{ .target = own_id } },
            .find_successor_resp,
            addr,
            timeout_ms,
        );
        switch (resp) {
            .find_successor_resp => |body| {
                return types.NodeAddr{
                    .id = body.node_id,
                    .host = body.node_addr,
                    .port = body.node_port,
                    .tcp_port = body.node_tcp_port,
                };
            },
            else => return Error.InvalidResponse,
        }
    }

    /// 遍历 bootstrap 地址列表，找到 successor
    ///
    /// 策略：
    /// 1. 顺序尝试每个 bootstrap 地址
    /// 2. 全部失败后按指数退避重试（最多 max_retries 次）
    /// 3. 任意地址成功则立即返回
    pub fn findSuccessor(self: Client, own_id: NodeId, addrs: []const types.NodeAddr, config: Config) !Result {
        if (addrs.len == 0) return Error.NoAddresses;

        var last_err: ?anyerror = null;
        var timeout = config.timeout_ms;
        var attempt: u32 = 0;
        const max_attempts = config.max_retries + 1;

        while (attempt < max_attempts) : (attempt += 1) {
            for (addrs) |addr| {
                if (self.querySuccessor(own_id, addr, timeout)) |succ| {
                    return Result{ .successor = succ, .used_addr = addr };
                } else |err| {
                    last_err = err;
                }
            }
            // 指数退避：每次完整遍历后增加超时
            if (config.backoff_base_ms > 0) {
                timeout = @min(config.backoff_base_ms * std.math.pow(u64, 2, attempt + 1), 30000);
            }
        }

        return last_err orelse Error.AllFailed;
    }
};
