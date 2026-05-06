# Logging Migration Guide

This guide helps you migrate from the old logging system to the new structured logging system in wasi-host.

## Overview

The new logging system provides:
- **Structured JSON logs** for better parsing and analysis
- **Multiple output destinations** (console, file)
- **Log rotation** by size and time
- **Dynamic log level adjustment** at runtime
- **Module-specific log levels**
- **Performance monitoring** built-in

## Migration Checklist

- [ ] Review the [Logging Configuration Guide](./logging-guide.md)
- [ ] Review [Log Management Procedures](./log-management.md)
- [ ] Update configuration files with logging settings
- [ ] Test logging in development environment
- [ ] Deploy to staging environment
- [ ] Monitor logs after deployment
- [ ] Update any custom log parsing scripts

## Migration Process

### Step 1: Update Configuration

Update your configuration files to enable logging:

```json
{
  "logging": {
    "level": "info",
    "enable_console": true,
    "enable_file": true,
    "file_path": "wasi-host.log",
    "max_file_size": 10485760,
    "max_files": 7,
    "enable_rotation": true
  }
}
```

#### Configuration Examples

**Development** (console only, debug level):
```json
{
  "logging": {
    "level": "debug",
    "enable_console": true,
    "enable_file": false
  }
}
```

**Production** (file only, info level):
```json
{
  "logging": {
    "level": "info",
    "enable_console": false,
    "enable_file": true,
    "file_path": "/var/log/wasi-host/wasi-host.log",
    "max_file_size": 10485760,
    "max_files": 7
  }
}
```

### Step 2: Update Application Code

If you have custom logging code, update it to use the new logging system.

#### Old Logging (std.log)

```zig
std.debug.print("[chord] Connected to node: {s}\n", .{node_id});
std.log.info("P2P handshake completed", .{});
std.log.warn("Warning: Retrying connection", .{});
```

#### New Logging (structured)

```zig
import logging;

logging.log.info("Connected to node: {s}", .{node_id});
logging.log.info("P2P handshake completed", .{});
logging.log.warn("Warning: Retrying connection", .{});
```

### Step 3: Module Initialization

Ensure logging is initialized in your application:

```zig
const logging = @import("src/logging/index.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Initialize logging with module name
    try logging.init(alloc, "my-module", logging.Config{
        .level = .info,
        .enable_console = true,
        .enable_file = false,
    });

    // Use logging...
    logging.log.info("Application started", .{});
}
```

### Step 4: Test in Development

1. **Run locally with console logging**
   ```bash
   zig run main.zig --config config-lan-seed.json
   ```

2. **Verify JSON logs appear in console**
   ```bash
   # Should see logs like:
   {"timestamp":1714953600,"level":"info","module":"my-module","pid":12345,"message":"Application started"}
   ```

3. **Test log levels**
   ```bash
   # Set log level to debug
   # Change logging level in config or use CLI flag
   ```

4. **Test file output**
   ```bash
   # Enable file output and verify wasi-host.log is created
   # Check contents are JSON format
   ```

### Step 5: Deploy to Staging

1. **Update configuration files**
   - Copy updated config files to staging servers
   - Verify log file paths are correct

2. **Deploy application**
   ```bash
   python deploy.py deploy
   ```

3. **Verify deployment**
   ```bash
   python deploy.py status
   python deploy.py logs
   ```

4. **Check log files**
   ```bash
   # On each node
   ssh root@node59 "cat /root/wasi-host.log"
   ```

### Step 6: Monitor in Production

1. **Set up log monitoring**
   - Configure log monitoring tools to watch log files
   - Set up alerts for errors (`level: "err"`)

2. **Verify log rotation**
   ```bash
   # Check log rotation is working
   ls -lh /var/log/wasi-host/wasi-host.log*
   ```

3. **Monitor disk usage**
   ```bash
   # Check log directory size
   du -sh /var/log/wasi-host/
   ```

## Breaking Changes

### Log Format Change

**Old Format** (text):
```
[chord] Connected to node: abc123
P2P handshake completed
Warning: Retrying connection
```

**New Format** (JSON):
```json
{"timestamp":1714953600,"level":"info","module":"chord","pid":12345,"message":"Connected to node: abc123"}
{"timestamp":1714953601,"level":"info","module":"p2p","pid":12345,"message":"P2P handshake completed"}
{"timestamp":1714953602,"level":"warn","module":"relay","pid":12345,"message":"Warning: Retrying connection"}
```

**Impact**: Log parsers that expect text format will need updates.

### Log Level Names

| Old Name | New Name |
|----------|----------|
| `info` | `info` |
| `warn` | `warn` |
| `error` | `err` |

**Impact**: Log level references in code using `.error` will need to change to `.err`.

### Module Access

**Old**: Direct `std.debug.print` calls throughout the codebase

**New**: Import and use logging module

**Impact**: All logging calls need to be updated to use the new logging system.

## Updating Custom Log Parsing Scripts

### Before (Text Format)

```bash
# Parse chord connection messages
grep "\[chord\]" wasi-host.log
```

### After (JSON Format)

```bash
# Parse chord connection messages with jq
jq -r 'select(.module == "chord") | .message' wasi-host.log

# Extract all errors
jq -r 'select(.level == "err") | "\(.timestamp): \(.message)"' wasi-host.log

# Count logs per module
jq -r '.module' wasi-host.log | sort | uniq -c
```

### Parsing Example in Python

```python
import json

# Old way
with open('wasi-host.log') as f:
    for line in f:
        if '[chord]' in line:
            print(line.strip())

# New way
with open('wasi-host.log') as f:
    for line in f:
        if line.strip():
            log = json.loads(line)
            if log['module'] == 'chord':
                print(f"{log['timestamp']}: {log['message']}")
```

### Parsing Example in Bash

```bash
# Old way
grep "chord" wasi-host.log

# New way
jq -r 'select(.module == "chord") | @json' wasi-host.log

# Convert to readable format
jq '.' wasi-host.log
```

## Migration Commands

### Check Current Logging

```bash
# Check if logging is enabled
grep "logging" config.json

# Check log file exists
ls -lh wasi-host.log
```

### Test Logging

```bash
# Run with console logging enabled
./wasi-host --config config-test.json

# Check output is JSON format
```

### Verify Log Rotation

```bash
# Check rotated files exist
ls -lh wasi-host.log.*

# Check file sizes
du -h wasi-host.log*
```

## Troubleshooting

### Logs Not Appearing

1. **Check if logging is configured**
   ```bash
   grep "logging" config.json
   ```

2. **Check log level**
   - Ensure log level includes the message level
   - Example: to see "info" messages, level must be "trace", "debug", or "info"

3. **Check module initialization**
   ```zig
   // Ensure logging.init() is called in main()
   try logging.init(alloc, "your-module", logging.Config{...});
   ```

### Logs in Wrong Format

1. **Verify configuration**
   - Check that logging configuration is properly parsed
   - Look for JSON syntax errors in config file

2. **Check file permissions**
   ```bash
   # Ensure log file is writable
   touch /path/to/log && rm /path/to/log
   ```

### Log Rotation Not Working

1. **Check rotation is enabled**
   ```bash
   grep "enable_rotation" config.json
   ```

2. **Check file size limit**
   ```bash
   grep "max_file_size" config.json
   ```

3. **Check disk space**
   ```bash
   df -h /path/to/log
   ```

## Rollback Procedure

If issues arise during migration, you can rollback to the old logging system:

1. **Revert Configuration**
   ```bash
   git checkout config.json
   ```

2. **Restore Previous Code**
   ```bash
   git checkout HEAD~1
   ```

3. **Rebuild and Deploy**
   ```bash
   zig build
   python deploy.py deploy
   ```

## Support

If you encounter issues during migration:

1. Check the [Logging Configuration Guide](./logging-guide.md)
2. Review [Log Management Procedures](./log-management.md)
3. Check the application logs for errors
4. Contact the development team for support

## Additional Resources

- [Logging Configuration Guide](./logging-guide.md)
- [Log Management Procedures](./log-management.md)
- [Configuration Schema](../config-schema.md)
