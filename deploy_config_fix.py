#!/usr/bin/env python3
"""Upload fixed configs and restart nodes"""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

targets = ['外2', 'node59', 'node60']
for m in MACHINES:
    if m['name'] not in targets:
        continue
    print(f"\n=== {m['name']} ===")
    try:
        with RemoteNode(m) as n:
            n.connect(timeout=15)

            # Upload config
            print("  Uploading config...")
            config_tmp = "/tmp/config-deploy-fix.json"
            sftp = n.client.open_sftp()
            with open(m['config'], 'rb') as f:
                sftp.putfo(f, config_tmp)
            sftp.close()
            ec, out, err = n.exec(
                f"rm -f {m['remote_config']} && cp {config_tmp} {m['remote_config']}"
                f" && rm -f {config_tmp} && echo OK",
                timeout=10,
            )
            print(f"  Config upload: {out.strip()}")

            # Restart process
            print("  Stopping...")
            n.stop()
            time.sleep(2)
            pid = n.start()
            if pid:
                print(f"  Started: PID={pid}")
                time.sleep(3)
                # Look for encrypted_relay in startup
                ec, out, err = n.exec(f"grep -a 'encrypted_relay' {m['remote_log']} 2>/dev/null | head -5", timeout=5)
                if out.strip():
                    for l in out.split('\n'):
                        print(f"  {l.strip()}")
                else:
                    print("  (no encrypted_relay log msg yet)")
            else:
                print("  FAILED to start!")
    except Exception as e:
        print(f"  ERROR: {e}")

# Restart relay-server on 外2 (was killed by restart)
print("\n=== relay-server (外2) ===")
m = MACHINES[0]
with RemoteNode(m) as n:
    n.connect(timeout=10)
    pid = n.start_relay()
    if pid:
        print(f"  relay-server PID={pid}")
    else:
        print("  relay-server FAILED")

print("\n=== Done ===")
