#!/usr/bin/env python3
"""Check for crashes and relay-server health"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

print("=== Relay-server health ===")
relay = [m for m in MACHINES if m['name'] == '外2'][0]
with RemoteNode(relay) as n:
    n.connect(timeout=10)
    ec, out, err = n.exec("pgrep -f relay-server || echo CRASHED", timeout=5)
    print(f"Running: {'YES' if 'CRASHED' not in out else 'NO'}")
    ec, out, err = n.exec("ss -tlnp | grep 20809 || echo NOT_LISTENING", timeout=5)
    print(f"Port 20809: {out.strip()[:200]}")
    ec, out, err = n.exec("grep -aE 'panic|Segmentation|CRASH' /root/relay-server.log 2>/dev/null | tail -5 || echo none", timeout=5)
    print(f"Errors: {out.strip()[:300] if out else 'none'}")

print("\n=== All nodes crash check ===")
for m in MACHINES:
    with RemoteNode(m) as n:
        n.connect(timeout=10)
        ec, out, err = n.exec(
            f"grep -aE 'panic|Segmentation|CRASH|Error|FATAL' {m['remote_log']} 2>/dev/null | tail -5",
            timeout=5,
        )
        crashes = [l.strip() for l in out.split('\n') if l.strip()]
        print(f"{m['name']}: {'OK' if not crashes else 'CRASHES: ' + '; '.join(crashes[:3])}")
