#!/usr/bin/env python3
"""Test lldb-server remote debugging on 外2"""
import os, sys, time, signal
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'wasi-host'))
from deploy import RemoteNode, MACHINES

m = [x for x in MACHINES if x['name'] == '外2'][0]
print(f"=== {m['name']} — lldb-server test ===")

with RemoteNode(m) as n:
    n.connect(timeout=15)

    # 1. Create a simple test program
    test_c = """
#include <stdio.h>
#include <unistd.h>
int main() {
    int i = 0;
    while (1) {
        printf("hello %d\\n", i++);
        sleep(2);
    }
    return 0;
}
"""
    # Write test program in heredoc
    n.exec("cat > /tmp/test.c << 'ENDTEST'\n" + test_c.strip() + "\nENDTEST", timeout=5)
    n.exec("gcc -g -O0 -o /tmp/test_lldb /tmp/test.c 2>&1", timeout=30)
    ec, out, err = n.exec("ls -la /tmp/test_lldb && file /tmp/test_lldb", timeout=5)
    print(out[:300] if out else '')

    # 2. Kill any existing wasi-host instance for the test
    n.exec("pkill -f wasi-host 2>/dev/null || true", timeout=5)
    time.sleep(1)

    # 3. Start test program under lldb-server in background
    n.exec("fuser -k 12345/tcp 2>/dev/null || true", timeout=5)
    # Use platform mode for simpler debugging
    n.exec(
        "nohup lldb-server-20 gdbserver :12345 /tmp/test_lldb > /tmp/lldb-test.log 2>&1 &",
        timeout=5,
    )
    time.sleep(2)

    # 4. Check it's running
    ec, out, err = n.exec("ss -tlnp | grep 12345", timeout=5)
    print(f"Port 12345: {out.strip()[:200]}")
    ec, out, err = n.exec("cat /tmp/lldb-test.log", timeout=5)
    print(f"Log: {out.strip()[:200]}")

    # 5. Test connecting from local - check if we have any lldb client
print()
print("=== Local lldb client ===")

# Check Windows lldb availability
import subprocess
for candidate in [
    "lldb.exe",
    "lldb",
    r"C:\Program Files\LLVM\bin\lldb.exe",
]:
    try:
        ec = subprocess.run([candidate, "--version"], capture_output=True, timeout=10).returncode
        print(f"{candidate}: found" if ec == 0 else f"{candidate}: not found")
    except:
        print(f"{candidate}: not found")

print()
print("=== Next steps ===")
print("On local Windows (if lldb client installed):")
print("  lldb -O 'platform select remote-gdb-server' -O 'platform connect connect://192.140.185.171:12345'")
print()
print("Then in lldb:")
print("  (lldb) process attach -n test_lldb")
print("  (lldb) continue")
print("  (lldb) break set -n main")
print("  (lldb) run")
