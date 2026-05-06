#!/usr/bin/env python3
"""Restart ARM nodes and check encrypted relay connection"""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

# Verify relay-server on 外2 is up first
print("=== Verify relay-server ===")
m = MACHINES[0]
with RemoteNode(m) as n:
    n.connect(timeout=10)
    ec, out, err = n.exec("ss -tlnp | grep 20809 || echo 'NOT LISTENING'", timeout=5)
    print(f"  外2 port 20809: {out.strip()[:200]}")

# Restart ARM nodes
for name in ['node59', 'node60']:
    m = [m for m in MACHINES if m['name'] == name][0]
    print(f"\n=== {name} ===")
    with RemoteNode(m) as n:
        n.connect(timeout=15)
        print(f"  Current PID: {n.pgrep()}")
        print(f"  Stopping...")
        n.stop()
        time.sleep(2)
        pid = n.start()
        if pid:
            print(f"  Started PID={pid}")
        else:
            print(f"  FAILED to start!")

# Wait for init
time.sleep(8)

# Check encrypted relay logs
print("\n=== Encrypted relay check ===")
for name in ['node59', 'node60', '外2']:
    m = [m for m in MACHINES if m['name'] == name][0]
    print(f"\n  {name}:")
    with RemoteNode(m) as n:
        n.connect(timeout=10)
        ec, out, err = n.exec(f"grep -a 'encrypted_relay' {m['remote_log']} 2>/dev/null | head -10", timeout=5)
        if out.strip():
            for l in out.split('\n'):
                print(f"    {l.strip()}")
        else:
            print(f"    (no encrypted_relay messages)")

# Relay-server might have been killed by 外2 restart
print("\n=== Relay-server check ===")
with RemoteNode(MACHINES[0]) as n:
    n.connect(timeout=10)
    ec, out, err = n.exec("ss -tlnp | grep 20809 || echo 'NOT LISTENING'", timeout=5)
    print(f"  外2 port 20809: {out.strip()[:200]}")
    if 'NOT LISTENING' in out:
        print("  Restarting relay-server...")
        pid = n.start_relay()
        print(f"  PID={pid}")
        time.sleep(3)
        ec, out, err = n.exec("ss -tlnp | grep 20809 || echo 'NOT LISTENING'", timeout=5)
        print(f"  After restart: {out.strip()[:200]}")

# Final status
print("\n=== Final status ===")
import subprocess
subprocess.run(["python3", "wasi-host/deploy.py", "status"], cwd="D:/claudework")
