#!/usr/bin/env python3
"""Chord DHT 集群巡检脚本

一键检查所有节点的健康状态、路由信息和资源使用情况。

用法:
  python ring_inspect.py              # 完整巡检
  python ring_inspect.py --quick      # 快速模式（仅进程 + 路由状态）
  python ring_inspect.py --json       # JSON 输出
  python ring_inspect.py --watch 30   # 持续监控（每30秒巡检一次）
  python ring_inspect.py --help       # 帮助
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

# ── 颜色定义 ──────────────────────────────────────────────────────────
class Color:
    GREEN = "\033[92m"
    YELLOW = "\033[93m"
    RED = "\033[91m"
    CYAN = "\033[96m"
    BOLD = "\033[1m"
    RESET = "\033[0m"
    GRAY = "\033[90m"

def ok(text):
    return f"{Color.GREEN}{text}{Color.RESET}"

def warn(text):
    return f"{Color.YELLOW}{text}{Color.RESET}"

def err(text):
    return f"{Color.RED}{text}{Color.RESET}"

def info(text):
    return f"{Color.CYAN}{text}{Color.RESET}"

def dim(text):
    return f"{Color.GRAY}{text}{Color.RESET}"

# 终端编码检测：Windows GBK 终端无法打印 Unicode emoji
_USE_ASCII = False
try:
    "✓".encode(sys.stdout.encoding or "utf-8")
except (UnicodeEncodeError, UnicodeDecodeError, LookupError):
    _USE_ASCII = True

if _USE_ASCII:
    SYM_OK = ok("[OK]")
    SYM_WARN = warn("[!!]")
    SYM_ERR = err("[XX]")
    SYM_INFO = info("[II]")
    OK_EMOJI = "[OK]"
    FAIL_EMOJI = "[FAIL]"
    WARN_EMOJI = "[WARN]"
else:
    SYM_OK = ok("✓")
    SYM_WARN = warn("⚠")
    SYM_ERR = err("✗")
    SYM_INFO = info("ℹ")
    OK_EMOJI = "✅"
    FAIL_EMOJI = "❌"
    WARN_EMOJI = "⚠️"

# ── 机器定义 ──────────────────────────────────────────────────────────
MACHINES = [
    {
        "name": "外2",
        "host": "192.140.185.171",
        "port": 22,
        "user": "root",
        "password": "aetej1AzIQpE",
        "log": "/root/test-ext-node2.log",
        "config": "/root/config-ext-node2.json",
    },
    {
        "name": "ext",
        "host": "ssh-metaai.alwaysdata.net",
        "port": 22,
        "user": "metaai",
        "password": "1qaz@WSXasdfasdf",
        "log": "/home/metaai/test-ext-server.log",
        "config": "/home/metaai/config-ext-server.json",
    },
    {
        "name": "node59",
        "host": "192.168.2.59",
        "port": 22,
        "user": "root",
        "password": "ecoo1234",
        "log": "/root/test-remote-node59.log",
        "config": "/root/config-remote-node59.json",
    },
    {
        "name": "node60",
        "host": "192.168.2.60",
        "port": 22,
        "user": "root",
        "password": "ecoo1234",
        "log": "/root/test-remote-node60.log",
        "config": "/root/config-remote-node60.json",
    },
]


# ── 本地 Seed 节点检查 ──────────────────────────────────────────────
def inspect_local_seed():
    """检查本地 seed 节点（通过本地子进程）"""
    result = {
        "name": "seed",
        "host": "localhost",
        "reachable": False,
        "pid": None,
        "uptime": None,
        "cpu": None,
        "mem": None,
        "rss": None,
        "own_id": None,
        "predecessor": None,
        "successor": None,
        "finger_filled": None,
        "dht_entries": None,
        "dht_pending": None,
        "error_count": 0,
        "error_samples": [],
        "status": "unknown",
    }

    try:
        # Try pgrep for wasi-host on Windows/Linux
        if sys.platform == "win32":
            pgrep = subprocess.run(
                ["tasklist", "/FI", "IMAGENAME eq wasi-host.exe", "/FO", "CSV"],
                capture_output=True, text=True, timeout=5,
            )
            if "wasi-host.exe" in pgrep.stdout:
                for line in pgrep.stdout.strip().split("\n"):
                    if "wasi-host.exe" in line:
                        parts = line.replace('"', "").split(",")
                        if len(parts) >= 2:
                            result["pid"] = parts[1].strip()
                        break
        else:
            pgrep = subprocess.run(
                ["pgrep", "-f", "wasi-host"],
                capture_output=True, text=True, timeout=5,
            )
            if pgrep.returncode == 0:
                result["pid"] = pgrep.stdout.strip().split("\n")[0]

        if result["pid"]:
            result["reachable"] = True
            # Get resource usage
            if sys.platform != "win32":
                ps = subprocess.run(
                    ["ps", "-p", result["pid"], "-o", "%cpu,%mem,rss,etime", "--no-headers"],
                    capture_output=True, text=True, timeout=5,
                )
                if ps.returncode == 0:
                    parts = ps.stdout.strip().split()
                    if len(parts) >= 4:
                        result["cpu"] = parts[0]
                        result["mem"] = parts[1]
                        result["rss"] = parts[2]
                        result["uptime"] = parts[3]

            # Check local log for routing state
            log_paths = ["wasi-host.log", "test-seed.log", "test-ext-node2.log"]
            for lp in log_paths:
                if os.path.exists(lp):
                    log_content = open(lp, "r", errors="replace").read()
                    result.update(_parse_log_state(log_content, lp))
                    break

            result["status"] = "ok"
        else:
            result["status"] = "stopped"
    except Exception as e:
        result["status"] = "error"
        result["error_samples"] = [str(e)]

    return result


# ── SSH 远程节点检查 ──────────────────────────────────────────────────
def inspect_node(machine, quick=False):
    """SSH 连接到一个远程节点并收集所有状态信息"""
    result = {
        "name": machine["name"],
        "host": machine["host"],
        "reachable": False,
        "pid": None,
        "uptime": None,
        "cpu": None,
        "mem": None,
        "rss": None,
        "own_id": None,
        "predecessor": None,
        "successor": None,
        "finger_filled": None,
        "dht_entries": None,
        "dht_pending": None,
        "error_count": 0,
        "error_samples": [],
        "status": "unknown",
    }

    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(
            machine["host"],
            port=machine["port"],
            username=machine["user"],
            password=machine["password"],
            timeout=10,
        )
    except Exception as e:
        result["status"] = "unreachable"
        result["error_samples"] = [str(e)]
        return result

    try:
        result["reachable"] = True

        # 1. Process health
        _, stdout, _ = client.exec_command(
            "pgrep -f wasi-host || echo NOT_RUNNING", timeout=5
        )
        pgrep_out = stdout.read().decode(errors="replace").strip()
        if "NOT_RUNNING" in pgrep_out:
            result["status"] = "stopped"
            return result

        pids = [p.strip() for p in pgrep_out.split("\n") if p.strip()]
        result["pid"] = pids[0] if pids else None
        result["status"] = "ok"

        # 2. Resource usage (skip in quick mode)
        if not quick:
            _, stdout, _ = client.exec_command(
                f"ps -p {result['pid']} -o %cpu,%mem,rss,etime --no-headers 2>/dev/null || "
                f"ps -p {result['pid']} -o %cpu,%mem,rss,etime 2>/dev/null",
                timeout=5,
            )
            ps_out = stdout.read().decode(errors="replace").strip()
            if ps_out:
                parts = ps_out.split()
                if len(parts) >= 4:
                    result["cpu"] = parts[0]
                    result["mem"] = parts[1]
                    result["rss"] = parts[2]
                    result["uptime"] = " ".join(parts[3:])

        # 3. Routing state from logs
        _, stdout, _ = client.exec_command(
            f"grep -aE '(本机|前驱|后继|已填充|DHT 存储)' {machine['log']} 2>/dev/null | tail -20",
            timeout=5,
        )
        log_state = stdout.read().decode(errors="replace")
        result.update(_parse_log_state(log_state, machine["log"]))

        # 4. Error/log anomalies
        _, stdout, _ = client.exec_command(
            f"grep -aE '(error|fail|Error|ERR|fallback|错误|失败|异常)' {machine['log']} 2>/dev/null | tail -20",
            timeout=5,
        )
        errors_raw = stdout.read().decode(errors="replace").strip()
        if errors_raw:
            lines = [l.strip() for l in errors_raw.split("\n") if l.strip()]
            result["error_count"] = len(lines)
            result["error_samples"] = lines[:5]  # keep top 5

        client.close()
    except Exception as e:
        result["status"] = "error"
        result["error_samples"].append(str(e))
        try:
            client.close()
        except Exception:
            pass

    return result


def _parse_log_state(log_content, log_path):
    """从日志内容解析路由状态"""
    state = {
        "own_id": None,
        "predecessor": None,
        "successor": None,
        "finger_filled": None,
        "dht_entries": None,
        "dht_pending": None,
    }

    # 本机 ID
    m = re.search(r"本机 ID:\s*(\S+)", log_content)
    if m:
        state["own_id"] = m.group(1)

    # 前驱
    m = re.search(r"前驱:\s+(\S+):(\d+)\s+\(id=(\S+)\)", log_content)
    if m:
        state["predecessor"] = {
            "host": m.group(1),
            "port": int(m.group(2)),
            "id": m.group(3),
        }

    # 后继
    m = re.search(r"后继:\s+(\S+):(\d+)\s+\(id=(\S+)\)", log_content)
    if m:
        state["successor"] = {
            "host": m.group(1),
            "port": int(m.group(2)),
            "id": m.group(3),
        }

    # Finger 已填充
    m = re.search(r"已填充\s+(\d+)/", log_content)
    if m:
        state["finger_filled"] = int(m.group(1))

    # DHT 存储
    m = re.search(r"DHT 存储:\s*(\d+)\s*条目.*?(\d+)\s*待复制", log_content)
    if m:
        state["dht_entries"] = int(m.group(1))
        state["dht_pending"] = int(m.group(2))

    return state


# ── 交叉验证 ──────────────────────────────────────────────────────────
def check_ring_consistency(results):
    """验证环一致性：检查所有节点的后继/前驱是否形成完整环"""
    checks = []
    valid_nodes = [r for r in results if r["status"] == "ok" and r["successor"]]

    if len(valid_nodes) < 2:
        checks.append({
            "ok": False,
            "msg": f"只有 {len(valid_nodes)} 个节点在线（需要至少 2 个才能验证）",
        })
        return checks

    # Build mapping: node_id -> node_result
    node_map = {}
    for r in valid_nodes:
        if r["own_id"]:
            node_map[r["own_id"]] = r

    # Check successor chains
    for r in valid_nodes:
        succ = r.get("successor")
        if not succ:
            checks.append({"ok": False, "msg": f"{r['name']}: 无后继"})
            continue

        succ_id = succ.get("id")
        if not succ_id:
            checks.append({"ok": False, "msg": f"{r['name']}: 后继无 ID"})
            continue

        # Find the node that claims this successor
        succ_node = node_map.get(succ_id)
        if succ_node:
            # Verify that successor's predecessor points back
            pred = succ_node.get("predecessor")
            if pred and pred.get("id") == r.get("own_id"):
                checks.append({
                    "ok": True,
                    "msg": f"{r['name']}({_short_id(r['own_id'])}) → {succ_node['name']}({_short_id(succ_id)}) {OK_EMOJI} 双向确认",
                })
            else:
                pred_name = _short_id(pred.get("id")) if pred else "?"
                checks.append({
                    "ok": False,
                    "msg": f"{r['name']}({_short_id(r['own_id'])}) → {succ_node['name']}({_short_id(succ_id)}) {WARN_EMOJI} 后继的前驱是 {pred_name}（期望 {_short_id(r['own_id'])}）",
                })
        else:
            checks.append({
                "ok": True,
                "msg": f"{r['name']} 的后继 {_short_id(succ_id)} 未在检查范围内（可能已离线）",
            })

    # Check for full ring closure
    if len(valid_nodes) >= 2:
        # Follow successor chain from first node
        visited = set()
        current = valid_nodes[0]
        chain = []
        while current and current.get("own_id") and current["own_id"] not in visited:
            visited.add(current["own_id"])
            chain.append(current["name"])
            succ = current.get("successor")
            if not succ:
                break
            succ_id = succ.get("id")
            current = node_map.get(succ_id)

        if len(chain) == len(valid_nodes):
            checks.append({
                "ok": True,
                "msg": f"环封闭: {' → '.join(chain)} → {chain[0]} {OK_EMOJI}",
            })
        else:
            checks.append({
                "ok": False,
                "msg": f"环断裂: 跟踪到 {len(chain)}/{len(valid_nodes)} 个节点: {' → '.join(chain)}",
            })

    return checks


def _short_id(node_id):
    """截断节点 ID 为 6 字符显示"""
    if not node_id:
        return "?"
    return node_id[:6] if len(node_id) > 6 else node_id


# ── 输出 ──────────────────────────────────────────────────────────────
def print_report(results, consistency_checks=None, json_mode=False):
    """打印巡检报告"""
    if json_mode:
        print(json.dumps({
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "nodes": results,
            "consistency": [
                {"ok": c["ok"], "msg": c["msg"]}
                for c in (consistency_checks or [])
            ],
        }, indent=2, ensure_ascii=False))
        return

    print()
    print("=" * 55)
    print(f"  {Color.BOLD}Chord DHT 集群巡检报告{Color.RESET}")
    print(f"  {dim(time.strftime('%Y-%m-%d %H:%M:%S'))}")
    print("=" * 55)
    print()

    # Print each node
    for r in results:
        _print_node(r)
        print()

    # Summary table
    _print_summary_table(results)

    # Ring consistency
    if consistency_checks:
        print(f"  {Color.BOLD}环一致性检查{Color.RESET}")
        print(f"  {'─' * 50}")
        for c in consistency_checks:
            prefix = ok(OK_EMOJI) if c["ok"] else err(FAIL_EMOJI)
            print(f"  {prefix} {c['msg']}")
        print()

    # Overall status
    ok_count = sum(1 for r in results if r["status"] == "ok")
    warn_count = sum(1 for r in results if r["status"] in ("stopped",) and r["pid"] is None)
    err_count = sum(1 for r in results if r["status"] in ("unreachable", "error"))
    error_total = sum(r.get("error_count", 0) for r in results)

    if err_count == 0 and warn_count == 0 and error_total == 0:
        status_line = ok(f"{OK_EMOJI} 全部正常")
    elif err_count > 0:
        status_line = err(f"{FAIL_EMOJI} {err_count} 个节点故障")
    else:
        status_line = warn(f"{WARN_EMOJI} {warn_count} 个节点警告, {error_total} 条异常日志")

    print(f"  节点状态: {ok_count} 正常 / {warn_count} 停止 / {err_count} 故障")
    print(f"  异常日志: {error_total} 条")
    print(f"  {Color.BOLD}结论: {status_line}{Color.RESET}")
    print()


def _print_node(r):
    """打印单个节点的详细信息"""
    status_sym = {
        "ok": SYM_OK,
        "stopped": SYM_WARN,
        "unreachable": SYM_ERR,
        "error": SYM_ERR,
        "unknown": SYM_INFO,
    }.get(r["status"], SYM_INFO)

    status_color = {
        "ok": ok,
        "stopped": warn,
        "unreachable": err,
        "error": err,
        "unknown": info,
    }.get(r["status"], info)

    print(f"  {status_sym} {Color.BOLD}{r['name']}{Color.RESET} ({r['host']}) — {status_color(r['status'].upper())}")

    if r["status"] == "unreachable":
        for s in r.get("error_samples", []):
            print(f"     {dim('└─')} {err(s)}")
        return

    if r["status"] == "stopped":
        print(f"     {dim('└─')} 进程未运行")
        return

    # Process info
    print(f"     {dim('├─')} 进程: PID={r.get('pid', '?')} (运行中)", end="")
    if r.get("uptime"):
        print(f"  运行: {r['uptime']}", end="")
    print()

    # Resources
    if r.get("cpu") is not None:
        print(f"     {dim('├─')} 资源: CPU={r['cpu']}%  MEM={r['mem']}%  RSS={_rss_str(r.get('rss'))}")

    # Routing
    print(f"     {dim('├─')} 路由:")
    if r.get("own_id"):
        print(f"     {dim('│  ├─')} 本机: {r['own_id']}")
    if r.get("predecessor"):
        p = r["predecessor"]
        print(f"     {dim('│  ├─')} 前驱: {_short_id(p['id'])} ({p['host']}:{p['port']})")
    else:
        print(f"     {dim('│  ├─')} 前驱: {warn('(无)')}")
    if r.get("successor"):
        s = r["successor"]
        print(f"     {dim('│  └─')} 后继: {_short_id(s['id'])} ({s['host']}:{s['port']})")
    else:
        print(f"     {dim('│  └─')} 后继: {warn('(无)')}")

    # Finger / DHT
    extra = []
    if r.get("finger_filled") is not None:
        filled = r["finger_filled"]
        if filled < 5:
            extra.append(warn(f"Finger: {filled}/160"))
        else:
            extra.append(f"Finger: {filled}/160")
    if r.get("dht_entries") is not None:
        pending = r.get("dht_pending", 0)
        extra.append(f"DHT: {r['dht_entries']} 条目")
        if pending > 0:
            extra.append(warn(f"{pending} 待复制"))
    if extra:
        print(f"     {dim('├─')} {' | '.join(extra)}")

    # Errors
    err_count = r.get("error_count", 0)
    if err_count > 0:
        print(f"     {dim('└─')} 异常: {err(f'{err_count} 条')}")
        for s in r.get("error_samples", []):
            truncated = s[:120] + "..." if len(s) > 120 else s
            print(f"        {dim('·')} {err(truncated)}")
    else:
        print(f"     {dim('└─')} 异常: 0")


def _print_summary_table(results):
    """打印汇总表"""
    print(f"  {Color.BOLD}汇总{Color.RESET}")
    print(f"  {'─' * 60}")
    header = f"  {'节点':<10} {'状态':<10} {'后继ID':<10} {'前驱ID':<10} {'运行时间':<12}"
    print(f"  {Color.BOLD}{header}{Color.RESET}")
    print(f"  {'─' * 60}")
    for r in results:
        name = r["name"]
        if _USE_ASCII:
            status_map = {"ok": "[OK]", "stopped": "[!!]", "unreachable": "[XX]", "error": "[XX]"}
        else:
            status_map = {"ok": "✅", "stopped": "⚠️", "unreachable": "❌", "error": "❌"}
        status_sym = status_map.get(r["status"], "[??]")

        succ_id = _short_id(r.get("successor", {}).get("id")) if r.get("successor") else "-"
        pred_id = _short_id(r.get("predecessor", {}).get("id")) if r.get("predecessor") else "-"
        uptime = r.get("uptime") or "-"

        line = f"  {name:<10} {status_sym:<10} {succ_id:<10} {pred_id:<10} {uptime:<12}"
        print(line)
    print(f"  {'─' * 60}")


def _rss_str(rss_val):
    """将 RSS 从 KB 转换为可读格式"""
    if rss_val is None:
        return "?"
    try:
        kb = int(rss_val)
        if kb > 1024 * 1024:
            return f"{kb / 1024 / 1024:.1f}GB"
        elif kb > 1024:
            return f"{kb / 1024:.1f}MB"
        else:
            return f"{kb}KB"
    except (ValueError, TypeError):
        return str(rss_val)


# ── 主入口 ────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="Chord DHT 集群巡检脚本",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--quick", action="store_true",
        help="快速模式（跳过资源使用检查）",
    )
    parser.add_argument(
        "--json", action="store_true",
        help="JSON 格式输出",
    )
    parser.add_argument(
        "--watch", type=int, metavar="SECONDS", default=0,
        help="持续监控模式，每 N 秒巡检一次",
    )
    parser.add_argument(
        "--no-local", action="store_true",
        help="跳过本地 seed 节点检查",
    )
    parser.add_argument(
        "--max-workers", type=int, default=8,
        help="最大并行 SSH 连接数（默认 8）",
    )
    args = parser.parse_args()

    # ── 持续监控模式 ──────────────────────────────────────────────
    if args.watch > 0:
        cycle = 0
        while True:
            cycle += 1
            if not args.json:
                print(f"\n{'#' * 55}")
                print(f"#  巡检周期 #{cycle}  {time.strftime('%Y-%m-%d %H:%M:%S')}")
                print(f"{'#' * 55}")

            results = run_inspection(args)

            if args.json:
                print(json.dumps({
                    "cycle": cycle,
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
                    "nodes": results,
                }, indent=2, ensure_ascii=False))
            else:
                print()

            if not args.json:
                print(f"{dim('下一次巡检:')} {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(time.time() + args.watch))}")
            time.sleep(args.watch)
        return

    # ── 单次巡检模式 ──────────────────────────────────────────────
    results = run_inspection(args)
    consistency = check_ring_consistency(results)
    print_report(results, consistency, json_mode=args.json)

    # Exit code: 0 = all ok, 1 = any issue
    has_error = any(
        r["status"] in ("unreachable", "error")
        or (r.get("error_count", 0) > 0)
        for r in results
    )
    has_consistency_fail = any(not c["ok"] for c in consistency) if consistency else False

    sys.exit(1 if (has_error or has_consistency_fail) else 0)


def run_inspection(args):
    """并行巡检所有节点"""
    results = []

    # Local seed
    if not args.no_local:
        results.append(inspect_local_seed())

    # Remote nodes (parallel)
    with ThreadPoolExecutor(max_workers=args.max_workers) as pool:
        futures = {
            pool.submit(inspect_node, m, quick=args.quick): m["name"]
            for m in MACHINES
        }
        for future in as_completed(futures):
            name = futures[future]
            try:
                result = future.result()
                results.append(result)
            except Exception as e:
                results.append({
                    "name": name,
                    "host": "?",
                    "reachable": False,
                    "status": "error",
                    "error_samples": [str(e)],
                })

    # Sort: remote nodes first (consistent order), seed last
    name_order = {m["name"]: i for i, m in enumerate(MACHINES)}
    results.sort(key=lambda r: name_order.get(r.get("name", ""), 999))

    return results


if __name__ == "__main__":
    main()
