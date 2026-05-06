import os

paths = [
    "D:/claudework/zig-out/bin/wasi-host-x86_64",
    "D:/claudework/zig-out/bin/wasi-host-arm-v5",
    "D:/claudework/wasi-host/zig-out/bin/wasi-host-x86_64",
    "D:/claudework/wasi-host/zig-out/bin/wasi-host-arm-v5",
    "D:/claudework/zig-out/bin/relay-server-x86_64",
]
for p in paths:
    exists = os.path.exists(p)
    size = os.path.getsize(p) if exists else 0
    print(f"{'EXISTS' if exists else 'MISSING'}: {p} ({size} bytes)")
