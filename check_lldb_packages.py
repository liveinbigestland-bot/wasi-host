#!/usr/bin/env python3
"""Check available lldb packages"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

m = [x for x in MACHINES if x['name'] == '外2'][0]
with RemoteNode(m) as n:
    n.connect(timeout=15)
    ec, out, err = n.exec(
        "apt-cache search lldb-server 2>&1; echo '==='; "
        "apt-cache search '^lldb-' 2>&1; echo '==='; "
        "apt-cache search lldb 2>&1 | grep -v lib | head -20",
        timeout=30,
    )
    print(out[:1000] if out else '(empty)')

print()

m2 = [x for x in MACHINES if x['name'] == 'node59'][0]
with RemoteNode(m2) as n:
    n.connect(timeout=15)
    ec, out, err = n.exec(
        "apt-cache search lldb-server 2>&1; echo '==='; "
        "apt-cache search '^lldb-' 2>&1; echo '==='; "
        "apt-cache search lldb 2>&1 | grep -v lib | head -20",
        timeout=30,
    )
    print(out[:1000] if out else '(empty)')
