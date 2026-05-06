#!/usr/bin/env python3
"""Check relay-server status and log right now"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

m = MACHINES[0]
with RemoteNode(m) as n:
    n.connect(timeout=10)

    # Is relay-server running?
    ec, out, err = n.exec("pgrep -a relay-server || echo NOT_RUNNING", timeout=5)
    print(f"Process: {out.strip()}")

    # Is port 20809 listening?
    ec, out, err = n.exec("ss -tlnp | grep 20809 || echo 'NOT LISTENING'", timeout=5)
    print(f"Port 20809: {out.strip()[:200]}")

    # Relay-server log tail
    ec, out, err = n.exec("tail -30 /root/relay-server.log 2>/dev/null || echo 'no log'", timeout=5)
    print(f"Log:\n{out.strip()}")

    # Test local TCP
    ec, out, err = n.exec("timeout 3 bash -c \"echo test | nc -q 0 127.0.0.1 20809\" 2>&1 || true", timeout=10)
    print(f"Local test: {out.strip()[:200]}")

    # binary timestamp
    ec, out, err = n.exec("stat /root/relay-server 2>&1 | head -3", timeout=5)
    print(f"Binary: {out.strip()}")
