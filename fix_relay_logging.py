#!/usr/bin/env python3
"""Script to fix logging integration in relay.zig"""

import re

def fix_relay_logging():
    with open('D:\\claudework\\wasi-host\\src\\p2p\\relay.zig', 'r', encoding='utf-8') as f:
        content = f.read()

    # Replace logger variable references with self.logger
    replacements = [
        (r'if \(logger\) \|l\| \{ l\.(\w+)\("\[relay\] (.*?)", \{(.*?)\}\} \}',
         r'if (self.logger) |l| { l.\1("\[relay\] \2", .{\3}) }'),
        (r'if \(logger\) \|l\| \{ l\.(\w+)\("\[relay/tcp\] (.*?)", \{(.*?)\}\} \}',
         r'if (self.logger) |l| { l.\1("\[relay/tcp\] \2", .{\3}) }'),
        (r'if \(logger\) \|l\| \{ l\.(\w+)\("([^"]*)", \{(.*?)\}\} \}',
         r'if (self.logger) |l| { l.\1("\2", .{\3}) }'),
        (r'if \(logger\) \|l\| \{ l\.(\w+)\("(.*?)", \{\}\} \}',
         r'if (self.logger) |l| { l.\1("\2", .{}) }'),
        (r'if \(logger\) \|l\| \{ l\.(\w+)\("\[relay/reader\] (.*?)", \{\}\} \}',
         r'if (self.logger) |l| { l.\1("\[relay/reader\] \2", .{}) }'),
    ]

    for old, new in replacements:
        content = re.sub(old, new, content)

    # Fix the run function to use self.logger
    content = re.sub(
        r'if \(logger\) \|l\| \{ l\.info\("\[relay\] TCP relay server 已启动 :\{d\}\n", \.\{\{self\.port\}\}\) \};',
        r'if (self.logger) |l| { l.info("[relay] TCP relay server 已启动 :{d}", .{self.port}) };',
        content
    )

    # Write back
    with open('D:\\claudework\\wasi-host\\src\\p2p\\relay.zig', 'w', encoding='utf-8') as f:
        f.write(content)

    print("Fixed relay logging integration")

if __name__ == "__main__":
    fix_relay_logging()