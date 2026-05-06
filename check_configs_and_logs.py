#!/usr/bin/env python3
"""Check remote configs and full logs for encrypted relay"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

# Check 外2 + node59 + node60
for name in ['外2', 'node59', 'node60']:
    m = [m for m in MACHINES if m['name'] == name][0]
    print(f"\n=== {name} ===")
    try:
        with RemoteNode(m) as n:
            n.connect(timeout=10)

            # Check config for encrypted_relay section
            ec, out, err = n.exec(f"grep -a 'encrypted_relay' {m['remote_config']} 2>/dev/null || echo 'NOT FOUND'", timeout=5)
            print(f"  Config encrypted_relay: {out.strip()[:100]}")

            # Grep for ANY encrypted_relay log message (from startup)
            ec, out, err = n.exec(f"grep -a 'encrypted_relay' {m['remote_log']} 2>/dev/null | head -10", timeout=5)
            if out.strip():
                print(f"  Log messages:")
                for l in out.split('\n'):
                    print(f"    {l.strip()}")
            else:
                print(f"  No encrypted_relay in log")
                # Check log start
                ec, out, err = n.exec(f"head -30 {m['remote_log']} 2>/dev/null", timeout=5)
                if out.strip():
                    print(f"  Log start:")
                    for l in out.split('\n'):
                        print(f"    {l.strip()}")
    except Exception as e:
        print(f"  ERROR: {e}")
