import sys, os
sys.path.insert(0, 'wasi-host')
from deploy import RemoteNode, MACHINES

# Check relay server on 外2
for m in MACHINES:
    if '外2' in m['name']:
        try:
            with RemoteNode(m, timeout=10) as n:
                result = n._ssh('pgrep -a relay-server', timeout=5)
                print('外2 relay-server:', result.stdout.strip() or 'NOT RUNNING')
                result2 = n._ssh('ss -tlnp | grep 20809', timeout=5)
                if result2.stdout.strip():
                    print('外2 port 20809: LISTENING')
                else:
                    print('外2 port 20809: NOT LISTENING')
                result3 = n._ssh('pgrep -a wasi-host', timeout=5)
                print('外2 wasi-host:', result3.stdout.strip() or 'NOT RUNNING')
        except Exception as e:
            print('外2 SSH error:', e)
