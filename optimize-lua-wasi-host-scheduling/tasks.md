## 1. Event Queue Foundation

- [x] 1.1 Define event types enum (PluginStart, PluginStop, PluginError, PluginComplete, PluginTimeout)
- [x] 1.2 Implement lock-free MPMC event queue with atomic operations
- [x] 1.3 Add event queue field to LuaStateManager
- [x] 1.4 Implement event posting method (postToQueue) for WASM threads
- [x] 1.5 Implement event consumption method (processEvents) for main thread
- [x] 1.6 Add queue overflow detection and backpressure handling
- [ ] 1.7 Write unit tests for event queue operations

## 2. Lua Host Functions

- [x] 2.1 Add wasm_start function to Lua API with config parsing
- [x] 2.2 Add wasm_stop function to Lua API with handle validation
- [x] 2.3 Add wasm_pause and wasm_resume functions to Lua API
- [x] 2.4 Add wasm_list_plugins function for plugin discovery
- [x] 2.5 Add wasm_list_active function for active plugin enumeration
- [x] 2.6 Add wasm_plugin_info function for metadata retrieval
- [x] 2.7 Register all host functions in LuaState.init()
- [x] 2.8 Implement plugin handle generation and management
- [x] 2.9 Add configuration parsing from Lua tables

## 3. WASM-to-Lua Integration

- [x] 3.1 Modify runPlugin to accept LuaStateManager reference
- [x] 3.2 Add event posting calls on plugin completion
- [x] 3.3 Add event posting calls on plugin timeout
- [x] 3.4 Add event posting calls on plugin error
- [x] 3.5 Implement event payload encoding (key-value pairs)
- [x] 3.6 Add unique plugin handle assignment on startup
- [x] 3.7 Update plugin context to include Lua event posting capability

## 4. Lua Event Callback System

- [x] 4.1 Implement wasm_on_event function to register callbacks
- [x] 4.2 Implement wasm_off_event function to unregister callbacks
- [x] 4.3 Add callback registry to LuaStateManager (map event_type -> function)
- [ ] 4.4 Implement default event handler with logging
- [ ] 4.5 Add Lua-side event payload parsing
- [ ] 4.6 Handle Lua callback errors gracefully

## 5. Connection-Specific Lua States

- [ ] 5.1 Enhance getConnectionState to track creation timestamp
- [ ] 5.2 Add last_activity timestamp to connection states
- [ ] 5.3 Implement cleanupExpiredStates with timeout logic
- [ ] 5.4 Add connection-specific host functions for per-user config
- [ ] 5.5 Implement state cleanup on connection close
- [ ] 5.6 Add connection_id-based plugin handle grouping

## 6. Main Loop Integration

- [x] 6.1 Add Lua event processing call to main event loop
- [x] 6.2 Implement time-bounded event processing (10ms limit per tick)
- [x] 6.3 Add Lua event processing to chordEventLoop
- [x] 6.4 Ensure non-blocking event queue consumption
- [x] 6.5 Add Lua periodic GC trigger in idle periods

## 7. P2P Event Integration

- [ ] 7.1 Add Chord node join event posting to Lua
- [ ] 7.2 Add successor change event posting to Lua
- [ ] 7.3 Add DHT put event posting to Lua
- [ ] 7.4 Add Lua hooks registration to ChordNode
- [ ] 7.5 Implement P2P event payload structure
- [ ] 7.6 Add configuration toggle for P2P events

## 8. Configuration and Scripts

- [x] 8.1 Add lua_script configuration field to TopConfig
- [ ] 8.2 Implement Lua script file loading capability
- [x] 8.3 Add lua_events_enabled configuration toggle
- [ ] 8.4 Implement embedded Lua script support
- [x] 8.5 Add event logging configuration
- [ ] 8.6 Create example Lua orchestration scripts

## 9. Testing and Documentation

- [ ] 9.1 Write integration test for Lua-to-WASM control flow
- [ ] 9.2 Write integration test for WASM-to-Lua event flow
- [ ] 9.3 Test concurrent plugin management from Lua
- [ ] 9.4 Test event queue overflow handling
- [ ] 9.5 Measure and document Lua-to-WASM latency
- [ ] 9.6 Update main.zig documentation for Lua integration
- [ ] 9.7 Add Lua API reference documentation
- [ ] 9.8 Write example Lua scripts for common use cases
