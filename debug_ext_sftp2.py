#!/usr/bin/env python3
"""Debug ext binary upload"""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
import deploy
from deploy import RemoteNode, MACHINES

m = [m for m in MACHINES if m['name'] == 'ext'][0]
binary_path = deploy.BINARIES[m['arch']]
print(f"Binary path: {binary_path}")
print(f"Binary size: {os.path.getsize(binary_path)}")
print(f"Remote bin: {m['remote_bin']}")

with RemoteNode(m) as n:
    n.connect(timeout=15)

    # Check disk from home dir
    print("\n=== Disk (from home) ===")
    ec, out, err = n.exec("df -h . 2>&1", timeout=5)
    print(f"df -h .: {out}")

    print("\n=== Disk (from /) ===")
    ec, out, err = n.exec("df -h 2>&1", timeout=5)
    print(f"df -h:\n{out}")

    # Check home disk quota
    print("\n=== Quota ===")
    ec, out, err = n.exec("quota 2>&1 || quota -u metaai 2>&1 || echo 'no quota cmd'", timeout=5)
    print(f"quota: {out}")

    # check if /home/metaai is a symlink
    print("\n=== home ===")
    ec, out, err = n.exec("ls -la /home/metaai/ 2>&1 | head -5", timeout=5)
    print(f"home: {out}")

    # Try uploading the actual binary to /tmp
    print(f"\n=== Upload binary to /tmp ===")
    sftp = n.client.open_sftp()
    try:
        sftp.put(binary_path, "/tmp/wasi-host-deploy")
        print("Upload to /tmp OK!")
        ec, out, err = n.exec("ls -la /tmp/wasi-host-deploy", timeout=5)
        print(f"Remote: {out}")
    except Exception as e:
        print(f"Upload to /tmp FAILED: {e}")
    finally:
        sftp.close()

    # Check SFTP root
    print("\n=== SFTP to /home/metaai directly ===")
    sftp = n.client.open_sftp()
    try:
        sftp.stat("/home/metaai/")
        print("stat /home/metaai/ OK")
    except Exception as e:
        print(f"stat /home/metaai/ FAILED: {e}")

    try:
        sftp.put(binary_path, "/tmp/wasi-host-deploy-test")
        print("put binary to /tmp/wasi-host-deploy-test OK")
        ec, out, err = n.exec("rm -f /tmp/wasi-host-deploy-test", timeout=5)
    except Exception as e:
        print(f"put FAILED: {e}")
    finally:
        sftp.close()
