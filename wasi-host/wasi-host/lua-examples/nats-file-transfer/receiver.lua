-- NATS File Transfer Receiver
-- Receives files via NATS message queue in chunks

local nats = require("nats")
local json = require("json")

-- Configuration
local CONFIG = {
    nats_host = "127.0.0.1",
    nats_port = 4222,
    subject_prefix = "file.transfer",
    output_dir = "received_files",
}

-- File transfer state
local transfer_state = {}

-- Ensure output directory exists
local function ensure_output_dir()
    -- This would be handled by the host application
    -- For now, we assume the directory exists
end

-- Handle file metadata
local function handle_metadata(metadata_json)
    local metadata = json.decode(metadata_json)
    print("[Receiver] Received metadata for: " .. metadata.filename)
    print("  Size: " .. metadata.size .. " bytes")
    print("  Chunks: " .. metadata.total_chunks)

    -- Initialize transfer state
    transfer_state[metadata.filename] = {
        metadata = metadata,
        chunks_received = {},
        total_received = 0,
    }

    -- Create output file path
    local output_path = CONFIG.output_dir .. "/" .. metadata.filename
    transfer_state[metadata.filename].output_path = output_path

    print("[Receiver] Ready to receive: " .. output_path)
end

-- Handle file chunk
local function handle_chunk(chunk_json)
    local chunk = json.decode(chunk_json)
    local filename = chunk.filename
    local state = transfer_state[filename]

    if not state then
        print("[Receiver] Warning: Received chunk for unknown file: " .. filename)
        return
    end

    -- Store chunk data
    state.chunks_received[chunk.chunk_index] = chunk.data
    state.total_received = state.total_received + 1

    print(string.format("[Receiver] Received chunk %d/%d for %s",
        chunk.chunk_index + 1, state.metadata.total_chunks, filename))

    -- If this is the last chunk, write the file
    if chunk.is_last then
        write_file(filename, state)
    end
end

-- Write received file to disk
local function write_file(filename, state)
    print("[Receiver] Writing file: " .. filename)

    local output_path = state.output_path
    local file, err = io.open(output_path, "wb")
    if not file then
        print("[Receiver] Error: Failed to create output file: " .. err)
        return
    end

    -- Write chunks in order
    for i = 0, state.metadata.total_chunks - 1 do
        local chunk_data = state.chunks_received[i]
        if chunk_data then
            file:write(chunk_data)
        else
            print("[Receiver] Warning: Missing chunk " .. i)
        end
    end

    file:close()

    -- Verify file size
    local file_size = file:seek("end")
    if file_size == state.metadata.size then
        print("[Receiver] File received successfully: " .. output_path)
        print("  Size: " .. file_size .. " bytes")
    else
        print("[Receiver] Warning: File size mismatch")
    end

    -- Cleanup transfer state
    transfer_state[filename] = nil
end

-- Handle completion signal
local function handle_completion(completion_json)
    local completion = json.decode(completion_json)
    print("[Receiver] Transfer complete for: " .. completion.filename)
    print("  Total chunks: " .. completion.total_chunks)
    print("  Total size: " .. completion.total_size .. " bytes")
end

-- Main receiver function
local function start_receiver()
    print("[Receiver] Starting NATS file transfer receiver...")
    print("[Receiver] Connecting to NATS at " .. CONFIG.nats_host .. ":" .. CONFIG.nats_port)

    -- Connect to NATS
    nats.connect(CONFIG.nats_host, CONFIG.nats_port)
    print("[Receiver] Connected to NATS")

    -- Subscribe to file transfer subjects
    local metadata_subject = CONFIG.subject_prefix .. ".metadata"
    local chunk_subject = CONFIG.subject_prefix .. ".chunk.*"
    local complete_subject = CONFIG.subject_prefix .. ".complete"

    nats.subscribe(metadata_subject, handle_metadata)
    nats.subscribe(chunk_subject, handle_chunk)
    nats.subscribe(complete_subject, handle_completion)

    print("[Receiver] Subscribed to subjects:")
    print("  - " .. metadata_subject)
    print("  - " .. chunk_subject)
    print("  - " .. complete_subject)
    print("[Receiver] Ready to receive files. Press Ctrl+C to stop.")

    -- Keep receiver running
    -- In a real implementation, this would be handled by the event loop
    while true do
        -- Sleep to prevent busy waiting
        -- This would be replaced by proper event handling
        os.execute("sleep 1")
    end
end

-- Main function
function main()
    -- Ensure output directory exists
    ensure_output_dir()

    -- Start the receiver
    local success, err = pcall(start_receiver)
    if not success then
        print("[Receiver] Error: " .. err)
    end
end

-- Run main
main()
