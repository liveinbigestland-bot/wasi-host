#!/usr/bin/env python3
"""Install lldb on remote nodes"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

# 外2: lldb-20
m = [x for x in MACHINES if x['name'] == '外2'][0]
print(f"=== {m['name']} — install lldb-20 ===")
with RemoteNode(m) as n:
    n.connect(timeout=15)
    ec, out, err = n.exec(
        "DEBIAN_FRONTEND=noninteractive apt-get install -y lldb-20 2>&1 | tail -15",
        timeout=180,
    )
    print(out[-500:] if out else '(empty)')
    if err:
        print("ERR:", err[-300:])
    ec, out, err = n.exec("which lldb-server-20 && lldb-server-20 --version 2>&1 || (which lldb-server-20 2>&1; ls /usr/lib/llvm-20/bin/lldb-server* 2>/dev/null)", timeout=10)
    print(out[:300])

# node59: try without proxy
m2 = [x for x in MACHINES if x['name'] == 'node59'][0]
print(f"\n=== {m2['name']} — install lldb-12 ===")
with RemoteNode(m2) as n:
    n.connect(timeout=15)
    ec, out, err = n.exec(
        "DEBIAN_FRONTEND=noninteractive apt-get install -y lldb-12 2>&1 | tail -15",
        timeout=180,
    )
    print(out[-500:] if out else '(empty)')
    if err:
        print("ERR:", err[-300:])
    ec, out, err = n.exec("which lldb-server-12 && lldb-server-12 --version 2>&1 || (ls /usr/lib/llvm-12/bin/lldb-server* 2>/dev/null; which lldb-server 2>&1)", timeout=10)
    print(out[:300])
