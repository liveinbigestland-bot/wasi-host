import paramiko, socket, time

test_code = """import socket, struct, time
s = socket.socket()
s.settimeout(10)
try:
    s.connect(("192.140.185.171", 8356))
    print("TCP connected")
    key = b"192.168.2.59:19999"
    reg = bytes([0, len(key)]) + key
    s.sendall(reg)
    print("REGISTER sent")
    s.sendall(bytes([8]))
    print("PING sent")
    data = s.recv(1)
    print("Received:", data.hex())
    time.sleep(2)
    s.sendall(bytes([8]))
    print("PING2 sent")
    data = s.recv(1)
    print("Received2:", data.hex())
    s.close()
    print("OK")
except Exception as e:
    print("FAIL:", e)
"""

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('192.168.2.59', username='root', password='ecoo1234', timeout=10)

sftp = ssh.open_sftp()
f = sftp.open('/tmp/relay_test.py', 'w')
f.write(test_code)
f.close()
sftp.close()

stdin, stdout, stderr = ssh.exec_command('python3 /tmp/relay_test.py 2>&1')
print(stdout.read().decode())

ssh.close()
