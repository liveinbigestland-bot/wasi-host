#!/usr/bin/env python3
"""Check relay-server crash details"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

m = MACHINES[0]
with RemoteNode(m) as n:
    n.connect(timeout=10)

    # Check if relay-server is running NOW
    ec, out, err = n.exec("pgrep -f relay-server || echo NONE", timeout=5)
    print(f"Relay-server now: {out.strip()}")

    ec, out, err = n.exec("ss -tlnp | grep 20809 || echo NONE", timeout=5)
    print(f"Port 20809: {out.strip()[:200]}")

    # Full log for panics
    ec, out, err = n.exec("grep -a 'panic\\|unreachable\\|close' /root/relay-server.log 2>/dev/null | tail -20", timeout=5)
    print(f"Panics/close errors:\n{out.strip()}")

    # Full log
    ec, out, err = n.exec("tail -40 /root/relay-server.log 2>/dev/null", timeout=5)
    print(f"Full log tail:\n{out.strip()}")

    # Count restarts
    ec, out, err = n.exec("grep -c 'relay2.*监听\\|relay2.*listen' /root/relay-server.log 2>/dev/null || echo 0", timeout=5)
    print(f"Server start count: {out.strip()}")
