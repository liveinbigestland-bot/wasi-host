#!/usr/bin/env python3
"""Chord DHT 统一部署管理脚本

整合了 deploy-remote.py / deploy_tcp.py / deploy-relay-fix.py 的所有功能。

用法:
  python deploy.py deploy              # 完整部署流程
  python deploy.py test                # 验证路由状态 + 环一致性
  python deploy.py status              # 查看各节点进程状态
  python deploy.py cleanup             # 停止所有节点
  python deploy.py logs                # 查看各节点最新日志
  python deploy.py check-stale         # 检查残留旧进程
  python deploy.py inspect             # 完整巡检（同 ring_inspect.py）

选项:
  --quick      跳过资源使用检查（仅影响 inspect 模式）
  --json       JSON 格式输出（仅影响 inspect 模式）
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import paramiko

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))

BINARIES = {
    "arm": os.path.join(PROJECT_DIR, "zig-out", "bin", "wasi-host-arm-v5"),
    "x86_64": os.path.join(PROJECT_DIR, "zig-out", "bin", "wasi-host-x86_64"),
}

MACHINES = [
    {
        "name": "外2",
        "host": "192.140.185.171",
        "port": 22,
        "user": "root",
        "password": "aetej1AzIQpE",
        "arch": "x86_64",
        "remote_bin": "/root/wasi-host",
        "config": os.path.join(PROJECT_DIR, "config-ext-node2.json"),
        "remote_config": "/root/config-ext-node2.json",
        "remote_log": "/root/test-ext-node2.log",
    },
    {
        "name": "ext",
        "host": "ssh-metaai.alwaysdata.net",
        "port": 22,
        "user": "metaai",
        "password": "1qaz@WSXasdfasdf",
        "arch": "x86_64",
        "remote_bin": "/home/metaai/wasi-host",
        "config": os.path.join(PROJECT_DIR, "config-ext-server.json"),
        "remote_config": "/home/metaai/config-ext-server.json",
        "remote_log": "/home/metaai/test-ext-server.log",
    },
    {
        "name": "node59",
        "host": "192.168.2.59",
        "port": 22,
        "user": "root",
        "password": "ecoo1234",
        "arch": "arm",
        "remote_bin": "/root/wasi-host",
        "config": os.path.join(PROJECT_DIR, "config-remote-node59.json"),
        "remote_config": "/root/config-remote-node59.json",
        "remote_log": "/root/test-remote-node59.log",
    },
    {
        "name": "node60",
        "host": "192.168.2.60",
        "port": 22,
        "user": "root",
        "password": "ecoo1234",
        "arch": "arm",
        "remote_bin": "/root/wasi-host",
        "config": os.path.join(PROJECT_DIR, "config-remote-node60.json"),
        "remote_config": "/root/config-remote-node60.json",
        "remote_log": "/root/test-remote-node60.log",
    },
]


# ── 机器名 -> 索引映射（用于排序） ──────────────────────────────────
NAME_ORDER = {m["name"]: i for i, m in enumerate(MACHINES)}


# ── SSH 包装器 ───────────────────────────────────────────────────────
class RemoteNode:
    """单个远程节点的 SSH 操作封装"""

    def __init__(self, machine):
        self.m = machine
        self.client = None

    def connect(self, timeout=10):
        self.client = paramiko.SSHClient()
        self.client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self.client.connect(
            self.m["host"],
            port=self.m["port"],
            username=self.m["user"],
            password=self.m["password"],
            timeout=timeout,
        )

    def close(self):
        if self.client:
            try:
                self.client.close()
            except Exception:
                pass

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, *args):
        self.close()

    def exec(self, cmd, timeout=10):
        _, stdout, stderr = self.client.exec_command(cmd, timeout=timeout)
        exit_code = stdout.channel.recv_exit_status()
        out = stdout.read().decode("utf-8", errors="replace").strip()
        err = stderr.read().decode("utf-8", errors="replace").strip()
        return exit_code, out, err

    def pgrep(self, pattern="wasi-host"):
        _, out, _ = self.exec(f"pgrep -f {pattern} || echo NOT_RUNNING", timeout=5)
        if "NOT_RUNNING" in out:
            return None
        return [p.strip() for p in out.split("\n") if p.strip()]

    # ── 操作 ──────────────────────────────────────────────

    def kill_all(self):
        """停止所有相关进程"""
        self.exec("pkill -f wasi-host 2>/dev/null || true", timeout=5)
        self.exec("pkill -f 'index.js' 2>/dev/null || true", timeout=5)
        self.exec("pkill -f 'ws-bridge' 2>/dev/null || true", timeout=5)
        self.exec("fuser -k 8356/tcp 2>/dev/null || true", timeout=5)
        time.sleep(1)

    def upload_binary(self):
        """上传并安装 binary（经 /tmp 中转避免 SFTP 直接写 /root/ 失败）"""
        remote_tmp = "/tmp/wasi-host-deploy"
        sftp = self.client.open_sftp()
        sftp.put(BINARIES[self.m["arch"]], remote_tmp)
        sftp.close()
        self.exec(
            f"rm -f {self.m['remote_bin']} && cp {remote_tmp} {self.m['remote_bin']}"
            f" && chmod +x {self.m['remote_bin']} && rm -f {remote_tmp}",
            timeout=10,
        )

    def upload_config(self):
        """上传配置文件"""
        remote_tmp = "/tmp/config-deploy.json"
        sftp = self.client.open_sftp()
        sftp.put(self.m["config"], remote_tmp)
        sftp.close()
        self.exec(
            f"rm -f {self.m['remote_config']} && cp {remote_tmp} {self.m['remote_config']}"
            f" && rm -f {remote_tmp}",
            timeout=10,
        )

    def start(self):
        """启动 wasi-host（先 kill 旧进程）"""
        self.kill_all()
        cmd = f"nohup {self.m['remote_bin']} {self.m['remote_config']} > {self.m['remote_log']} 2>&1 &"
        self.exec(cmd, timeout=5)
        time.sleep(2)
        pids = self.pgrep()
        return pids[0] if pids else None

    def stop(self):
        self.exec("pkill -f wasi-host 2>/dev/null || true", timeout=5)
        time.sleep(1)

    def grep_log(self, pattern, tail=20):
        """从远程日志中 grep"""
        _, out, _ = self.exec(
            f"grep -aE '{pattern}' {self.m['remote_log']} 2>/dev/null | tail -{tail}",
            timeout=5,
        )
        return out

    def tail_log(self, n=20):
        _, out, _ = self.exec(f"tail -{n} {self.m['remote_log']}", timeout=5)
        return out

    def check_port(self, port):
        _, out, _ = self.exec(
            f"ss -tlnp | grep {port} || echo NO_LISTENER", timeout=5
        )
        return "NO_LISTENER" not in out

    def get_routing_state(self):
        """从日志解析路由状态"""
        log = self.grep_log("本机|前驱|后继|已填充|DHT 存储", 20)
        state = {"own_id": None, "predecessor": None, "successor": None}
        m = re.search(r"本机 ID:\s*(\S+)", log)
        if m:
            state["own_id"] = m.group(1)
        m = re.search(r"前驱:\s+(\S+):(\d+)\s+\(id=(\S+)\)", log)
        if m:
            state["predecessor"] = {"host": m.group(1), "port": int(m.group(2)), "id": m.group(3)}
        m = re.search(r"后继:\s+(\S+):(\d+)\s+\(id=(\S+)\)", log)
        if m:
            state["successor"] = {"host": m.group(1), "port": int(m.group(2)), "id": m.group(3)}
        return state


# ── 命令: 部署 ───────────────────────────────────────────────────────
def cmd_deploy():
    """完整部署流程"""
    print("=" * 55)
    print("  Chord DHT 集群部署")
    print("=" * 55)

    for arch, path in BINARIES.items():
        if not os.path.exists(path):
            print(f"[ERR] 未找到: {path}")
            print("请先编译: zig build -Dtarget=...")
            sys.exit(1)

    # 阶段 1: 清理所有旧进程
    print("\n── 阶段 1: 清理旧进程 ──")
    for m in MACHINES:
        with RemoteNode(m) as n:
            print(f"  {m['name']}: ", end="", flush=True)
            n.kill_all()
            print("已清理")

    # 阶段 2: 上传 binary + config
    print("\n── 阶段 2: 上传 binary + config ──")
    for m in MACHINES:
        with RemoteNode(m) as n:
            print(f"  {m['name']}: ", end="", flush=True)
            n.upload_binary()
            n.upload_config()
            print("已上传")

    # 阶段 3: 启动 外2（中继服务器）
    print("\n── 阶段 3: 启动 外2（中继服务器）──")
    ext2 = MACHINES[0]
    with RemoteNode(ext2) as n:
        pid = n.start()
        if pid:
            print(f"  [OK] {ext2['name']} PID={pid}")
        else:
            print(f"  [ERR] {ext2['name']} 启动失败!")
            print(f"  {n.tail_log(10)}")
            sys.exit(1)
        if n.check_port(8356):
            print(f"  [OK] port 8356 (relay) listening")
        if n.check_port(443) or n.check_port(8443):
            print(f"  [OK] WSS listening")

    print("  等待 外2 就绪 (5s)...")
    time.sleep(5)

    # 阶段 4: 启动其他节点
    print("\n── 阶段 4: 启动其余节点 ──")
    for m in MACHINES[1:]:
        print(f"  {m['name']} ({m['host']}): ", end="", flush=True)
        try:
            with RemoteNode(m) as n:
                pid = n.start()
                if pid:
                    print(f"[OK] PID={pid}")
                else:
                    print("[ERR] start failed")
        except Exception as e:
            print(f"[ERR] {e}")

    print("\n  等待 stabilize (30s)...")
    time.sleep(30)

    # 验证
    cmd_status(verbose=True)
    print("\n[OK] 部署完成。验证路由状态: python deploy.py test")


# ── 命令: 状态 ───────────────────────────────────────────────────────
def cmd_status(verbose=False):
    """查看各节点进程状态"""
    if not verbose:
        print("=" * 55)
        print("  节点状态")
        print("=" * 55)
    for m in MACHINES:
        try:
            with RemoteNode(m) as n:
                pids = n.pgrep()
                status = pids[0] if pids else "stopped"
                ports = []
                for p in [8356, 443, 8443, 20808]:
                    if n.check_port(p):
                        ports.append(str(p))
                port_str = f" [port: {','.join(ports)}]" if ports else ""
                if status != "stopped":
                    print(f"  {m['name']:<10} ({m['host']}): [OK] PID={status}{port_str}")
                else:
                    print(f"  {m['name']:<10} ({m['host']}): [--] stopped")
        except Exception as e:
            print(f"  {m['name']:<10} ({m['host']}): [ERR] {e}")


# ── 命令: 测试（路由验证）────────────────────────────────────────────
def cmd_test():
    """验证所有节点的路由状态和环一致性"""
    print("=" * 55)
    print("  Chord DHT 路由验证")
    print("=" * 55)
    print()

    results = []
    for m in MACHINES:
        print(f"  [{m['name']}] ({m['host']})")
        try:
            with RemoteNode(m) as n:
                state = n.get_routing_state()
                results.append({"name": m["name"], **state})

                if state["own_id"]:
                    print(f"    本机: {state['own_id']}")
                if state["predecessor"]:
                    p = state["predecessor"]
                    print(f"    前驱: {p['id'][:6]} ({p['host']}:{p['port']})")
                else:
                    print(f"    前驱: (无)")
                if state["successor"]:
                    s = state["successor"]
                    print(f"    后继: {s['id'][:6]} ({s['host']}:{s['port']})")
                else:
                    print(f"    后继: (无)")

                # Finger 表
                filled = n.grep_log("已填充", 1)
                if filled:
                    print(f"    {filled.strip()}")
                # DHT
                dht = n.grep_log("DHT 存储", 1)
                if dht:
                    print(f"    {dht.strip()}")
        except Exception as e:
            print(f"    [ERR] {e}")
            results.append({"name": m["name"], "own_id": None, "predecessor": None, "successor": None})
        print()

    # 环一致性检查
    valid = [r for r in results if r["successor"] and r["own_id"]]
    print("── 环一致性 ──")
    if len(valid) >= 2:
        node_map = {r["own_id"]: r for r in valid}
        ok_count = 0
        for r in valid:
            succ_id = r["successor"]["id"]
            succ_node = node_map.get(succ_id)
            if succ_node:
                pred = succ_node.get("predecessor")
                if pred and pred["id"] == r["own_id"]:
                    print(f"  [OK] {r['name']} -> {succ_node['name']} (双向确认)")
                    ok_count += 1
                else:
                    pred_name = pred["id"][:6] if pred else "?"
                    print(f"  [!!] {r['name']} -> {succ_node['name']} (前驱={pred_name})")
            else:
                print(f"  [..] {r['name']} -> {succ_id[:6]} (在线节点外)")
        print(f"\n  {ok_count}/{len(valid)} 双向确认")
    else:
        print(f"  [!!] 只有 {len(valid)} 个节点有路由状态")


# ── 命令: 清理 ───────────────────────────────────────────────────────
def cmd_cleanup():
    print("=" * 55)
    print("  清理所有节点")
    print("=" * 55)
    for m in MACHINES:
        try:
            with RemoteNode(m) as n:
                n.kill_all()
                print(f"  [OK] {m['name']}: 已清理")
        except Exception as e:
            print(f"  [ERR] {m['name']}: {e}")


# ── 命令: 日志 ───────────────────────────────────────────────────────
def cmd_logs(tail=20):
    print("=" * 55)
    print("  各节点日志")
    print("=" * 55)
    for m in MACHINES:
        try:
            with RemoteNode(m) as n:
                print(f"\n── {m['name']} ({m['host']}) ──")
                print(n.tail_log(tail))
        except Exception as e:
            print(f"\n── {m['name']}: [ERR] {e}")


# ── 命令: 检查旧进程 ─────────────────────────────────────────────────
def cmd_check_stale():
    print("=" * 55)
    print("  检查残留旧进程")
    print("=" * 55)
    for m in MACHINES:
        try:
            with RemoteNode(m) as n:
                print(f"\n── {m['name']} ({m['host']}) ──")
                _, idx_out, _ = n.exec("pgrep -af 'index.js' 2>/dev/null || echo 'none'", timeout=5)
                _, bridge_out, _ = n.exec("pgrep -af 'bridge' 2>/dev/null || echo 'none'", timeout=5)
                port_8356 = n.check_port(8356)
                print(f"  index.js: {'[YES]' if idx_out != 'none' else '[--]'}")
                print(f"  bridge:   {'[YES]' if bridge_out != 'none' else '[--]'}")
                print(f"  port 8356: {'[OK]  listening' if port_8356 else '[--]  not listening'}")
        except Exception as e:
            print(f"\n── {m['name']}: [ERR] {e}")


# ── 命令: 巡检（复用 ring_inspect.py 逻辑）─────────────────────────
def cmd_inspect(quick=False, json_mode=False):
    """完整巡检：进程、资源、路由、异常"""
    try:
        from ring_inspect import (
            check_ring_consistency,
            inspect_local_seed,
            inspect_node,
            print_report,
        )
    except ImportError:
        print("[ERR] ring_inspect.py 未找到，请确认在同一目录")
        sys.exit(1)

    results = []
    results.append(inspect_local_seed())

    # 标准化机器字典（ring_inspect.inspect_node 需要 `log` 键）
    def _normalize(m):
        d = dict(m)
        d["log"] = m["remote_log"]
        return d

    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = {
            pool.submit(inspect_node, _normalize(m), quick=quick): m["name"]
            for m in MACHINES
        }
        for future in as_completed(futures):
            name = futures[future]
            try:
                results.append(future.result())
            except Exception as e:
                results.append({
                    "name": name, "host": "?",
                    "reachable": False, "status": "error",
                    "error_samples": [str(e)],
                })

    results.sort(key=lambda r: NAME_ORDER.get(r.get("name", ""), 999))
    consistency = check_ring_consistency(results)
    print_report(results, consistency, json_mode=json_mode)

    has_error = any(
        r["status"] in ("unreachable", "error") or r.get("error_count", 0) > 0
        for r in results
    )
    sys.exit(1 if has_error else 0)


# ── 主入口 ────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="Chord DHT 统一部署管理",
        epilog=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "command", nargs="?",
        choices=["deploy", "test", "cleanup", "status", "logs", "check-stale", "inspect"],
        default="status",
        help="操作（默认: status）",
    )
    parser.add_argument("--quick", action="store_true", help="快速模式（仅 inspect）")
    parser.add_argument("--json", action="store_true", help="JSON 输出（仅 inspect）")
    parser.add_argument("--tail", type=int, default=20, help="日志行数（默认 20）")
    args = parser.parse_args()

    cmds = {
        "deploy": cmd_deploy,
        "test": cmd_test,
        "cleanup": cmd_cleanup,
        "status": cmd_status,
        "logs": lambda: cmd_logs(tail=args.tail),
        "check-stale": cmd_check_stale,
        "inspect": lambda: cmd_inspect(quick=args.quick, json_mode=args.json),
    }

    cmds[args.command]()


if __name__ == "__main__":
    main()
