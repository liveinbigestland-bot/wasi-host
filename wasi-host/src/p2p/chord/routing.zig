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
    /// 备份后继节点（主后继 failure 时 O(1) 切换）
    backup_successors: [2]?NodeAddr = .{null, null},
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

    /// 设置主后继。如果 successor 已存在且 id 不同，将旧主后继压入备份列表。
    /// 如果 id 相同但地址变了，仅更新地址。
    pub fn setSuccessor(self: *Routing, addr: NodeAddr) void {
        if (self.successor) |old_succ| {
            if (old_succ.id == addr.id) {
                // ID 相同：仅更新地址字段
                self.successor = addr;
                return;
            }
            // 将旧后继加入备份（如果不在备份中且不是自身）
            if (old_succ.id != self.own_id) {
                self.addBackupSuccessor(old_succ);
            }
        }
        // 从备份中移除新后继（避免重复）
        self.removeFromBackups(addr.id);
        self.successor = addr;
    }

    /// 从整个后继列表（主 + 备份）中移除指定 ID 的节点，左移备份填补空缺。
    /// 返回新的主后继（可能是之前的备份）。
    pub fn removeSuccessor(self: *Routing, dead_id: NodeId) ?NodeAddr {
        // 如果主后继匹配
        if (self.successor) |succ| {
            if (succ.id == dead_id) {
                // 从备份中提升第一个
                const promoted = self.backup_successors[0];
                if (promoted) |p| {
                    self.successor = p;
                    self.backup_successors[0] = self.backup_successors[1];
                    self.backup_successors[1] = null;
                } else {
                    self.successor = null;
                }
                return self.successor;
            }
        }
        // 从备份中移除
        self.removeFromBackups(dead_id);
        return self.successor;
    }

    /// 从备份列表中移除指定 ID 的节点
    fn removeFromBackups(self: *Routing, dead_id: NodeId) void {
        var j: usize = 0;
        for (&self.backup_successors) |*slot| {
            if (slot.*) |b| {
                if (b.id != dead_id) {
                    self.backup_successors[j] = slot.*;
                    j += 1;
                }
            }
        }
        // 清空剩余槽位
        while (j < 2) {
            self.backup_successors[j] = null;
            j += 1;
        }
    }

    /// 尝试将节点加入备份列表（去重、顺时针排序、最大 2 个）
    pub fn addBackupSuccessor(self: *Routing, candidate: NodeAddr) void {
        // 不能是自身
        if (candidate.id == self.own_id) return;
        // 不能是主后继
        if (self.successor) |s| if (s.id == candidate.id) return;
        // 去重
        for (&self.backup_successors) |*slot| {
            if (slot.*) |b| {
                if (b.id == candidate.id) {
                    // ID 相同但地址可能变了
                    slot.* = candidate;
                    return;
                }
            }
        }
        // 找空位插入
        for (&self.backup_successors) |*slot| {
            if (slot.* == null) {
                slot.* = candidate;
                // 按顺时针顺序排序（可选优化，简单实现：对新条目直接放入第一个空位）
                return;
            }
        }
        // 已满：替换最远的那个（离 own_id 最远的备份优先级最低）
        // 找距离 own_id 最远的备份位置
        var farthest_idx: usize = 0;
        var farthest_dist: NodeId = 0;
        for (&self.backup_successors, 0..) |*slot, i| {
            if (slot.*) |b| {
                const dist = ring.distance(self.own_id, b.id);
                if (dist > farthest_dist) {
                    farthest_dist = dist;
                    farthest_idx = i;
                }
            }
        }
        self.backup_successors[farthest_idx] = candidate;
    }

    /// 返回主后继 + 所有备份的合并数组（最多 3 个，null 表示无）
    pub fn allReachableSuccessors(self: Routing) [3]?NodeAddr {
        var result: [3]?NodeAddr = .{null, null, null};
        result[0] = self.successor;
        result[1] = self.backup_successors[0];
        result[2] = self.backup_successors[1];
        return result;
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
