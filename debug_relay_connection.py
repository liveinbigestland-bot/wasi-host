#!/usr/bin/env python3
"""Debug relay-server connectivity"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

# Check 外2 relay-server
m = MACHINES[0]
print(f"=== 外2 relay-server ===")
with RemoteNode(m) as n:
    n.connect(timeout=10)

    # UFW status
    ec, out, err = n.exec("ufw status 2>/dev/null | head -20 || echo 'no ufw'", timeout=5)
    print(f"UFW:\n{out}")

    # Check port 20809
    ec, out, err = n.exec("ss -tlnp | grep 20809", timeout=5)
    print(f"Port 20809: {out}")

    # Check relay-server log
    ec, out, err = n.exec("tail -30 /root/relay-server.log 2>/dev/null || echo 'no log'", timeout=5)
    print(f"Relay-server log:\n{out}")

    # Test connectivity from 外2 itself to 127.0.0.1:20809
    ec, out, err = n.exec("timeout 3 bash -c 'echo test | nc -q 0 127.0.0.1 20809' 2>&1 || echo 'nc exit: '$?", timeout=5)
    print(f"Local connect test: {out.strip()[:200]}")

    # netstat for 20809
    ec, out, err = n.exec("netstat -tlnp 2>/dev/null | grep 20809 || ss -tlnp | grep 20809", timeout=5)
    print(f"netstat/ss: {out[:200]}")

# Check node59 relay connectivity
print(f"\n=== node59 connectivity to 外2:20809 ===")
m = [m for m in MACHINES if m['name'] == 'node59'][0]
with RemoteNode(m) as n:
    n.connect(timeout=15)
    # Test TCP connection to relay-server
    ec, out, err = n.exec("timeout 5 bash -c 'echo test > /dev/tcp/192.140.185.171/20809 && echo OK' 2>&1 || echo 'bash tcp failed'", timeout=10)
    print(f"TCP test: {out.strip()[:200]}")

    # DNS resolution
    ec, out, err = n.exec("nslookup 192.140.185.171 2>/dev/null | head -5 || host 192.140.185.171 2>/dev/null || echo 'no dns tools'", timeout=5)
    print(f"DNS: {out.strip()[:200]}")

    # Try nc
    ec, out, err = n.exec("nc -zv -w 3 192.140.185.171 20809 2>&1 || echo 'nc failed'", timeout=10)
    print(f"nc test: {out.strip()[:200]}")
