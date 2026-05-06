#!/usr/bin/env python3
"""Check encrypted relay + ring status after single-reader fix deploy"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

print("=== Encrypted relay check ===")
time.sleep(10)  # Wait for stabilization

for m in MACHINES:
    if m['arch'] != 'arm':
        continue
    with RemoteNode(m) as n:
        n.connect(timeout=10)
        ec, out, err = n.exec(
            f"grep -a 'encrypted_relay' {m['remote_log']} 2>/dev/null | tail -10",
            timeout=5,
        )
        print(f"\n{m['name']}:")
        for l in out.strip().split('\n'):
            l = l.strip()
            if l:
                print(f"  {l}")

print("\n=== Ring status ===")
for m in MACHINES:
    with RemoteNode(m) as n:
        n.connect(timeout=10)
        ec, out, err = n.exec(
            f"grep -a 'successor\\|predecessor\\|finger\\|ring\\|join' {m['remote_log']} 2>/dev/null | tail -5",
            timeout=5,
        )
        print(f"\n{m['name']}:")
        for l in out.strip().split('\n'):
            l = l.strip()
            if l:
                print(f"  {l}")
