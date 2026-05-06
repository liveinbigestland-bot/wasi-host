#!/usr/bin/env python3
"""Script to fix logging statements in proxy.zig"""

import re

def fix_proxy_logging():
    with open('D:\\claudework\\wasi-host\\src\\p2p\\proxy.zig', 'r', encoding='utf-8') as f:
        content = f.read()

    # Pattern to match the invalid logging statements
    pattern = r'const logger = logging\.getLogger\("p2p\.@basename"\); if \(logger\) \|l\| \{ l\.info\("\[([^\]]+)\] ([^"]+)"(?:, \.\{([^}]*)\})? \}\);'

    def replace_logging(match):
        module = match.group(1)
        message = match.group(2)
        args = match.group(3) if match.group(3) else ""

        # Clean up the message
        message = message.replace('\\n', '')

        # Build the replacement
        if args:
            return f'log.info("[{module}] {message}", .{{{args}}});'
        else:
            return f'log.info("[{module}] {message}", .{{}});'

    content = re.sub(pattern, replace_logging, content)

    # Write back
    with open('D:\\claudework\\wasi-host\\src\\p2p\\proxy.zig', 'w', encoding='utf-8') as f:
        f.write(content)

    print("Fixed proxy.zig logging statements")

if __name__ == "__main__":
    fix_proxy_logging()
