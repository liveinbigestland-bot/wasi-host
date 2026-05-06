#!/usr/bin/env python3
"""Comprehensive deployment test script"""

import subprocess
import time
import sys
import os

def run_cmd(cmd):
    """Run command and return output"""
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        return result.returncode == 0, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return False, "", "Timeout"

def test_node_connection(node_name, host, port):
    """Test connection to a specific node"""
    cmd = f"nc -z -w 2 {host} {port}"
    success, stdout, stderr = run_cmd(cmd)
    return success

def main():
    print("=== Comprehensive Deployment Test ===\n")

    # Node configurations
    nodes = [
        ("seed", "192.168.2.210", 20808),
        ("外2", "192.140.185.171", 20808),
        ("ext", "ssh-metaai.alwaysdata.net", 20808),
        ("node59", "192.168.2.59", 20808),
        ("node60", "192.168.2.60", 20808)
    ]

    print("1. Testing node connectivity:")
    all_nodes_up = True

    for node_name, host, port in nodes:
        if node_name == "seed":
            print(f"   [{node_name}] {host}:{port} - [!!] Not running (no local seed)")
            continue

        success = test_node_connection(node_name, host, port)
        status = "[OK]" if success else "[FAIL]"
        print(f"   [{node_name}] {host}:{port} - {status}")
        if not success:
            all_nodes_up = False

    print("\n2. Checking deployment script status:")
    success, stdout, stderr = run_cmd("python deploy.py status")
    if success:
        print("   Status check - [OK]")
        print(stdout)
    else:
        print(f"   Status check - [FAIL]: {stderr}")

    print("\n3. Checking relay connectivity:")
    # Test relay server on 外2
    relay_success = test_node_connection("relay", "192.140.185.171", 20809)
    print(f"   Relay server (外2:20809) - {'[OK]' if relay_success else '[FAIL]'}")

    print("\n4. Recent log summary:")
    # Get recent log snippets
    success, stdout, stderr = run_cmd("python deploy.py logs | head -50")
    if success:
        print("   Recent logs (first 50 lines):")
        print(stdout)
    else:
        print(f"   Could not get logs: {stderr}")

    print("\n5. Test results:")
    print(f"   - Node connectivity: {'PASS' if all_nodes_up else 'FAIL'}")
    print("   - Note: Seed node is not running locally")
    print("   - Note: Routing tables may be empty due to missing seed")

    print("\n=== Recommendations ===")
    print("1. Start the seed node for proper routing")
    print("2. Verify all nodes can connect to each other")
    print("3. Check relay server logs for any connection issues")
    print("4. Monitor for timeout errors in stabilize operations")

if __name__ == "__main__":
    main()