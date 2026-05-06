/// Node registry — 纯内存会话表管理
/// Key = NodeID (20 字节 SHA-1), Value = 会话结构体
const std = @import("std");

pub const NodeID = [20]u8;

pub const Protocol = enum(u8) {
    udp = 0,
    tcp = 1,
};

pub const SessionState = enum(u8) {
    pending_challenge = 0,
    active = 1,
};

pub const Session = struct {
    node_id: NodeID,
    protocol: Protocol,
    state: SessionState,

    addr: std.net.Address,

    /// UDP: 节点发送数据包的源地址（可能变化）
    udp_addr: ?std.net.Address = null,
    /// TCP: 连接 fd
    tcp_fd: ?std.posix.socket_t = null,

    last_heartbeat_ms: i64,
    registered_at_ms: i64,

    /// ED25519 公钥（注册时提交）
    public_key: [32]u8 = undefined,

    /// 挑战 nonce（pending_challenge 状态时有效）
    challenge: ?[32]u8 = null,

    /// 速率限制：每秒发包计数
    packet_count_this_second: u32 = 0,
    rate_limit_reset_ms: i64 = 0,
};

pub const RegistryOptions = struct {
    max_sessions: u32 = 1000,
    heartbeat_timeout_ms: u64 = 60_000,
    max_packets_per_second: u32 = 1000,
};

pub const Registry = struct {
    alloc: std.mem.Allocator,
    sessions: std.AutoHashMap(NodeID, *Session),
    mutex: std.Thread.Mutex = .{},

    max_sessions: u32,
    heartbeat_timeout_ms: u64,
    max_packets_per_second: u32,

    pub fn init(alloc: std.mem.Allocator, opts: RegistryOptions) Registry {
        return Registry{
            .alloc = alloc,
            .sessions = std.AutoHashMap(NodeID, *Session).init(alloc),
            .max_sessions = opts.max_sessions,
            .heartbeat_timeout_ms = opts.heartbeat_timeout_ms,
            .max_packets_per_second = opts.max_packets_per_second,
        };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            self.closeSessionFd(entry.value_ptr.*);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit();
    }

    fn closeSessionFd(_: *Registry, session: *Session) void {
        if (session.tcp_fd) |fd| {
            _ = std.posix.close(fd);
        }
    }

    /// 创建或替换会话（进入 pending_challenge 状态）
    /// 注意：fd 同时作为旧会话踢除依据和本会话标识，必须在 mutex 内原子化设置
    pub fn register(self: *Registry, node_id: NodeID, protocol: Protocol, addr: std.net.Address, public_key: [32]u8, fd: ?std.posix.socket_t) !*Session {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.count() >= self.max_sessions) {
            return error.SessionLimitReached;
        }

        const now = std.time.milliTimestamp();

        if (self.sessions.get(node_id)) |existing| {
            // 关闭旧会话 fd（这样旧线程的 read() 会返回错误/断开）
            self.closeSessionFd(existing);
            // 重置会话为新状态，同时设置 tcp_fd — 防止旧线程的 unregisterIfFdMatches 误删新会话
            existing.* = .{
                .node_id = node_id,
                .protocol = protocol,
                .state = .pending_challenge,
                .addr = addr,
                .udp_addr = if (protocol == .udp) addr else null,
                .tcp_fd = fd,
                .public_key = public_key,
                .last_heartbeat_ms = now,
                .registered_at_ms = now,
                .challenge = null,
            };
            return existing;
        }

        const session = try self.alloc.create(Session);
        session.* = .{
            .node_id = node_id,
            .protocol = protocol,
            .state = .pending_challenge,
            .addr = addr,
            .udp_addr = if (protocol == .udp) addr else null,
            .tcp_fd = fd,
            .public_key = public_key,
            .last_heartbeat_ms = now,
            .registered_at_ms = now,
        };
        try self.sessions.put(node_id, session);
        return session;
    }

    /// 激活会话（鉴权通过后调用）
    pub fn activate(self: *Registry, node_id: NodeID) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const session = self.sessions.get(node_id) orelse return error.SessionNotFound;
        session.state = .active;
        session.challenge = null;
    }

    /// 更新心跳时间
    pub fn heartbeat(self: *Registry, node_id: NodeID) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const session = self.sessions.get(node_id) orelse return error.SessionNotFound;
        session.last_heartbeat_ms = std.time.milliTimestamp();
    }

    /// 删除会话（优雅下线/连接断开）
    pub fn unregister(self: *Registry, node_id: NodeID) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.sessions.get(node_id)) |session| {
            self.closeSessionFd(session);
            _ = self.sessions.remove(node_id);
            self.alloc.destroy(session);
        }
    }

    /// 仅当会话的 TCP fd 匹配时才删除（避免竞争：旧线程误删新注册的会话）
    pub fn unregisterIfFdMatches(self: *Registry, node_id: NodeID, expected_fd: std.posix.socket_t) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.sessions.get(node_id)) |session| {
            if (session.tcp_fd) |fd| {
                if (fd != expected_fd) return;
            }
            self.closeSessionFd(session);
            _ = self.sessions.remove(node_id);
            self.alloc.destroy(session);
        }
    }

    /// 获取会话（线程安全）
    pub fn get(self: *Registry, node_id: NodeID) ?*Session {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.get(node_id);
    }

    /// 按 UDP 地址查找会话
    /// 使用原始字节比较（避开 extern union 的 padding/struct layout 差异）
    pub fn getByUdpAddr(self: *Registry, addr: std.net.Address) ?*Session {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const s = entry.value_ptr.*;
            if (s.udp_addr) |ua| {
                if (ua.getPort() != addr.getPort()) continue;
                // extern union 首字节一致，读取 family (u16 LE)
                const ua_family = @as(*const u16, @ptrCast(&ua)).*;
                const addr_family = @as(*const u16, @ptrCast(&addr)).*;
                if (ua_family != addr_family) continue;
                // 比较 port (2B) + addr (4B) = 6B from offset 2
                const ua_key = @as(*const [8]u8, @ptrCast(&ua))[2..8];
                const addr_key = @as(*const [8]u8, @ptrCast(&addr))[2..8];
                if (std.mem.eql(u8, ua_key, addr_key)) return s;
            }
        }
        return null;
    }

    /// 按 TCP fd 查找会话
    pub fn getByTcpFd(self: *Registry, fd: std.posix.socket_t) ?*Session {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const s = entry.value_ptr.*;
            if (s.tcp_fd) |f| {
                if (f == fd) return s;
            }
        }
        return null;
    }

    /// 回收过期会话（60s 无心跳）
    pub fn reapExpired(self: *Registry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = std.time.milliTimestamp();
        var to_remove = std.ArrayList(NodeID).init(self.alloc);
        defer to_remove.deinit();

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr.*;
            const elapsed = now - session.last_heartbeat_ms;
            if (elapsed > @as(i64, @intCast(self.heartbeat_timeout_ms))) {
                to_remove.append(entry.key_ptr.*) catch {};
            }
        }

        for (to_remove.items) |node_id| {
            if (self.sessions.get(node_id)) |session| {
                self.closeSessionFd(session);
                _ = self.sessions.remove(node_id);
                self.alloc.destroy(session);
            }
        }
    }

    /// 检查并消耗速率限制配额。返回 true = 允许, false = 超限丢弃
    pub fn checkRateLimit(self: *Registry, node_id: NodeID) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const session = self.sessions.get(node_id) orelse return false;
        const now = std.time.milliTimestamp();
        if (now - session.rate_limit_reset_ms > 1000) {
            session.packet_count_this_second = 0;
            session.rate_limit_reset_ms = now;
        }
        if (session.packet_count_this_second >= self.max_packets_per_second) {
            return false;
        }
        session.packet_count_this_second += 1;
        return true;
    }

    /// 当前会话数
    pub fn count(self: *Registry) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return @as(u32, @intCast(self.sessions.count()));
    }
};
