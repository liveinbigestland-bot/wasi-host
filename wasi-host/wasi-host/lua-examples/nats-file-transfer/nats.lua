-- NATS Lua API Module
-- Provides Lua bindings for NATS message queue operations

local nats = {}

-- NATS client handle (set by host application)
local client_handle = nil

-- Initialize NATS client
function nats.connect(host, port)
    if client_handle ~= nil then
        error("NATS client already connected")
    end
    client_handle = _nats_connect(host, port)
    return client_handle
end

-- Publish message to subject
function nats.publish(subject, payload)
    if client_handle == nil then
        error("NATS client not connected. Call nats.connect() first.")
    end
    _nats_publish(client_handle, subject, payload)
end

-- Subscribe to subject with callback
function nats.subscribe(subject, callback)
    if client_handle == nil then
        error("NATS client not connected. Call nats.connect() first.")
    end
    _nats_subscribe(client_handle, subject, callback)
end

-- Request-reply pattern
function nats.request(subject, payload, timeout_ms)
    if client_handle == nil then
        error("NATS client not connected. Call nats.connect() first.")
    end
    return _nats_request(client_handle, subject, payload, timeout_ms or 5000)
end

-- Unsubscribe from subject
function nats.unsubscribe(subject)
    if client_handle == nil then
        error("NATS client not connected. Call nats.connect() first.")
    end
    _nats_unsubscribe(client_handle, subject)
end

-- Close NATS connection
function nats.close()
    if client_handle ~= nil then
        _nats_close(client_handle)
        client_handle = nil
    end
end

return nats
