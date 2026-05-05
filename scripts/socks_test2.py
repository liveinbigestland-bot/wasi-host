import paramiko

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('192.168.2.59', username='root', password='ecoo1234', timeout=10)

# Write and run test for example.com
sftp = ssh.open_sftp()
f = sftp.open('/tmp/stest2.py', 'w')
f.write("""import socket
s=socket.socket()
s.settimeout(15)
s.connect(('127.0.0.1',1080))
print('OK: connected')
s.sendall(b'\\x05\\x01\\x00')
r=s.recv(2)
print('OK: auth', r.hex())
host=b'example.com'
s.sendall(b'\\x05\\x01\\x00\\x03'+bytes([len(host)])+host+b'\\x00\\x50')
r=s.recv(10)
print('OK: connect', r.hex())
if r[1]==0:
    s.sendall(b'GET / HTTP/1.0\\r\\nHost: example.com\\r\\n\\r\\n')
    import time
    time.sleep(1)
    data=s.recv(8192)
    print('OK: response', len(data), 'bytes')
    print(data[:300].decode(errors='replace'))
else:
    print('FAIL: code', r[1])
s.close()
""")
f.close()
sftp.close()

stdin, stdout, stderr = ssh.exec_command('python3 /tmp/stest2.py 2>&1')
print(stdout.read().decode())

ssh.close()
