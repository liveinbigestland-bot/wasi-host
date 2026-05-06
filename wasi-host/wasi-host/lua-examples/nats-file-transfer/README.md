# NATS File Transfer Example

This example demonstrates how to send and receive files via NATS message queue using Lua scripts.

## Architecture

```
┌─────────────────┐         ┌─────────────────┐
│  Sender Script  │         │  Receiver Script│
│  (sender.lua)   │         │  (receiver.lua) │
└────────┬────────┘         └────────┬────────┘
         │                           │
         └─────────── NATS ──────────┘
                   (4222)
```

## Files

- `nats.lua` - NATS Lua API module
- `sender.lua` - File sender script
- `receiver.lua` - File receiver script
- `README.md` - This file

## How It Works

### Sender (sender.lua)

1. Connects to NATS server
2. Reads file in chunks (64KB each)
3. Sends metadata first (filename, size, chunk count)
4. Sends each chunk as a separate NATS message
5. Sends completion signal

### Receiver (receiver.lua)

1. Connects to NATS server
2. Subscribes to file transfer subjects
3. Receives metadata and initializes transfer state
4. Receives chunks and stores them
5. Writes file to disk when all chunks received

## Message Flow

```
1. Sender → NATS: file.transfer.metadata (JSON metadata)
2. Sender → NATS: file.transfer.chunk.0 (chunk 0)
3. Sender → NATS: file.transfer.chunk.1 (chunk 1)
4. ...
5. Sender → NATS: file.transfer.chunk.N (last chunk)
6. Sender → NATS: file.transfer.complete (completion signal)
```

## Usage

### Prerequisites

- NATS server running on localhost:4222
- wasi-host with Lua support enabled

### Running the Example

1. Start the receiver (in one terminal):
   ```bash
   lua receiver.lua
   ```

2. Send a file (in another terminal):
   ```bash
   lua sender.lua path/to/file.txt
   ```

### Example Commands

```bash
# Send a text file
lua sender.lua example.txt

# Send an image
lua sender.lua photo.jpg

# Send a binary file
lua sender.lua data.bin
```

## Configuration

Edit `nats.lua` to change NATS server settings:

```lua
local CONFIG = {
    nats_host = "127.0.0.1",
    nats_port = 4222,
    chunk_size = 64 * 1024,  -- 64KB chunks
}
```

## Message Format

### Metadata Message (file.transfer.metadata)

```json
{
    "filename": "example.txt",
    "filepath": "/path/to/example.txt",
    "size": 102400,
    "chunk_size": 65536,
    "total_chunks": 2,
    "timestamp": 1234567890,
    "sender_id": "lua-sender-1234567890"
}
```

### Chunk Message (file.transfer.chunk.N)

```json
{
    "filename": "example.txt",
    "chunk_index": 0,
    "data": "<base64 or binary data>",
    "is_last": false
}
```

### Completion Message (file.transfer.complete)

```json
{
    "filename": "example.txt",
    "total_chunks": 2,
    "total_size": 102400
}
```

## Notes

- This example uses JSON for message encoding
- Large files are split into chunks to avoid message size limits
- The receiver maintains transfer state in memory
- For production use, consider:
  - Persistent storage for large files
  - Error recovery and retry logic
  - Compression for large files
  - Encryption for sensitive data
