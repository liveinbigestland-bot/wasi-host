/// P2P 网络配置加载

const std = @import("std");

/// 传输模式
pub const TransportMode = enum(u8) {
    udp = 0,   // UDP only
    tcp = 1,   // TCP only
    dual = 2,  // UDP + TCP
};

/// P2P 节点全局配置
pub const P2PConfig = struct {
    /// 是否启用 P2P 网络
    enabled: bool = false,
    /// 节点监听地址（对外通告的地址）
    listen_host: []const u8 = "127.0.0.1",
    /// 节点监听端口（DHT + 数据传输）
    listen_port: u16 = 20808,
    /// 传输模式
    transport_mode: TransportMode = .udp,
    /// TCP 监听端口（0 = 与 listen_port 相同，仅 transport_mode != udp 时有效）
    tcp_port: u16 = 0,
    /// 外部映射端口（0 = 与 tcp_port 相同）
    /// 用于 NAT/端口映射场景：内部监听 tcp_port，外部通过 external_tcp_port 入站
    /// 例：ext 内部监听 8400，AlwaysData 外部映射 443→8400，设 external_tcp_port=443
    external_tcp_port: u16 = 0,
    /// Bootstrap 节点地址列表
    bootstrap: []const BootstrapAddr = &.{},
    /// 节点密钥文件路径（PEM 格式保存 ED25519 种子）
    key_file: []const u8 = "p2p_key.bin",
    /// 数据存储目录
    data_dir: []const u8 = "p2p_data",
    /// 代理服务配置
    proxy: ProxyConfig = .{},
    /// DHT 稳定化间隔（毫秒）
    stabilize_interval_ms: u64 = 30_000,
    /// DNS 种子地址（可选，用于自动发现种子节点）
    dns_seeds: []const []const u8 = &.{},
    /// SOCKS5 代理端口（0 = 禁用）。
    /// 在此端口启动 SOCKS5 代理，通过独立 relay TCP 隧道转发流量到 relay server。
    socks_proxy_port: u16 = 0,
    /// SOCKS5 代理 relay 服务器地址（用于创建独立 relay 连接）
    socks_relay_host: []const u8 = "",
    /// SOCKS5 代理 relay 服务器端口
    socks_relay_port: u16 = 0,
    /// 如果为 true，在检测公网 IP 时优先使用 IPv4 地址
    /// 用于 relay 协议不支持 IPv6 的环境（如 ext 节点 on alwaysdata）
    prefer_ipv4: bool = true,
    /// 节点存活时间（秒），之后自动退出
    run_duration_s: u64 = 15,
};

/// Bootstrap 节点地址
pub const BootstrapAddr = struct {
    host: []const u8,
    port: u16,
    /// TCP 端口（0 = 未知，首次 join 会从 find_successor_resp 学习）
    tcp_port: u16 = 0,
};

/// 代理服务配置
pub const ProxyConfig = struct {
    enabled: bool = false,
    /// "server" | "client" | "off"
    mode: []const u8 = "off",
    /// "tcp" | "websocket"
    transport: []const u8 = "tcp",
    /// server: TCP listener port for relay (0 = disabled)
    listen_port: u16 = 0,
    /// client: relay server host
    remote_host: []const u8 = "",
    /// client: relay server port
    remote_port: u16 = 0,
    /// client: traffic to this host goes through proxy
    route_host: []const u8 = "",
    /// client: traffic to this port goes through proxy
    route_port: u16 = 0,
    /// client: WebSocket path (e.g. "/chord")
    remote_path: []const u8 = "/chord",
    max_connections: u32 = 10,
    max_per_user: u32 = 2,
    bandwidth_limit_kb: u32 = 512,
    per_user_bandwidth_kb: u32 = 128,
    connection_timeout_sec: u64 = 180,
    heartbeat_sec: u64 = 30,

    /// WSS server config
    wss_enabled: bool = false,
    wss_port: u16 = 443,
    wss_path: []const u8 = "/chord",
    wss_cert_file: []const u8 = "",
    wss_key_file: []const u8 = "",
    /// WSS bridges to TCP relay server instead of Chord UDP
    wss_tcp_bridge: bool = false,
    /// Use WebSocket framing for relay transport
    relay_ws: bool = false,
    /// Relay TCP server bind address (e.g. "127.0.0.1" for local-only)
    relay_listen_host: []const u8 = "0.0.0.0",
    /// UDP echo debug server port (0 = disabled)
    udp_echo_port: u16 = 0,
};

pub const default_bootstrap = [_]BootstrapAddr{
    .{ .host = "127.0.0.1", .port = 20808 },
};

/// 从 JSON 字符串解析 P2P 配置
pub fn parseP2PConfig(alloc: std.mem.Allocator, json_text: []const u8) !P2PConfig {
    const parsed = try std.json.parseFromSlice(P2PConfig, alloc, json_text, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return parsed.value;
}
