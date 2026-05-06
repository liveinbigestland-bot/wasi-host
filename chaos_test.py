#!/usr/bin/env python3
"""
Chaos Stability Test — 随机节点上下线检测

每 3-5 分钟随机选一个节点下线 → 3分钟后上线 → 持续5小时。
记录每次事件、环状态、异常。

用法:
  python chaos_test.py              # 前台运行（可 Ctrl+C 中断）
  python chaos_test.py > log.txt    # 重定向到文件
  nohup python chaos_test.py &      # 后台运行
"""
import sys, os, time, json, random, datetime, traceback
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "wasi-host"))
from deploy import RemoteNode, MACHINES

# ── 配置（可调）──
OFFLINE_DURATION_S = 180       # 下线持续时间 (3 分钟)
INTERVAL_MIN = 180             # 操作间隔下限 (3 分钟)
INTERVAL_MAX = 300             # 操作间隔上限 (5 分钟)
TOTAL_DURATION_S = 5 * 3600   # 总时长 (5 小时)
SSH_TIMEOUT = 15               # SSH 连接超时（秒）
PROTECTED = {"外2"}            # 不可下线的关键节点

# ── 状态 ──
events = []
start_time = time.time()
health_log = []
logfile = None

def log(msg, also_print=True):
    """带时间戳和 flush 的日志"""
    ts = datetime.datetime.now().strftime("%H:%M:%S")
    line = f"[{ts}] {msg}"
    if also_print:
        print(line, flush=True)
    global logfile
    if logfile:
        logfile.write(line + "\n")
        logfile.flush()

def safe_ssh(m, func_name, *args, **kwargs):
    """安全的 SSH 调用，带超时和错误处理"""
    try:
        with RemoteNode(m, timeout=SSH_TIMEOUT) as n:
            method = getattr(n, func_name)
            return method(*args, **kwargs)
    except Exception as e:
        log(f"  [SSH_ERR] {m['name']}.{func_name}: {e}")
        return None

def check_node(m):
    """检查单节点状态（独立连接，超时隔离）"""
    try:
        with RemoteNode(m, timeout=SSH_TIMEOUT) as n:
            pids = n.pgrep()
            if not pids:
                return {"name": m["name"], "alive": False, "pid": None, "pred": None, "succ": None, "error": None}
            state = n.get_routing_state()
            return {
                "name": m["name"],
                "alive": True,
                "pid": pids[0],
                "pred": state.get("predecessor"),
                "succ": state.get("successor"),
                "error": None,
            }
    except Exception as e:
        return {"name": m["name"], "alive": False, "pid": None, "pred": None, "succ": None, "error": str(e)}

def check_all_nodes():
    """并行检查所有节点（每个节点独立超时）"""
    results = {}
    with ThreadPoolExecutor(max_workers=8) as pool:
        futs = {pool.submit(check_node, m): m["name"] for m in MACHINES}
        for f in as_completed(futs):
            try:
                r = f.result()
                results[r["name"]] = r
            except Exception as e:
                name = futs[f]
                results[name] = {"name": name, "alive": False, "pid": None, "pred": None, "succ": None, "error": str(e)}
    return results

def health_snapshot(label=""):
    """记录健康快照"""
    prefix = f"[{label}] " if label else ""
    results = check_all_nodes()
    alive = sum(1 for r in results.values() if r["alive"])
    total = len(results)
    errors = [r for r in results.values() if r.get("error")]

    snapshot = {
        "ts": time.time(),
        "alive": alive,
        "total": total,
        "nodes": {n: r["alive"] for n, r in results.items()},
        "errors": [(r["name"], r["error"]) for r in errors],
    }
    health_log.append(snapshot)

    parts = []
    # 每节点状态
    for r in results.values():
        n = r["name"]
        if r["alive"]:
            succ_id = r["succ"]["id"][:8] if r.get("succ") and r["succ"].get("id") else "?"
            pred_id = r["pred"]["id"][:8] if r.get("pred") and r["pred"].get("id") else "?"
            parts.append(f"{n}[up  pred={pred_id} succ={succ_id}]")
        else:
            err = r.get("error", "")
            parts.append(f"{n}[DOWN {err}]" if err else f"{n}[DOWN]")

    log(f"{prefix}健康 {alive}/{total} | {' | '.join(parts)}")
    return snapshot

def stop_node(name):
    """停止指定节点"""
    m = _find_machine(name)
    if not m:
        log(f"[ERR] 节点 {name} 未找到")
        return False
    log(f"[下线] {name} 正在停止...")
    try:
        with RemoteNode(m, timeout=SSH_TIMEOUT) as n:
            n.stop()
        log(f"[下线] {name} 已停止")
        return True
    except Exception as e:
        log(f"[ERR] 停止 {name} 失败: {e}")
        return False

def start_node(name):
    """启动指定节点"""
    m = _find_machine(name)
    if not m:
        log(f"[ERR] 节点 {name} 未找到")
        return False
    log(f"[上线] {name} 正在启动...")
    try:
        with RemoteNode(m, timeout=SSH_TIMEOUT) as n:
            pid = n.start()
            if pid:
                log(f"[上线] {name} PID={pid}")
            else:
                log(f"[ERR] {name} 启动失败!")
        return True
    except Exception as e:
        log(f"[ERR] 启动 {name} 失败: {e}")
        return False

def _find_machine(name):
    for m in MACHINES:
        if m["name"] == name:
            return m
    return None

def pick_target(exclude=None):
    """选择可下线的随机节点"""
    exclude = exclude or set()
    exclude |= PROTECTED
    candidates = [m["name"] for m in MACHINES if m["name"] not in exclude]
    return random.choice(candidates) if candidates else None

def run():
    global logfile
    # 日志文件（追加模式）
    log_path = os.path.join(os.path.dirname(__file__), "chaos_test.log")
    logfile = open(log_path, "a", encoding="utf-8")
    logfile.write(f"\n{'='*60}\n")

    log("混沌稳定性测试启动")
    log(f"  间隔: {INTERVAL_MIN}-{INTERVAL_MAX}s (随机)")
    log(f"  下线时长: {OFFLINE_DURATION_S}s")
    log(f"  总时长: {TOTAL_DURATION_S / 3600:.0f} 小时")
    log(f"  保护节点: {', '.join(PROTECTED)}")
    log("=" * 60)

    # 初始健康快照
    log("[初始] 全节点健康检查...")
    health_snapshot("初始")

    cycle = 0
    while True:
        elapsed = time.time() - start_time
        if elapsed >= TOTAL_DURATION_S:
            log(f"\n{'='*60}")
            log(f"测试完成！运行时长: {elapsed/3600:.1f} 小时")
            break

        cycle += 1
        wait_time = random.randint(INTERVAL_MIN, INTERVAL_MAX)
        remaining = TOTAL_DURATION_S - elapsed

        log(f"\n{'─'*60}")
        log(f"轮次 {cycle} | 已运行 {elapsed/60:.0f} 分钟 | 剩余 {remaining/60:.0f} 分钟")
        log(f"等待 {wait_time}s 后执行下线操作...")

        # 分小段 sleep 以便检测中断
        for s in range(0, wait_time, 10):
            time.sleep(min(10, wait_time - s))
            if not os.path.exists(os.path.join(os.path.dirname(__file__), "chaos_test.stop")):
                continue
            else:
                log("检测到停止标记 (chaos_test.stop)，退出")
                os.remove(os.path.join(os.path.dirname(__file__), "chaos_test.stop"))
                health_snapshot("退出")
                _generate_report(cycle)
                return

        # 选择目标节点
        target = pick_target()
        if not target:
            log("[ERR] 没有可下线的节点")
            time.sleep(60)
            continue

        # ── 下线 ──
        log(f"\n[操作] 目标: {target}")
        events.append({"cycle": cycle, "ts": time.time(), "action": "offline", "target": target})

        # 下线前快照
        health_snapshot("下线前")

        if not stop_node(target):
            log(f"[WARN] {target} 停止失败，跳过本轮")
            continue

        # 等待下线持续时间（每 30s 检查一次）
        log(f"等待 {OFFLINE_DURATION_S}s 让 {target} 离线...")
        for i in range(0, OFFLINE_DURATION_S, 30):
            elapsed_off = OFFLINE_DURATION_S - i
            remaining_off = OFFLINE_DURATION_S - i - 30
            if remaining_off > 0 and remaining_off % 60 == 0:
                health_snapshot(f"{target}离线中")
            time.sleep(min(30, elapsed_off))

        # 离线中健康检查
        health_snapshot(f"{target}离线完毕")

        # ── 上线 ──
        log(f"[操作] 恢复: {target}")
        events.append({"cycle": cycle, "ts": time.time(), "action": "online", "target": target})

        if not start_node(target):
            log(f"[WARN] {target} 启动失败，人工介入")
            # 尝试重试一次
            log(f"重试启动 {target}...")
            time.sleep(5)
            start_node(target)

        # 等待 stabilize
        log(f"等待 stabilize (30s)...")
        time.sleep(30)

        # 恢复后检查
        snap = health_snapshot(f"{target}恢复后")

        if snap["nodes"].get(target, False):
            log(f"[OK] {target} 已成功恢复上线")
        else:
            log(f"[WARN] {target} 可能未恢复, 需关注")

        log(f"[OK] 轮次 {cycle} 完成 ({target} 下线→上线)")

    # ── 最终报告 ──
    _generate_report(cycle)

def _generate_report(cycle):
    log(f"\n{'='*60}")
    log("最终健康检查...")
    health_snapshot("最终")

    log(f"\n{'='*60}")
    log("混沌测试报告")
    log(f"{'='*60}")
    log(f"运行时长: {(time.time()-start_time)/3600:.1f} 小时")
    log(f"执行轮次: {cycle}")
    log(f"操作节点: {set(e['target'] for e in events)}")
    log(f"健康快照数: {len(health_log)}")

    all_errors = []
    for snap in health_log:
        all_errors.extend(snap.get("errors", []))

    offline_counts = {}
    for e in events:
        if e["action"] == "offline":
            offline_counts[e["target"]] = offline_counts.get(e["target"], 0) + 1

    log(f"\n下线次数: {json.dumps(offline_counts, indent=2)}")

    if all_errors:
        log(f"\n异常汇总 ({len(all_errors)} 次):")
        for name, err in all_errors[:15]:
            log(f"  {name}: {err}")
    else:
        log(f"\n异常汇总: 无")

    report_path = os.path.join(os.path.dirname(__file__), "chaos_report.json")
    with open(report_path, "w") as f:
        json.dump({
            "duration_h": (time.time() - start_time) / 3600,
            "cycles": cycle,
            "offline_counts": offline_counts,
            "error_count": len(all_errors),
            "health_log": health_log,
            "events": events,
        }, f, indent=2, default=str)
    log(f"\n报告已保存: {report_path}")
    log("混沌测试结束")

    if logfile:
        logfile.close()

if __name__ == "__main__":
    try:
        run()
    except KeyboardInterrupt:
        log("\n\n用户中断。恢复所有节点...")
        for m in MACHINES:
            try:
                with RemoteNode(m, timeout=SSH_TIMEOUT) as n:
                    if not n.pgrep():
                        log(f"  启动 {m['name']}...")
                        n.start()
            except:
                pass
        log("中断退出")
    except Exception as e:
        log(f"\n[FATAL] 未预期异常: {e}")
        log(traceback.format_exc())
        # 尝试恢复
        log("尝试恢复所有节点...")
        for m in MACHINES:
            try:
                with RemoteNode(m, timeout=SSH_TIMEOUT) as n:
                    if not n.pgrep():
                        n.start()
            except:
                pass
        log("恢复完成（可能部分失败）")
