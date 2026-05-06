## ADDED Requirements

### Requirement: Lua to WASM control functions
The system SHALL provide Lua host functions that allow Lua scripts to control WASM plugin lifecycle including start, stop, pause, and resume operations.

#### Scenario: Start WASM plugin from Lua
- **WHEN** Lua script calls `wasm_start(plugin_name, config)`
- **THEN** system SHALL initialize the WASM runtime with the specified configuration
- **AND** return a plugin handle for subsequent operations

#### Scenario: Stop running WASM plugin
- **WHEN** Lua script calls `wasm_stop(plugin_handle)`
- **THEN** system SHALL gracefully terminate the WASM plugin
- **AND** release associated resources

#### Scenario: Pause WASM plugin execution
- **WHEN** Lua script calls `wasm_pause(plugin_handle)`
- **THEN** system SHALL suspend plugin execution without terminating

#### Scenario: Resume paused WASM plugin
- **WHEN** Lua script calls `wasm_resume(plugin_handle)`
- **AND** plugin is currently paused
- **THEN** system SHALL continue plugin execution from pause point

### Requirement: Thread-safe event queue
The system SHALL implement a lock-free MPMC (Multi-Producer Multi-Consumer) event queue for asynchronous communication between WASM plugins and Lua.

#### Scenario: WASM plugin posts event to queue
- **WHEN** WASM plugin needs to notify Lua of state change
- **THEN** system SHALL add event to queue without blocking
- **AND** return immediately

#### Scenario: Lua consumes event from queue
- **WHEN** main thread processes Lua event queue
- **THEN** system SHALL retrieve next available event
- **AND** invoke registered Lua callback with event payload

#### Scenario: Queue overflow handling
- **WHEN** event queue reaches capacity
- **THEN** system SHALL apply backpressure strategy
- **AND** log warning message
- **AND** may drop non-critical events

### Requirement: Plugin handle management
The system SHALL provide unique handles for each WASM plugin instance that can be used by Lua for control operations.

#### Scenario: Generate unique plugin handle
- **WHEN** Lua starts a new WASM plugin
- **THEN** system SHALL assign unique handle
- **AND** store handle-to-plugin mapping

#### Scenario: Validate plugin handle
- **WHEN** Lua calls control function with handle
- **THEN** system SHALL validate handle exists
- **AND** return error if handle is invalid

#### Scenario: Cleanup on plugin termination
- **WHEN** plugin terminates normally or via error
- **THEN** system SHALL remove handle from registry
- **AND** free associated resources

### Requirement: Configuration passing
The system SHALL allow Lua scripts to pass configuration data to WASM plugins at startup.

#### Scenario: Pass configuration to WASM plugin
- **WHEN** Lua calls `wasm_start(plugin_name, config)`
- **AND** config contains memory allocation, timeout, and network settings
- **THEN** system SHALL initialize WASM runtime with specified config
- **AND** apply timeout guard with provided timeout_ms

#### Scenario: Default configuration
- **WHEN** Lua omits config parameter or provides null
- **THEN** system SHALL use default configuration values
- **AND** initialize with 512KB memory, 5000ms timeout, no network access

### Requirement: Bidirectional latency requirements
The system SHALL maintain sub-millisecond latency for Lua-to-WASM control calls.

#### Scenario: Measure Lua-to-WASM call latency
- **WHEN** Lua calls synchronous control function
- **THEN** round-trip latency SHALL be less than 1ms for direct calls
- **AND** SHALL be less than 10ms for async operations

#### Scenario: Event queue processing latency
- **WHEN** WASM posts event to queue
- **THEN** event SHALL be processed within one Chord tick (100ms)
- **AND** typically within 10ms
