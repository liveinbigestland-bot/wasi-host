#!/usr/bin/env python3
"""Script to fix logging statements in relay_v2.zig"""

import re

def fix_relay_v2_logging():
    with open('D:\\claudework\\wasi-host\\src\\p2p\\relay_v2.zig', 'r', encoding='utf-8') as f:
        content = f.read()

    # Pattern to match the invalid logging statements
    pattern = r'if \(self\.logger\) \|l\| \{ l\.info\("\[([^\]]+)\] ([^"]+)"(?:, \.\{([^}]*)\})? \}\);'

    def replace_logging(match):
        module = match.group(1)
        message = match.group(2)
        args = match.group(3) if match.group(3) else ""

        # Clean up the message
        message = message.replace('\\n', '')

        # Build the replacement
        if args:
            return f'if (self.logger) |l| {{ l.info("[{module}] {message}", .{{{args}}}); }}'
        else:
            return f'if (self.logger) |l| {{ l.info("[{module}] {message}", .{{}}); }}'

    content = re.sub(pattern, replace_logging, content)

    # Write back
    with open('D:\\claudework\\wasi-host\\src\\p2p\\relay_v2.zig', 'w', encoding='utf-8') as f:
        f.write(content)

    print("Fixed relay_v2.zig logging statements")

if __name__ == "__main__":
    fix_relay_v2_logging()
