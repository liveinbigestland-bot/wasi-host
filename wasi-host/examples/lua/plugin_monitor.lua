-- Example Lua script: Plugin Monitor
-- This script demonstrates:
-- - Registering event callbacks for plugin lifecycle events
-- - Monitoring plugin execution
-- - Logging metrics and statistics

local start_time = os.time()
local plugin_count = 0
local completed_plugins = 0
local error_plugins = 0
local total_duration = 0

-- Register callback for plugin start events
wasm_on_event("plugin_start", function(payload)
    plugin_count = plugin_count + 1
    print(string.format("[Plugin Monitor] Plugin started: %s (handle=%d)",
        payload.plugin_name, payload.plugin_handle))
end)

-- Register callback for plugin completion events
wasm_on_event("plugin_complete", function(payload)
    completed_plugins = completed_plugins + 1
    local duration = payload.duration_ms
    total_duration = total_duration + duration

    print(string.format("[Plugin Monitor] Plugin completed: %s (handle=%d, exit_code=%d, duration=%dms)",
        payload.plugin_name, payload.plugin_handle, payload.exit_code, duration))
end)

-- Register callback for plugin errors
wasm_on_event("plugin_error", function(payload)
    error_plugins = error_plugins + 1
    print(string.format("[Plugin Monitor] Plugin error: %s (handle=%d, error_code=%d, message=%s)",
        payload.plugin_name, payload.plugin_handle, payload.error_code, payload.error_message))
end)

-- Print summary every 60 seconds
local function print_summary()
    local elapsed = os.time() - start_time
    print(string.format("\n--- Plugin Monitor Summary ---"))
    print(string.format("Time elapsed: %d seconds", elapsed))
    print(string.format("Total plugins started: %d", plugin_count))
    print(string.format("Plugins completed: %d", completed_plugins))
    print(string.format("Plugins with errors: %d", error_plugins))
    if completed_plugins > 0 then
        print(string.format("Average duration: %.2fms", total_duration / completed_plugins))
    end
    print("--------------------------------\n")
end

-- Print summary every 60 seconds
timer = os.time() + 60
while true do
    local now = os.time()
    if now >= timer then
        print_summary()
        timer = now + 60
    end
    -- Sleep for 1 second
    os.execute("sleep 1")
end
