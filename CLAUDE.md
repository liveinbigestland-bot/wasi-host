# wasi-host — Chord DHT 项目

## 机器拓扑

| 节点 | IP/主机 | 用户 | 架构 | 角色 |
|------|---------|------|------|------|
| **seed** | 192.168.2.210:20808 | (local Windows) | x86_64 | LAN 种子节点 |
| **node59** | 192.168.2.59:20808 | root / ecoo1234 | armv7l | LAN 加入节点 |
| **node60** | 192.168.2.60:20808 | root / ecoo1234 | armv7l | LAN 加入节点 |
| **ext** | ssh-metaai.alwaysdata.net:20808 | metaai / 1qaz@WSXasdfasdf | x86_64 | 外网加入节点 (UDP inbound blocked, TCP direct port 8400) |
| **外2** | 192.140.185.171:20808 | root / aetej1AzIQpE | x86_64 Ubuntu 24.04 | 独立 VPS (UFW 已开放 20808/udp) |

## 构建命令

```bash
# Windows (native)
zig build

# ARM (armv7l 节点)
zig build -Dtarget=arm-linux-musleabihf -p /d/tmp/zig-out-arm && cp /d/tmp/zig-out-arm/bin/wasi-host zig-out/bin/wasi-host-arm-v5

# x86_64 Linux (外网服务器 + relay-server)
zig build -Dtarget=x86_64-linux-gnu -p /d/tmp/zig-out-x64 && cp /d/tmp/zig-out-x64/bin/wasi-host zig-out/bin/wasi-host-x86_64 && cp /d/tmp/zig-out-x64/bin/relay-server zig-out/bin/relay-server-x86_64
```

## 配置映射

| 机器 | 本地配置 | 远程路径 |
|------|---------|---------|
| seed | config-lan-seed.json | (本地运行) |
| node59 | config-lan-node59.json | /root/config-lan-node59.json |
| node60 | config-lan-node60.json | /root/config-lan-node60.json |
| ext | config-ext-daemon.json | /home/metaai/config-ext-daemon.json |
| 外2 | config-ext-node2.json | /root/config-ext-node2.json |

## 远程路径

- Binary: /root/wasi-host (ARM/外2), /root/wasi-hostd (外2 daemon)
- Ext binary: /home/metaai/wasi-host, /home/metaai/wasi-hostd (daemon)
- Log: /root/test-remote-node{59,60}.log / /root/test-ext-node2.log
- Ext log: /home/metaai/wasi-hostd.log
- 上传中转: /tmp/wasi-host-deploy (SFTP 直接写 /root/ 会失败)

## 部署脚本

主要通过 `deploy.py` 管理:

```bash
python deploy.py deploy       # 完整部署流程（清理→上传→启动→验证）
python deploy.py test         # 验证路由状态 + 环一致性
python deploy.py status       # 查看各节点进程状态
python deploy.py cleanup      # 停止所有节点
python deploy.py logs         # 查看各节点最新日志
python deploy.py check-stale  # 检查残留旧进程
python deploy.py inspect      # 完整巡检（进程/资源/路由/异常）
```

## 运维子智能体

Ops agent (`gsd-ops`) 位于 `$CLAUDE_HOME/agents/gsd-ops.md`，提供以下工作流:

- **deploy-ring**: build → cleanup → start-seed → deploy → restart-remote → verify
- **test-ring**: 验证所有节点的后继/前驱/finger 表
- **status-ring**: 检查各节点进程存活和最近日志
- **cleanup-ring**: 停止所有节点（远程 + 本地）

## 关键坑点

1. **文件锁**: Windows 上编译前要先 kill wasi-host.exe，否则 zig build 报 AccessDenied
2. **启动顺序**: 必须先启 seed → 再启 ARM 节点（否则 bootstrap 失败）
3. **SFTP 中转**: ARM 机器上 SFTP 直接写 /root/ 可能失败，必须经 /tmp/
4. **后继自指**: 孤立 seed 的 successor=null，需要 stabilize 中特判逻辑修复
5. **UDP**: 外网服务器 alwaysdata 屏蔽 inbound UDP，ext 使用 direct TCP (port 8400) 通信

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:5c2c0639 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->

## graphify

This project has a graphify-rs knowledge graph at graphify-out/.

Rules:
- Before answering architecture or codebase questions, read graphify-out/GRAPH_REPORT.md for god nodes and community structure
- If graphify-out/wiki/index.md exists, navigate it instead of reading raw files
- After modifying code files in this session, run `graphify-rs build --path . --output graphify-out --no-llm --update` to keep the graph current (fast, AST-only, ~2-5s)
