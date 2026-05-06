#!/usr/bin/env python3
"""Final verification after encrypted relay fix"""
import sys, os, subprocess
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

print("=== Ring health ===")
subprocess.run(["python", "deploy.py", "status"], cwd="wasi-host")

print("\n=== Ring test ===")
subprocess.run(["python", "deploy.py", "test"], cwd="wasi-host")

print("\n=== Relay-server log ===")
m = MACHINES[0]
with RemoteNode(m) as n:
    n.connect(timeout=10)
    ec, out, err = n.exec("tail -15 /root/relay-server.log", timeout=5)
    for l in out.strip().split('\n'):
        l = l.strip()
        if l:
            print(f"  {l}")

print("\n=== Encrypted relay summary ===")
for name in ['node59', 'node60']:
    m2 = [m2 for m2 in MACHINES if m2['name'] == name][0]
    with RemoteNode(m2) as n:
        n.connect(timeout=10)
        ec, out, err = n.exec("grep -c 'encrypted relay ok' {}".format(m2['remote_log']), timeout=5)
        ec2, out2, err2 = n.exec("grep -c 'encrypted relay send err' {}".format(m2['remote_log']), timeout=5)
        ok_count = out.strip()
        err_count = out2.strip()
        print(f"  {name}: ok={ok_count}  err={err_count}")
