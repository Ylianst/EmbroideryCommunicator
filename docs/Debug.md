# Debug Window Documentation

![image](https://github.com/Ylianst/EmbroideryCommunicator/blob/main/docs/images/traffic-debug.png)

## Overview

The Debug Window provides real-time visibility into the serial communication between EmbroideryCommunicator and the embroidery machine. This powerful tool allows developers and advanced users to:

- **Monitor Protocol Traffic**: See every command sent and response received
- **Debug Communication Issues**: Diagnose connection problems and protocol errors
- **Learn the Protocol**: Understand how the machine communicates
- **Verify Operations**: Confirm that commands are being executed correctly
- **Troubleshoot Problems**: Identify where failures occur in command sequences

## Enabling Debug Mode

The Debug menu option is **hidden by default** and must be enabled at application startup.

### Windows

#### Method 1: Command Line
1. Open Command Prompt or PowerShell
2. Navigate to the application directory
3. Run with the `-debug` flag:
   ```cmd
   EmbroideryCommunicator.exe -debug
   ```

#### Method 2: Create a Shortcut
1. Right-click on `EmbroideryCommunicator.exe`
2. Select **Create shortcut**
3. Right-click the new shortcut and select **Properties**
4. In the **Target** field, add `-debug` to the end:
   ```
   "C:\Path\To\EmbroideryCommunicator.exe" -debug
   ```
5. Click **OK**
6. Use this shortcut to launch in debug mode

#### Method 3: Batch File
Create a file named `Debug.bat` with the following content:
```batch
@echo off
start EmbroideryCommunicator.exe -debug
```

## Opening the Debug Window

Once the application is running in debug mode:

1. Look for the **Debug** menu in the menu bar (appears after Help)
2. Click **Debug → Developer Debug**
3. The Debug Window will open

**Note**: The debug window can be opened **at any time** - you don't need to be connected to the machine first.

## Debug Window Interface

The Debug Window consists of:

### 1. Output Area (Main Panel)
- Large text area showing all communication traffic
- Automatically scrolls to show the latest messages
- Can be manually scrolled to review earlier traffic
- Supports text selection and copying

### 2. Command Input Section
Located at the bottom:
- **Command Input Field**: Enter raw commands to send to the machine
- **Send Button**: Transmit the command
- **Read Button**: Request a read operation
- **Write Button**: Request a write operation
- **Protocol Reset Button**: Send protocol reset command

### 3. Status Bar
Shows current connection state and activity.

## Understanding the Output

The debug window displays several types of messages:

### Connection Events
```
Connected: COM3 @ 19200 baud
Baud rate changed to 57600
```

### Command Traffic
Each command shows:
- **Direction** (→ = sent, ← = received)
- **Command Type** (Read, Write, Large Read, etc.)
- **Address** (memory location)
- **Data** (payload in hexadecimal)
- **Timestamp** (implicit in sequence)

Example output:
```
→ R200100?
← !20010048656C6C6F20576F726C64...

→ N024080?
← @024080<256 bytes of data>

→ W0201E101?
← $0201E1
```

### Protocol Messages
```
SessionStart: TrMEYQ
SessionEnd: TrME
Protocol Reset: RF?
```

### Error Messages
```
Error: Timeout waiting for response
Error: Invalid checksum in response
Failed to invoke function 0x0031
```

### Debug Messages
Internal operations and state changes:
```
ReadEmbroideryFiles: Starting read from EmbroideryModuleMemory
ReadEmbroideryFiles: Total file count: 15
InvokeFunctionAsync: Invoking function 0x0031
```

## Command Format Reference

### Read Command (R)
- **Format**: `R` + 6 hex digits (address) + `?`
- **Example**: `R200100?`
- **Returns**: 32 bytes of data
- **Response Prefix**: `!` + address + data

### Large Read Command (N)
- **Format**: `N` + 6 hex digits (address) + `?`
- **Example**: `N024080?`
- **Returns**: 256 bytes of data
- **Response Prefix**: `@` + address + data

### Write Command (W)
- **Format**: `W` + 6 hex digits (address) + data (hex) + `?`
- **Example**: `W0201E101?` (write 0x01 to address 0x0201E1)
- **Max Data**: 32 bytes
- **Response Prefix**: `$` + address

### Checksum Command (L)
- **Format**: `L` + 6 hex digits (address) + 6 hex digits (length) + `?`
- **Example**: `L02010000100?` (checksum 0x100 bytes from 0x020100)
- **Response**: Checksum value in hex

### Upload Command (PS)
- **Format**: `PS` + 4 hex digits (address>>8) + 256 bytes data + `?`
- **Example**: `PS0201<256 bytes>?`
- **Returns**: Confirmation

### Session Commands
- **Session Start**: `TrMEYQ` (enter embroidery mode)
- **Session End**: `TrME` (return to sewing mode)
- **Protocol Reset**: `RF?`

## Use Cases

### 1. Debugging Connection Issues

When connections fail, the debug window shows exactly where the breakdown occurs:

```
→ RF?
(No response - timeout)
Error: Timeout waiting for response
```

This indicates the machine isn't responding at all - check physical connections.

### 2. Understanding File Operations

Watch the complete sequence of commands when reading files:

```
TrMEYQ                           # Enter embroidery mode
→ R57FF80?                       # Check session mode
← !57FF80...
→ Function 0x00A1                # Select embroidery module storage
→ R0201DC01?                     # Set argument 2
→ R0201E100?                     # Set argument 1
→ Function 0x0031                # Initialize file read
→ Function 0x0021                # Execute read
→ R024080?                       # Get file count
← !02408015                      # 15 files available
```

### 3. Learning the Protocol

Send custom commands to experiment:

1. Enter `R200100?` in the command field
2. Click **Send**
3. Observe the response in the output area

This helps understand:
- Response timing
- Data formats
- Error conditions
- Protocol behavior

### 4. Verifying Uploads

When uploading files, confirm each step executes correctly:

```
→ Function 0x0011                # Ready module for upload
→ W028E98<header data>?          # Write file header
→ PS0289<256 bytes>?             # Upload first block
→ PS028A<256 bytes>?             # Upload second block
...
→ Function 0x0201                # Store file (wait 4s)
← $FFFED00002                    # Success!
```

### 5. Troubleshooting Failures

Identify exactly where operations fail:

```
→ Function 0x0401                # Request file data
→ R028F40?                       # Read file lengths
← !028F40000100000002000         # FileData: 256 bytes, Extra: 512 bytes
→ N028F48?                       # Start reading file
Error: Checksum mismatch!        # Problem identified
```

## Advanced Features

### Sending Raw Commands

The command input allows sending **any** raw command:

1. Type the exact command string (e.g., `R200100?`)
2. Click **Send**
3. Watch the response in the output area

**Supported formats:**
- Read: `R` + address + `?`
- Write: `W` + address + hex data + `?`
- Large Read: `N` + address + `?`
- Checksum: `L` + address + length + `?`
- Function: `TrME`, `TrMEYQ`, `RF?`

### Command Buttons

Quick access to common operations:

- **Read**: Opens dialog to read from a specific address
- **Write**: Opens dialog to write data to an address
- **Protocol Reset**: Immediately sends `RF?`

### Copying Output

1. Select text in the output area
2. Right-click and choose **Copy** (or Ctrl+C)
3. Paste into a text file for analysis

Useful for:
- Creating bug reports
- Sharing protocol traces
- Documenting behavior

### Clearing Output

While there's no clear button, you can:
1. Close and reopen the debug window for a fresh start
2. Or scroll to ignore earlier messages

## Example Session

Here's a complete example showing file reading:

```
# Application starts
Debug window opened

# User connects to machine
Connected: COM3 @ 19200 baud
→ RF?
← !RF

# Baud rate negotiation
Changing to 57600 baud...
Baud rate changed to 57600

# Read firmware info
→ TrME                           # Ensure sewing mode
← !TrME
→ RF?
← !RF
→ R57FF80?
← !57FF80B4A5...                 # In sewing mode

→ R200100?                       # Read firmware version
← !200100v2.05.00...

# Switch to embroidery mode
→ TrMEYQ
← !TrMEYQ
→ RF?
← !RF

# Read embroidery firmware
→ R200100?
← !200100v1.20.00...

# Read embroidery files
→ Function 0x00A1                # Select embroidery storage
→ Function 0x0031                # Initialize read
→ Function 0x0021                # Execute
→ R024080?                       # Get file count
← !02408015                      # 15 files

# Read first page of files
→ R0240B9?                       # Attributes
← !0240B9A4A4A4...
→ N0240D5?                       # Filenames (256 bytes)
← @0240D5DESIGN1...

# Read preview for first file
→ L02452E00000022E?              # Get preview checksum
← !L00012ABC
→ N02452E?                       # Read first preview block
← @02452E<256 bytes>
→ N02462E?                       # Read next preview block
← @02462E<256 bytes>
...

# Return to sewing mode
→ Function 0x0101                # Cleanup
→ TrME                           # End session
← !TrME
```

## Additional Resources

- **SerialStack Documentation**: `docs/SerialStack-Documentation.md` - Protocol details
- **Memory Dump Documentation**: `docs/MemoryDump.md` - Memory structure
- **Main Application**: Use alongside main window for full functionality
