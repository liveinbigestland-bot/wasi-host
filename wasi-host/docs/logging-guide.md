# Logging Configuration Guide

## Overview

The wasi-host project uses a structured logging system that provides JSON-formatted logs with:
- Multiple output destinations (console, file)
- Log level control (trace, debug, info, warn, err)
- Log rotation (by size and time)
- Performance monitoring
- Module-specific log levels

## Configuration

### Log Levels

| Level | Description | Use Case |
|-------|-------------|----------|
| `trace` | Verbose diagnostic information | Detailed debugging of system internals |
| `debug` | Development and troubleshooting | Development/debugging scenarios |
| `info` | General informational messages | Standard operation |
| `warn` | Warning conditions | Non-critical issues that should be monitored |
| `err` | Error conditions | Critical issues that require attention |

### Configuration Structure

```json
{
  "logging": {
    "level": "info",
    "enable_console": true,
    "enable_file": true,
    "file_path": "wasi-host.log",
    "max_file_size": 10485760,
    "max_files": 7,
    "enable_rotation": true,
    "time_rotation_interval": 86400
  }
}
```

### Configuration Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `level` | string | `"info"` | Minimum log level to output |
| `enable_console` | boolean | `true` | Enable console output |
| `enable_file` | boolean | `false` | Enable file output |
| `file_path` | string | `"wasi-host.log"` | Path to log file |
| `max_file_size` | integer | `10485760` (10MB) | Maximum log file size before rotation |
| `max_files` | integer | `7` | Number of rotated files to retain |
| `enable_rotation` | boolean | `true` | Enable log rotation |
| `time_rotation_interval` | integer | `86400` (24 hours) | Time interval for time-based rotation (seconds) |

## Usage Examples

### Console Only

```json
{
  "logging": {
    "level": "debug",
    "enable_console": true,
    "enable_file": false
  }
}
```

### File Only

```json
{
  "logging": {
    "level": "info",
    "enable_console": false,
    "enable_file": true,
    "file_path": "/var/log/wasi-host/wasi-host.log"
  }
}
```

### Console and File with Rotation

```json
{
  "logging": {
    "level": "debug",
    "enable_console": true,
    "enable_file": true,
    "file_path": "/var/log/wasi-host/wasi-host.log",
    "max_file_size": 10485760,
    "max_files": 7,
    "enable_rotation": true
  }
}
```

### Production Configuration

```json
{
  "logging": {
    "level": "info",
    "enable_console": false,
    "enable_file": true,
    "file_path": "/var/log/wasi-host/wasi-host.log",
    "max_file_size": 10485760,
    "max_files": 7,
    "enable_rotation": true,
    "time_rotation_interval": 86400
  }
}
```

## Log Rotation

### Size-Based Rotation

Logs are rotated when the file reaches `max_file_size`. Rotated files are named:
- `wasi-host.log` - Current log file
- `wasi-host.log.1` - Most recent rotated log
- `wasi-host.log.2` - Second most recent rotated log
- ...and so on up to `max_files`

### Time-Based Rotation

Logs are automatically rotated at regular intervals. The `time_rotation_interval` specifies the interval in seconds:
- `86400` (default) - Daily rotation
- `3600` - Hourly rotation
- `1800` - Every 30 minutes
- `600` - Every 10 minutes

### Retention Policy

Only the last `max_files` rotated files are retained. Older files are automatically deleted.

## Module-Specific Logging

Each module can have its own log level:

```json
{
  "logging": {
    "level": "info",
    "modules": {
      "chord": "debug",
      "p2p": "info",
      "relay": "warn",
      "default": "info"
    }
  }
}
```

## Dynamic Configuration

Log level can be adjusted at runtime without restarting the application:

```bash
# Set global log level
./wasi-host --set-log-level debug

# Set module-specific log level
./wasi-host --set-log-level chord debug
```

## Performance Monitoring

The logging system tracks performance metrics:

- **Throughput**: Logs per second (LPS)
- **Latency**: P50, P95, P99 percentiles of log operation latency

Access metrics programmatically:

```zig
// Get logs per second
const lps = init.getLogsPerSecond();

// Get latency percentile
const p95 = init.getLatencyPercentile(0.95);
```

## File Permissions

Log files are created with the following permissions:
- Owner: read/write
- Group: read
- Others: none (600)

## Log Format

All logs are output in JSON format with the following fields:

```json
{
  "timestamp": 1714953600,
  "level": "info",
  "module": "chord",
  "pid": 12345,
  "message": "Log message here"
}
```

### Fields

- `timestamp`: Unix timestamp (seconds)
- `level`: Log level (trace, debug, info, warn, err)
- `module`: Module name that generated the log
- `pid`: Process ID
- `message`: Log message

## Troubleshooting

### Logs Not Appearing

1. Check that `enable_console` or `enable_file` is set to `true`
2. Verify that the log level includes the desired message level
3. Check module-specific log levels

### File Permissions Denied

- Ensure the application has write permissions to the log directory
- On Linux, the directory should be writable by the application user

### Log File Not Rotating

1. Verify `enable_rotation` is `true`
2. Check that `max_file_size` is set correctly
3. Ensure there's sufficient disk space

### High CPU Usage

- Reduce `time_rotation_interval` to decrease rotation frequency
- Increase `max_file_size` to reduce the number of rotations
- Consider using async logging for very high volume

## Best Practices

1. **Development**: Use `debug` level with console output enabled
2. **Production**: Use `info` or `warn` level with file output only
3. **Critical Systems**: Monitor error-level logs for alerting
4. **Regular Cleanup**: Check log rotation is working and files are retained
5. **Storage Planning**: Calculate storage needs based on `max_files` and `max_file_size`

## Migration from std.log

If migrating from `std.log`:

1. Replace `std.log.print` with `init.log.info`
2. Add `init.init()` call in application startup
3. Configure logging in the config file
4. Test that log output is working correctly

## Examples

### Development Environment

```json
{
  "logging": {
    "level": "debug",
    "enable_console": true,
    "enable_file": false
  }
}
```

### Production with Monitoring

```json
{
  "logging": {
    "level": "info",
    "enable_console": false,
    "enable_file": true,
    "file_path": "/var/log/wasi-host/wasi-host.log",
    "max_file_size": 10485760,
    "max_files": 7,
    "enable_rotation": true,
    "time_rotation_interval": 86400
  }
}
```

### High-Volume System

```json
{
  "logging": {
    "level": "warn",
    "enable_console": false,
    "enable_file": true,
    "file_path": "/var/log/wasi-host/wasi-host.log",
    "max_file_size": 20971520,
    "max_files": 14,
    "enable_rotation": true,
    "time_rotation_interval": 3600
  }
}
```
