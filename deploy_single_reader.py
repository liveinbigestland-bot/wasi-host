#!/usr/bin/env python3
"""Deploy single-reader fix to ARM nodes"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, BINARIES, MACHINES

arm_nodes = [m for m in MACHINES if m['arch'] == 'arm']

# Verify binary
arm_bin = BINARIES['arm']
size = os.path.getsize(arm_bin)
print(f"ARM binary: {size} bytes")

for m in arm_nodes:
    name = m['name']
    print(f"\n--- {name} ---")
    with RemoteNode(m) as n:
        n.connect(timeout=15)

        # Stop
        print(f"  Stopping {name}...")
        pids = n.pgrep()
        if pids:
            print(f"  Running PIDs: {pids}")
        n.kill_all()
        time.sleep(1)
        pids = n.pgrep()
        if pids:
            print(f"  WARNING: still running: {pids}")

        # Upload binary
        print(f"  Uploading binary...")
        n.upload_binary()

        # Verify binary
        ec, out, err = n.exec(f"ls -la {m['remote_bin']}", timeout=5)
        print(f"  Deployed: {out.strip()}")

        # Start
        print(f"  Starting...")
        pid = n.start()
        print(f"  PID={pid}")
        time.sleep(2)

        # Check log for encrypted relay
        ec, out, err = n.exec(f"grep -a 'encrypted_relay' {m['remote_log']} 2>/dev/null | head -5", timeout=5)
        for l in out.strip().split('\n'):
            l = l.strip()
            if l:
                print(f"  LOG: {l}")

        # Verify running
        pids = n.pgrep()
        print(f"  Running: {pids}")

print("\n=== All ARM nodes deployed ===")
