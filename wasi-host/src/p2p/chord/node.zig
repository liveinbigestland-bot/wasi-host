/// Chord 节点：加入网络、Stabilize、消息处理、事件循环

const std = @import("std");
const ring = @import("ring.zig");
const types = @import("types.zig");
const routing = @import("routing.zig");
const udp = @import("../transport/udp.zig");
const tcp_mod = @import("../transport/tcp.zig");
const proxy = @import("../proxy.zig");
const relay = @import("../relay.zig");
const kv_store = @import("../metadata/store.zig");
const meta_permission = @import("../metadata/permission.zig");
const replication = @import("../metadata/replication.zig");
const config_mod = @import("../config.zig");

const NodeId = ring.NodeId;
const Message = types.Message;
const MsgType = types.MsgType;
const NodeAddr = types.NodeAddr;
const Routing = routing.Routing;
const UdpSocket = udp.UdpSocket;
const TcpTransport = tcp_mod.TcpTransport;
const TransportMode = config_mod.TransportMode;
const KVStore = kv_store.KVStore;
const ReplicationManager = replication.ReplicationManager;
const DHTEntry = @import("../metadata/types.zig").DHTEntry;
const Permission = @import("../metadata/types.zig").Permission;

/// 时间戳（毫秒）
fn timestamp() i64 {
    return std.time.milliTimestamp();
}

/// Chord DHT 节点
pub const ChordNode = struct {
    alloc: std.mem.Allocator,
    msg_arena: std.heap.ArenaAllocator,
    own_id: NodeId,
    own_host: []const u8,
    own_port: u16,
    routing: Routing,
    socket: UdpSocket,
    running: bool,

    // 传输模式
    transport_mode: TransportMode = .udp,
    /// 对外通告的 TCP 端口（0 = 不支持 TCP）
    tcp_port: u16 = 0,
    /// TCP 传输（用于 accept 入站 + sendAndWait 出站）
    tcp_transport: ?TcpTransport = null,
    /// TCP accept 线程
    tcp_thread: ?std.Thread = null,

    // WebSocket 代理配置
    proxy_enabled: bool = false,
    proxy_transport: []const u8 = "tcp",
    proxy_remote_host: []const u8 = "",
    proxy_remote_port: u16 = 0,
    proxy_remote_path: []const u8 = "/chord",
    proxy_route_host: []const u8 = "",
    proxy_route_port: u16 = 0,
    // 原生 TCP Relay 客户端（替代 index.js）
    relay_client: ?*relay.RelayClient = null,
    // 兜底 Bootstrap 节点地址列表（当后继不可达时尝试重新加入）
    bootstrap_addrs: []NodeAddr = &.{},

    // DHT KV 存储
    store: KVStore,
    replication_mgr: ReplicationManager,
    last_save: i64 = 0,
    save_interval_ms: u64 = 60000, // 每分钟持久化一次
    own_pk_hex: []const u8 = "", // 本机公钥十六进制

    // 定时器状态
    last_stabilize: i64 = 0,
    last_fix_fingers: i64 = 0,
    last_check_pred: i64 = 0,
    stabilize_ms: u64,
    fix_fingers_ms: u64,

    /// 分配器 + 节点 ID + 监听地址 + 配置 → 初始化 Chord 节点
    pub fn init(
        alloc: std.mem.Allocator,
        own_id: NodeId,
        host: []const u8,
        port: u16,
        stabilize_ms: u64,
        proxy_transport: []const u8,
        proxy_remote_host: []const u8,
        proxy_remote_port: u16,
        proxy_remote_path: []const u8,
        proxy_route_host: []const u8,
        proxy_route_port: u16,
        data_dir: []const u8,
        own_pk_hex: []const u8,
        relay_client: ?*relay.RelayClient,
        transport_mode: TransportMode,
        tcp_port: u16,
        bootstrap_addrs: []NodeAddr,
    ) !ChordNode {
        const socket = try UdpSocket.bind(port);
        const actual_port = socket.localPort();
        std.debug.print("[chord] UDP 监听 :{d}\n", .{actual_port});

        const using_relay = relay_client != null;
        var node = ChordNode{
            .alloc = alloc,
            .msg_arena = std.heap.ArenaAllocator.init(alloc),
            .own_id = own_id,
            .own_host = host,
            .own_port = actual_port,
            .routing = Routing.init(own_id, host, actual_port, tcp_port),
            .socket = socket,
            .running = false,
            .stabilize_ms = stabilize_ms,
            .fix_fingers_ms = stabilize_ms * 2,
            // relay 模式下禁用旧的 proxy 路径，reply() 走直接 UDP
            .proxy_enabled = !using_relay and proxy_remote_host.len > 0,
            .proxy_transport = proxy_transport,
            .proxy_remote_host = proxy_remote_host,
            .proxy_remote_port = proxy_remote_port,
            .proxy_remote_path = proxy_remote_path,
            .proxy_route_host = proxy_route_host,
            .proxy_route_port = proxy_route_port,
            .relay_client = relay_client,
            .store = KVStore.init(alloc, try alloc.dupe(u8, data_dir)),
            .replication_mgr = ReplicationManager.init(alloc),
            .own_pk_hex = try alloc.dupe(u8, own_pk_hex),
            .transport_mode = transport_mode,
            .tcp_port = tcp_port,
            .bootstrap_addrs = bootstrap_addrs,
        };
        // 加载持久化数据
        node.store.load() catch |err| {
            std.debug.print("[store] 加载持久化数据失败: {}\n", .{err});
        };
        return node;
    }

    /// 启动 TCP 监听器（transport_mode == tcp 或 dual 时调用）
    pub fn startTcpListener(self: *ChordNode, port: u16) !void {
        if (self.transport_mode == .udp) return; // UDP 模式不需要 TCP
        const effective_port = if (port > 0) port else self.own_port;
        const transport = try TcpTransport.init(effective_port);
        self.tcp_transport = transport;
        self.tcp_port = transport.port;
        self.routing.own_tcp_port = transport.port; // 同步到路由表
        // 同时更新所有 successor 条目的 tcp_port
        if (self.routing.successor) |*succ| {
            if (succ.id == self.own_id) {
                succ.tcp_port = transport.port;
            }
        }
        for (&self.routing.backup_successors) |*slot| {
            if (slot.*) |*b| {
                if (b.id == self.own_id) {
                    b.tcp_port = transport.port;
                }
            }
        }
        std.debug.print("[chord] TCP 监听 :{d} (通告 tcp_port={d})\n", .{ transport.port, self.tcp_port });
        // 启动 accept 线程（处理入站 TCP 连接）
        const T = struct {
            fn runLoop(trans: *TcpTransport, udp_port: u16) void {
                trans.acceptLoop(udp_port);
            }
        };
        self.tcp_thread = try std.Thread.spawn(.{}, T.runLoop, .{ &self.tcp_transport.?, self.own_port });
    }

    /// 关闭 TCP 监听器
    pub fn stopTcpListener(self: *ChordNode) void {
        if (self.tcp_transport) |*t| {
            t.running = false;
            t.listener.deinit();
        }
        if (self.tcp_thread) |t| {
            t.join();
            self.tcp_thread = null;
        }
        self.tcp_transport = null;
    }

    /// 加入 Chord 环：联系 Bootstrap 节点
    pub fn join(self: *ChordNode, bootstrap: types.NodeAddr) !void {
        std.debug.print("[chord] 加入网络: target node={s}:{d}\n", .{ bootstrap.host, bootstrap.port });

        // 向 Bootstrap 节点查询自己的后继
        const resp = try self.sendAndWait(Message{ .find_successor = .{ .target = self.own_id } }, .find_successor_resp, bootstrap, 3000);

        switch (resp) {
            .find_successor_resp => |body| {
                const succ = NodeAddr{ .id = body.node_id, .host = body.node_addr, .port = body.node_port, .tcp_port = body.node_tcp_port };
                std.debug.print("[chord] 后继节点: id={s} addr={s}:{d} tcp={d}\n", .{
                    ring.idToHex(succ.id), succ.host, succ.port, succ.tcp_port,
                });
                self.routing.setSuccessor(succ);

                // ── Finger 表快速填充：利用后继节点批量填充初始 finger 条目 ──
                if (self.routing.successor) |s| {
                    // finger[0] 必然指向 successor
                    self.routing.fingers[0].node = s;
                    // 对于 i=1..15，如果 finger[i].start 落在 (own_id, successor.id] 区间，直接填充
                    var i: u8 = 1;
                    while (i < 16 and i < ring.M) : (i += 1) {
                        const start = ring.fingerStart(self.own_id, i);
                        if (ring.betweenLeftInclusive(start, self.own_id, s.id)) {
                            self.routing.fingers[i].node = s;
                        } else {
                            // 超出 successor 区间：向 successor 发送 find_successor 查询
                            const f_resp = self.sendAndWait(Message{ .find_successor = .{ .target = start } }, .find_successor_resp, s, 3000) catch |err| {
                                std.debug.print("[chord] join: finger[{d}] 查询失败: {}\n", .{ i, err });
                                continue;
                            };
                            switch (f_resp) {
                                .find_successor_resp => |fb| {
                                    const f_node = NodeAddr{ .id = fb.node_id, .host = fb.node_addr, .port = fb.node_port, .tcp_port = fb.node_tcp_port };
                                    self.routing.fingers[i].node = f_node;
                                },
                                else => {},
                            }
                        }
                    }
                    std.debug.print("[chord] join: 快速填充了 {d} 个 finger 条目\n", .{i});
                }
            },
            else => {
                std.debug.print("[chord] join: 意外的响应类型\n", .{});
                return error.JoinFailed;
            },
        }
    }

    /// 事件循环主循环（单次迭代，供外部定时调用）
    pub fn tick(self: *ChordNode) !void {
        const now = timestamp();

        // 处理收到的消息（耗尽 recv 缓冲区）
        while (true) {
            var buf: [65535]u8 = undefined;
            const result = self.socket.recvFrom(&buf) catch |err| {
                if (err == error.WouldBlock) break;
                std.debug.print("[chord] recv 错误: {}\n", .{err});
                break;
            };
            const data = buf[0..result.n];
            const msg = Message.decode(data, self.msg_arena.allocator()) catch |err| {
                std.debug.print("[chord] 消息解码失败: {}\n", .{err});
                continue;
            };
            self.handleMessage(msg, result.addr);
        }

        // 定时 Stabilize
        if (self.routing.successor != null) {
            if (now - self.last_stabilize >= @as(i64, @intCast(self.stabilize_ms))) {
                try self.doStabilize();
                self.last_stabilize = now;
            }

            // 定时 FixFingers
            if (now - self.last_fix_fingers >= @as(i64, @intCast(self.fix_fingers_ms))) {
                try self.doFixFingers();
                self.last_fix_fingers = now;
            }

            // 定时检查前驱存活
            if (now - self.last_check_pred >= @as(i64, @intCast(self.stabilize_ms * 2))) {
                try self.doCheckPredecessor();
                self.last_check_pred = now;
            }

            // 处理副本同步队列
            try self.processReplication();

            // 定时持久化存储
            if (now - self.last_save >= @as(i64, @intCast(self.save_interval_ms))) {
                self.store.save() catch |err| {
                    std.debug.print("[store] 自动保存失败: {}\n", .{err});
                };
                self.last_save = now;
            }
        }
    }

    // ═══════════════════════════════════════════════
    // 消息处理
    // ═══════════════════════════════════════════════

    fn handleMessage(self: *ChordNode, msg: Message, from: std.net.Address) void {
        switch (msg) {
            .ping => {
                std.debug.print("[chord] ← ping from {}\n", .{from});
                self.reply(from, Message{ .pong = {} }) catch {};
            },
            .find_successor => |body| {
                std.debug.print("[chord] find_successor from {} (port={d})\n", .{ from, @as(u16, from.in.sa.port) });
                const succ = self.routing.findSuccessor(body.target);
                self.reply(from, Message{ .find_successor_resp = .{
                    .node_id = succ.id,
                    .node_addr = succ.host,
                    .node_port = succ.port,
                    .node_tcp_port = succ.tcp_port,
                } }) catch {};
            },
            .get_predecessor => {
                const pred = self.routing.predecessor;
                self.reply(from, Message{ .get_predecessor_resp = .{
                    .node_id = if (pred) |p| p.id else null,
                    .node_addr = if (pred) |p| p.host else "",
                    .node_port = if (pred) |p| p.port else 0,
                    .node_tcp_port = if (pred) |p| p.tcp_port else 0,
                } }) catch {};
            },
            .notify => |body| {
                const candidate = NodeAddr{ .id = body.node_id, .host = body.node_addr, .port = body.node_port, .tcp_port = body.node_tcp_port };
                std.debug.print("[chord] ← notify from {} id={s} host={s}:{d} tcp={d}, my_pred={?s}:{?d}\n", .{
                    from, ring.idToHex(body.node_id), candidate.host, candidate.port, candidate.tcp_port,
                    if (self.routing.predecessor) |p| p.host else null,
                    if (self.routing.predecessor) |p| p.port else null,
                });
                const old_pred = self.routing.predecessor;
                self.routing.notifyCandidate(candidate);
                if (self.routing.predecessor != null and !std.meta.eql(self.routing.predecessor, old_pred)) {
                    std.debug.print("[chord] 前驱更新为 {s}:{d}\n", .{ candidate.host, candidate.port });
                }
                self.reply(from, Message{ .notify_ok = {} }) catch {};
            },
            .pong, .find_successor_resp, .get_predecessor_resp, .notify_ok, .ping_req, .ping_resp => {
                // 这些是响应类型，应该在 sendAndWait 中处理
            },

            // ── DHT 存储消息 ──────────────────────────────────
            .dht_put => |body| {
                std.debug.print("[store] ← dht_put key={s} from {}\n", .{ body.key, from });
                const perm = Permission.fromU8(body.permission);
                // 检查写入权限：新条目始终允许，更新条目需要匹配 owner
                const existing = self.store.get(body.key);
                if (existing) |entry| {
                    if (!std.mem.eql(u8, entry.owner, body.owner)) {
                        std.debug.print("[store] dht_put 权限拒绝: owner 不匹配\n", .{});
                        self.reply(from, Message{ .dht_put_resp = .{ .ok = false, .version = entry.version } }) catch {};
                        return;
                    }
                }
                _ = self.store.put(body.key, body.value, body.owner, perm) catch |err| {
                    std.debug.print("[store] dht_put 失败: {}\n", .{err});
                    self.reply(from, Message{ .dht_put_resp = .{ .ok = false, .version = 0 } }) catch {};
                    return;
                };
                // 队列副本同步
                if (self.store.get(body.key)) |entry| {
                    self.replication_mgr.enqueue(&entry) catch |err| {
                        std.debug.print("[store] 副本入队失败: {}\n", .{err});
                    };
                }
                self.reply(from, Message{ .dht_put_resp = .{ .ok = true, .version = self.store.get(body.key).?.version } }) catch {};
            },
            .dht_put_resp => {
                // 在 sendAndWait 中处理
            },
            .dht_get => |body| {
                std.debug.print("[store] ← dht_get key={s} from {}\n", .{ body.key, from });
                if (self.store.get(body.key)) |entry| {
                    // 检查读取权限
                    const result = meta_permission.checkRead(&entry, self.own_pk_hex);
                    if (result != .allowed) {
                        std.debug.print("[store] dht_get 权限拒绝: {}\n", .{result});
                        self.reply(from, Message{ .dht_get_resp = .{
                            .found = false, .key = body.key,
                            .value = "", .owner = "", .permission = 0, .version = 0, .timestamp = 0,
                        } }) catch {};
                        return;
                    }
                    self.reply(from, Message{ .dht_get_resp = .{
                        .found = true,
                        .key = entry.key,
                        .value = entry.value,
                        .owner = entry.owner,
                        .permission = @intFromEnum(entry.permission),
                        .version = entry.version,
                        .timestamp = entry.timestamp,
                    } }) catch {};
                } else {
                    self.reply(from, Message{ .dht_get_resp = .{
                        .found = false, .key = body.key,
                        .value = "", .owner = "", .permission = 0, .version = 0, .timestamp = 0,
                    } }) catch {};
                }
            },
            .dht_get_resp => {
                // 在 sendAndWait 中处理
            },
            .dht_delete => |body| {
                std.debug.print("[store] ← dht_delete key={s} from {}\n", .{ body.key, from });
                if (self.store.get(body.key)) |entry| {
                    if (!std.mem.eql(u8, entry.owner, body.owner)) {
                        std.debug.print("[store] dht_delete 权限拒绝: owner 不匹配\n", .{});
                        self.reply(from, Message{ .dht_delete_resp = .{ .ok = false } }) catch {};
                        return;
                    }
                }
                const ok = self.store.delete(body.key);
                self.reply(from, Message{ .dht_delete_resp = .{ .ok = ok } }) catch {};
            },
            .dht_delete_resp => {
                // 在 sendAndWait 中处理
            },
            .dht_replicate => |body| {
                // 副本存储：不检查权限，信任主节点
                const perm = Permission.fromU8(body.permission);
                _ = self.store.put(body.key, body.value, body.owner, perm) catch |err| {
                    std.debug.print("[store] dht_replicate 失败: {}\n", .{err});
                    self.reply(from, Message{ .dht_replicate_resp = .{ .ok = false } }) catch {};
                    return;
                };
                self.reply(from, Message{ .dht_replicate_resp = .{ .ok = true } }) catch {};
            },
            .dht_replicate_resp => {
                // 在 sendAndWait 中处理
            },
        }
    }

    /// 判断目标 IP 是否为私网/回环地址（用于 proxy 模式下区分 LAN/WAN 流量）
    fn isPrivateTarget(addr: u32) bool {
        // addr 来自 std.net.Address.in.sa.addr，始终是网络字节序
        // 转为主机字节序后取前两个八位组判断
        const host = std.mem.bigToNative(u32, addr);
        const first = @as(u8, @truncate(host >> 24));
        const second = @as(u8, @truncate(host >> 16));
        return first == 10 or first == 127 or (first == 192 and second == 168) or (first == 172 and second >= 16 and second <= 31);
    }

    /// 判断地址是否为 127.0.0.1（回环地址）
    fn isLocalhost(addr: std.net.Address) bool {
        const host = std.mem.bigToNative(u32, addr.in.sa.addr);
        return @as(u8, @truncate(host >> 24)) == 127;
    }

    /// 检查地址是否匹配 route_host:route_port（用于代理路由判断）
    fn addrMatchesRoute(self: *ChordNode, addr: std.net.Address) bool {
        if (self.proxy_route_host.len == 0 or self.proxy_route_port == 0) return false;
        if (addr.in.sa.port != std.mem.nativeToBig(u16, self.proxy_route_port)) return false;
        const parsed = std.net.Address.parseIp(self.proxy_route_host, 0) catch return false;
        return addr.in.sa.addr == parsed.in.sa.addr;
    }

    fn reply(self: *ChordNode, to: std.net.Address, msg: Message) !void {
        if (self.proxy_enabled) {
            // 与 sendAndWait 保持一致的代理路由逻辑
            const should_proxy = if (self.proxy_route_host.len > 0 and self.proxy_route_port > 0)
                self.addrMatchesRoute(to)
            else
                // 无 route_host: 所有流量走代理，但排除本地回环（127.0.0.1 的回复直接 UDP）
                !isLocalhost(to);
            if (should_proxy) {
                const data = try msg.encode(self.alloc);
                defer self.alloc.free(data);
                var buf: [65536]u8 = undefined;
                _ = proxy.sendViaProxy(
                    self.alloc,
                    self.proxy_transport,
                    self.proxy_remote_host, self.proxy_remote_port, self.proxy_remote_path,
                    to.in.sa.addr, to.in.sa.port,
                    data, &buf, 5000,
                ) catch {};
                return;
            }
        }
        return self.replyDirect(to, msg);
    }

    fn replyDirect(self: *ChordNode, to: std.net.Address, msg: Message) !void {
        const data = try msg.encode(self.alloc);
        defer self.alloc.free(data);
        try self.socket.sendTo(to, data);
    }

    /// 发送消息并等待指定类型的响应（带超时）
    /// 只接受 expected_type 类型的消息作为有效响应，忽略其他消息（防止其他节点的消息干扰）
    /// 传输优先级：self-target → TCP → relay → WebSocket proxy → UDP
    pub fn sendAndWait(self: *ChordNode, msg: Message, expected_type: MsgType, target: NodeAddr, timeout_ms: u64) !Message {
        // ═══ 1. Self-target optimization: handle locally to avoid loopback UDP issue ═══
        // 只有当 host:port + 节点 ID 都匹配才算 self-target
        // NAT 后的多节点共享同一公网 IP，但 ID 不同→走 relay/UDP 通道
        if (target.id == self.own_id and std.mem.eql(u8, target.host, self.own_host) and target.port == self.own_port) {
            switch (msg) {
                .ping => return Message{ .pong = {} },
                .get_predecessor => {
                    const pred = self.routing.predecessor;
                    return Message{ .get_predecessor_resp = .{
                        .node_id = if (pred) |p| p.id else null,
                        .node_addr = if (pred) |p| p.host else "",
                        .node_port = if (pred) |p| p.port else 0,
                        .node_tcp_port = if (pred) |p| p.tcp_port else 0,
                    } };
                },
                .find_successor => |body| {
                    const succ = self.routing.findSuccessor(body.target);
                    return Message{ .find_successor_resp = .{
                        .node_id = succ.id,
                        .node_addr = succ.host,
                        .node_port = succ.port,
                        .node_tcp_port = succ.tcp_port,
                    } };
                },
                .notify => |body| {
                    const candidate = NodeAddr{ .id = body.node_id, .host = body.node_addr, .port = body.node_port, .tcp_port = body.node_tcp_port };
                    std.debug.print("[chord] self-target notify from id={s} host={s}:{d} tcp={d}\n", .{
                        ring.idToHex(body.node_id), candidate.host, candidate.port, candidate.tcp_port,
                    });
                    self.routing.notifyCandidate(candidate);
                    return Message{ .notify_ok = {} };
                },
                .dht_get => |body| {
                    if (self.store.get(body.key)) |entry| {
                        return Message{ .dht_get_resp = .{
                            .found = true,
                            .key = entry.key,
                            .value = entry.value,
                            .owner = entry.owner,
                            .permission = @intFromEnum(entry.permission),
                            .version = entry.version,
                            .timestamp = entry.timestamp,
                        } };
                    } else {
                        return Message{ .dht_get_resp = .{
                            .found = false, .key = body.key,
                            .value = "", .owner = "", .permission = 0, .version = 0, .timestamp = 0,
                        } };
                    }
                },
                .dht_put => |body| {
                    const perm = Permission.fromU8(body.permission);
                    _ = self.store.put(body.key, body.value, body.owner, perm) catch {
                        return Message{ .dht_put_resp = .{ .ok = false, .version = 0 } };
                    };
                    if (self.store.get(body.key)) |entry| {
                        self.replication_mgr.enqueue(&entry) catch {};
                    }
                    return Message{ .dht_put_resp = .{ .ok = true, .version = self.store.get(body.key).?.version } };
                },
                .dht_delete => |body| {
                    const ok = self.store.delete(body.key);
                    return Message{ .dht_delete_resp = .{ .ok = ok } };
                },
                inline else => {},
            }
        }

        // ═══ 2. TCP 直接传输路径（最低延迟，性能最优）═══
        if (self.transport_mode != .udp and target.tcp_port > 0) {
            const encoded = try msg.encode(self.alloc);
            defer self.alloc.free(encoded);
            var buf: [65536]u8 = undefined;
            if (TcpTransport.sendAndWait(target.host, target.tcp_port, encoded, &buf, timeout_ms)) |resp_len| {
                const resp = try Message.decode(buf[0..resp_len], self.msg_arena.allocator());
                const tag_matches = switch (resp) {
                    inline else => |_, tag| tag == expected_type,
                };
                if (!tag_matches) {
                    std.debug.print("[chord] TCP: 期望={s}, 收到={s}\n", .{ @tagName(expected_type), @tagName(resp) });
                    return error.ProxyWrongType;
                }
                std.debug.print("[chord] TCP 成功 → {s}:{d}\n", .{ target.host, target.tcp_port });
                return resp;
            } else |err| {
                std.debug.print("[chord] TCP 失败 {s}:{d}: {}, fallback\n", .{ target.host, target.tcp_port, err });
                // TCP 失败，fall through 到 relay/UDP
            }
        }

        // ═══ 3. 原生 TCP Relay 路径（适合外网节点间通信）═══
        relay_blk: {
            if (self.relay_client) |client| {
                // 中继协议仅支持 IPv4（路由键使用 u32 IP 地址）
                if (std.mem.indexOfScalar(u8, target.host, ':') != null) {
                    std.debug.print("[chord] relay 跳过（目标 {s} 为 IPv6，中继协议不支持）\n", .{target.host});
                    if (self.transport_mode == .tcp) return error.ProxyFailed;
                    break :relay_blk;
                }
                const encoded = try msg.encode(self.alloc);
                defer self.alloc.free(encoded);
                const target_addr = std.net.Address.parseIp(target.host, target.port) catch |err| {
                    std.debug.print("[chord] relay 地址解析失败: {s} ({})\n", .{ target.host, err });
                    return error.InvalidAddress;
                };
                var buf: [65536]u8 = undefined;
                const resp_len = client.sendRequest(
                    std.mem.nativeToBig(u32, target_addr.in.sa.addr), target.port,
                    encoded, &buf, timeout_ms,
                ) catch |err| {
                    std.debug.print("[chord] relay send err: {}\n", .{err});
                    if (self.transport_mode == .tcp) return error.ProxyFailed;
                    // dual mode: TCP 已尝试并失败，relay 也失败 → fall through to UDP
                    break :relay_blk;
                };
                std.debug.print("[chord] relay resp raw: {s}\n", .{buf[0..@min(resp_len, @as(usize, 512))]});
                const resp = try Message.decode(buf[0..resp_len], self.msg_arena.allocator());
                const tag_matches = switch (resp) {
                    inline else => |_, tag| tag == expected_type,
                };
                if (!tag_matches) {
                    std.debug.print("[chord] relay: 期望={s}, 收到={s}\n", .{ @tagName(expected_type), @tagName(resp) });
                    return error.ProxyWrongType;
                }
                return resp;
            }
        }

        // ═══ 3b. TCP 兜底（relay 通道不稳定时，目标支持 TCP 则直接连接）═══
        if (target.tcp_port > 0) {
            const encoded = try msg.encode(self.alloc);
            defer self.alloc.free(encoded);
            var buf: [65536]u8 = undefined;
            if (TcpTransport.sendAndWait(target.host, target.tcp_port, encoded, &buf, timeout_ms)) |resp_len| {
                const resp = try Message.decode(buf[0..resp_len], self.msg_arena.allocator());
                const tag_matches = switch (resp) {
                    inline else => |_, tag| tag == expected_type,
                };
                if (!tag_matches) {
                    std.debug.print("[chord] TCP fallback: 期望={s}, 收到={s}\n", .{ @tagName(expected_type), @tagName(resp) });
                    return error.ProxyWrongType;
                }
                std.debug.print("[chord] TCP fallback 成功 → {s}:{d}\n", .{ target.host, target.tcp_port });
                return resp;
            } else |err| {
                std.debug.print("[chord] TCP fallback 失败 {s}:{d}: {}\n", .{ target.host, target.tcp_port, err });
            }
        }

        // ═══ 4. WebSocket 代理路径（旧版代理兼容）═══
        if (self.proxy_enabled) {
            const should_proxy = if (self.proxy_route_host.len > 0 and self.proxy_route_port > 0)
                std.mem.eql(u8, target.host, self.proxy_route_host) and target.port == self.proxy_route_port
            else
                !std.mem.eql(u8, target.host, "127.0.0.1") and !std.mem.eql(u8, target.host, self.own_host);

            if (should_proxy) {
                const target_addr = std.net.Address.parseIp(target.host, target.port) catch |err| {
                    std.debug.print("[chord] 代理地址解析失败: {s} ({})\n", .{ target.host, err });
                    return error.InvalidAddress;
                };

                const encoded = try msg.encode(self.alloc);
                defer self.alloc.free(encoded);

                var buf: [65536]u8 = undefined;
                const resp_len = proxy.sendViaProxy(
                    self.alloc,
                    self.proxy_transport,
                    self.proxy_remote_host, self.proxy_remote_port, self.proxy_remote_path,
                    target_addr.in.sa.addr, target.port, // 网络字节序
                    encoded, &buf, timeout_ms,
                ) catch |err| {
                    std.debug.print("[chord] proxy send err: {}\n", .{err});
                    return error.ProxyFailed;
                };
                const resp = try Message.decode(buf[0..resp_len], self.msg_arena.allocator());
                const tag_matches = switch (resp) {
                    inline else => |_, tag| tag == expected_type,
                };
                if (!tag_matches) {
                    std.debug.print("[chord] proxy: 期望={s}, 收到={s}, 重试\n", .{ @tagName(expected_type), @tagName(resp) });
                    return error.ProxyWrongType;
                }
                return resp;
            }
        }

        // ═══ 5. UDP 传输路径（兜底）═══
        const target_addr = std.net.Address.parseIp(target.host, target.port) catch |err| {
            std.debug.print("[chord] 地址解析失败 {}: {s}\n", .{ err, target.host });
            return error.InvalidAddress;
        };

        const data = try msg.encode(self.alloc);
        defer self.alloc.free(data);
        try self.socket.sendTo(target_addr, data);

        // 等待响应（非阻塞轮询）
        const deadline = timestamp() + @as(i64, @intCast(timeout_ms));
        while (timestamp() < deadline) {
            var buf: [65535]u8 = undefined;
            const result = self.socket.recvFrom(&buf) catch |err| switch (err) {
                error.WouldBlock => {
                    std.time.sleep(10 * std.time.ns_per_ms);
                    continue;
                },
                else => |e| return e,
            };
            const resp = Message.decode(buf[0..result.n], self.msg_arena.allocator()) catch continue;
            // 检查消息类型是否匹配（过滤其他节点的干扰消息）
            const tag_matches = switch (resp) {
                inline else => |_, tag| tag == expected_type,
            };
            if (!tag_matches) {
                // 处理非期望消息防止并发 stabilize 互相丢失
                self.handleMessage(resp, result.addr);
                continue;
            }
            return resp;
        }
        return error.Timeout;
    }

    // ═══════════════════════════════════════════════
    // Chord 维护协议
    // ═══════════════════════════════════════════════

    /// 在 successor 失效时，从备份列表、finger 表和前驱中寻找替代节点
    fn findAlternativeSuccessor(self: *ChordNode, dead_succ: NodeAddr) ?NodeAddr {
        // 1. 从备份后继列表检查（O(1) 切换，无需网络开销大扫描）
        const backups = self.routing.allReachableSuccessors();
        for (backups) |maybe_bak| {
            const bak = maybe_bak orelse continue;
            if (bak.id == dead_succ.id or bak.id == self.own_id) continue;
            const ping_bak = self.sendAndWait(Message{ .ping = {} }, .pong, bak, 3000);
            if (ping_bak) |_| {
                std.debug.print("[chord] findAlternative: 备份后继 {s}:{d} 存活\n", .{ ring.idToHex(bak.id), bak.port });
                // 从列表中移除死节点，将备份提升为主续
                _ = self.routing.removeSuccessor(dead_succ.id);
                return bak;
            } else |_| {
                std.debug.print("[chord] findAlternative: 备份后继 {s}:{d} 无响应, 移除\n", .{ ring.idToHex(bak.id), bak.port });
                _ = self.routing.removeSuccessor(bak.id);
            }
        }

        // 2. 从 finger 表扫描（finger[0] 范围最小，最可能负责这段区间）
        for (self.routing.fingers) |finger| {
            const node = finger.node orelse continue;
            if (node.id == dead_succ.id) continue; // 跳过死节点
            // ping 验证存活
            const ping_result = self.sendAndWait(Message{ .ping = {} }, .pong, node, 3000);
            if (ping_result) |_| {
                std.debug.print("[chord] findAlternative: finger 节点 {s}:{d} 存活\n", .{ ring.idToHex(node.id), node.port });
                return node;
            } else |_| continue;
        }
        // 3. 尝试前驱
        if (self.routing.predecessor) |pred| {
            if (pred.id != dead_succ.id) {
                const ping_pred = self.sendAndWait(Message{ .ping = {} }, .pong, pred, 3000);
                if (ping_pred) |_| {
                    std.debug.print("[chord] findAlternative: 前驱 {s}:{d} 存活\n", .{ ring.idToHex(pred.id), pred.port });
                    return pred;
                } else |_| {}
            }
        }
        return null;
    }

    /// 兜底：联系已配置的 Bootstrap 节点重新加入环
    /// 返回 true 表示至少一个 bootstrap 成功
    fn tryBootstrapFallback(self: *ChordNode) bool {
        for (self.bootstrap_addrs) |boot| {
            std.debug.print("[chord] tryBootstrap: 尝试重新加入 {s}:{d}\n", .{ boot.host, boot.port });
            const resp = self.sendAndWait(Message{ .find_successor = .{ .target = self.own_id } }, .find_successor_resp, boot, 5000) catch |err| {
                std.debug.print("[chord] tryBootstrap: {s}:{d} 失败: {}\n", .{ boot.host, boot.port, err });
                continue;
            };
            switch (resp) {
                .find_successor_resp => |body| {
                    const new_succ = NodeAddr{
                        .id = body.node_id,
                        .host = body.node_addr,
                        .port = body.node_port,
                        .tcp_port = body.node_tcp_port,
                    };
                    std.debug.print("[chord] tryBootstrap: 找到后继 {s}:{d} tcp={d}\n", .{
                        ring.idToHex(new_succ.id), new_succ.port, new_succ.tcp_port,
                    });
                    // 全量重连：清空备份后继列表
                    self.routing.backup_successors = .{null, null};
                    self.routing.setSuccessor(new_succ);
                    return true;
                },
                else => {
                    std.debug.print("[chord] tryBootstrap: 意外的响应类型\n", .{});
                    continue;
                },
            }
        }
        return false;
    }

    /// Stabilize: 验证后继并通知
    fn doStabilize(self: *ChordNode) !void {
        const succ = self.routing.successor orelse return;
        std.debug.print("[chord] stabilize: 后继={s}\n", .{ring.idToHex(succ.id)});

        // 询问后继的前驱
        const resp = self.sendAndWait(Message{ .get_predecessor = {} }, .get_predecessor_resp, succ, 5000) catch |err| {
            std.debug.print("[chord] stabilize: 联系后继失败 {}\n", .{err});
            // 尝试找替代后继
            if (self.findAlternativeSuccessor(succ)) |alt| {
                std.debug.print("[chord] stabilize: 切换到替代后继 {s}:{d}\n", .{ ring.idToHex(alt.id), alt.port });
                self.routing.setSuccessor(alt);
            } else if (self.tryBootstrapFallback()) {
                // 兜底：重新连接 Bootstrap 节点
                std.debug.print("[chord] stabilize: 通过 Bootstrap 成功重新加入\n", .{});
            } else {
                std.debug.print("[chord] stabilize: 未找到替代后继，保持当前后继\n", .{});
            }
            return;
        };

        switch (resp) {
            .get_predecessor_resp => |body| {
                if (body.node_id) |pred_id| {
                    const pred_addr = NodeAddr{ .id = pred_id, .host = body.node_addr, .port = body.node_port };
                    // 后继指向自己时，直接采用前驱作为后继（孤立节点发现新节点加入）
                    if (succ.id == self.own_id and pred_id != self.own_id) {
                        self.routing.setSuccessor(pred_addr);
                        std.debug.print("[chord] stabilize: 孤立节点检测到新节点，更新后继为 {s}\n", .{ring.idToHex(pred_id)});
                    } else if (ring.between(pred_id, self.own_id, succ.id)) {
                        self.routing.setSuccessor(pred_addr);
                        std.debug.print("[chord] stabilize: 更新后继为 {s}\n", .{ring.idToHex(pred_id)});
                    }
                }
            },
            else => {},
        }

        // 兜底：后继仍是自己时尝试 Bootstrap 重新加入
        if (succ.id == self.own_id) {
            if (self.routing.successor) |cur| {
                if (cur.id == self.own_id) {
                    if (self.tryBootstrapFallback()) {
                        std.debug.print("[chord] stabilize: 孤立节点通过 Bootstrap 成功重新加入\n", .{});
                    }
                }
            }
        }

        // 通知后继
        const current_succ = self.routing.successor orelse return;
        _ = self.sendAndWait(Message{ .notify = .{
            .node_id = self.own_id,
            .node_addr = self.own_host,
            .node_port = self.own_port,
            .node_tcp_port = self.tcp_port,
        } }, .notify_ok, current_succ, 5000) catch |err| {
            std.debug.print("[chord] stabilize: notify 失败 {}\n", .{err});
            return;
        };
        std.debug.print("[chord] stabilize: notify 成功发送到 {s}\n", .{ring.idToHex(current_succ.id)});

        // 查询 successor 的 successor，填充备份列表
        if (current_succ.id != self.own_id) {
            const next_id = current_succ.id +% 1;
            const next_resp = self.sendAndWait(Message{ .find_successor = .{ .target = next_id } }, .find_successor_resp, current_succ, 3000) catch |err| {
                std.debug.print("[chord] stabilize: 查询后继的后继失败 {}\n", .{err});
                return;
            };
            switch (next_resp) {
                .find_successor_resp => |body| {
                    const backup = NodeAddr{ .id = body.node_id, .host = body.node_addr, .port = body.node_port, .tcp_port = body.node_tcp_port };
                    if (backup.id != self.own_id and backup.id != current_succ.id) {
                        self.routing.addBackupSuccessor(backup);
                        std.debug.print("[chord] stabilize: 添加备份后继 {s}:{d}\n", .{ ring.idToHex(backup.id), backup.port });
                    }
                },
                else => {},
            }
        }
    }

    /// 修复 finger 表下一项
    fn doFixFingers(self: *ChordNode) !void {
        const node = self.routing.findSuccessor(self.routing.fingers[self.routing.next_finger].start);
        self.routing.fingers[self.routing.next_finger].node = node;
        std.debug.print("[chord] fix finger[{d}] → {s}\n", .{
            self.routing.next_finger,
            ring.idToHex(node.id),
        });
        self.routing.next_finger = (self.routing.next_finger + 1) % ring.M;
    }

    /// 检查前驱是否存活
    fn doCheckPredecessor(self: *ChordNode) !void {
        if (self.routing.predecessor) |pred| {
            const resp = self.sendAndWait(Message{ .ping = {} }, .pong, pred, 5000) catch {
                std.debug.print("[chord] 前驱 {s} 无响应, 清除\n", .{ring.idToHex(pred.id)});
                self.routing.predecessor = null;
                return;
            };
            _ = resp;
        }
    }

    /// 处理副本同步队列：向所有可达后继节点复制条目
    fn processReplication(self: *ChordNode) !void {
        // 每次 tick 最多处理一个条目的一步复制，避免阻塞
        const item = self.replication_mgr.next() orelse return;

        // 获取所有可达后继（主 + 备份，最多 3 个）
        const targets = self.routing.allReachableSuccessors();

        // 尝试向每个目标复制
        for (targets) |maybe_target| {
            if (self.replication_mgr.isCurrentDone()) break;
            const target = maybe_target orelse continue;
            if (target.id == self.own_id) continue;

            const replicate_msg = Message{ .dht_replicate = .{
                .key = item.key,
                .value = item.value,
                .owner = item.owner,
                .permission = item.permission,
                .version = item.version,
                .timestamp = item.timestamp,
            } };

            const result = self.sendAndWait(replicate_msg, .dht_replicate_resp, target, 3000);
            if (result) |resp| {
                _ = resp;
                std.debug.print("[store] 副本已复制到 {s}:{d}\n", .{ ring.idToHex(target.id), target.port });
                self.replication_mgr.markAttempted();
            } else |_| {
                std.debug.print("[store] 副本复制到 {s}:{d} 失败\n", .{ ring.idToHex(target.id), target.port });
            }
        }

        // 完成或跳过（无可用目标时也弹出）
        if (self.replication_mgr.isCurrentDone() or targets[0] == null) {
            self.replication_mgr.popFront();
        }
    }

    /// 打印路由状态
    pub fn printState(self: *ChordNode) void {
        std.debug.print("--- Chord 路由状态 ---\n", .{});
        std.debug.print("本机 ID:  {s}\n", .{ring.idToHex(self.own_id)});
        if (self.routing.predecessor) |p| {
            std.debug.print("前驱:     {s}:{d} (id={s})\n", .{ p.host, p.port, ring.idToHex(p.id) });
        } else {
            std.debug.print("前驱:     (无)\n", .{});
        }
        if (self.routing.successor) |s| {
            std.debug.print("后继:     {s}:{d} (id={s})\n", .{ s.host, s.port, ring.idToHex(s.id) });
        } else {
            std.debug.print("后继:     (无)\n", .{});
        }
        // 打印备份后继列表
        var backup_count: u8 = 0;
        for (&self.routing.backup_successors) |*slot| {
            if (slot.*) |b| {
                backup_count += 1;
                std.debug.print("  后继备{d}: {s}:{d} (id={s})\n", .{ backup_count, b.host, b.port, ring.idToHex(b.id) });
            }
        }
        std.debug.print("Finger 表: {d} 条目\n", .{ring.M});
        var count: usize = 0;
        for (self.routing.fingers, 0..) |f, i| {
            if (f.node) |n| {
                std.debug.print("  [{d:>3}] start={s}... → {s}\n", .{
                    i, ring.idToHex(f.start)[0..8], ring.idToHex(n.id)[0..8],
                });
                count += 1;
            }
        }
        if (count > 0) std.debug.print("  已填充 {d} 项\n", .{count});
        std.debug.print("DHT 存储: {d} 条目, {d} 待复制\n", .{ self.store.count(), self.replication_mgr.pendingCount() });
        std.debug.print("------------------------\n", .{});
    }

    pub fn deinit(self: *ChordNode) void {
        // 关闭 TCP 监听
        self.stopTcpListener();
        // 保存 DHT 存储
        self.store.save() catch |err| {
            std.debug.print("[store] 持久化失败: {}\n", .{err});
        };
        self.store.deinit();
        self.replication_mgr.deinit();
        if (self.own_pk_hex.len > 0) self.alloc.free(self.own_pk_hex);
        self.msg_arena.deinit();
        self.socket.close();
    }
};
