#!/usr/bin/env python3
"""Script to replace std.debug.print calls in p2p module with logging"""

import re
import os

def process_file(file_path):
    """Process a single Zig file and replace std.debug.print with logging"""
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Pattern to match std.debug.print with bracket format
    pattern1 = r'std\.debug\.print\(\["(.*?)", \.(.*?)\]\)'
    replacement1 = r'if (node.logger) |l| { l.\2("\1", .{\2}) }'
    content = re.sub(pattern1, replacement1, content)

    # Pattern for simple std.debug.print calls
    pattern2 = r'std\.debug\.print\("([^"]*)"\)'

    # File-specific replacements
    if 'node.zig' in file_path:
        # Chord node specific patterns
        replacements = [
            (r'std\.debug\.print\("([^"]*)"\)', r'if (node.logger) |l| { l.info("\1", .{}) }'),
            (r'std\.debug\.print\("([^\"]*)", \.(.*?)\)', r'if (node.logger) |l| { l.info("\1", .{\2}) }'),
        ]
    elif 'relay' in file_path or 'socks_relay' in file_path:
        # Relay specific patterns
        replacements = [
            (r'std\.debug\.print\("([^"]*)"\)', r'if (logger) |l| { l.info("\1", .{}) }'),
            (r'std\.debug\.print\("([^\"]*)", \.(.*?)\)', r'if (logger) |l| { l.info("\1", .{\2}) }'),
            (r'std\.debug\.print\("recv 错误: {}"\n', r'if (logger) |l| { l.err("recv 错误: {}", .{err}) }'),
        ]
    elif 'thread_pool' in file_path or 'event_loop' in file_path:
        # General patterns for utility modules
        replacements = [
            (r'std\.debug\.print\("([^"]*)"\)', r'const logger = logging.getLogger("p2p.@basename"); if (logger) |l| { l.info("\1", .{}) }'),
            (r'std\.debug\.print\("([^\"]*)", \.(.*?)\)', r'const logger = logging.getLogger("p2p.@basename"); if (logger) |l| { l.info("\1", .{\2}) }'),
        ]
    else:
        # Default patterns for other p2p files
        replacements = [
            (r'std\.debug\.print\("([^"]*)"\)', r'const logger = logging.getLogger("p2p.@basename"); if (logger) |l| { l.info("\1", .{}) }'),
            (r'std\.debug\.print\("([^\"]*)", \.(.*?)\)', r'const logger = logging.getLogger("p2p.@basename"); if (logger) |l| { l.info("\1", .{\2}) }'),
        ]

    # Apply all replacements
    for old, new in replacements:
        content = re.sub(old, new, content)

    # Write back if changes were made
    original_content = open(file_path, 'r', encoding='utf-8').read()
    if content != original_content:
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f"Processed: {file_path}")
        return True
    return False

# Process all p2p files
p2p_dir = 'D:\\claudework\\wasi-host\\src\\p2p'
processed_count = 0

for root, dirs, files in os.walk(p2p_dir):
    for file in files:
        if file.endswith('.zig'):
            file_path = os.path.join(root, file)
            if process_file(file_path):
                processed_count += 1

print(f"\nReplacements completed in {processed_count} files")