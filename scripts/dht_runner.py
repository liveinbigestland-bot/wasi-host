import paramiko, socket, struct, json, time

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('192.140.185.171', username='root', password='aetej1AzIQpE', timeout=10)

sftp = ssh.open_sftp()
# Upload the test file
with open(r'D:\claudework\dht_test.py', 'rb') as f:
    sftp.putfo(f, '/tmp/dht_test2.py')

# Now execute it
stdin, stdout, stderr = ssh.exec_command("python3 /tmp/dht_test2.py 2>&1")
print(stdout.read().decode())

sftp.close()
ssh.close()
