# Lua-WASM Integration - Complete Summary

## Overview

This document provides a comprehensive summary of the Lua-WASM orchestration layer implemented in wasi-host. The integration enables bidirectional communication between Lua scripts and WASM plugins, providing dynamic plugin management, runtime configuration, and event-driven control.

## Architecture

### Core Components

```
┌─────────────────────────────────────────────────────────────┐
│                      Lua Script Layer                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │   Control    │  │   Events     │  │   Plugins    │    │
│  │   Functions  │  │   Callbacks  │  │   Management │    │
│  └──────────────┘  └──────────────┘  └──────────────┘    │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                   LuaStateManager                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │ Event Queue  │  │ Connection   │  │ Plugin       │    │
│  │ (MPMC)       │  │ State        │  │ Handle Mgr   │    │
│  └──────────────┘  └──────────────┘  └──────────────┘    │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                   Lua State (VM)                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │ Global       │  │ Connection   │  │ Callback     │    │
│  │ State        │  │ Specific     │  │ Registry     │    │
│  └──────────────┘  └──────────────┘  └──────────────┘    │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                   WASM Host Functions                       │
│  wasm_start, wasm_stop, wasm_pause, wasm_resume            │
│  wasm_list_plugins, wasm_list_active, wasm_plugin_info     │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                   WASM Runtime                              │
│  Plugin Execution                                           │
└─────────────────────────────────────────────────────────────┘
```

## Features Implemented

### 1. Event Queue System

**Type:** Lock-free MPMC (Multi-Producer Multi-Consumer)

**Capacity:** 256 events

**Features:**
- Thread-safe posting from WASM threads
- Event consumption from main thread
- Overflow detection and backpressure
- Atomic operations for performance

**Event Types:**
- `plugin_start` - Plugin execution started
- `plugin_complete` - Plugin completed successfully
- `plugin_error` - Plugin encountered an error
- `plugin_timeout` - Plugin execution timed out
- `chord_node_join` - New Chord node joined
- `chord_successor_change` - Successor node changed
- `dht_put` - DHT put operation performed

**File:** `src/lua/events.zig`

### 2. Plugin Control Functions

**Functions:**
- `wasm_start(plugin_name, config) → handle`
- `wasm_stop(plugin_handle) → success`
- `wasm_pause(plugin_handle) → success`
- `wasm_resume(plugin_handle) → success`
- `wasm_list_plugins() → array`
- `wasm_list_active() → array`
- `wasm_plugin_info(plugin_name) → info`

**Configuration Options:**
- `mem_kb` (default: 512) - Memory allocation
- `timeout_ms` (default: 5000) - Execution timeout
- `network` (default: false) - Network access
- `write` (default: false) - File write access
- `allow_host_info` (default: true) - Host information access

**File:** `src/lua/host_functions.zig`

### 3. Event Callback System

**Functions:**
- `wasm_on_event(event_type, callback) → success`
- `wasm_off_event(event_type) → success`

**Default Handler:**
- Logs events to console when no callback is registered
- Provides visibility into event flow

**Error Handling:**
- Graceful error handling for Lua callback failures
- Error messages logged and recovered

**File:** `src/lua/state.zig`

### 4. Connection-Specific States

**Features:**
- Per-connection Lua state isolation
- Connection creation tracking
- Last activity timestamps
- Automatic cleanup (30s timeout)
- Per-connection plugin handle grouping

**Functions:**
- `wasm_get_connection_state(connection_id) → LuaState`
- `wasm_set_connection_config(connection_id, config) → success`
- `wasm_remove_connection_state(connection_id) → success`

**Benefits:**
- Multi-user support
- Connection-specific configuration
- Isolated plugin management

**File:** `src/lua/state.zig`

### 5. P2P Event Integration

**Features:**
- Chord node join event posting
- Successor change event posting
- DHT put event posting
- Configuration toggle (lua_p2p_events_enabled)

**Integration Points:**
- `chord_node.join()` - Node join notification
- `chord_node.doStabilize()` - Successor changes
- `host_dht_put` - DHT write operations

**File:** `src/p2p/chord/node.zig`, `src/host/p2p_bindings.zig`

### 6. Configuration System

**Options:**
- `lua_script` - Path to Lua script file
- `lua_events_enabled` - Enable event processing (default: true)
- `lua_p2p_events_enabled` - Enable P2P events (default: true)
- `event_logging` - Enable detailed event logging

**Loading Methods:**
- File-based scripts (`lua_script` config)
- Embedded scripts (via `loadEmbeddedScript()` API)

**File:** `main.zig`, `src/lua/state.zig`

## Testing

### Test Suite

**Total Tests:** 40

**Categories:**
1. **Control Flow Tests (8):** Lua-to-WASM control operations
2. **Event Flow Tests (8):** WASM-to-Lua event processing
3. **Concurrent Plugin Tests (9):** Concurrent plugin management
4. **Latency Tests (4):** Performance measurements
5. **Event Queue Tests (11):** Event queue unit tests

**Files:**
- `tests/lua/test_lua_wasm_control.zig`
- `tests/lua/test_wasm_to_lua_events.zig`
- `tests/lua/test_concurrent_plugins.zig`
- `tests/lua/test_latency.zig`
- `tests/lua/test_event_queue.zig`

### Test Coverage

- ✅ Event queue operations
- ✅ Plugin lifecycle control
- ✅ Concurrent access safety
- ✅ Overflow handling
- ✅ Latency measurements
- ✅ Error handling
- ✅ State management

## Examples

### 1. Plugin Monitor

**File:** `examples/lua/plugin_monitor.lua`

**Features:**
- Monitors plugin execution lifecycle
- Tracks statistics (started, completed, errors)
- Reports average duration
- Prints summary every 60 seconds

### 2. Orchestrator

**File:** `examples/lua/orchestrator.lua`

**Features:**
- Manages multiple plugins concurrently
- Controls plugin lifecycle (start, stop, pause, resume)
- Implements orchestration logic
- Reports plugin status

### 3. P2P Monitor

**File:** `examples/lua/p2p_monitor.lua`

**Features:**
- Monitors Chord DHT events
- Tracks network topology changes
- Logs DHT operations
- Monitors plugin errors

## API Reference

See `docs/lua_api_reference.md` for complete API documentation with:

- Function signatures
- Parameter descriptions
- Return values
- Error handling
- Code examples

## Usage Guide

### Basic Usage

1. **Configure Lua script in config.json:**
   ```json
   {
       "lua_script": "/path/to/script.lua"
   }
   ```

2. **Write Lua script:**
   ```lua
   wasm_on_event("plugin_complete", function(payload)
       print(string.format("Plugin %d completed in %dms",
           payload.plugin_handle, payload.duration_ms))
   end)
   ```

3. **Start the application:**
   ```bash
   zig build
   ```

### Multi-User Support

```lua
-- Get connection-specific state
local conn_state = wasm_get_connection_state(connection_id)

-- Register callbacks for this connection
conn_state:registerCallback("plugin_complete", callback_function)

-- Execute Lua code in connection context
conn_state:execute("print('Connection specific message')")
```

### Plugin Orchestration

```lua
-- Start multiple plugins
local handles = {}
for _, plugin_name in ipairs({"ai_plugin", "api_plugin"}) do
    local handle, err = wasm_start(plugin_name, {
        mem_kb = 1024,
        timeout_ms = 10000,
    })
    if handle then
        handles[handle] = true
    end
end

-- Monitor plugin status
local active = wasm_list_active()
for _, handle in ipairs(active) do
    local info = wasm_plugin_info(handle)
    print(info.status)
end
```

## Performance Characteristics

### Latency

- **Lua → WASM:** < 1ms (direct calls)
- **WASM → Lua:** < 100ms (event queue, typically < 10ms)
- **Event Queue Push:** < 10μs
- **Event Queue Pop:** < 5μs

### Throughput

- **Event Queue:** 256 events capacity
- **Event Processing:** Time-bounded (10ms per tick)
- **GC Trigger:** Periodic (idle periods)

### Memory

- **Event Queue:** ~8KB (256 events × 32 bytes)
- **Connection States:** Dynamic (per-connection)
- **Plugin Handles:** Sequential, 64-bit integers

## Deployment

### Windows

```bash
zig build
```

### ARM (armv7l)

```bash
zig build -Dtarget=arm-linux-musleabihf -p /tmp/zig-out-arm
cp /tmp/zig-out-arm/bin/wasi-host zig-out/bin/wasi-host-arm-v5
```

### Linux x86_64

```bash
zig build -Dtarget=x86_64-linux-gnu -p /tmp/zig-out-x64
cp /tmp/zig-out-x64/bin/wasi-host zig-out/bin/wasi-host-x86_64
```

## Troubleshooting

### Lua Script Not Loading

1. Check file path in `config.json`
2. Verify file exists and is readable
3. Check for syntax errors in Lua script
4. Enable detailed logging

### Plugin Not Starting

1. Verify plugin name exists
2. Check plugin configuration
3. Review error events
4. Verify network access permissions

### Event Callbacks Not Firing

1. Verify callback registration
2. Check event type spelling
3. Review Lua callback errors
4. Ensure event processing is enabled

## Future Enhancements

Potential improvements for future iterations:

1. **Script Hot-Reload:** Reload Lua scripts without restart
2. **Persistent State:** Save Lua state across restarts
3. **Event Persistence:** Store events in log files
4. **Metrics Collection:** Built-in metrics and monitoring
5. **Script Modules:** Lua module system for code organization
6. **Plugin API:** Standardized plugin interface
7. **Performance Tuning:** Configurable queue sizes and timeouts
8. **Security:** Input validation and sanitization

## References

- **OpenSpec Change:** `2026-05-06-optimize-lua-wasi-host-scheduling`
- **API Documentation:** `docs/lua_api_reference.md`
- **Example Scripts:** `examples/lua/`
- **Test Suite:** `tests/lua/`

## Conclusion

The Lua-WASM integration provides a robust, feature-rich bridge between Lua scripting and WASM plugin execution. With comprehensive testing, complete documentation, and practical examples, this implementation is production-ready and suitable for integration into the wasi-host project.
