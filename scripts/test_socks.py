import paramiko, socket, struct

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('192.168.2.59', username='root', password='ecoo1234', timeout=10)

# Check if SOCKS is listening
stdin, stdout, stderr = ssh.exec_command('ss -tlnp | grep 1080')
print('SOCKS:', stdout.read().decode())

# Quick test with nc
stdin, stdout, stderr = ssh.exec_command('timeout 5 bash -c "echo -n '' | nc -v 127.0.0.1 1080" 2>&1')
print('nc test:', stdout.read().decode()[:200])

ssh.close()
