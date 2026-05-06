#!/usr/bin/env python3
"""Test TCP connectivity from ARM nodes to relay-server:20809"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

for name in ['node59', 'node60']:
    m = [m for m in MACHINES if m['name'] == name][0]
    print(f"=== {name} → 外2:20809 ===")
    try:
        with RemoteNode(m) as n:
            n.connect(timeout=15)
            ec, out, err = n.exec('timeout 5 bash -c "echo test > /dev/tcp/192.140.185.171/20809 && echo OK" 2>&1 || echo FAIL', timeout=10)
            print(f"  {out.strip()}")
    except Exception as e:
        print(f"  ERROR: {e}")
