import paramiko

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('192.168.2.59', username='root', password='ecoo1234', timeout=10)

sftp = ssh.open_sftp()
f = sftp.open('/tmp/stest_baidu.py', 'w')
f.write("""import socket
s=socket.socket()
s.settimeout(15)
s.connect(('127.0.0.1',1080))
print('OK: connected')
s.sendall(b'\\x05\\x01\\x00')
r=s.recv(2)
print('OK: auth', r.hex())
host=b'www.baidu.com'
s.sendall(b'\\x05\\x01\\x00\\x03'+bytes([len(host)])+host+b'\\x00\\x50')
r=s.recv(10)
print('OK: connect', r.hex())
if r[1]==0:
    s.sendall(b'GET / HTTP/1.0\\r\\nHost: www.baidu.com\\r\\n\\r\\n')
    import time
    time.sleep(2)
    s.settimeout(5)
    all_data=b''
    while True:
        try:
            d=s.recv(8192)
            if not d: break
            all_data+=d
        except: break
    print('OK: response', len(all_data), 'bytes')
    print(all_data[:500].decode(errors='replace'))
else:
    print('FAIL: code', r[1])
s.close()
""")
f.close()
sftp.close()

stdin, stdout, stderr = ssh.exec_command('python3 /tmp/stest_baidu.py 2>&1')
print(stdout.read().decode())

ssh.close()
