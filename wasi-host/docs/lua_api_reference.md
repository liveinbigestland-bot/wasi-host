# Lua API Reference

## Overview

The wasi-host Lua integration provides a bidirectional communication layer between Lua scripts and WASM plugin execution. This allows dynamic plugin orchestration, runtime configuration, and event-driven control.

## Core Functions

### WASM Control Functions

#### `wasm_start(plugin_name, config) → handle, error`

Start a WASM plugin with optional configuration.

**Parameters:**
- `plugin_name` (string): Name of the plugin to start
- `config` (table, optional): Configuration table with:
  - `mem_kb` (number, default 512): Memory allocation in KB
  - `timeout_ms` (number, default 5000): Execution timeout in ms
  - `network` (boolean, default false): Enable network access
  - `write` (boolean, default false): Enable file write access
  - `allow_host_info` (boolean, default true): Allow access to host information

**Returns:**
- `handle` (number): Unique plugin handle
- `error` (string or nil): Error message or nil on success

**Example:**
```lua
local handle, err = wasm_start("ai_plugin", {
    mem_kb = 1024,
    timeout_ms = 10000,
    network = true,
})
if handle then
    print("Plugin started with handle: " .. handle)
end
```

#### `wasm_stop(plugin_handle) → success, error`

Stop a running WASM plugin.

**Parameters:**
- `plugin_handle` (number): Plugin handle returned by `wasm_start`

**Returns:**
- `success` (boolean): True if successful
- `error` (string or nil): Error message or nil on success

**Example:**
```lua
local success, err = wasm_stop(1)
if success then
    print("Plugin stopped successfully")
end
```

#### `wasm_pause(plugin_handle) → success, error`

Pause a running WASM plugin without terminating it.

**Parameters:**
- `plugin_handle` (number): Plugin handle

**Returns:**
- `success` (boolean): True if successful
- `error` (string or nil): Error message or nil on success

#### `wasm_resume(plugin_handle) → success, error`

Resume a paused WASM plugin.

**Parameters:**
- `plugin_handle` (number): Plugin handle

**Returns:**
- `success` (boolean): True if successful
- `error` (string or nil): Error message or nil on success

#### `wasm_list_plugins() → array`

Get list of available WASM plugins.

**Returns:**
- Array of plugin names (embedded and file-based)

**Example:**
```lua
local plugins = wasm_list_plugins()
for i, name in ipairs(plugins) do
    print(name)
end
```

#### `wasm_list_active() → array`

Get list of currently active plugins.

**Returns:**
- Array of active plugin handles

**Example:**
```lua
local active = wasm_list_active()
for i, handle in ipairs(active) do
    print("Active plugin: " .. handle)
end
```

#### `wasm_plugin_info(plugin_name) → info_table`

Get metadata for a plugin.

**Parameters:**
- `plugin_name` (string): Plugin name

**Returns:**
- Info table containing:
  - `name` (string): Plugin name
  - `default_mem_kb` (number): Default memory allocation
  - `default_timeout_ms` (number): Default timeout

**Example:**
```lua
local info = wasm_plugin_info("ai_plugin")
print("Memory: " .. info.default_mem_kb .. "KB")
print("Timeout: " .. info.default_timeout_ms .. "ms")
```

### Connection Management Functions

#### `wasm_get_connection_state(connection_id) → LuaState, error`

Get Lua state for a specific connection.

**Parameters:**
- `connection_id` (number): Connection identifier

**Returns:**
- LuaState: Lua state object for the connection
- `error` (string or nil): Error message or nil on success

**Note:** This enables per-connection Lua state isolation for multi-user scenarios.

#### `wasm_set_connection_config(connection_id, config) → success, error`

Set configuration for a specific connection.

**Parameters:**
- `connection_id` (number): Connection identifier
- `config` (table): Configuration table

**Returns:**
- `success` (boolean): True if successful
- `error` (string or nil): Error message or nil on success

#### `wasm_remove_connection_state(connection_id) → success, error`

Remove a connection state and clean up resources.

**Parameters:**
- `connection_id` (number): Connection identifier

**Returns:**
- `success` (boolean): True if successful
- `error` (string or nil): Error message or nil on success

### Event Registration Functions

#### `wasm_on_event(event_type, callback) → success`

Register a callback function for a specific event type.

**Parameters:**
- `event_type` (string): Event type to register for
- `callback` (function): Callback function to execute

**Supported event types:**
- `plugin_start`: Plugin execution started
- `plugin_complete`: Plugin completed successfully
- `plugin_error`: Plugin encountered an error
- `plugin_timeout`: Plugin execution timed out
- `chord_node_join`: New Chord node joined
- `chord_successor_change`: Successor node changed
- `dht_put`: DHT put operation performed

**Returns:**
- `success` (boolean): True if successful
- `error` (string or nil): Error message or nil on success

**Example:**
```lua
wasm_on_event("plugin_complete", function(payload)
    print(string.format("Plugin %d completed: %dms",
        payload.plugin_handle,
        payload.duration_ms))
end)
```

#### `wasm_off_event(event_type) → success`

Unregister a callback for a specific event type.

**Parameters:**
- `event_type` (string): Event type to unregister

**Returns:**
- `success` (boolean): True if successful
- `error` (string or nil): Error message or nil on success

**Example:**
```lua
wasm_off_event("plugin_complete")
```

## Event Payload Structure

Events include a payload table with key-value pairs:

### Plugin Events
```lua
-- plugin_start
{
    event_type = "plugin_start",
    plugin_handle = 1,
    plugin_name = "ai_plugin",
    connection_id = 12345  -- nil for global
}

-- plugin_complete
{
    event_type = "plugin_complete",
    plugin_handle = 1,
    exit_code = 0,
    duration_ms = 100
}

-- plugin_error
{
    event_type = "plugin_error",
    plugin_handle = 1,
    error_code = -1,
    error_message = "Execution failed"
}

-- plugin_timeout
{
    event_type = "plugin_timeout",
    plugin_handle = 1,
    timeout_ms = 5000
}
```

### P2P Events
```lua
-- chord_node_join
{
    event_type = "chord_node_join",
    node_id = "0x0102030405060708090a0b0c0d0e0f1011121314",
    host = "192.168.1.1",
    port = 20808
}

-- chord_successor_change
{
    event_type = "chord_successor_change",
    old_successor_id = "0x...",
    new_successor_id = "0x..."
}

-- dht_put
{
    event_type = "dht_put",
    key = "test_key",
    value_size = 256
}
```

## Connection State Methods

For connection-specific Lua states, you can access Lua methods:

```lua
-- Get connection state
local conn_state = wasm_get_connection_state(12345)

-- Register callbacks in connection state
conn_state:registerCallback("plugin_complete", callback_function)

-- Execute Lua code in connection context
conn_state:execute("print('Connection specific message')")
```

## Script Loading

### File-Based Scripts

Configure in `config.json`:
```json
{
    "lua_script": "/path/to/script.lua"
}
```

### Embedded Scripts

Can be loaded via `LuaStateManager.loadEmbeddedScript()` API.

## Best Practices

1. **Error Handling**: Always check error returns from WASM functions
2. **Handle Validation**: Verify plugin handles before use
3. **Callback Cleanup**: Call `wasm_off_event()` when done with callbacks
4. **Connection Cleanup**: Call `wasm_remove_connection_state()` when closing connections
5. **Event Processing**: Call `wasm_process_events(10)` periodically in main loops

## Examples

See `examples/lua/` for complete examples:
- `plugin_monitor.lua`: Plugin execution monitoring
- `orchestrator.lua`: Multi-plugin orchestration
- `p2p_monitor.lua`: P2P network event monitoring
