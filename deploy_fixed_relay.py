#!/usr/bin/env python3
"""Deploy fixed relay-server, then restart all nodes for encrypted relay"""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

print("=== Step 1: Deploy fixed relay-server ===")
m = MACHINES[0]  # 外2
with RemoteNode(m) as n:
    n.connect(timeout=10)
    n.upload_relay()
    n.upload_relay_config()
    n.stop_relay()
    time.sleep(1)
    relay_pid = n.start_relay()
    print(f"  relay-server PID={relay_pid}")
    time.sleep(2)
    ec, out, err = n.exec("ss -tlnp | grep 20809 || echo 'NOT LISTENING'", timeout=5)
    print(f"  Port 20809: {out.strip()[:200]}")

# Now restart ARM nodes so encrypted relay connects
print("\n=== Step 2: Restart ARM nodes ===")
for name in ['node59', 'node60']:
    m = [m for m in MACHINES if m['name'] == name][0]
    print(f"\n  {name}:")
    with RemoteNode(m) as n:
        n.connect(timeout=15)
        print(f"  Stopping...")
        n.stop()
        time.sleep(2)
        pid = n.start()
        print(f"  PID={pid}")

# Wait for init
print("\n  Waiting 8s for init...")
time.sleep(8)

# Check
print("\n=== Step 3: Check encrypted relay ===")
for name in ['node59', 'node60']:
    m = [m for m in MACHINES if m['name'] == name][0]
    print(f"\n  {name}:")
    with RemoteNode(m) as n:
        n.connect(timeout=10)
        ec, out, err = n.exec(f"grep -a 'encrypted_relay' {m['remote_log']} 2>/dev/null | head -10", timeout=5)
        if out.strip():
            for l in out.split('\n'):
                print(f"    {l.strip()}")
        else:
            print("    (none)")

# Final status
print("\n=== Final status ===")
import subprocess
subprocess.run(["python3", "wasi-host/deploy.py", "status"], cwd="D:/claudework")
