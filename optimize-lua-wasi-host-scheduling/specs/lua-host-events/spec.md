## ADDED Requirements

### Requirement: WASM-to-Lua event posting
The system SHALL provide mechanism for WASM plugins to post events to Lua state for notification.

#### Scenario: Plugin posts completion event
- **WHEN** WASM plugin finishes execution successfully
- **THEN** plugin SHALL post "plugin_complete" event to Lua
- **AND** include plugin handle in event payload
- **AND** include exit status

#### Scenario: Plugin posts timeout event
- **WHEN** WASM plugin exceeds timeout guard
- **THEN** plugin SHALL post "plugin_timeout" event to Lua
- **AND** include plugin handle and timeout value

#### Scenario: Plugin posts error event
- **WHEN** WASM plugin encounters execution error
- **THEN** plugin SHALL post "plugin_error" event to Lua
- **AND** include plugin handle and error message

### Requirement: Event payload structure
The system SHALL define consistent event payload structure for all WASM-to-Lua events.

#### Scenario: Completion event payload
- **WHEN** plugin_complete event is posted
- **THEN** payload SHALL contain:
  - event_type: "plugin_complete"
  - plugin_handle: unique identifier
  - exit_code: numeric exit status
  - duration_ms: execution time

#### Scenario: Error event payload
- **WHEN** plugin_error event is posted
- **THEN** payload SHALL contain:
  - event_type: "plugin_error"
  - plugin_handle: unique identifier
  - error_code: numeric error identifier
  - error_message: descriptive text

### Requirement: Lua event callbacks
The system SHALL allow Lua scripts to register callback functions for specific event types.

#### Scenario: Register completion callback
- **WHEN** Lua calls `wasm_on_event("plugin_complete", function)`
- **THEN** system SHALL store callback for plugin_complete events
- **AND** invoke callback when event is processed

#### Scenario: Unregister callback
- **WHEN** Lua calls `wasm_off_event("plugin_complete")`
- **THEN** system SHALL remove registered callback
- **AND** events of this type shall be ignored

#### Scenario: Default event handler
- **WHEN** event type has no registered callback
- **THEN** system SHALL use default logging handler
- **AND** log event details to console

### Requirement: Event processing loop
The system SHALL process pending events in the main event loop without blocking Chord operations.

#### Scenario: Process events in event loop
- **WHEN** main loop reaches event processing phase
- **THEN** system SHALL process all pending events in queue
- **AND** invoke registered callbacks
- **AND** continue to next loop iteration

#### Scenario: Event processing time limit
- **WHEN** event processing takes longer than 10ms
- **THEN** system SHALL yield to Chord tick
- **AND** continue processing in next iteration

### Requirement: P2P event integration
The system SHALL allow Lua scripts to receive Chord DHT events through the same event system.

#### Scenario: Node join event
- **WHEN** new node joins Chord ring
- **THEN** system SHALL post "chord_node_join" event to Lua
- **AND** include node ID and address

#### Scenario: Successor change event
- **WHEN** successor node changes
- **THEN** system SHALL post "chord_successor_change" event to Lua
- **AND** include old and new successor IDs

#### Scenario: DHT put event
- **WHEN** key-value pair is stored in DHT
- **THEN** system SHALL post "dht_put" event to Lua
- **AND** include key and value size

### Requirement: Event persistence (optional)
The system MAY provide mechanism to persist events for debugging and audit purposes.

#### Scenario: Enable event logging
- **WHEN** configuration enables event logging
- **THEN** system SHALL write all events to log file
- **AND** include timestamp and payload

#### Scenario: Disable event logging
- **WHEN** event logging is disabled
- **THEN** system SHALL NOT write events to file
- **AND** only process in-memory
