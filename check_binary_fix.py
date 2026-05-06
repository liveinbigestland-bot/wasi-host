#!/usr/bin/env python3
"""Check deployed binary for fix symbols"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

m = MACHINES[0]
with RemoteNode(m) as n:
    n.connect(timeout=10)

    # Check for unregisterIfFdMatches string in binary
    ec, out, err = n.exec("strings /root/relay-server | grep -i 'unregisterIfFd\\|safeClose' | head -10", timeout=10)
    print(f"Fix symbols in binary: {out.strip()}")

    # Check for line 460
    ec, out, err = n.exec("strings /root/relay-server | grep -i 'last_heartbeat' | head -5", timeout=10)
    print(f"Session field: {out.strip()}")

    # Check binary size
    ec, out, err = n.exec("stat /root/relay-server 2>&1 | head -3", timeout=5)
    print(f"Binary: {out.strip()}")

    # Check the relay-server log for crash AFTER fix
    ec, out, err = n.exec("tail -30 /root/relay-server.log 2>/dev/null", timeout=5)
    print(f"Log:\n{out.strip()}")
