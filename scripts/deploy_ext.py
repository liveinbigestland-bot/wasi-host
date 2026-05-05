import paramiko, time
ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('ssh-metaai.alwaysdata.net', username='metaai', password='1qaz@WSXasdfasdf', timeout=15)
sftp = ssh.open_sftp()

# Upload x64 binary
sftp.put('D:/claudework/.claude/worktrees/jolly-proskuriakova-e0563b/wasi-host/zig-out/bin/wasi-hostd-x86_64', '/tmp/wasi-hostd-update')
print('Uploaded')

# Stop, replace, restart
stdin, stdout, stderr = ssh.exec_command('pkill -9 wasi-hostd; sleep 1; cp /tmp/wasi-hostd-update /home/metaai/wasi-hostd && chmod +x /home/metaai/wasi-hostd && echo OK')
print(f'Replace: {stdout.read().decode().strip()}')

# Start daemon
stdin, stdout, stderr = ssh.exec_command('cd /home/metaai && nohup ./wasi-hostd /home/metaai/config-ext-daemon.json /home/metaai/wasi-host > /home/metaai/wasi-hostd.log 2>&1 &')
time.sleep(2)

# Verify
stdin, stdout, stderr = ssh.exec_command('ps aux | grep wasi-hostd | grep -v grep')
ps = stdout.read().decode().strip()
if ps:
    print(f'Running: {ps[:80]}...')
else:
    print('WARNING: daemon not running!')

sftp.close()
ssh.close()
