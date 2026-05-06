# Log Management Procedures

This document describes the procedures for managing logs in the wasi-host system, including rotation, cleanup, monitoring, and troubleshooting.

## Overview

The wasi-host system uses a structured JSON logging system with the following features:
- **Log Rotation**: Automatic rotation by size and time
- **File Retention**: Configurable number of rotated files
- **Performance Monitoring**: Built-in throughput and latency tracking
- **Multi-Module Logging**: Each module can have its own log level

## Log File Locations

### Local Deployment

| Service | Log File Path |
|---------|---------------|
| wasi-host | `wasi-host.log` (current) |
| Relay Server | `/var/log/wasi-host/relay-server.log` |

### Remote Deployment

| Machine | Log File Path |
|---------|---------------|
| node59 | `/root/wasi-host.log` |
| node60 | `/root/wasi-host.log` |
| ext | `/home/metaai/wasi-host.log` |
| 外2 (VPS) | `/var/log/wasi-host/wasi-host.log` |

## Log Rotation

### Automatic Rotation

Logs are automatically rotated according to the configured policy:
- **Size-based**: When log file reaches `max_file_size` (default: 10MB)
- **Time-based**: At regular intervals (default: daily at midnight)

### Rotated Files

Rotated files are named sequentially:
- `wasi-host.log` - Current log file
- `wasi-host.log.1` - Most recent rotated log
- `wasi-host.log.2` - Second most recent rotated log
- ...and so on up to `max_files` (default: 7 files)

## Log Cleanup Procedures

### Daily Cleanup

1. **Check for Old Log Files**
   ```bash
   ls -lh wasi-host.log*
   ```

2. **Verify Retention Policy**
   - Ensure only the last `max_files` rotated files exist
   - Delete files older than `max_files` count

3. **Clean Up Log Directory**
   ```bash
   # On remote nodes
   ssh root@node59 "rm -f /root/wasi-host.log.*"

   # On VPS
   ssh root@192.140.185.171 "rm -f /var/log/wasi-host/wasi-host.log.*"
   ```

### Weekly Cleanup

1. **Archive Old Logs** (optional, for compliance)
   ```bash
   # Archive logs older than 30 days
   find /var/log/wasi-host -name "*.log.*" -mtime +30 -exec gzip {} \;
   ```

2. **Verify Archive Integrity**
   - Check that compressed archives are valid
   - Ensure archived logs are accessible

3. **Remove Archives** (after verification)
   ```bash
   # Keep archives for 90 days
   find /var/log/wasi-host -name "*.log.*.gz" -mtime +90 -delete
   ```

## Monitoring

### Check Log Files

#### Check Current Log
```bash
# View current log
tail -f wasi-host.log

# View last 100 lines
tail -n 100 wasi-host.log

# View specific pattern
grep "error" wasi-host.log
```

#### Check Rotated Logs
```bash
# View most recent rotated log
tail -n 100 wasi-host.log.1

# Search in all rotated logs
grep "error" wasi-host.log*
```

#### Check Remote Logs
```bash
# Using deploy.py
python deploy.py logs

# Manual SSH
ssh root@node59 "tail -n 50 /root/wasi-host.log"
ssh root@192.140.185.171 "tail -n 50 /var/log/wasi-host/wasi-host.log"
```

### Monitor Log Growth

#### Check Disk Usage
```bash
# Check log directory size
du -sh /var/log/wasi-host/

# Check individual file sizes
du -h /var/log/wasi-host/wasi-host.log*
```

#### Monitor Rotation Frequency
```bash
# Check when last rotation occurred
ls -l /var/log/wasi-host/wasi-host.log

# Check modification times of rotated files
ls -l /var/log/wasi-host/wasi-host.log.*
```

### Set Up Log Monitoring Alerts

#### Log Size Alert
```bash
# Create a monitoring script
cat > /usr/local/bin/check-log-size.sh << 'EOF'
#!/bin/bash
LOG_DIR="/var/log/wasi-host"
MAX_SIZE_GB=5

for log_file in "$LOG_DIR"/*.log; do
    if [ -f "$log_file" ]; then
        SIZE_GB=$(du -b "$log_file" | cut -f1 | awk '{print $1/1024/1024/1024}')
        if (( $(echo "$SIZE_GB > $MAX_SIZE_GB" | bc -l) )); then
            echo "WARNING: $log_file is ${SIZE_GB}GB"
        fi
    fi
done
EOF

chmod +x /usr/local/bin/check-log-size.sh

# Add to cron (hourly)
echo "0 * * * * /usr/local/bin/check-log-size.sh" | crontab -
```

#### Log Rotation Alert
```bash
# Monitor for failed rotations
cat > /usr/local/bin/check-log-rotation.sh << 'EOF'
#!/bin/bash
LOG_DIR="/var/log/wasi-host"
LOG_FILE="$LOG_DIR/wasi-host.log"
ROTATION_COUNT=$(find "$LOG_DIR" -name "wasi-host.log.*" | wc -l)

if [ "$ROTATION_COUNT" -lt 1 ]; then
    echo "WARNING: No rotated log files found"
fi
EOF

chmod +x /usr/local/bin/check-log-rotation.sh

# Add to cron (daily)
echo "0 0 * * * /usr/local/bin/check-log-rotation.sh" | crontab -
```

## Troubleshooting

### Logs Not Being Written

1. **Check File Permissions**
   ```bash
   # Check if file is writable
   touch /var/log/wasi-host/wasi-host.log && rm /var/log/wasi-host/wasi-host.log
   ```

2. **Check Disk Space**
   ```bash
   df -h /var/log/
   ```

3. **Check Application Status**
   ```bash
   ps aux | grep wasi-host
   ```

### Log File Not Rotating

1. **Verify Rotation is Enabled**
   ```bash
   # Check configuration
   grep "enable_rotation" /root/config-*.json
   ```

2. **Check File Size**
   ```bash
   ls -lh /var/log/wasi-host/wasi-host.log
   ```

3. **Check Disk Space**
   ```bash
   df -h /var/log/
   ```

### High CPU Usage from Logging

1. **Reduce Log Volume**
   - Lower log level to `warn` or `error`
   - Disable debug logging

2. **Increase Rotation Interval**
   - Set `time_rotation_interval` to larger value

3. **Optimize Performance**
   - Increase `max_file_size`
   - Use async logging for high volume

## Log Analysis

### Common Log Patterns

#### Errors
```bash
grep "error" wasi-host.log
```

#### Warnings
```bash
grep "warn" wasi-host.log
```

#### Specific Module
```bash
grep '"module":"chord"' wasi-host.log
grep '"module":"relay"' wasi-host.log
```

### JSON Log Parsing

#### Using jq (recommended)
```bash
# Extract error messages
jq -r '.message' wasi-host.log | grep error

# Get timestamp of last error
jq -r 'select(.level == "err") | .timestamp' wasi-host.log | tail -1

# Count errors per module
jq -r '.module' wasi-host.log | sort | uniq -c
```

#### Using grep
```bash
# Find all log entries with error field
grep '"level":"err"' wasi-host.log

# Get timestamps of errors
grep '"level":"err"' wasi-host.log | jq -r '.timestamp'
```

## Log Backup and Recovery

### Backup Logs

#### Backup Current Logs
```bash
# Backup all logs with timestamps
tar -czf wasi-host-backup-$(date +%Y%m%d).tar.gz wasi-host.log wasi-host.log.*
```

#### Backup Remote Logs
```bash
# From deploy.py
python deploy.py backup-logs

# Manual SSH
ssh root@node59 "tar -czf /root/wasi-host-backup-$(date +%Y%m%d).tar.gz /root/wasi-host.log*"
```

### Restore Logs

#### Restore from Backup
```bash
# Extract backup
tar -xzf wasi-host-backup-20250115.tar.gz

# Replace current log
mv wasi-host.log wasi-host.log.old
mv wasi-host-backup-20250115/wasi-host.log wasi-host.log
```

## Security Considerations

### File Permissions

Ensure logs have appropriate permissions:
```bash
chmod 600 /var/log/wasi-host/wasi-host.log
chmod 644 /var/log/wasi-host/wasi-host.log.*
```

### Access Control

Restrict log file access:
```bash
# Only owner can read
chmod 600 /var/log/wasi-host/wasi-host.log

# Owner and group can read
chmod 640 /var/log/wasi-host/wasi-host.log
```

### Encryption

For sensitive data in logs:
- Do not log PII or sensitive credentials
- Use log aggregation systems with encryption
- Implement log retention policies

## Best Practices

1. **Regular Monitoring**: Check logs daily during active operation
2. **Alert Configuration**: Set up alerts for errors and log growth
3. **Regular Cleanup**: Remove old logs according to retention policy
4. **Compression**: Compress old logs after daily rotation
5. **Monitoring**: Track log volume and rotation frequency
6. **Access Control**: Limit log file permissions
7. **Backup**: Archive important logs for compliance

## References

- [Logging Configuration Guide](./logging-guide.md)
- [Configuration File Format](../config-schema.md)
