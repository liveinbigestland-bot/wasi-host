#!/usr/bin/env python3
"""Test encrypted relay connectivity and verify integration"""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

# Restart ARM nodes and 外2 to trigger encrypted relay reconnection
# (The adapters have error.AllRelaysFailed cached, need restart)
targets = ['外2', 'node59', 'node60']

# First check if encrypted relay log shows anything new since restarting relay-server
for m_name in targets:
    m = [m for m in MACHINES if m['name'] == m_name][0]
    print(f"\n=== {m_name} encrypted_relay status ===")
    with RemoteNode(m) as n:
        n.connect(timeout=10)
        ec, out, err = n.exec(f"grep -a 'encrypted_relay' {m['remote_log']} 2>/dev/null | tail -10", timeout=5)
        if out.strip():
            for l in out.split('\n'):
                print(f"  {l.strip()}")
        else:
            print("  No encrypted_relay messages")

# Restart 外2 and ARM nodes to re-initialize encrypted relay
print("\n\n=== Restarting nodes to re-init encrypted relay ===")
for m in MACHINES:
    if m['name'] not in targets:
        continue
    print(f"\n  {m['name']}: restarting...")
    with RemoteNode(m) as n:
        n.connect(timeout=15)
        n.stop()
        time.sleep(2)
        pid = n.start()
        if pid:
            print(f"  Started PID={pid}")
        else:
            print(f"  FAILED")

# Restart relay-server (killed by 外2 restart)
time.sleep(2)
print("\n  relay-server: restarting...")
with RemoteNode(MACHINES[0]) as n:
    n.connect(timeout=10)
    pid = n.start_relay()
    print(f"  Started PID={pid}")

# Wait for init
time.sleep(10)

# Check encrypted relay logs
print("\n\n=== Checking encrypted relay after restart ===")
for m_name in targets:
    m = [m for m in MACHINES if m['name'] == m_name][0]
    print(f"\n  {m_name}:")
    with RemoteNode(m) as n:
        n.connect(timeout=10)
        ec, out, err = n.exec(f"grep -a 'encrypted_relay\\|relay2' {m['remote_log']} 2>/dev/null | tail -10", timeout=5)
        if out.strip():
            for l in out.split('\n'):
                print(f"    {l.strip()}")
        else:
            print("    (none)")

# Final status
print("\n\n=== Final status ===")
import subprocess
subprocess.run(["python3", "wasi-host/deploy.py", "status"], cwd="D:/claudework")
