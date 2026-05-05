# ext 服务器 (alwaysdata) 现状

## 机器信息

| 项目        | 值                            |
| --------- | ---------------------------- |
| 主机        | ssh-metaai.alwaysdata.net:22 |
| 用户        | metaai                       |
| 架构        | x86_64 Debian 12             |
| Public IP | 185.31.41.85                 |
| 工作目录      | /home/metaai/                |

## 服务进程

### index.js (WebSocket 服务器)

- **端口**: 8356 (通过环境变量 `PORT` 配置，默认 8356)
- **启动方式**: `node index.js` (由用户手动或 supervisor 启动)
- **作用**: 提供 WebSocket ↔ UDP 中继，接收外部 WS 连接，转发到本机 wasi-host

**`/chord` 路径的核心逻辑** (index.js 408-420 行):

```javascript
if (url === '/chord') {
    const udp = dgram.createSocket('udp4');
    ws.on('message', (data) => {
        if (data.length > 6) {
            const payload = data.slice(6);           // 剥掉 6 字节路由头
            udp.send(payload, 20808, '127.0.0.1');   // 始终发到本地 127.0.0.1:20808
        }
    });
    udp.on('message', (msg) => {
        if (ws.readyState === ws.OPEN) ws.send(msg); // UDP 响应原路 WS 返回
    });
}
```

**关键行为**:

1. WS 帧格式: `[target_ip(4)B][target_port(2)B][payload]` — 但 index.js **忽略** target_ip/target_port
2. 始终将 payload 转发到 `127.0.0.1:20808` (本机 wasi-host)
3. UDP 响应通过同一 WS 连接返回给客户端
4. 每次 WS 消息创建一个新的 UDP socket (ephemeral port)

**结论**: 这是一个简单的本地中继，不是通用代理。不支持按目标地址路由到其他机器。

### wasi-host

- **配置**: `config-ext-server.json`
- **监听**: `127.0.0.1:20808` (仅 loopback)
- **状态**: 需要手动启动，当前未运行
- **Chord ID**: `f4da4565ca08d8cf4b6960b8a7ed9fb377818138`
- **代理**: `proxy.enabled = false` — 不需要代理，通过 index.js 接收外部消息

**通信路径**:

| 方向           | 路径                                                   |
| ------------ | ---------------------------------------------------- |
| 外部→ext       | WS → index.js:8356 → UDP 127.0.0.1:20808 → wasi-host |
| ext→外部(回复)   | wasi-host → UDP → index.js ephemeral port → WS → 外部  |
| ext→外部(主动发起) | wasi-host → 直接 UDP → 目标 (仅公网 IP 可达，内网私有 IP 不可达)      |

## 已知问题

### 1. 端口不匹配

本地配置文件中的 `remote_port` 写的是 `80`，但 index.js 实际运行在 **8356**。

需要修改的文件:

- `config-remote-node59.json`: `remote_port` 80 → 8356
- `config-remote-node60.json`: `remote_port` 80 → 8356
- `config-remote-seed.json`: `remote_port` 80 → 8356

### 2. WAN→LAN 单向通信限制

由于 index.js 只转发到 `127.0.0.1:20808`，而 ext 所在 alwaysdata 无法通过 UDP 到达内网私有 IP (192.168.x.x)，导致:

- **LAN→ext**: 可通过 WS 代理 ✅
- **ext→LAN**: 直接 UDP 到私有 IP 被阻塞 ❌
- **外2→LAN**: 同理 ❌
- **LAN→外2**: 直接 UDP (LAN 可访问公网) ✅
- **ext↔外2**: 直接 UDP (双方公网 IP) ✅

### 3. Ring 顺序限制

Chord ID 排序:

```
node59(67adbb) < 外2(720b1f) < seed(a39831) < node60(e4aba7) < ext(f4da45)
```

Chord 环: node59 → 外2 → seed → node60 → ext → node59

ext 的后继是 node59 (LAN 节点) — ext 无法稳定到 LAN 后继 ❌

### 4. 修复方案选项

- **A**: 修改 index.js，按 WS 帧中的 target_ip/target_port 转发 UDP — 但仍无法解决 WAN→LAN
- **B**: 在 LAN 路由器上配置端口转发，使 ext 能通过公网 IP→端口转发→LAN 节点
- **C**: 修改 index.js 支持 WS 连接间路由 (track 持久 WS 连接 + 按目标地址路由) — 最完整但改动大
