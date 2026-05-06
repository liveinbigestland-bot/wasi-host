#!/usr/bin/env python3
"""Check logs for encrypted relay messages"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

for m in MACHINES:
    print(f"\n=== {m['name']} ({m['host']}) ===")
    try:
        with RemoteNode(m) as n:
            n.connect(timeout=10)

            # Check for encrypted_relay in log
            ec, out, err = n.exec(
                f"grep -aE 'encrypted_relay|EncryptedRelay|sendAndWait.*relay|CRYPT' {m['remote_log']} 2>/dev/null | tail -20",
                timeout=5,
            )
            if out.strip():
                print(f"  Encrypted relay logs:")
                for line in out.split('\n'):
                    print(f"    {line}")
            else:
                print("  No encrypted_relay messages found")

            # Show recent log lines
            ec, out, err = n.exec(f"tail -20 {m['remote_log']} 2>/dev/null", timeout=5)
            if out.strip():
                print(f"  Recent logs:")
                for line in out.split('\n'):
                    print(f"    {line}")
    except Exception as e:
        print(f"  ERROR: {e}")
