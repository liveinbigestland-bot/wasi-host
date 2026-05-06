#!/usr/bin/env python3
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

m = MACHINES[0]
with RemoteNode(m) as n:
    n.connect(timeout=10)
    ec, out, err = n.exec("tail -50 /root/relay-server.log 2>/dev/null", timeout=5)
    print(out[-3000:])
