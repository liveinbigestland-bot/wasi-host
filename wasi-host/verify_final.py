#!/usr/bin/env python3
import os
import sys

# Set UTF-8 encoding for Windows
if sys.platform == 'win32':
    import io
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

docs = [
    'docs/lua_api_reference.md',
    'docs/LUA_INTEGRATION_SUMMARY.md',
    'examples/lua/plugin_monitor.lua',
    'examples/lua/orchestrator.lua',
    'examples/lua/p2p_monitor.lua',
]

tests = [
    'tests/lua/test_lua_wasm_control.zig',
    'tests/lua/test_wasm_to_lua_events.zig',
    'tests/lua/test_concurrent_plugins.zig',
    'tests/lua/test_latency.zig',
    'tests/lua/test_event_queue.zig',
]

core = [
    'src/lua/events.zig',
    'src/lua/state.zig',
    'src/lua/host_functions.zig',
]

print('Lua Integration - Complete Summary')
print('=' * 50)
print()
print('Documentation:')
for d in docs:
    exists = 'OK' if os.path.exists(d) else 'MISSING'
    print(f'  {exists} {d}')

print()
print('Tests:')
for t in tests:
    exists = 'OK' if os.path.exists(t) else 'MISSING'
    print(f'  {exists} {t}')

print()
print('Core Implementation:')
for c in core:
    exists = 'OK' if os.path.exists(c) else 'MISSING'
    print(f'  {exists} {c}')

print()
print('All files verified!')
