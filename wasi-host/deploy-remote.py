#!/usr/bin/env python3
"""【已弃用】请使用 deploy.py 替代

用法:
  python deploy.py [deploy|test|cleanup|status|logs|check-stale|inspect]

远程 Chord DHT 节点部署与自动化测试。

用法:
  python deploy-remote.py              # 部署并启动所有节点
  python deploy-remote.py test         # 部署 + 启动 + 验证 stabilize
  python deploy-remote.py cleanup      # 清理远程进程

目标机器配置 (从 REMOTE-DEPLOY.md):
  内网2 (192.168.2.60) — armv7l Ubuntu
  内网1 (192.168.2.59) — armv7l Ubuntu
  外网 (ssh-metaai.alwaysdata.net) — x86_64 Debian
"""

import paramiko
import time
import sys
import os

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
BINARIES = {
    "arm": os.path.join(PROJECT_DIR, "zig-out", "bin", "wasi-host-arm-v5"),
    "x86_64": os.path.join(PROJECT_DIR, "zig-out", "bin", "wasi-host-x86_64"),
}

CONFIGS = {
    "59": os.path.join(PROJECT_DIR, "config-remote-node59.json"),
    "60": os.path.join(PROJECT_DIR, "config-remote-node60.json"),
    "ext": os.path.join(PROJECT_DIR, "config-ext-server.json"),
    "ext2": os.path.join(PROJECT_DIR, "config-ext-node2.json"),
}

MACHINES = [
    {
        "name": "内网1 (59)",
        "host": "192.168.2.59",
        "port": 22,
        "user": "root",
        "password": "ecoo1234",
        "binary": BINARIES["arm"],
        "remote_bin": "/root/wasi-host",
        "config": CONFIGS["59"],
        "remote_config": "/root/config-remote-node59.json",
        "remote_log": "/root/test-remote-node59.log",
    },
    {
        "name": "内网2 (60)",
        "host": "192.168.2.60",
        "port": 22,
        "user": "root",
        "password": "ecoo1234",
        "binary": BINARIES["arm"],
        "remote_bin": "/root/wasi-host",
        "config": CONFIGS["60"],
        "remote_config": "/root/config-remote-node60.json",
        "remote_log": "/root/test-remote-node60.log",
    },
    {
        "name": "外网",
        "host": "ssh-metaai.alwaysdata.net",
        "port": 22,
        "user": "metaai",
        "password": "1qaz@WSXasdfasdf",
        "binary": BINARIES["x86_64"],
        "remote_bin": "/home/metaai/wasi-host",
        "config": CONFIGS["ext"],
        "remote_config": "/home/metaai/config-ext-server.json",
        "remote_log": "/home/metaai/test-ext-server.log",
    },
    {
        "name": "外2",
        "host": "192.140.185.171",
        "port": 22,
        "user": "root",
        "password": "aetej1AzIQpE",
        "binary": BINARIES["x86_64"],
        "remote_bin": "/root/wasi-host",
        "config": CONFIGS["ext2"],
        "remote_config": "/root/config-ext-node2.json",
        "remote_log": "/root/test-ext-node2.log",
    },
]


class RemoteDeployer:
    def __init__(self, machine):
        self.m = machine
        self.client = None

    def connect(self):
        print(f"  SSH 连接 {self.m['name']} ({self.m['host']})...")
        self.client = paramiko.SSHClient()
        self.client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self.client.connect(
            self.m["host"],
            port=self.m["port"],
            username=self.m["user"],
            password=self.m["password"],
            timeout=10,
        )
        print(f"  [OK] 已连接")

    def close(self):
        if self.client:
            self.client.close()

    def exec(self, cmd, timeout=10):
        _, stdout, stderr = self.client.exec_command(cmd, timeout=timeout)
        exit_code = stdout.channel.recv_exit_status()
        out = stdout.read().decode("utf-8", errors="replace").strip()
        err = stderr.read().decode("utf-8", errors="replace").strip()
        return exit_code, out, err

    def deploy_binary(self):
        print(f"  上传 binary...")
        # 使用 /tmp 中转解决某些机器 /root/ SFTP 直接写入失败问题
        remote_tmp = "/tmp/wasi-host-deploy"
        sftp = self.client.open_sftp()
        sftp.put(self.m["binary"], remote_tmp)
        sftp.close()
        self.exec(f"cp {remote_tmp} {self.m['remote_bin']} && chmod +x {self.m['remote_bin']} && rm -f {remote_tmp}")
        print(f"  [OK] binary 已部署")

    def deploy_config(self):
        print(f"  上传 config...")
        remote_tmp = "/tmp/config-remote-deploy.json"
        sftp = self.client.open_sftp()
        sftp.put(self.m["config"], remote_tmp)
        sftp.close()
        self.exec(f"cp {remote_tmp} {self.m['remote_config']} && rm -f {remote_tmp}")
        print(f"  [OK] config 已部署")

    def start_node(self):
        print(f"  启动 wasi-host...")
        # Kill existing process first
        self.exec(f"pkill -f wasi-host 2>/dev/null || true", timeout=5)
        time.sleep(1)
        # Start in background with nohup
        cmd = f"nohup {self.m['remote_bin']} {self.m['remote_config']} > {self.m['remote_log']} 2>&1 &"
        self.exec(cmd, timeout=5)
        time.sleep(2)
        # Verify process started
        _, out, _ = self.exec("pgrep -f wasi-host || echo 'NOT_RUNNING'", timeout=5)
        if "NOT_RUNNING" in out:
            print(f"  [WARN]  wasi-host 可能未启动")
            print(f"  检查日志: {self.m['remote_log']}")
        else:
            print(f"  [OK] wasi-host PID={out.split(chr(10))[0]}")

    def stop_node(self):
        print(f"  停止 wasi-host...")
        self.exec(f"pkill -f wasi-host 2>/dev/null || true", timeout=5)
        print(f"  [OK] 已停止")

    def deploy_bridge(self):
        print(f"  上传 ws-bridge.py...")
        remote_tmp = "/tmp/ws-bridge-deploy.py"
        sftp = self.client.open_sftp()
        sftp.put(BRIDGE_SCRIPT, remote_tmp)
        sftp.close()
        self.exec(f"cp {remote_tmp} {self.m['remote_bridge_script']} && chmod +x {self.m['remote_bridge_script']} && rm -f {remote_tmp}")
        print(f"  [OK] ws-bridge.py 已部署")

    def start_bridge(self):
        print(f"  启动 ws-bridge (WebSocket 桥接)...")
        self.exec(f"pkill -f ws-bridge.py 2>/dev/null || true", timeout=5)
        time.sleep(1)
        cmd = f"nohup python3 {self.m['remote_bridge_script']} > {self.m['remote_bridge_log']} 2>&1 &"
        self.exec(cmd, timeout=5)
        time.sleep(3)
        _, out, _ = self.exec("pgrep -f ws-bridge.py || echo 'NOT_RUNNING'", timeout=5)
        if "NOT_RUNNING" in out:
            print(f"  [WARN] ws-bridge 可能未启动")
            self.exec(f"tail -5 {self.m['remote_bridge_log']}", timeout=5)
        else:
            print(f"  [OK] ws-bridge PID={out.split(chr(10))[0]}")

    def stop_bridge(self):
        print(f"  停止 ws-bridge...")
        self.exec(f"pkill -f ws-bridge.py 2>/dev/null || true", timeout=5)
        print(f"  [OK] ws-bridge 已停止")

    def check_logs(self, grep_pattern, tail=5):
        _, out, _ = self.exec(f"grep -a '{grep_pattern}' {self.m['remote_log']} | tail -{tail}", timeout=5)
        return out

    def print_logs(self, tail=20):
        _, out, _ = self.exec(f"tail -{tail} {self.m['remote_log']}", timeout=5)
        print(f"  📋 日志 (tail {tail}):")
        for line in out.split("\n"):
            print(f"    {line}")

    def wait_stabilize(self, seconds=30):
        print(f"  等待 stabilize {seconds}s...")
        time.sleep(seconds)

    def show_routing_state(self):
        print(f"\n  === 路由状态 ({self.m['name']}) ===")
        for pattern in ["后继:", "前驱:", "finger"]:
            result = self.check_logs(pattern, 3)
            if result:
                for line in result.split("\n")[:3]:
                    print(f"    {line}")
            else:
                print(f"    未找到 `{pattern}` 日志")


def deploy_all():
    print("=" * 60)
    print("远程 Chord DHT 节点部署")
    print("=" * 60)
    print()

    seed_host = "192.168.2.210"
    seed_port = 20808

    # Ensure binaries exist
    for arch, path in BINARIES.items():
        if not os.path.exists(path):
            print(f"[ERR] 二进制文件未找到: {path}")
            sys.exit(1)

    # 先部署外网机器（ProxyServer + wasi-host）
    ext_machine = MACHINES[2]  # 外网
    print(f"\n--- 1/4 部署外网机器 {ext_machine['name']} ({ext_machine['host']}) ---")
    print("    先启动外网 ProxyServer + wasi-host")
    ext_deployer = RemoteDeployer(ext_machine)
    try:
        ext_deployer.connect()
        ext_deployer.deploy_binary()
        ext_deployer.deploy_config()
        ext_deployer.start_node()
        print(f"  [OK] 外网 wasi-host + ProxyServer 已启动")
    except Exception as e:
        print(f"  [ERR] 外网部署失败: {e}")
    finally:
        ext_deployer.close()

    # 等待外网 ProxyServer 就绪
    print(f"\n  等待外网服务器就绪 (5s)...")
    time.sleep(5)

    # 再部署内网节点（ProxyClient 模式 + WebSocket 桥接）
    for m in MACHINES[:2]:  # node59, node60
        print(f"\n--- 2/4 部署 {m['name']} ({m['host']}) ---")
        deployer = RemoteDeployer(m)
        try:
            deployer.connect()
            deployer.deploy_binary()
            deployer.deploy_config()
            deployer.start_node()
        except Exception as e:
            print(f"  [ERR] 失败: {e}")
        finally:
            deployer.close()

    # 部署外2节点 (独立 VPS)
    ext2_machine = MACHINES[3]
    print(f"\n--- 3/4 部署 {ext2_machine['name']} ({ext2_machine['host']}) ---")
    ext2_deployer = RemoteDeployer(ext2_machine)
    try:
        ext2_deployer.connect()
        ext2_deployer.deploy_binary()
        ext2_deployer.deploy_config()
        ext2_deployer.start_node()
        print(f"  [OK] 外2 wasi-host 已启动")
    except Exception as e:
        print(f"  [ERR] 外2 部署失败: {e}")
    finally:
        ext2_deployer.close()

    print()
    print("=" * 60)
    print("部署完成！请在本机启动种子节点（带代理客户端）:")
    print(f"  cd wasi-host")
    print(f"  ./wasi-host config-remote-seed.json")
    print()
    print("然后运行验证:")
    print(f"  python deploy-remote.py test")
    print("=" * 60)


def test_all():
    print("=" * 60)
    print("Chord DHT 远程组网验证")
    print("=" * 60)
    print(f"种子节点: 192.168.2.210:20808")

    for m in MACHINES:
        deployer = RemoteDeployer(m)
        try:
            deployer.connect()
            deployer.wait_stabilize(5)
            deployer.show_routing_state()
        except Exception as e:
            print(f"  [ERR] 连接失败: {e}")
        finally:
            deployer.close()

    print()
    print("=" * 60)

    # Cross-check: verify remote predecessor matches seed
    print("\n--- 交叉验证 ---")
    for m in MACHINES:
        deployer = RemoteDeployer(m)
        try:
            deployer.connect()
            succ = deployer.check_logs("后继:", 1)
            pred = deployer.check_logs("前驱:", 1)
            print(f"  {m['name']}:")
            for line in succ.split("\n")[:1]:
                print(f"    {line}")
            for line in pred.split("\n")[:1]:
                print(f"    {line}")
        except Exception as e:
            print(f"  [ERR]: {e}")
        finally:
            deployer.close()


def cleanup_all():
    print("=" * 60)
    print("清理远程节点")
    print("=" * 60)
    for m in MACHINES:
        print(f"\n--- 清理 {m['name']} ---")
        deployer = RemoteDeployer(m)
        try:
            deployer.connect()
            deployer.stop_node()
        except Exception as e:
            print(f"  [ERR]: {e}")
        finally:
            deployer.close()


def show_status():
    print("=" * 60)
    print("远程节点状态")
    print("=" * 60)
    for m in MACHINES:
        deployer = RemoteDeployer(m)
        try:
            deployer.connect()
            _, out, _ = deployer.exec("pgrep -f wasi-host || echo 'STOPPED'", timeout=5)
            status = out.strip()
            print(f"  {m['name']} ({m['host']}): {'运行中 PID=' + status if status != 'STOPPED' else '已停止'}")
        except Exception as e:
            print(f"  {m['name']} ({m['host']}): [ERR] 无法连接 ({e})")
        finally:
            deployer.close()


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "deploy"
    if mode == "deploy":
        deploy_all()
    elif mode == "test":
        test_all()
    elif mode == "cleanup":
        cleanup_all()
    elif mode == "status":
        show_status()
    else:
        print(f"用法: python deploy-remote.py [deploy|test|cleanup|status]")
        sys.exit(1)
