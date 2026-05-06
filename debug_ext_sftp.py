#!/usr/bin/env python3
"""Debug ext SFTP upload failure"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

m = [m for m in MACHINES if m['name'] == 'ext'][0]
print(f"Debugging ext: {m['host']}")
print(f"Binary: {m['arch']} -> {__import__('deploy').BINARIES[m['arch']]}")

with RemoteNode(m) as n:
    n.connect(timeout=15)

    # Check disk space
    print("\n=== Disk space ===")
    ec, out, err = n.exec("df -h /home 2>&1 || df -h / 2>&1", timeout=5)
    print(f"stdout: {out}")
    print(f"stderr: {err}")

    # Check /tmp
    print("\n=== /tmp ===")
    ec, out, err = n.exec("ls -la /tmp/ 2>&1 | head -10", timeout=5)
    print(f"stdout: {out}")

    # Try a simple SFTP upload
    print("\n=== SFTP test ===")
    from paramiko import SFTPClient
    sftp = n.client.open_sftp()
    try:
        test_file = os.path.join(os.path.dirname(__file__), 'check_binaries.py')
        remote_path = "/tmp/sftp-test-upload"
        print(f"Uploading {test_file} -> {remote_path}")
        sftp.put(test_file, remote_path)
        print("SFTP upload OK!")
        # Check file
        ec, out, err = n.exec(f"ls -la {remote_path}", timeout=5)
        print(f"Remote file: {out}")
        # Cleanup
        n.exec(f"rm -f {remote_path}", timeout=5)
    except Exception as e:
        print(f"SFTP error: {e}")
        # Try alternative
        print("Trying alternative upload method...")
        sftp = n.client.open_sftp()
        try:
            sftp.putfo(open(test_file, 'rb'), "/tmp/sftp-test-putfo")
            print("putfo worked!")
        except Exception as e2:
            print(f"putfo also failed: {e2}")
    finally:
        sftp.close()
