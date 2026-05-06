#!/usr/bin/env python3
"""Script to fix logging statements in wss.zig"""

import re

def fix_wss_logging():
    with open('D:\\claudework\\wasi-host\\src\\p2p\\wss.zig', 'r', encoding='utf-8') as f:
        content = f.read()

    # Pattern to match the invalid logging statements
    pattern = r'const logger = logging\.getLogger\("p2p\.@basename"\); if \(logger\) \|l\| \{ l\.info\("\[wss\] ([^"]+)"(?:, \.\{([^}]*)\})? \}\);'

    def replace_logging(match):
        message = match.group(1)
        args = match.group(2) if match.group(2) else ""

        # Clean up the message
        message = message.replace('\\n', '')

        # Build the replacement
        if args:
            return f'log.info("[wss] {message}", .{{{args}}});'
        else:
            return f'log.info("[wss] {message}", .{{}});'

    content = re.sub(pattern, replace_logging, content)

    # Write back
    with open('D:\\claudework\\wasi-host\\src\\p2p\\wss.zig', 'w', encoding='utf-8') as f:
        f.write(content)

    print("Fixed wss.zig logging statements")

if __name__ == "__main__":
    fix_wss_logging()
