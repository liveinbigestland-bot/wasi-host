#!/usr/bin/env python3
"""Check encrypted relay traffic after full fix deployment"""
import sys, os, time, subprocess
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

print("Waiting 45s for ring stabilize + encrypted relay traffic...")
time.sleep(45)

print("\n=== Relay-server health ===")
m = MACHINES[0]
with RemoteNode(m) as n:
    n.connect(timeout=10)
    ec, out, err = n.exec("pgrep -f relay-server || echo CRASHED", timeout=5)
    print(f"Running: {'YES' if 'CRASHED' not in out else 'NO'}")
    ec, out, err = n.exec("ss -tlnp | grep 20809 || echo NOT_LISTENING", timeout=5)
    print(f"Port: {out.strip()[:200]}")
    ec, out, err = n.exec("grep -aE 'panic|Segmentation|Error' /root/relay-server.log 2>/dev/null | tail -5 || echo none", timeout=5)
    print(f"Errors: {out.strip()[:300]}")
    ec, out, err = n.exec("grep -a 'encrypted_relay' /root/relay-server.log 2>/dev/null | tail -20", timeout=5)
    for l in out.strip().split('\n'):
        l = l.strip()
        if l: print(f"  Relay: {l}")

print("\n=== Encrypted relay init ===")
for name in ['node59', 'node60']:
    m2 = [m2 for m2 in MACHINES if m2['name'] == name][0]
    print(f"\n  {name}:")
    with RemoteNode(m2) as n:
        n.connect(timeout=10)
        ec, out, err = n.exec("grep -a 'encrypted_relay' {} | tail -10".format(m2['remote_log']), timeout=5)
        for l in out.strip().split('\n'):
            l = l.strip()
            if l: print(f"    {l}")

print("\n=== Encrypted relay sendAndWait results ===")
for name in ['node59', 'node60']:
    m2 = [m2 for m2 in MACHINES if m2['name'] == name][0]
    print(f"\n  {name}:")
    with RemoteNode(m2) as n:
        n.connect(timeout=10)
        ec, out, err = n.exec("grep -a 'encrypted relay' {} | tail -20".format(m2['remote_log']), timeout=5)
        for l in out.strip().split('\n'):
            l = l.strip()
            if l: print(f"    {l}")

print("\n=== Ring test ===")
subprocess.run(["python", "deploy.py", "test"], cwd="wasi-host")
