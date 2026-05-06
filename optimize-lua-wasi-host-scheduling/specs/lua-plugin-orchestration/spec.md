## ADDED Requirements

### Requirement: Global Lua state management
The system SHALL maintain a global Lua state for system-wide plugin orchestration policies and scripts.

#### Scenario: Initialize global Lua state
- **WHEN** wasi-host starts
- **THEN** system SHALL create global Lua state
- **AND** register plugin orchestration host functions
- **AND** load default orchestration script if provided

#### Scenario: Access global Lua state
- **WHEN** system component needs global Lua context
- **THEN** system SHALL provide reference to global state via LuaStateManager
- **AND** ensure thread-safe access through event queue

### Requirement: Per-connection Lua sandboxing
The system SHALL create isolated Lua states for each connection or session to enable per-user plugin management.

#### Scenario: Create connection-specific Lua state
- **WHEN** new connection is established
- **THEN** system SHALL create new Lua state via LuaStateManager
- **AND** assign unique connection_id
- **AND** initialize with connection-specific host functions

#### Scenario: Get existing connection state
- **WHEN** subsequent operation references connection_id
- **THEN** system SHALL retrieve existing Lua state
- **AND** return error if connection_id not found

#### Scenario: Cleanup connection state
- **WHEN** connection closes or expires
- **THEN** system SHALL deinit Lua state
- **AND** remove from connection_states map
- **AND** free associated resources

### Requirement: Dynamic plugin discovery
The system SHALL allow Lua scripts to discover available WASM plugins and their metadata.

#### Scenario: List available plugins
- **WHEN** Lua calls `wasm_list_plugins()`
- **THEN** system SHALL return array of plugin names
- **AND** include embedded plugins
- **AND** include loaded file-based plugins

#### Scenario: Get plugin metadata
- **WHEN** Lua calls `wasm_plugin_info(plugin_name)`
- **THEN** system SHALL return plugin metadata
- **AND** include default memory, timeout, and network settings

### Requirement: Script-based plugin configuration
The system SHALL support Lua scripts to define and apply plugin configurations.

#### Scenario: Define plugin configuration
- **WHEN** Lua script defines config table
- **THEN** system SHALL parse and validate configuration
- **AND** apply to subsequent plugin starts

#### Scenario: Apply per-connection config
- **WHEN** connection-specific Lua state has custom config
- **THEN** plugins started from this state SHALL use connection config
- **AND** override global defaults

### Requirement: Concurrent plugin management
The system SHALL allow Lua scripts to manage multiple concurrent WASM plugins.

#### Scenario: Start multiple plugins
- **WHEN** Lua script calls `wasm_start` multiple times
- **THEN** each plugin SHALL run in separate thread
- **AND** receive unique handle
- **AND** operate independently

#### Scenario: Monitor multiple plugins
- **WHEN** Lua calls `wasm_list_active()`
- **THEN** system SHALL return list of active plugin handles
- **AND** include each plugin's state (running, paused, stopped, error)

#### Scenario: Stop all plugins for connection
- **WHEN** connection is closing
- **AND** multiple plugins are active for that connection
- **THEN** system SHALL gracefully stop all associated plugins
- **AND** wait for cleanup completion

### Requirement: Plugin state cleanup
The system SHALL implement automatic cleanup of expired or inactive connection states.

#### Scenario: Cleanup inactive states
- **WHEN** connection state has no activity for timeout period
- **THEN** system SHALL call `cleanupExpiredStates()`
- **AND** remove idle Lua states
- **AND** free associated resources

#### Scenario: Cleanup on Lua error
- **WHEN** Lua script encounters unrecoverable error
- **AND** is running in connection-specific state
- **THEN** system SHALL deinit that connection state
- **AND** log error details
