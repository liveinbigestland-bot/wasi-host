#!/usr/bin/env python3
"""Check logs for encrypted relay after config fix, wait for startup"""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

time.sleep(5)  # Wait for nodes to initialize

for m in MACHINES:
    print(f"\n=== {m['name']} ({m['host']}) ===")
    try:
        with RemoteNode(m) as n:
            n.connect(timeout=10)

            # Check config first
            ec, out, err = n.exec(f"grep -c 'encrypted_relay' {m['remote_config']} 2>/dev/null || echo 0", timeout=5)
            print(f"  Config has encrypted_relay: {out.strip()}")

            # Full log for encrypted_relay
            ec, out, err = n.exec(f"grep -a 'encrypted_relay\\|EncryptedRelay\\|CRYPT' {m['remote_log']} 2>/dev/null | head -20", timeout=5)
            if out.strip():
                for l in out.split('\n'):
                    print(f"  {l.strip()}")
            else:
                print("  No encrypted_relay in log")
                # Check the beginning of the log for init sequence
                ec, out, err = n.exec(f"head -40 {m['remote_log']} 2>/dev/null", timeout=5)
                print(f"  Log start:")
                for l in out.split('\n'):
                    if 'encrypt' in l.lower() or 'relay' in l.lower() or 'p2p' in l.lower() or 'chord' in l.lower():
                        print(f"    {l.strip()}")

            # Check if binary has the string
            ec, out, err = n.exec(f"strings {m['remote_bin']} | grep -c 'encrypted_relay' 2>/dev/null || echo 0", timeout=10)
            print(f"  Binary has 'encrypted_relay': {out.strip()}")
    except Exception as e:
        print(f"  ERROR: {e}")
