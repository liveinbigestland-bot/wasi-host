#!/usr/bin/env python3
import os
import sys

# Check files exist
files = [
    'src/lua/events.zig',
    'src/lua/state.zig',
    'src/lua/host_functions.zig',
    'tests/lua/test_lua_wasm_control.zig',
    'tests/lua/test_wasm_to_lua_events.zig',
    'tests/lua/test_concurrent_plugins.zig',
    'tests/lua/test_latency.zig',
    'tests/lua/test_event_queue.zig',
    'docs/lua_api_reference.md',
]

print('Checking implementation files:')
print()
all_exist = True
for f in files:
    exists = os.path.exists(f)
    status = '✓' if exists else '✗'
    print(f'  {status} {f}')
    if not exists:
        all_exist = False

print()
if all_exist:
    print('All files present!')
    sys.exit(0)
else:
    print('Some files are missing!')
    sys.exit(1)
