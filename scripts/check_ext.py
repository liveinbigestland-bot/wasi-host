import paramiko
ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('ssh-metaai.alwaysdata.net', username='metaai', password='1qaz@WSXasdfasdf', timeout=15)

# Check wasi-host log
stdin, stdout, stderr = ssh.exec_command('tail -30 /home/metaai/wasi-hostd.log')
print("=== ext wasi-hostd log ===")
print(stdout.read().decode())

# Check config
stdin, stdout, stderr = ssh.exec_command('cat /home/metaai/config-ext-daemon.json')
print("=== ext daemon config ===")
print(stdout.read().decode())

# Check wasi-host process
stdin, stdout, stderr = ssh.exec_command('ps aux | grep wasi-host | grep -v grep')
print("=== ext processes ===")
print(stdout.read().decode())

# Check relay registration
stdin, stdout, stderr = ssh.exec_command('ss -tnp | grep 8356')
print("=== ext port 8356 connections ===")
print(stdout.read().decode())

# Check if ext can reach 外2 relay
stdin, stdout, stderr = ssh.exec_command('curl -s --connect-timeout 5 http://127.0.0.1:8400/ 2>&1 || echo "8400 not reachable"')
print("=== ext local 8400 ===")
print(stdout.read().decode())

ssh.close()
