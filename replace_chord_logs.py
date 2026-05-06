#!/usr/bin/env python3
"""Script to replace std.debug.print calls in chord/node.zig with logging"""

import re

# Read the file
with open('D:\\claudework\\wasi-host\\src\\p2p\\chord\\node.zig', 'r', encoding='utf-8') as f:
    content = f.read()

# Pattern to match std.debug.print calls with chord prefix
pattern = r'std\.debug\.print\(\["\[chord\] (.*?)", \.(.*?)\]\)'
# Replace with logger calls
replacement = r'if (node.logger) |l| { l.\2("\1", .{\2}) }'
content = re.sub(pattern, replacement, content)

# Pattern for store messages
pattern = r'std\.debug\.print\("\[store\] (.*?)", \.(.*?)\)'
replacement = r'if (node.logger) |l| { l.\1("\1", .{\2}) }'
content = re.sub(pattern, replacement, content)

# Simple replacements for standalone chord messages
simple_replacements = [
    (r'std\.debug\.print\("\[chord\] (.*?)"\,', r'if (node.logger) |l| { l.info("\1", .{}) }'),
    (r'std\.debug\.print\("\[chord\] (.*?)"\)\s*;', r'if (node.logger) |l| { l.info("\1", .{}) }'),
    (r'std\.debug\.print\("recv 错误: {}"\n', r'if (node.logger) |l| { l.err("recv 错误: {}", .{err}) }'),
]

for old, new in simple_replacements:
    content = re.sub(old, new, content)

# Write back
with open('D:\\claudework\\wasi-host\\src\\p2p\\chord\\node.zig', 'w', encoding='utf-8') as f:
    f.write(content)

print("Replacements completed")