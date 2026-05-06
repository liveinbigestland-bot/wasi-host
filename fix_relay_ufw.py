#!/usr/bin/env python3
"""Fix UFW and restart relay-server on 外2"""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

m = MACHINES[0]
print(f"=== Fix UFW + relay-server on {m['name']} ===")

with RemoteNode(m) as n:
    n.connect(timeout=10)

    # Check port 20809 in UFW
    ec, out, err = n.exec("ufw status | grep 20809 || echo 'NOT IN UFW'", timeout=5)
    print(f"UFW 20809: {out.strip()}")

    # Add UFW rule for 20809
    print("Adding UFW rule for 20809/tcp...")
    ec, out, err = n.exec("ufw allow 20809/tcp 2>&1", timeout=5)
    print(f"  ufw allow: {out.strip()}")
    ec, out, err = n.exec("ufw allow 20809/udp 2>&1", timeout=5)
    print(f"  ufw allow udp: {out.strip()}")

    # Verify
    ec, out, err = n.exec("ufw status | grep 20809", timeout=5)
    print(f"  UFW check: {out.strip()}")

    # Check relay-server status
    ec, out, err = n.exec("pgrep -f relay-server || echo 'NOT RUNNING'", timeout=5)
    print(f"Relay-server: {out.strip()}")

    # If not running, start it
    if 'NOT RUNNING' in out:
        print("Relay-server not running, starting...")
        pid = n.start_relay()
        print(f"  PID: {pid}")
    else:
        print("Relay-server is running, checking if 20809 is listening...")
        ec, out, err = n.exec("ss -tlnp | grep 20809 || echo 'NOT LISTENING'", timeout=5)
        print(f"  {out.strip()}")
        if 'NOT LISTENING' in out:
            print("  Port not listening, restarting relay-server...")
            n.stop_relay()
            time.sleep(1)
            pid = n.start_relay()
            print(f"  PID: {pid}")

    # Final check
    time.sleep(2)
    ec, out, err = n.exec("ss -tlnp | grep 20809 || echo 'NOT LISTENING'", timeout=5)
    print(f"Final port check: {out.strip()[:200]}")

print("\n=== Done ===")
