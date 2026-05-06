#!/usr/bin/env python3
"""Deploy fully fixed relay-server and verify encrypted relay"""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

relay_local = os.path.join(os.path.dirname(__file__), 'wasi-host/zig-out/bin/relay-server-x86_64')
print(f"Binary: {os.path.getsize(relay_local)} bytes")

m = MACHINES[0]
with RemoteNode(m) as n:
    n.connect(timeout=10)
    # Upload relay-server
    remote_tmp = "/tmp/relay-server-deploy"
    sftp = n.client.open_sftp()
    sftp.put(relay_local, remote_tmp)
    sftp.close()
    n.exec("rm -f /root/relay-server && cp {} /root/relay-server && chmod +x /root/relay-server && rm -f {}".format(remote_tmp, remote_tmp), timeout=10)
    # Also stop old wasi-hostd supervisor that auto-restarts the old binary
    n.exec("pkill -f wasi-hostd 2>/dev/null || true", timeout=5)
    time.sleep(1)
    # Kill old relay-server
    n.stop_relay()
    time.sleep(1)
    # Start new
    pid = n.start_relay()
    print(f"relay-server PID={pid}")
    time.sleep(2)
    ec, out, err = n.exec("ss -tlnp | grep 20809 || echo NOT_LISTENING", timeout=5)
    print(f"Port 20809: {out.strip()[:200]}")

# Restart ARM nodes
for name in ['node59', 'node60']:
    m2 = [m2 for m2 in MACHINES if m2['name'] == name][0]
    print(f"\nRestarting {name}...")
    with RemoteNode(m2) as n:
        n.connect(timeout=15)
        n.stop()
        time.sleep(2)
        pid = n.start()
        print(f"  PID={pid}")

# Wait for stabilization
print("\nWaiting 15s...")
time.sleep(15)

# Check encrypted relay
print("\n=== Encrypted relay check ===")
for name in ['node59', 'node60']:
    m2 = [m2 for m2 in MACHINES if m2['name'] == name][0]
    print(f"\n  {name}:")
    with RemoteNode(m2) as n:
        n.connect(timeout=10)
        ec, out, err = n.exec("grep -a 'encrypted_relay' {} 2>/dev/null | head -10".format(m2['remote_log']), timeout=5)
        for l in out.strip().split('\n'):
            l = l.strip()
            if l:
                print(f"    {l}")

# Check relay-server is still running
print("\n=== Relay-server health ===")
with RemoteNode(m) as n:
    n.connect(timeout=10)
    ec, out, err = n.exec("pgrep -f relay-server || echo CRASHED", timeout=5)
    print(f"Running: {'YES' if 'CRASHED' not in out else 'NO'}")
    ec, out, err = n.exec("ss -tlnp | grep 20809 || echo NOT_LISTENING", timeout=5)
    print(f"Port: {out.strip()[:200]}")
    ec, out, err = n.exec("grep -aE 'panic|Segmentation' /root/relay-server.log 2>/dev/null | tail -3 || echo none", timeout=5)
    print(f"Errors: {out.strip()[:300]}")

# Status
print("\n=== Status ===")
import subprocess
subprocess.run(["python3", "wasi-host/deploy.py", "status"], cwd="D:/claudework")
