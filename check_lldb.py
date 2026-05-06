#!/usr/bin/env python3
"""Check lldb/lldb-server availability on remote nodes"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

targets = ['外2', 'node59']
for m in [x for x in MACHINES if x['name'] in targets]:
    print(f"=== {m['name']} ({m['host']}) ===")
    with RemoteNode(m) as n:
        n.connect(timeout=15)
        ec, out, err = n.exec("which lldb-server lldb-server-14 lldb-server-18 gdbserver 2>&1; echo '---'; uname -m; echo '---'; cat /etc/os-release 2>/dev/null | head -3; echo '---'; dpkg -l 2>/dev/null | grep -i 'lldb\\|llvm' | head -5; echo '---'; apt list --installed 2>/dev/null | grep -i lldb | head -5", timeout=15)
        print(out[:800] if out else '(empty)')
        if err:
            print("STDERR:", err[:300])
    print()
