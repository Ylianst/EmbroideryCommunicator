# Embroidery Relay TCP Protocol

This document describes the TCP protocol used to communicate with an Embroidery Relay device (typically running on a Raspberry Pi) that provides remote access to an embroidery machine. The relay handles the low-level serial protocol described in `SerialProtocol.md` and exposes a higher-level TCP interface to avoid the latency of single-character round-trips over the network.

## Protocol Overview

- **Transport**: TCP/IP
- **Port**: Configurable (default: 8888)
- **Encoding**: ASCII/Binary hybrid (command headers in ASCII, data payloads may be binary)
- **Authentication**: None (trusted network assumed)
- **Request/Response Model**: Each request has a unique request ID that is echoed in the response
- **Endianness**: Big-endian for multi-byte integers

## Message Format

All messages follow this structure:

```
[MessageType:4][RequestID:8][PayloadLength:8][Payload:N]
```

- **MessageType**: 4 ASCII characters identifying the message type
- **RequestID**: 8 ASCII hex characters (00000000-FFFFFFFF) assigned by client
- **PayloadLength**: 8 ASCII hex characters (00000000-FFFFFFFF) indicating payload size in bytes
- **Payload**: Variable length data (may be ASCII or binary depending on message type)

### Example Message Structure
```
STAT    00000001        00000000        4800
^^^^    ^^^^^^^^        ^^^^^^^^        ^^^^
Type    Request ID      Payload Length  Payload
```

## Message Types

### Configuration Commands

#### GCFG - Get Configuration
Request the relay's current serial port configuration.

**Request:**
```
GCFG[RequestID:8]00000000
```

**Response:**
```
RCFG[RequestID:8][PayloadLength:8][Payload]
```

**Payload Format (ASCII JSON):**
```json
{
  "serialPort": "COM3",
  "baudRate": 57600,
  "relayVersion": "1.0.0"
}
```

**Example:**
```
Request:  GCFG0000000100000000
Response: RCFG00000001000000437B227365726961...  (JSON payload)

Decoded payload:
{
  "serialPort": "COM3",
  "baudRate": 57600,
  "relayVersion": "1.0.0"
}
```

#### SCFG - Set Configuration
Configure the relay's serial port settings (port name and initial baud rate).

**Request:**
```
SCFG[RequestID:8][PayloadLength:8][Payload]
```

**Payload Format (ASCII JSON):**
```json
{
  "serialPort": "/dev/ttyUSB0",
  "baudRate": 19200
}
```

**Response:**
```
RCFG[RequestID:8][PayloadLength:8][Payload]
```

**Payload Format (ASCII JSON):**
```json
{
  "success": true,
  "message": "Configuration updated"
}
```

**Example:**
```
Request:  SCFG00000002000000357B227365726961...  (JSON payload)

Decoded payload:
{
  "serialPort": "/dev/ttyUSB0",
  "baudRate": 19200
}

Response: RCFG0000000200000035 {"success":true,"message":"Configuration updated"}
```

#### STAT - Get Status
Request the current status of the relay and machine connection.

**Request:**
```
STAT[RequestID:8]00000000
```

**Response:**
```
RSTA[RequestID:8][PayloadLength:8][Payload]
```

**Payload Format (ASCII JSON):**
```json
{
  "connected": true,
  "baudRate": 57600,
  "sessionOpen": true,
  "lastError": ""
}
```

**Example:**
```
Request:  STAT0000000300000000
Response: RSTA00000003000000557B22636F6E6E65...  (JSON payload)

Decoded payload:
{
  "connected": true,
  "baudRate": 57600,
  "sessionOpen": true,
  "lastError": ""
}
```

### Machine Communication Commands

#### READ - Read Memory
Read 32 bytes of memory from the machine (corresponds to serial "R" command).

**Request:**
```
READ[RequestID:8]00000006[Address:6]
```

**Address**: 6 ASCII hex characters representing the memory address

**Response:**
```
RDAT[RequestID:8][PayloadLength:8][Payload]
```

**Payload**: 64 ASCII hex characters (32 bytes of data, hex-encoded)

**Example:**
```
Request:  READ00000004000000066200100
Response: RDAT000000040000004053524D5630332E30312000467269747A204765676175662041470D004F637420

Decoded payload (64 hex chars = 32 bytes):
53524D5630332E30312000467269747A204765676175662041470D004F637420
```

#### LRED - Large Read Memory
Read 256 bytes of memory from the machine (corresponds to serial "N" command).

**Request:**
```
LRED[RequestID:8]00000006[Address:6]
```

**Address**: 6 ASCII hex characters representing the memory address

**Response:**
```
LDAT[RequestID:8][PayloadLength:8][Payload]
```

**Payload**: 256 bytes of binary data

**Example:**
```
Request:  LRED000000050000000602240F5
Response: LDAT0000000500000100[256 bytes of binary data...]

Decoded payload (256 bytes binary):
4C6973615634355265763800...  (256 bytes)
```

#### WRIT - Write Memory
Write data to machine memory (corresponds to serial "W" command).

**Request:**
```
WRIT[RequestID:8][PayloadLength:8][Address:6][Data:N]
```

**Address**: 6 ASCII hex characters representing the memory address
**Data**: Variable length ASCII hex characters (2 hex chars per byte to write)

**Response:**
```
WACK[RequestID:8]00000001[Status:1]
```

**Status**: 1 ASCII character ('O' = success, 'E' = error)

**Example:**
```
Request:  WRIT0000000600000008020201E101
         (Write 0x01 to address 0x0201E1)
Response: WACK000000060000000104F

Status 'O' = Success
```

#### UPLD - Upload Block
Upload 256 bytes to machine memory (corresponds to serial "PS" command).

**Request:**
```
UPLD[RequestID:8][PayloadLength:8][Address:4][Data:256]
```

**Address**: 4 ASCII hex characters (e.g., "028F" for address 0x028F00)
**Data**: 256 bytes of binary data

**Response:**
```
UACK[RequestID:8]00000001[Status:1]
```

**Status**: 1 ASCII character ('O' = success, 'E' = error)

**Example:**
```
Request:  UPLD0000000700000104028F[256 bytes of binary data...]
Response: UACK000000070000000104F

Status 'O' = Success
```

#### CSUM - Calculate Checksum
Calculate checksum of memory region (corresponds to serial "L" command).

**Request:**
```
CSUM[RequestID:8]0000000C[Address:6][Length:6]
```

**Address**: 6 ASCII hex characters representing start address
**Length**: 6 ASCII hex characters representing number of bytes to sum

**Response:**
```
RSUM[RequestID:8]00000008[Checksum:8]
```

**Checksum**: 8 ASCII hex characters representing the sum result

**Example:**
```
Request:  CSUM000000080000000C0240D5000360
Response: RSUM000000080000000800004CC9

Checksum result: 0x00004CC9
```

### Session Management Commands

#### SOPE - Session Open
Open embroidery module session (corresponds to serial "TrMEYQ" command).

**Request:**
```
SOPE[RequestID:8]00000000
```

**Response:**
```
SACK[RequestID:8]00000001[Status:1]
```

**Status**: 1 ASCII character ('O' = success, 'E' = error/module not attached)

**Example:**
```
Request:  SOPE0000000900000000
Response: SACK000000090000000104F

Status 'O' = Session opened successfully
```

#### SCLO - Session Close
Close embroidery module session (corresponds to serial "TrME" command).

**Request:**
```
SCLO[RequestID:8]00000000
```

**Response:**
```
SACK[RequestID:8]00000001[Status:1]
```

**Status**: 1 ASCII character ('O' = success, 'E' = error)

**Example:**
```
Request:  SCLO0000000A00000000
Response: SACK0000000A0000000104F

Status 'O' = Session closed successfully
```

#### BAUD - Change Baud Rate
Change serial baud rate (corresponds to serial "TrMEJ04" or "TrMEJ05" commands).

**Request:**
```
BAUD[RequestID:8]00000005[Rate:5]
```

**Rate**: 5 ASCII characters representing baud rate ("19200" or "57600")

**Response:**
```
BACK[RequestID:8]00000001[Status:1]
```

**Status**: 1 ASCII character ('O' = success, 'E' = error)

**Example:**
```
Request:  BAUD0000000B0000000557600
Response: BACK0000000B0000000104F

Status 'O' = Baud rate changed to 57600
```

#### RSET - Protocol Reset
Reset machine protocol state (corresponds to serial "RF?" command).

**Request:**
```
RSET[RequestID:8]00000000
```

**Response:**
```
RACK[RequestID:8]00000001[Status:1]
```

**Status**: 1 ASCII character ('O' = success, 'E' = error)

**Example:**
```
Request:  RSET0000000C00000000
Response: RACK0000000C0000000104F

Status 'O' = Protocol reset successful
```

**Note:** The relay software should automatically send "RF?" and perform a resync whenever it receives an error response (Q, ?, or !) from the machine during any serial operation. This automatic recovery means clients typically do not need to send RSET commands explicitly - the relay handles protocol errors transparently. The RSET command is provided for manual reset if needed.


### Error Handling

#### ERRO - Error Response
Sent by relay when a command fails or is invalid.

**Response:**
```
ERRO[RequestID:8][PayloadLength:8][Payload]
```

**Payload Format (ASCII JSON):**
```json
{
  "error": "Error description",
  "code": 1001
}
```

**Example:**
```
Response: ERRO0000000500000035{"error":"Invalid address format","code":1001}
```

**Error Codes:**
- **1001**: Invalid message format
- **1002**: Serial port not configured
- **1003**: Serial port not connected
- **1004**: Machine timeout/no response
- **1005**: Machine returned error (Q/!/?)
- **1006**: Invalid command parameters
- **1007**: Session already open
- **1008**: Session not open
- **1009**: Baud rate change failed

## Request ID Management

- Client generates unique request IDs (recommended: sequential or random)
- Request IDs are 8 ASCII hex characters (00000000-FFFFFFFF)
- Relay echoes the request ID in the corresponding response
- This allows multiple requests in flight simultaneously
- Client should implement timeout logic (recommended: 30 seconds for normal operations, 60 seconds for large uploads)

## Connection Flow Example

```
1. Client connects to relay TCP socket (e.g., 192.168.1.100:8888)

2. Client requests configuration:
   GCFG0000000100000000
   
3. Relay responds:
   RCFG00000001000000437B227365726961...
   {"serialPort":"/dev/ttyUSB0","baudRate":19200,"relayVersion":"1.0.0"}

4. Client requests status:
   STAT0000000200000000
   
5. Relay responds:
   RSTA00000002000000557B22636F6E6E65...
   {"connected":true,"baudRate":19200,"sessionOpen":false,"lastError":""}

6. Client changes to 57600 baud:
   BAUD000000030000000557600
   
7. Relay responds:
   BACK000000030000000104F

8. Client opens embroidery session:
   SOPE0000000400000000
   
9. Relay responds:
   SACK000000040000000104F

10. Client reads memory:
    READ00000005000000066200100
    
11. Relay responds:
    RDAT000000050000004053524D5630332E30312000467269747A...

12. [Perform operations...]

13. Client closes session:
    SCLO000000FF00000000
    
14. Relay responds:
    SACK000000FF0000000104F
```

## Implementation Notes

### Relay Implementation (Raspberry Pi)

- The relay should handle the low-level serial protocol including:
  - Single-character echo/wait loop for commands
  - Protocol reset (RF?) on errors
  - Baud rate detection and changes
  - Session management
  - Timeout handling

- The relay should maintain state:
  - Current baud rate
  - Session open/closed status
  - Last error condition
  - Connection status

- The relay should handle concurrent TCP connections gracefully (one client at a time recommended)

### Client Implementation (C# WinForms)

- Client should maintain a request ID counter or generator
- Client should implement timeout logic for all requests
- Client should handle network disconnection and reconnection
- Client should provide UI for selecting between:
  - Direct serial port connection (existing functionality)
  - TCP relay connection (IP:port)

### Machine-Specific Operations

Some embroidery machines support invoking machine functions by writing to specific memory addresses. For example, the Bernina Artista uses the following pattern:

1. Write argument 1 to address 0x0201E1 using WRIT command
2. Write argument 2 to address 0x0201DC using WRIT command  
3. Write function number to address 0xFFFED0 using WRIT command
4. Read result from address 0xFFFED0 using READ command

**Example - Invoking function 0x0031:**
```
Request 1: WRIT0000001000000008020201DC01
          (Write 0x01 to 0x0201DC - argument 2)
Response:  WACK000000100000000104F

Request 2: WRIT0000001100000008020201E100
          (Write 0x00 to 0x0201E1 - argument 1)
Response:  WACK000000110000000104F

Request 3: WRIT00000012000000080FFFED00031
          (Write 0x0031 to 0xFFFED0 - function number)
Response:  WACK000000120000000104F

Request 4: READ00000013000000066FFFED0
          (Read result from 0xFFFED0)
Response:  RDAT0000001300000040000200000000000...
          (First 2 bytes: 0x0002 = function completed)
```

This approach is machine-specific and other embroidery machines may use different memory addresses or mechanisms. The protocol intentionally uses generic READ/WRIT commands to support different machine types without protocol changes.

### Performance Considerations

- READ command: ~0.5-2 seconds (depending on network latency and serial timing)
- LRED command: ~2-8 seconds (256 bytes of data)
- UPLD command: ~2-8 seconds (256 bytes upload)
- CSUM command: ~0.5-3 seconds (depends on length to sum)

These times are significantly faster than serial-over-TCP which would require hundreds of round-trips for a single operation.

## Protocol Version

**Version**: 1.0.0
**Date**: December 2025
**Compatibility**: Designed for Bernina Artista embroidery machines using the serial protocol described in SerialProtocol.md
