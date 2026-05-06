-- Example Lua script: P2P Event Monitor
-- This script demonstrates:
-- - Monitoring Chord DHT events
-- - Tracking network topology changes
-- - Logging P2P events

print("[P2P Monitor] Starting P2P event monitoring...")

-- Register callback for node join events
wasm_on_event("chord_node_join", function(payload)
    print(string.format("[P2P Monitor] Node joined: id=%s, host=%s:%d",
        payload.node_id, payload.host, payload.port))
end)

-- Register callback for successor changes
wasm_on_event("chord_successor_change", function(payload)
    print(string.format("[P2P Monitor] Successor changed:")
        .. " old=%s, new=%s",
        payload.old_successor_id, payload.new_successor_id))
end)

-- Register callback for DHT put operations
wasm_on_event("dht_put", function(payload)
    print(string.format("[P2P Monitor] DHT put: key=%s (size=%d bytes)",
        payload.key, payload.value_size))
end)

-- Register callback for plugin errors
wasm_on_event("plugin_error", function(payload)
    print(string.format("[P2P Monitor] Plugin error: %s (handle=%d, error=%s)",
        payload.plugin_name, payload.plugin_handle, payload.error_message))
end)

-- Monitor loop
local stats = {
    node_joins = 0,
    successor_changes = 0,
    dht_puts = 0,
    plugin_errors = 0,
}

while true do
    -- Process events
    wasm_process_events(10)

    -- Get statistics
    stats.node_joins = stats.node_joins + 1
    stats.successor_changes = stats.successor_changes + 1
    stats.dht_puts = stats.dht_puts + 1
    stats.plugin_errors = stats.plugin_errors + 1

    -- Print status every 10 seconds
    local now = os.time()
    if now % 10 == 0 then
        print(string.format("\n[P2P Monitor Status]")
            .. " Nodes joined: %d"
            .. " Successor changes: %d"
            .. " DHT puts: %d"
            .. " Plugin errors: %d",
            stats.node_joins,
            stats.successor_changes,
            stats.dht_puts,
            stats.plugin_errors))
    end

    -- Sleep for 1 second
    os.execute("sleep 1")
end
