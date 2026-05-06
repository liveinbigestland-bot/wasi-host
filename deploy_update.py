#!/usr/bin/env python3
"""Targeted binary/config update for encrypted relay integration"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

def deploy_node(m):
    name = m['name']
    print(f'\n=== {name} ({m["host"]}) ===')
    try:
        with RemoteNode(m, timeout=15) as n:
            # Upload binary
            print(f'  Uploading binary...')
            n.upload_binary()
            # Upload config
            print(f'  Uploading config...')
            n.upload_config()
            # Restart
            print(f'  Stopping...')
            n.stop()
            time.sleep(3)
            pid = n.start()
            if pid:
                print(f'  Started PID={pid}')
                time.sleep(3)
                # Quick health check
                logs = n.grep_log('encrypted_relay|relay.*connect|chord.*stabilize', 5)
                if logs:
                    print(f'  Logs: {logs.strip()[-200:]}')
                pids = n.pgrep()
                print(f'  Running: {pids}')
                return True
            else:
                print(f'  FAILED to start!')
                return False
    except Exception as e:
        print(f'  ERROR: {e}')
        return False

# Deploy to nodes that need encrypted relay (ARM nodes)
targets = [m for m in MACHINES if m['name'] in ('node59', 'node60')]
print('=' * 55)
print('  Targeted deploy: encrypted relay integration')
print('=' * 55)
print(f'  Targets: {[m["name"] for m in targets]}')

for m in targets:
    deploy_node(m)

print('\n=== Done ===')
