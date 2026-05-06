#!/usr/bin/env python3
"""Deploy stable relay-server, verify no crash, then restart ARM nodes"""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

def upload_binary(n, local_path, remote_path):
    """Upload binary via /tmp"""
    remote_tmp = "/tmp/relay-server-deploy"
    sftp = n.client.open_sftp()
    sftp.put(local_path, remote_tmp)
    sftp.close()
    n.exec(
        f"rm -f {remote_path} && cp {remote_tmp} {remote_path}"
        f" && chmod +x {remote_path} && rm -f {remote_tmp}",
        timeout=10,
    )

relay_local = os.path.join(os.path.dirname(__file__), 'wasi-host/zig-out/bin/relay-server-x86_64')
relay_size = os.path.getsize(relay_local)
print(f"relay-server binary: {relay_size} bytes")

# Step 1: Upload and start relay-server
print("\n=== Step 1: Deploy relay-server ===")
m = MACHINES[0]
with RemoteNode(m) as n:
    n.connect(timeout=10)

    # Upload
    upload_binary(n, relay_local, "/root/relay-server")
    print("  Binary uploaded")

    # Stop old
    n.stop_relay()
    time.sleep(1)

    # Start new
    pid = n.start_relay()
    print(f"  PID={pid}")
    time.sleep(2)

    # Verify listening
    ec, out, err = n.exec("ss -tlnp | grep 20809 || echo 'NOT LISTENING'", timeout=5)
    ok = 'LISTEN' in out
    print(f"  Port 20809: {'LISTENING' if ok else 'NOT LISTENING'}")

# Step 2: Wait and verify relay-server doesn't crash
print("\n=== Step 2: Stability check (20s) ===")
for i in range(4):
    time.sleep(5)
    with RemoteNode(m) as n:
        n.connect(timeout=10)
        ec, out, err = n.exec("pgrep -f relay-server || echo CRASHED", timeout=5)
        running = 'CRASHED' not in out
        ec2, out2, err2 = n.exec("ss -tlnp | grep 20809 || echo 'NOT LISTENING'", timeout=5)
        listening = 'LISTEN' in out2
        ec3, out3, err3 = n.exec("grep -a 'panic' /root/relay-server.log 2>/dev/null | tail -1 || echo none", timeout=5)
        panic = 'none' not in out3.lower() and out3.strip() != ''
        print(f"  +{5*(i+1)}s: running={running} listening={listening} panic={'YES' if panic else 'no'}")

# Step 3: Restart ARM nodes
print("\n=== Step 3: Restart ARM nodes ===")
for name in ['node59', 'node60']:
    m2 = [m2 for m2 in MACHINES if m2['name'] == name][0]
    print(f"  {name}: ", end="", flush=True)
    with RemoteNode(m2) as n:
        n.connect(timeout=15)
        n.stop()
        time.sleep(2)
        pid = n.start()
        print(f"PID={pid}")

# Step 4: Verify encrypted relay
time.sleep(10)
print("\n=== Step 4: Encrypted relay status ===")
for name in ['node59', 'node60']:
    m2 = [m2 for m2 in MACHINES if m2['name'] == name][0]
    print(f"  {name}:")
    with RemoteNode(m2) as n:
        n.connect(timeout=10)
        ec, out, err = n.exec(f"grep -a 'encrypted_relay' {m2['remote_log']} 2>/dev/null | head -10", timeout=5)
        for l in out.strip().split('\n'):
            l = l.strip()
            if l:
                print(f"    {l}")

# Step 5: Final relay stability check
print("\n=== Step 5: Relay-server after ARM restart ===")
with RemoteNode(m) as n:
    n.connect(timeout=10)
    ec, out, err = n.exec("pgrep -f relay-server || echo CRASHED", timeout=5)
    print(f"  Running: {'YES' if 'CRASHED' not in out else 'NO'}")
    ec, out, err = n.exec("ss -tlnp | grep 20809 || echo 'NOT LISTENING'", timeout=5)
    print(f"  Port 20809: {'LISTENING' if 'LISTEN' in out else 'NOT LISTENING'}")
    ec, out, err = n.exec("grep -a 'panic\\|Segmentation' /root/relay-server.log 2>/dev/null | tail -3 || echo none", timeout=5)
    print(f"  Errors: {out.strip()[:200]}")

print("\n=== Done ===")
