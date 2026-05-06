#!/usr/bin/env python3
"""Check if forward fix works - look for encrypted relay success after stabilization"""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

print("Waiting 30s for ring to stabilize...")
time.sleep(30)

print("\n=== ARM node encrypted relay traffic ===")
for name in ['node59', 'node60']:
    m = [m2 for m2 in MACHINES if m2['name'] == name][0]
    print(f"\n  {name}:")
    with RemoteNode(m) as n:
        n.connect(timeout=10)
        # Check for encrypted relay success AND failures
        ec, out, err = n.exec("grep -a 'encrypted relay' {} | tail -20".format(m['remote_log']), timeout=5)
        for l in out.strip().split('\n'):
            l = l.strip()
            if l:
                print(f"    {l}")

print("\n=== Relay-server log ===")
m = MACHINES[0]
with RemoteNode(m) as n:
    n.connect(timeout=10)
    ec, out, err = n.exec("tail -30 /root/relay-server.log", timeout=5)
    for l in out.strip().split('\n'):
        l = l.strip()
        if l:
            print(f"  {l}")

print("\n=== Ring health ===")
import subprocess
subprocess.run(["python", "deploy.py", "status"], cwd="wasi-host")
print("\n=== Ring test ===")
subprocess.run(["python", "deploy.py", "test"], cwd="wasi-host")
