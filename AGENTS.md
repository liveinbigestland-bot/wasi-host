# Agent Instructions

## 项目概览

**wasi-host** — Zig 跨平台 WASM 插件运行时，基于 wasm3 解释器。

核心能力：
- WASM 插件沙箱执行（内存/超时/网络/文件系统权限控制）
- 动态插件加载：控制通道（本地 TCP）+ DHT 内容寻址分发
- Chord DHT：节点发现、键值存储、内容寻址（SHA256）
- P2P 通信：UDP + TCP 双传输，自动网络检测
- 守护进程 wasi-hostd：节点监控、自恢复、远程升级
- 中继服务器 relay-server：加密中继（NAT 穿透）

详细机器拓扑、部署脚本、构建命令见 [CLAUDE.md](CLAUDE.md)。

## 分支策略

| 分支 | 用途 |
|------|------|
| `master` | 主分支。Lua 已移除，编排由动态插件机制承担 |
| `lua-preserved` | Lua 集成版本保留（36b02fcf），不再演进 |

## 构建与测试

```powershell
# 主构建（含 WASM 插件、守护进程、中继服务器）
zig build

# 单元测试（全部通过为成功标准）
zig build test

# 交叉编译（见 CLAUDE.md）
zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7
zig build -Dtarget=x86_64-linux-gnu
```

**注意**：Windows 上编译前须先终止 `wasi-host.exe`，否则 zig build 报 AccessDenied。

## 代码结构

```
wasi-host/
├── main.zig              # 入口：插件装载、控制通道、事件循环
├── build.zig             # 构建配置（无 Lua 依赖）
├── src/
│   ├── plugin/           # 动态插件运行时
│   │   ├── manager.zig   # 注册表、看门狗、取消/暂停/超时
│   │   └── content.zig   # 内容寻址（SHA256 ↔ DHT 键 ↔ Base64）
│   ├── p2p/chord/        # Chord DHT 节点
│   ├── p2p/metadata/     # 键值存储、权限、复制
│   ├── host/             # WASM 宿主函数（DHT、文件、网络）
│   ├── daemon/           # 守护进程（controller/supervisor/reporter）
│   ├── relay/            # 加密中继服务器
│   └── logging/          # 日志模块
├── plugins/              # WASM 插件源码（wasm32-wasi）
├── wasm3/                # wasm3 解释器（含 m3_Yield/m3_ControlCheck 钩子）
└── tests/                # 单元测试
```

## 关键设计约束

1. **WASM 执行隔离**：插件在独立线程运行，看门狗线程统一处理超时
2. **控制通道鉴权**：所有控制请求必须携带 `control_token`
3. **内容寻址不可变**：插件字节码 SHA256 即身份，DHT 值不可篡改
4. **插件卸载安全**：仅允许卸载非活动实例（completed/failed/timeout/cancelled）
5. **热更新序列**：取消旧实例 → 等待退出 → 拉取新字节码（缓存优先）→ 重载

## 会话收尾协议

代码变更后必须完成：

```powershell
zig build          # 编译通过
zig build test     # 测试通过（当前 98/98，0 泄漏）
git pull --rebase
git push
git status         # 确认 "up to date with origin"
```

## 临时文件规范

- 根目录禁止遗留一次性脚本（test_*.py、deploy_*.py、fix_*.ps1 等）
- 运行时数据目录（p2p_data/、wasm-cache/）不提交，但清理前须确认无节点运行
- zig-cache/、zig-out/ 已加入 .gitignore

## 已知问题

- `web config overrides` 测试在 Windows 上偶发失败（端口占用），Linux 正常
