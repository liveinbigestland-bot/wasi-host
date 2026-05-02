/// Chord 路由表 + 查找算法

const std = @import("std");
const ring = @import("ring.zig");
const NodeId = ring.NodeId;
const M = ring.M;

const types = @import("types.zig");
const NodeAddr = types.NodeAddr;

/// Finger 表条目
pub const FingerEntry = struct {
    start: NodeId, // (n + 2^(i-1)) mod 2^m
    node: ?NodeAddr = null, // 负责该区间的第一个节点
};

/// Chord 路由状态
pub const Routing = struct {
    /// 本节点 ID
    own_id: NodeId,
    /// 本节点监听地址
    own_host: []const u8 = "0.0.0.0",
    own_port: u16 = 0,
    /// 本节点 TCP 端口（transport_mode != udp 时有效）
    own_tcp_port: u16 = 0,
    /// 后继节点（Must never be null after join）
    successor: ?NodeAddr = null,
    /// 前驱节点
    predecessor: ?NodeAddr = null,
    /// Finger 表（环形索引：i = 1..M）
    fingers: [M]FingerEntry = undefined,
    /// 下次待修复的 finger 索引
    next_finger: u8 = 0,

    pub fn init(own_id: NodeId, host: []const u8, port: u16, tcp_port: u16) Routing {
        var rt = Routing{
            .own_id = own_id,
            .own_host = host,
            .own_port = port,
            .own_tcp_port = tcp_port,
        };
        // 初始化 finger[start] = (own_id + 2^i) mod 2^160
        for (&rt.fingers, 0..) |*f, i| {
            f.* = .{ .start = ring.fingerStart(own_id, @intCast(i)) };
        }
        // 标准 Chord: 孤立节点以后继自身启动，使 stabilize 能立即运行
        rt.successor = NodeAddr{ .id = own_id, .host = host, .port = port, .tcp_port = tcp_port };
        return rt;
    }

    /// 最近的前驱节点：在 Finger 表中找最接近 target、但不超过 target 的节点
    pub fn closestPrecedingNode(self: Routing, target: NodeId) ?NodeAddr {
        // 从最大的 finger 开始往前找（从后往前遍历 finger 表）
        var i: usize = M;
        while (i > 0) {
            i -= 1;
            if (self.fingers[i].node) |node| {
                // finger.node 必须在 (own_id, target) 之间
                if (ring.betweenLeftInclusive(node.id, self.own_id, target) and node.id != self.own_id) {
                    return node;
                }
            }
        }
        // 退回到后继节点
        return self.successor;
    }

    /// 查找 target 的后继节点
    /// 如果环上只有本节点，返回自身
    pub fn findSuccessor(self: Routing, target: NodeId) NodeAddr {
        if (self.successor) |succ| {
            // target ∈ (self, successor] → 后继就是答案
            if (ring.between(target, self.own_id, succ.id)) {
                return succ;
            }
            // 否则找最近的前驱继续查询
            if (self.closestPrecedingNode(target)) |node| {
                return node;
            }
            return succ;
        }
        // 无后继：本节点是环上唯一节点
        return NodeAddr{ .id = self.own_id, .host = self.own_host, .port = self.own_port, .tcp_port = self.own_tcp_port };
    }

    /// 通知：对方告知可能是我们的前驱
    pub fn notifyCandidate(self: *Routing, candidate: NodeAddr) void {
        // 自通知不应该覆盖已有真实前驱
        if (candidate.id == self.own_id) {
            if (self.predecessor == null) {
                self.predecessor = candidate;
            }
            return;
        }
        if (self.predecessor == null or self.predecessor.?.id == self.own_id) {
            self.predecessor = candidate;
        } else {
            const pred = self.predecessor.?;
            if (ring.between(candidate.id, pred.id, self.own_id)) {
                self.predecessor = candidate;
            } else if (candidate.id == pred.id) {
                // 同一节点但地址可能已变化（如 ext 从 0.0.0.0 变为公网 IP）
                self.predecessor = candidate;
            }
        }
    }

    /// 维护：更新下一个 finger 表条目
    pub fn fixNextFinger(self: *Routing) ?NodeAddr {
        const idx = self.next_finger;
        self.next_finger = (self.next_finger + 1) % M;
        // 查询 finger[idx].start 的后继节点
        return self.findSuccessor(self.fingers[idx].start);
    }
};

test "init" {
    const rt = Routing.init(100, "0.0.0.0", 20808, 0);
    try std.testing.expect(rt.successor != null);
    try std.testing.expectEqual(@as(NodeId, 100), rt.successor.?.id);
    try std.testing.expect(rt.predecessor == null);
    try std.testing.expectEqual(@as(NodeId, 101), rt.fingers[0].start);
    try std.testing.expectEqual(@as(NodeId, 102), rt.fingers[1].start);
    try std.testing.expectEqual(@as(NodeId, 104), rt.fingers[2].start);
}

test "closestPrecedingNode" {
    var rt = Routing.init(0, "0.0.0.0", 20808, 0);
    rt.successor = NodeAddr{ .id = 50, .host = "127.0.0.1", .port = 20809 };
    rt.fingers[5].node = NodeAddr{ .id = 40, .host = "127.0.0.1", .port = 20810 };

    // 查找 target=45，最接近的节点应该是 40
    const closest = rt.closestPrecedingNode(45);
    try std.testing.expect(closest != null);
    if (closest) |n| {
        try std.testing.expectEqual(@as(NodeId, 40), n.id);
    }
}
