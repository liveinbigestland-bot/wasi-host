import socket, struct, json, time

def send_msg(host, port, msg_dict):
    payload = json.dumps(msg_dict).encode()
    s = socket.socket()
    s.settimeout(10)
    s.connect((host, port))
    frame = struct.pack(">I", len(payload)) + payload
    s.sendall(frame)
    hdr = s.recv(4)
    if len(hdr) == 4:
        rlen = struct.unpack(">I", hdr)[0]
        resp = s.recv(rlen)
        s.close()
        return json.loads(resp.decode())
    s.close()

print("=== 1. dht_put (TCP:8444) ===")
resp = send_msg("127.0.0.1", 8444, {
    "dht_put": {"key": "test-key-001", "value": "Hello DHT!",
        "owner": "test-owner-pk", "permission": 2, "version": 0,
        "timestamp": int(time.time() * 1000)}
})
print(f"Response: {resp}")

print("\n=== 2. dht_get ===")
resp = send_msg("127.0.0.1", 8444, {"dht_get": {"key": "test-key-001"}})
print(f"Response: {resp}")
if resp and resp.get("dht_get_resp", {}).get("found"):
    r = resp["dht_get_resp"]
    print(f"  value: {r['value']}")
    print(f"  version: {r['version']}")

print("\n=== 3. dht_get (non-existent) ===")
resp = send_msg("127.0.0.1", 8444, {"dht_get": {"key": "non-existent-key"}})
print(f"Response: {resp}")

print("\n=== 4. dht_put (update) ===")
resp = send_msg("127.0.0.1", 8444, {
    "dht_put": {"key": "test-key-001", "value": "Updated Value v2",
        "owner": "test-owner-pk", "permission": 2, "version": 0,
        "timestamp": int(time.time() * 1000)}
})
print(f"Response: {resp}")

print("\n=== 5. dht_get (verify version) ===")
resp = send_msg("127.0.0.1", 8444, {"dht_get": {"key": "test-key-001"}})
if resp and resp.get("dht_get_resp", {}).get("found"):
    r = resp["dht_get_resp"]
    print(f"  value: {r['value']}")
    print(f"  version: {r['version']} (should be 2)")
