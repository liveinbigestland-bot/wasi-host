-- NATS File Transfer Sender
-- Sends a file via NATS message queue in chunks

local nats = require("nats")
local json = require("json")

-- Configuration
local CONFIG = {
    nats_host = "127.0.0.1",
    nats_port = 4222,
    chunk_size = 64 * 1024,  -- 64KB chunks
    subject_prefix = "file.transfer",
}

-- File metadata structure
local function create_file_metadata(filename, filepath, file_size)
    return {
        filename = filename,
        filepath = filepath,
        size = file_size,
        chunk_size = CONFIG.chunk_size,
        total_chunks = math.ceil(file_size / CONFIG.chunk_size),
        timestamp = os.time(),
        sender_id = "lua-sender-" .. os.time(),
    }
end

-- Read file in chunks and send via NATS
local function send_file(filepath)
    print("[Sender] Starting file transfer: " .. filepath)

    -- Open file
    local file, err = io.open(filepath, "rb")
    if not file then
        error("Failed to open file: " .. err)
    end

    -- Get file info
    local file_size = file:seek("end")
    file:seek("set", 0)

    local filename = filepath:match("([^/]+)$")
    local metadata = create_file_metadata(filename, filepath, file_size)

    -- Connect to NATS
    print("[Sender] Connecting to NATS at " .. CONFIG.nats_host .. ":" .. CONFIG.nats_port)
    nats.connect(CONFIG.nats_host, CONFIG.nats_port)
    print("[Sender] Connected to NATS")

    -- Send metadata first
    local metadata_subject = CONFIG.subject_prefix .. ".metadata"
    local metadata_json = json.encode(metadata)
    nats.publish(metadata_subject, metadata_json)
    print("[Sender] Sent metadata: " .. metadata_json)

    -- Send file in chunks
    local chunk_index = 0
    while chunk_index < metadata.total_chunks do
        local chunk_data = file:read(CONFIG.chunk_size)
        if not chunk_data then break end

        local chunk_message = {
            filename = filename,
            chunk_index = chunk_index,
            data = chunk_data,
            is_last = (chunk_index == metadata.total_chunks - 1),
        }

        local chunk_subject = CONFIG.subject_prefix .. ".chunk." .. chunk_index
        local chunk_json = json.encode(chunk_message)
        nats.publish(chunk_subject, chunk_json)

        print(string.format("[Sender] Sent chunk %d/%d (%d bytes)",
            chunk_index + 1, metadata.total_chunks, #chunk_data))

        chunk_index = chunk_index + 1
    end

    -- Send completion signal
    local completion_subject = CONFIG.subject_prefix .. ".complete"
    local completion_msg = {
        filename = filename,
        total_chunks = metadata.total_chunks,
        total_size = file_size,
    }
    nats.publish(completion_subject, json.encode(completion_msg))
    print("[Sender] File transfer complete: " .. filename)

    -- Cleanup
    file:close()
    nats.close()
end

-- Main function
function main()
    -- Get file path from command line or use default
    local filepath = arg[1] or "test-file.txt"

    -- Check if file exists
    local file = io.open(filepath, "rb")
    if not file then
        print("Error: File not found: " .. filepath)
        print("Usage: lua sender.lua <filepath>")
        return
    end
    file:close()

    -- Send the file
    local success, err = pcall(send_file, filepath)
    if not success then
        print("[Sender] Error: " .. err)
    end
end

-- Run main
main()
