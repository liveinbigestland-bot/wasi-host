import paramiko, time, os

# Upload x64 binary to ext
x64_binary = 'D:\\claudework\\.claude\\worktrees\\jolly-proskuriakova-e0563b\\wasi-host\\zig-out\\bin\\wasi-hostd-x86_64'

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('ssh-metaai.alwaysdata.net', username='metaai', password='1qaz@WSXasdfasdf', timeout=15)
sftp = ssh.open_sftp()

# Upload x64 binary
sftp.put(x64_binary, '/tmp/wasi-hostd-update')
print('Uploaded')

# Stop, replace, restart
stdin, stdout, stderr = ssh.exec_command('pkill -f wasi-host; sleep 1; cp /tmp/wasi-hostd-update /home/metaai/wasi-host && chmod +x /home/metaai/wasi-host && echo OK')
print(f'Replace: {stdout.read().decode().strip()}')

# Start daemon
stdin, stdout, stderr = ssh.exec_command('cd /home/metaai && nohup ./wasi-hostd /home/metaai/config-ext-daemon.json /home/metaai/wasi-host > /home/metaai/wasi-hostd.log 2>&1 &')
time.sleep(3)

# Verify
stdin, stdout, stderr = ssh.exec_command('ps aux | grep wasi-host | grep -v grep')
ps = stdout.read().decode().strip()
if ps:
    print(f'Running: {ps[:120]}...')
else:
    print('WARNING: daemon not running!')

# Check TCP binding
stdin, stdout, stderr = ssh.exec_command('ss -tlnp | grep 8400')
print(f'TCP binding: {stdout.read().decode().strip()}')

sftp.close()
ssh.close()
