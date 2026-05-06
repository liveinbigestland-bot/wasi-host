#!/usr/bin/env python3
"""Deploy new binaries and restart nodes"""
import sys, os, time
sys.path.insert(0, 'wasi-host')
from deploy import RemoteNode, MACHINES

def upload_and_restart(m):
    """Upload binary + config, then restart wasi-host"""
    name = m['name']
    print(f"\n=== {name} ({m['host']}) ===")
    try:
        with RemoteNode(m, timeout=15) as n:
            # Check current PID
            pids = n.pgrep()
            print(f"  Current PID: {pids}")

            # Upload config first (has encrypted_relay section)
            print(f"  Uploading config: {m['config']}")
            remote_tmp = "/tmp/config-deploy.json"
            sftp = n.client.open_sftp()
            sftp.put(m['config'], remote_tmp)
            sftp.close()
            n.exec(f"rm -f {m['remote_config']} && cp {remote_tmp} {m['remote_config']}"
                   f" && rm -f {remote_tmp}", timeout=10)
            print(f"  Config uploaded to {m['remote_config']}")

            # Upload binary
            print(f"  Uploading binary ({m['arch']})...")
            remote_tmp = "/tmp/wasi-host-deploy"
            sftp = n.client.open_sftp()
            sftp.put(BINARIES[m['arch']], remote_tmp)
            sftp.close()
            n.exec(f"rm -f {m['remote_bin']} && cp {remote_tmp} {m['remote_bin']}"
                   f" && chmod +x {m['remote_bin']} && rm -f {remote_tmp}", timeout=10)
            print(f"  Binary uploaded to {m['remote_bin']}")

            # Kill old process and start new one
            print("  Restarting...")
            n.stop()
            time.sleep(2)
            new_pid = n.start()
            print(f"  New PID: {new_pid}")
            return True
    except Exception as e:
        print(f"  ERROR: {e}")
        return False

# Target nodes: node59, node60, 外2
print("=" * 55)
print("  Deploy encrypted relay integration")
print("=" * 55)

# ARM nodes (node59, node60)
arm_nodes = [m for m in MACHINES if m['name'] in ('node59', 'node60')]
for m in arm_nodes:
    upload_and_restart(m)

# Also update 外2 with new wasi-host binary
ext2 = [m for m in MACHINES if '外2' in m['name']]
for m in ext2:
    upload_and_restart(m)

print("\n=== Done ===")
