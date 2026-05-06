## Why

The Lua engine is initialized but currently not integrated with the WASM plugin execution pipeline. There is no coordination mechanism between Lua scripting and WASM runtime, missing an opportunity for dynamic scripting, runtime configuration, and flexible plugin orchestration.

## What Changes

- Add Lua-WASI mutual scheduling layer to coordinate execution between Lua scripts and WASM plugins
- Implement Lua host functions for controlling WASM plugin lifecycle (start, stop, pause, resume)
- Add WASM host callbacks to Lua for plugin state notifications (completion, timeout, errors)
- Create Lua sandbox for connection-specific plugin management
- Add event queue for asynchronous Lua-WASI communication

## Capabilities

### New Capabilities

- `lua-wasi-bridge`: Bidirectional communication and control between Lua scripts and WASM runtime
- `lua-plugin-orchestration`: Dynamic plugin management through Lua scripting
- `lua-host-events`: Event-driven communication from WASM back to Lua

### Modified Capabilities

(No existing specs modified - this is a new capability layer)

## Impact

Affected code:

- `src/lua/state.zig` - Add scheduling and event queue to LuaStateManager
- `src/lua/api.zig` - Add WASM control host functions
- `main.zig` - Integrate Lua scheduler with WASM plugin execution loop
- `src/host/p2p_bindings.zig` - Add Lua hooks for P2P events

New dependencies:

- None (uses existing Lua and wasm3 bindings)

Performance impact:

- Minimal overhead for Lua-WASI bridge (microsecond-level call latency)
- Added memory for event queues and Lua state management
