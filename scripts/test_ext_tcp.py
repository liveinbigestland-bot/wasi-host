import paramiko, socket, struct, json

ssh2 = paramiko.SSHClient()
ssh2.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh2.connect('192.140.185.171', username='root', password='aetej1AzIQpE', timeout=10)

# Send actual Chord TCP frame to ext:8400 via domain
script = r"""python3 -c '
import socket, struct, json
s = socket.socket()
s.settimeout(5)
s.connect(("ssh-metaai.alwaysdata.net", 8400))
print("connected to ext:8400 via domain!")
msg = json.dumps({"ping":{}}).encode()
frame = struct.pack(">I", len(msg)) + msg
s.sendall(frame)
print("sent frame", len(frame), "bytes")
try:
    hdr = s.recv(4)
    if len(hdr) == 4:
        rlen = struct.unpack(">I", hdr)[0]
        data = s.recv(min(rlen, 65536))
        print("resp:", data.decode())
    else:
        print("partial hdr:", len(hdr))
except Exception as e:
    print("recv err:", e)
s.close()
'
"""

stdin, stdout, stderr = ssh2.exec_command(script)
out = stdout.read().decode()
err = stderr.read().decode()
print("OUT:", out)
if err:
    print("ERR:", err)

ssh2.close()
