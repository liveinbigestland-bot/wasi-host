#!/usr/bin/env python3
"""Install lldb-server on remote nodes"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

# 外2: LLVM 20
m = [x for x in MACHINES if x['name'] == '外2'][0]
print(f"=== {m['name']} — install lldb-server ===")
with RemoteNode(m) as n:
    n.connect(timeout=15)
    ec, out, err = n.exec("apt-get update -qq && apt-get install -y -qq lldb-server-20 2>&1 | tail -10", timeout=120)
    print(out[-500:] if out else '')
    if err:
        print("ERR:", err[-300:])
    ec, out, err = n.exec("which lldb-server-20 && lldb-server-20 --version 2>&1 || echo FAILED", timeout=10)
    print(out[:300])

# node59: LLVM 12
m = [x for x in MACHINES if x['name'] == 'node59'][0]
print(f"\n=== {m['name']} — install lldb-server ===")
with RemoteNode(m) as n:
    n.connect(timeout=15)
    ec, out, err = n.exec("apt-get update -qq && apt-get install -y -qq lldb-server-12 2>&1 | tail -10", timeout=120)
    print(out[-500:] if out else '')
    if err:
        print("ERR:", err[-300:])
    ec, out, err = n.exec("which lldb-server-12 && lldb-server-12 --version 2>&1 || echo FAILED", timeout=10)
    print(out[:300])
