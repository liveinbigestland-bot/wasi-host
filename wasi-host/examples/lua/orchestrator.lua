-- Example Lua script: Plugin Orchestrator
-- This script demonstrates:
-- - Managing multiple plugins concurrently
-- - Controlling plugin lifecycle (start, pause, resume, stop)
-- - Implementing orchestration logic

local active_plugins = {}
local plugin_configs = {
    {name = "ai_plugin", mem_kb = 1024, timeout_ms = 10000},
    {name = "api_plugin", mem_kb = 512, timeout_ms = 5000},
}

-- Initialize plugins
for i, config in ipairs(plugin_configs) do
    print(string.format("[Orchestrator] Initializing plugin %d: %s", i, config.name))
    local handle, err = wasm_start(config.name, {
        mem_kb = config.mem_kb,
        timeout_ms = config.timeout_ms,
    })

    if handle ~= nil then
        active_plugins[handle] = {
            config = config,
            name = config.name,
            status = "running",
        }
        print(string.format("[Orchestrator] Plugin %s started with handle %d", config.name, handle))
    else
        print(string.format("[Orchestrator] Failed to start plugin %s: %s", config.name, err))
    end
end

print(string.format("[Orchestrator] Started %d plugins", #active_plugins))

-- Wait for plugins to complete
while true do
    local has_running = false

    for handle, plugin in pairs(active_plugins) do
        if plugin.status == "running" then
            has_running = true

            -- Get plugin info
            local info = wasm_plugin_info(plugin.name)
            print(string.format("[Orchestrator] %s (handle=%d): %s", plugin.name, handle,
                info.status or "running"))
        end
    end

    if not has_running then
        break
    end

    -- Check for stopped plugins
    local list = wasm_list_active()
    print(string.format("[Orchestrator] Active plugins: %d", #list))

    -- Process events to update plugin status
    wasm_process_events(10)

    -- Sleep for 100ms
    os.execute("sleep 0.1")
end

-- Print summary
print("\n[Orchestrator] All plugins completed!")
for handle, plugin in pairs(active_plugins) do
    print(string.format("  - %s (handle=%d) - %s", plugin.name, handle, plugin.status))
end
