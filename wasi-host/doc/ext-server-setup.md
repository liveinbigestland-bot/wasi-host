# ext 服务器 (alwaysdata) 说明

## 机器信息

| 项目 | 值 |
|------|-----|
| 主机 | ssh-metaai.alwaysdata.net:22 |
| 用户 | metaai |
| 架构 | x86_64 Debian 12（共享主机） |
| 公网 IP | 185.31.41.85 |
| 工作目录 | /home/metaai/ |
| 二进制 | /home/metaai/wasi-host |
| 配置 | /home/metaai/config-ext-server.json（本地同名文件由 deploy.py 上传） |
| 日志 | /home/metaai/test-ext-server.log |

## 网络出入站限制

### 入站（inbound）

| 协议 | 状态 | 说明 |
|------|------|------|
| UDP | ❌ 完全屏蔽 | alwaysdata 共享主机不允许任何 inbound UDP |
| TCP | ⚠️ 仅面板映射端口 | 只能在 alwaysdata 控制面板配置固定端口映射，当前为 **443 → 内部 8400** |

因此 ext 节点配置为 `transport_mode: "tcp"`，内部监听 8400，对外通告
`external_tcp_port: 443`（其他节点连接 ext 时走 443）。

### 出站（outbound）

| 方向 | 可达性 |
|------|--------|
| ext → 公网 IP（外2 等） | ✅ UDP/TCP 均可（但当前外2 安全组未放行，见下文） |
| ext → LAN 私有 IP（192.168.x.x） | ❌ 不可达，包直接被丢弃 |

## 当前通信架构

`config-ext-server.json` 关键配置：

```json
{
    "p2p": {
        "listen_host": "0.0.0.0",
        "listen_port": 20808,
        "transport_mode": "tcp",
        "tcp_port": 8400,
        "bootstrap": [{"host": "170.106.170.85", "port": 20808, "tcp_port": 8444}],
        "encrypted_relay": {
            "enabled": true,
            "relays": [{"host": "170.106.170.85", "port": 20809}],
            "use_tcp": true
        }
    }
}
```

连接策略（按优先级回退）：

1. **TCP 直连** 外2:8444（因 UDP 入站被屏蔽，UDP 出站也不可靠）
2. **加密中继** 外2:20809（relay-server），直连失败时使用

## 方向性连通矩阵

| 方向 | 路径 | 状态 |
|------|------|------|
| LAN → ext | TCP 直连 185.31.41.85:443（映射到 8400） | ✅ |
| ext → LAN | 无路径（私有 IP 不可达） | ❌ |
| ext → 外2 | TCP 8444 直连 / relay 20809 | ⚠️ 待外2 安全组放行 |
| 外2 → ext | TCP 185.31.41.85:443 | ✅ |

## 对 Chord 环的影响

Chord ID 排序（当前密钥）：

```
node59(f11ee1) < 外2(c8101b) < node60(b3f6ac) < seed(7b6bb7) < ext(f4da45)
```

> 注意：node 密钥文件变更后 Chord ID 会变，排序需重新确认。

风险点：若 ext 的后继指针落在 LAN 节点上，ext → LAN 方向不通会导致
stabilize 持续失败。规避方式是让 LAN 环与外网环分离运行（当前部署即如此：
LAN 三环独立，ext/外2 组成外网环），或确保 ext 的后继始终是公网可达节点。

## 历史方案（已废弃）

早期曾使用 alwaysdata 上的 `index.js`（WebSocket 服务器，端口 8356）做
WS↔UDP 中继，将外部 WS 消息转发到本机 `127.0.0.1:20808`。该方案已废弃：

- 只是固定本地中继，不支持按目标地址路由
- 无法解决 ext→LAN 单向性问题
- 现已被「TCP 直连 + encrypted_relay」取代

## 运维备忘

- 重启节点：上传新配置后 `pkill -f wasi-host; nohup ./wasi-host config-ext-server.json > test-ext-server.log 2>&1 &`
- 端口映射变更需在 alwaysdata 面板操作，无 API
- 若需更换对外 TCP 端口，须同步修改：alwaysdata 面板映射、`tcp_port`、
  `external_tcp_port`、以及各对端 bootstrap 配置中的 `tcp_port`
