import paramiko, socket, base64, struct, json

ssh2 = paramiko.SSHClient()
ssh2.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh2.connect('192.140.185.171', username='root', password='aetej1AzIQpE', timeout=10)

script = r"""
python3 << 'PYEOF'
import socket, base64, struct, json

s = socket.socket()
s.settimeout(5)
s.connect(("185.31.41.85", 443))

key = base64.b64encode(b"1234567890123456").decode()
handshake = (
    "GET /chord HTTP/1.1\r\n"
    "Host: 185.31.41.85\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n"
    "Sec-WebSocket-Key: " + key + "\r\n"
    "Sec-WebSocket-Version: 13\r\n"
    "\r\n"
)
s.sendall(handshake.encode())
print("WS handshake sent")
resp = s.recv(4096)
print("resp:", resp.decode(errors='replace')[:300])

# Send chord ping over WebSocket
msg = json.dumps({"ping":{}}).encode()
frame = bytearray()
frame.append(0x82)  # binary frame, FIN
if len(msg) < 126:
    frame.extend(struct.pack(">B", len(msg)))
else:
    frame.extend(struct.pack(">BH", 126, len(msg)))
frame.extend(msg)
s.sendall(bytes(frame))
print("WS data sent", len(frame), "bytes")

try:
    data = s.recv(4096)
    print("WS recv:", data)
except Exception as e:
    print("recv err:", e)
s.close()
PYEOF
"""

stdin, stdout, stderr = ssh2.exec_command(script)
out = stdout.read().decode()
err = stderr.read().decode()
print("OUT:", out)
if err:
    print("ERR:", err)

ssh2.close()
