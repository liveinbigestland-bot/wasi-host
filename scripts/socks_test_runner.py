import paramiko, socket, struct, json

# Write test script
test_script = """import socket, struct

def test_socks():
    s = socket.socket()
    s.settimeout(10)
    try:
        s.connect(("127.0.0.1", 1080))
        print("OK: connected")

        # SOCKS5 handshake
        s.sendall(b"\\x05\\x01\\x00")
        resp = s.recv(2)
        print("OK: auth resp", resp.hex())

        # CONNECT www.google.com:80
        host = b"www.google.com"
        req = b"\\x05\\x01\\x00\\x03" + bytes([len(host)]) + host + b"\\x00\\x50"
        s.sendall(req)
        resp = s.recv(10)
        print("OK: connect resp", resp.hex())

        if resp[1] == 0x00:
            s.sendall(b"GET / HTTP/1.0\\r\\nHost: www.google.com\\r\\n\\r\\n")
            data = s.recv(4096)
            print("OK: HTTP response", len(data), "bytes")
            print(data[:300].decode(errors="replace"))
        else:
            print("FAIL: connect error code", resp[1])
    except Exception as e:
        print("FAIL:", type(e).__name__, str(e)[:100])
    finally:
        s.close()

test_socks()
"""

with open(r'D:\claudework\stest_remote.py', 'w') as f:
    f.write(test_script)

# Upload to node59
ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('192.168.2.59', username='root', password='ecoo1234', timeout=10)
sftp = ssh.open_sftp()
sftp.put(r'D:\claudework\stest_remote.py', '/tmp/stest.py')
sftp.close()

stdin, stdout, stderr = ssh.exec_command('python3 /tmp/stest.py 2>&1')
print(stdout.read().decode())
ssh.close()
