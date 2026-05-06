## Context

The wasi-host project currently initializes a Lua engine but lacks integration with the WASM plugin execution pipeline. The current architecture has:

- Lua state initialized at startup but unused in plugin execution
- WASM plugins running in independent threads with no Lua coordination
- LuaStateManager supporting global and per-connection states but no scheduling mechanism
- No event-driven communication between WASM and Lua

Constraints:
- Must maintain thread safety (WASM plugins run in separate threads)
- Cannot block the Chord event loop (100ms tick interval)
- Memory footprint must remain modest (running on ARMv7l devices)
- Existing P2P integration must remain functional

## Goals / Non-Goals

**Goals:**
- Enable Lua scripts to control WASM plugin lifecycle dynamically
- Provide bidirectional event flow between WASM and Lua
- Support per-connection Lua sandboxing for multi-user scenarios
- Maintain sub-millisecond Lua→WASI call latency
- Thread-safe event queue for asynchronous communication

**Non-Goals:**
- Full WASI sandboxing in Lua (Lua itself provides isolation)
- Hot-reloading of WASM plugins (beyond current implementation)
- Complex Lua module system (keep it minimal and focused)
- Persistent Lua state across restarts (unless explicitly saved)

## Decisions

### Event Queue Architecture

**Decision:** Use a lock-free MPMC (Multi-Producer Multi-Consumer) event queue

**Rationale:**
- WASM plugins (multiple threads) and main thread both produce events
- Lua event consumer runs on main thread only
- Lock-free design avoids contention with Chord event loop
- Zig's std.atomic provides primitives for this

**Alternatives considered:**
- Mutex-protected queue: Simpler but could block Chord ticks
- Channel-based: More complex, not needed for single-consumer case

### Lua State Management

**Decision:** Keep existing LuaStateManager with added event processing loop

**Rationale:**
- Already has global and per-connection state separation
- Only need to add event queue and processing method
- Minimal changes to existing structure

**Alternatives considered:**
- Single global Lua state: No isolation between connections
- Full multi-threaded Lua: Complex, Lua 5.1 has limited threading support

### WASM-to-Lua Callbacks

**Decision:** Use lightweight string-based event messages with JSON payload

**Rationale:**
- Simple to parse in Lua (using standard json library or simple parser)
- Type-safe enough for our use cases (state, timeout, error)
- Avoids complex FFI structures

**Alternatives considered:**
- Direct C callbacks: More complex FFI, harder to debug
- Binary protocol: Overkill for simple events

### Plugin Lifecycle Control

**Decision:** Lua functions for start/stop/pause/resume with async completion notification

**Rationale:**
- Non-blocking for main event loop
- Allows Lua to manage multiple concurrent plugins
- Matches the existing TimeoutGuard pattern

**Alternatives considered:**
- Synchronous control: Would block Chord loop
- Full process manager: Overkill for simple plugin control

## Risks / Trade-offs

### Lua GC Pauses

**Risk:** Lua's garbage collector may cause unpredictable pauses affecting Chord tick timing.

**Mitigation:**
- Use incremental GC mode (`lua_gc(LUA_GCCOLLECT)` in controlled intervals)
- Set GC threshold appropriately for constrained environments
- Consider calling GC in idle periods only

### Event Queue Overflow

**Risk:** High-frequency WASM events could fill the event queue.

**Mitigation:**
- Bounded queue size with backpressure notification
- Drop non-critical events when queue is full
- Add monitoring for queue depth

### Memory Leaks in Lua

**Risk:** Long-running Lua scripts may accumulate memory.

**Mitigation:**
- Implement state cleanup timeout (existing TODO in cleanupExpiredStates)
- Periodically restart connection states after inactivity
- Provide manual state reset function

### Thread Safety

**Risk:** Race conditions between WASM threads posting events and Lua consuming them.

**Mitigation:**
- Lock-free queue implementation with proper memory ordering
- Single consumer (main thread) eliminates read-write conflicts
- Atomic operations for queue state

## Migration Plan

### Phase 1: Event Queue Foundation
1. Implement lock-free MPMC event queue
2. Add event types enum (PluginStart, PluginStop, PluginError, etc.)
3. Integrate queue into LuaStateManager

### Phase 2: Lua Host Functions
1. Add plugin control functions to Lua API (wasm_start, wasm_stop, etc.)
2. Register host functions in Lua initialization
3. Add event processing method to LuaStateManager

### Phase 3: WASM-to-Lua Callbacks
1. Modify runPlugin to post events to Lua queue
2. Add event payload encoding
3. Handle Lua callback errors gracefully

### Phase 4: Integration
1. Wire Lua event processing into main event loop
2. Add Lua script loading capability (optional)
3. Test with existing plugin configurations

**Rollback:**
- All changes additive; can disable Lua integration by not loading scripts
- Existing WASM-only execution path remains unchanged

## Open Questions

1. **Lua Script Loading:** Should we load Lua scripts from files or embed them like WASM plugins?
   - Recommendation: Support both, with file-based for development, embedded for production

2. **Event Serialization:** Simple JSON or custom format for event payloads?
   - Recommendation: Start with simple key-value pairs, upgrade to JSON if needed

3. **P2P Event Integration:** Should Chord events (successor changes, etc.) trigger Lua events?
   - Recommendation: Yes, but as optional feature (requires Lua script to register)

4. **Error Handling:** How to handle Lua errors during host function execution?
   - Recommendation: Log and continue, with configurable "crash on error" mode
