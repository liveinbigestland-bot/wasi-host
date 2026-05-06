#!/usr/bin/env python3
"""Targeted deployment: relay-server + encrypted relay wasi-host"""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES, RELAY_BINARY

def deploy_relay_server():
    """Upload and restart relay-server on 外2"""
    print("\n=== relay-server: 外2 (192.140.185.171) ===")
    m = MACHINES[0]  # 外2
    with RemoteNode(m) as n:
        n.connect(timeout=15)
        # Upload binary
        print("  Uploading relay-server binary...")
        n.upload_relay()

        # Upload config
        print("  Uploading relay-server config...")
        n.upload_relay_config()

        # Kill old relay-server
        print("  Stopping old relay-server...")
        n.stop_relay()
        time.sleep(2)

        # Start new relay-server
        relay_pid = n.start_relay()
        if relay_pid:
            print(f"  relay-server started: PID={relay_pid}")
            # Check port
            if n.check_port(20809):
                print("  Port 20809: LISTENING")
            return True
        else:
            print("  relay-server FAILED to start!")
            return False

def deploy_wasi_host(m):
    """Upload new wasi-host binary + config and restart one node"""
    name = m['name']
    print(f"\n=== {name} ({m['host']}) ===")
    try:
        with RemoteNode(m) as n:
            n.connect(timeout=15)
            # Current PID
            pids = n.pgrep()
            print(f"  Current PID: {pids}")

            # Upload binary
            print(f"  Uploading binary ({m['arch']})...")
            n.upload_binary()

            # Upload config
            print(f"  Uploading config...")
            n.upload_config()

            # Stop old process
            print(f"  Stopping...")
            n.stop()
            time.sleep(2)

            # Start new process
            pid = n.start()
            if pid:
                print(f"  Started: PID={pid}")
                time.sleep(3)
                logs = n.grep_log('encrypted_relay|relay.*connect|chord.*stabilize|本机', 5)
                if logs:
                    print(f"  Logs: {logs.strip()[-300:]}")
                return True
            else:
                print(f"  FAILED to start!")
                return False
    except Exception as e:
        print(f"  ERROR: {e}")
        return False

print("=" * 55)
print("  Deploy: encrypted relay integration")
print("=" * 55)
print(f"  relay-server binary: {RELAY_BINARY}")
print(f"  relay-server exists: {os.path.exists(RELAY_BINARY)}")

# Step 1: Deploy relay-server to 外2
ok = deploy_relay_server()
if not ok:
    print("  relay-server deployment failed, aborting!")
    sys.exit(1)

# Step 2: Deploy wasi-host to 外2 (also needs new binary)
deploy_wasi_host(MACHINES[0])

# Wait for 外2 to stabilize
print("\n  Waiting 5s for 外2...")
time.sleep(5)

# Step 3: Deploy wasi-host to ARM nodes + ext
for m in MACHINES[1:]:
    deploy_wasi_host(m)
    time.sleep(3)

print("\n=== Done ===")
