#!/usr/bin/env python3
"""Deploy wasi-host to ext using putfo (which works)"""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
import deploy
from deploy import RemoteNode, MACHINES

m = [m for m in MACHINES if m['name'] == 'ext'][0]
binary_path = deploy.BINARIES[m['arch']]
print(f"=== ext ({m['host']}) ===")
print(f"Binary: {binary_path} ({os.path.getsize(binary_path)} bytes)")

with RemoteNode(m) as n:
    n.connect(timeout=15)

    # Current state
    pids = n.pgrep()
    print(f"Current PID: {pids}")

    # Remove the stale DIRECTORY at /tmp/wasi-host-deploy (rm -f won't work on dirs)
    print("Cleaning stale /tmp/wasi-host-deploy (directory)...")
    ec, out, err = n.exec("rm -rf /tmp/wasi-host-deploy && echo OK", timeout=5)
    print(f"  clean: {out.strip()}")

    # Use putfo (confirmed working) with a unique temp file name
    print("Uploading binary...")
    remote_tmp = "/tmp/wasi-host-deploy-new"
    sftp = n.client.open_sftp()
    with open(binary_path, 'rb') as f:
        sftp.putfo(f, remote_tmp)
    sftp.close()
    print(f"  uploaded to {remote_tmp}")

    # Copy to final location and clean up
    ec, out, err = n.exec(
        f"rm -f {m['remote_bin']} && cp {remote_tmp} {m['remote_bin']}"
        f" && chmod +x {m['remote_bin']} && rm -f {remote_tmp} && echo OK",
        timeout=10,
    )
    print(f"  install: {out.strip()}")

    # Upload config (using putfo too)
    print("Uploading config...")
    config_tmp = "/tmp/config-deploy-new.json"
    sftp = n.client.open_sftp()
    with open(m['config'], 'rb') as f:
        sftp.putfo(f, config_tmp)
    sftp.close()
    ec, out, err = n.exec(
        f"rm -f {m['remote_config']} && cp {config_tmp} {m['remote_config']}"
        f" && rm -f {config_tmp} && echo OK",
        timeout=10,
    )
    print(f"  config: {out.strip()}")

    # Stop + Start
    print("Restarting...")
    n.stop()
    time.sleep(2)
    pid = n.start()
    if pid:
        print(f"Started: PID={pid}")
        time.sleep(3)
        logs = n.tail_log(10)
        print(f"Recent logs:\n{logs}")
    else:
        print("FAILED to start!")
        sys.exit(1)

print("\n=== Done ===")
