#!/usr/bin/env python3
"""Restart relay-server on 外2"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

m = MACHINES[0]  # 外2
print(f"=== Restart relay-server on {m['name']} ===")

with RemoteNode(m) as n:
    n.connect(timeout=10)
    # Check relay binary exists
    ec, out, err = n.exec("ls -la /root/relay-server", timeout=5)
    print(f"Binary: {out}")

    # Start relay-server
    pid = n.start_relay()
    if pid:
        print(f"relay-server PID={pid}")
        ok = n.check_port(20809)
        print(f"Port 20809: {'LISTENING' if ok else 'NOT LISTENING'}")
    else:
        print("FAILED to start relay-server!")
        sys.exit(1)

print("=== Done ===")
