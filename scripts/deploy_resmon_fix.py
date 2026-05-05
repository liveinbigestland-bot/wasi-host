import paramiko, os, time

# Deploy daemon binary to nodes
arm_binary = 'D:/claudework/.claude/worktrees/jolly-proskuriakova-e0563b/wasi-host/zig-out/bin/wasi-hostd'
x64_binary = 'D:/claudework/.claude/worktrees/jolly-proskuriakova-e0563b/wasi-host/zig-out/bin/wasi-hostd-x86_64'

nodes = [
    {'host': '192.168.2.59', 'user': 'root', 'pwd': 'ecoo1234', 'label': 'node59', 'binary': arm_binary, 'config': '/root/config-lan-node59.json'},
    {'host': '192.168.2.60', 'user': 'root', 'pwd': 'ecoo1234', 'label': 'node60', 'binary': arm_binary, 'config': '/root/config-lan-node60.json'},
    {'host': '192.140.185.171', 'user': 'root', 'pwd': 'aetej1AzIQpE', 'label': '外2', 'binary': x64_binary, 'config': '/root/config-ext-node2.json'},
]

for node in nodes:
    print(f'--- Deploying to {node["label"]} ({node["host"]}) ---')
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(node['host'], username=node['user'], password=node['pwd'], timeout=15)

    # 1. Upload new binary via /tmp
    sftp = ssh.open_sftp()
    tmp_path = '/tmp/wasi-hostd-update'
    remote_path = '/root/wasi-hostd'
    sftp.put(node['binary'], tmp_path)
    print(f'  Uploaded to {tmp_path}')

    # 2. Stop daemon, replace binary, restart
    stdin, stdout, stderr = ssh.exec_command('pkill -9 wasi-hostd; sleep 1; cp /tmp/wasi-hostd-update /root/wasi-hostd && chmod +x /root/wasi-hostd && echo OK')
    print(f'  Replace: {stdout.read().decode().strip()}')

    # 3. Start daemon
    stdin, stdout, stderr = ssh.exec_command(f'cd /root && nohup ./wasi-hostd {node["config"]} /root/wasi-host > /root/wasi-hostd.log 2>&1 &')
    time.sleep(2)

    # 4. Verify
    stdin, stdout, stderr = ssh.exec_command('ps aux | grep wasi-hostd | grep -v grep')
    ps = stdout.read().decode().strip()
    if ps:
        print(f'  Running: {ps[:80]}...')
    else:
        print(f'  WARNING: daemon not running!')

    sftp.close()
    ssh.close()
    print()

print('Done!')
