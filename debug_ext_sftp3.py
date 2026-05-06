#!/usr/bin/env python3
"""Debug SFTP upload in detail"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
import deploy
from deploy import RemoteNode, MACHINES

m = [m for m in MACHINES if m['name'] == 'ext'][0]
binary_path = deploy.BINARIES[m['arch']]

with RemoteNode(m) as n:
    n.connect(timeout=15)

    # Check what's in /tmp
    ec, out, err = n.exec("ls -la /tmp/wasi-host-deploy 2>&1 || echo 'NO FILE'", timeout=5)
    print(f"Before rm: {out}")

    # Remove
    ec, out, err = n.exec("rm -f /tmp/wasi-host-deploy && echo 'OK'", timeout=5)
    print(f"rm result: {out}")

    ec, out, err = n.exec("ls -la /tmp/wasi-host-deploy 2>&1 || echo 'NO FILE'", timeout=5)
    print(f"After rm: {out}")

    # Try sftp
    print("\nTrying sftp.put() again...")
    sftp = n.client.open_sftp()
    try:
        sftp.put(binary_path, "/tmp/wasi-host-deploy")
        print("SUCCESS!")
        ec, out, err = n.exec("ls -la /tmp/wasi-host-deploy 2>&1", timeout=5)
        print(f"Remote file: {out}")
    except Exception as e:
        print(f"FAILED: {e}")
        # Try with putfo
        print("\nTrying putfo...")
        try:
            with open(binary_path, 'rb') as f:
                sftp.putfo(f, "/tmp/wasi-host-deploy-putfo")
                print("putfo SUCCESS!")
        except Exception as e2:
            print(f"putfo FAILED: {e2}")

        # Try with a different name
        print("\nTrying unique name...")
        try:
            sftp.put(binary_path, "/tmp/wasi-host-deploy-new")
            print("Unique name SUCCESS!")
        except Exception as e3:
            print(f"Unique name FAILED: {e3}")
    finally:
        sftp.close()

    # Try rsync/scp instead
    print("\nTrying SCP...")
    try:
        from paramiko import SSHClient
        from scp import SCPClient
        # paramiko might not have scp built in
        print("scp not available")
    except:
        print("no scp module")

    # Try base64 transfer
    print("\nTrying base64 pipe...")
    import base64
    with open(binary_path, 'rb') as f:
        data = f.read()
    b64 = base64.b64encode(data).decode()
    print(f"Binary base64 size: {len(b64)} chars")
    # Upload in chunks
    ec, out, err = n.exec("base64 -d > /tmp/wasi-host-deploy-b64 < /dev/null 2>&1 || echo 'no base64'", timeout=5)
    if 'no base64' in out:
        # Try with python
        ec, out, err = n.exec("python3 -c 'import sys; sys.stdout.write(\"test\")' 2>&1", timeout=5)
        print(f"Python available: {out}")

    # Try using python on remote to write file
    print("\nTrying python remote write...")
    chunk = b64[:1000]
    escaped = chunk.replace("'", "'\\''")
    ec, out, err = n.exec(f"python3 -c \"import base64; open('/tmp/wasi-host-deploy-py', 'wb').write(base64.b64decode('{escaped}'))\" 2>&1", timeout=10)
    print(f"Python write result: {out}")
    ec, out, err = n.exec("ls -la /tmp/wasi-host-deploy-py 2>&1", timeout=5)
    print(f"Python file: {out}")
