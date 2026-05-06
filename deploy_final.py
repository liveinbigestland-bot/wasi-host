#!/usr/bin/env python3
"""Deploy fixed relay-server, restart ARM nodes, verify encrypted relay"""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

# 1. Deploy fixed relay-server
print("=== Step 1: Fixed relay-server ===")
m = MACHINES[0]
with RemoteNode(m) as n:
    n.connect(timeout=10)
    # Upload new binary
    remote_tmp = "/tmp/relay-server-deploy"
    sftp = n.client.open_sftp()
    sftp.put(
        os.path.join(os.path.dirname(__file__), 'wasi-host/zig-out/bin/relay-server-x86_64'),
        remote_tmp
    )
    sftp.close()
    n.exec(
        f"rm -f /root/relay-server && cp {remote_tmp} /root/relay-server"
        f" && chmod +x /root/relay-server && rm -f {remote_tmp}",
        timeout=10,
    )
    print("  Binary uploaded")

    # Kill old and start
    n.stop_relay()
    time.sleep(1)
    pid = n.start_relay()
    print(f"  PID={pid}")
    time.sleep(2)
    ec, out, err = n.exec("ss -tlnp | grep 20809 || echo 'NOT LISTENING'", timeout=5)
    print(f"  Port 20809: {out.strip()[:200]}")

# Verify relay-server stays up
time.sleep(5)
with RemoteNode(m) as n:
    n.connect(timeout=10)
    ec, out, err = n.exec("pgrep -f relay-server || echo CRASHED", timeout=5)
    print(f"  After 5s: {out.strip()}")
    ec, out, err = n.exec("grep -a 'panic' /root/relay-server.log 2>/dev/null | tail -3 || echo no panic", timeout=5)
    print(f"  Panics: {out.strip()[:200]}")

# 2. Restart ARM nodes
print("\n=== Step 2: Restart ARM nodes ===")
for name in ['node59', 'node60']:
    m = [m for m in MACHINES if m['name'] == name][0]
    print(f"  {name}: ", end="", flush=True)
    with RemoteNode(m) as n:
        n.connect(timeout=15)
        n.stop()
        time.sleep(2)
        pid = n.start()
        print(f"PID={pid}")

# 3. Wait and check
time.sleep(10)
print("\n=== Step 3: Encrypted relay status ===")
for name in ['node59', 'node60']:
    m = [m for m in MACHINES if m['name'] == name][0]
    print(f"  {name}:")
    with RemoteNode(m) as n:
        n.connect(timeout=10)
        ec, out, err = n.exec(f"grep -a 'encrypted_relay' {m['remote_log']} 2>/dev/null | head -5", timeout=5)
        for l in out.strip().split('\n'):
            print(f"    {l.strip()}")

# 4. Status
print("\n=== Final status ===")
import subprocess
subprocess.run(["python3", "wasi-host/deploy.py", "status"], cwd="D:/claudework")
