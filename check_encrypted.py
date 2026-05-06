#!/usr/bin/env python3
"""Check encrypted relay usage and ring health"""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

# Check ARM nodes for encrypted relay usage
print("=== ARM node encrypted relay logs ===")
for name in ['node59', 'node60']:
    m = [m2 for m2 in MACHINES if m2['name'] == name][0]
    print(f"\n  {name}:")
    with RemoteNode(m) as n:
        n.connect(timeout=10)
        ec, out, err = n.exec("grep -a 'encrypted_relay' {} | tail -10".format(m['remote_log']), timeout=5)
        for l in out.strip().split('\n'):
            l = l.strip()
            if l:
                print(f"    {l}")

# Check for encrypted relay sendAndWait usage
print("\n=== Encrypted relay in Chord traffic ===")
for name in ['node59', 'node60']:
    m = [m2 for m2 in MACHINES if m2['name'] == name][0]
    print(f"\n  {name}:")
    with RemoteNode(m) as n:
        n.connect(timeout=10)
        ec, out, err = n.exec("grep -a 'encrypted relay' {} | tail -10".format(m['remote_log']), timeout=5)
        for l in out.strip().split('\n'):
            l = l.strip()
            if l:
                print(f"    {l}")

# Check relay-server log
print("\n=== Relay-server log ===")
m = MACHINES[0]
with RemoteNode(m) as n:
    n.connect(timeout=10)
    ec, out, err = n.exec("tail -30 /root/relay-server.log", timeout=5)
    for l in out.strip().split('\n'):
        l = l.strip()
        if l:
            print(f"  {l}")

# Ring status
print("\n=== Ring status ===")
import subprocess
subprocess.run(["python", "deploy.py", "status"], cwd="wasi-host")
