# Serial Capture Documentation

![image](https://github.com/Ylianst/EmbroideryCommunicator/blob/main/docs/images/serial-capture.png)

## Overview

The Serial Capture tool allows you to intercept and record serial communication between the original Bernina software (ArtLink, DesignerPlus, etc.) and your embroidery machine. This captured traffic is invaluable for:

- **Reverse Engineering**: Understanding undocumented protocol features
- **Feature Development**: Helping developers add new capabilities to EmbroideryCommunicator
- **Protocol Analysis**: Learning how the original software implements various operations
- **Bug Investigation**: Comparing expected vs actual behavior
- **Community Contribution**: Sharing findings to improve the software

## Prerequisites

### Hardware Requirements

1. **Two Serial-to-USB cables**: Your computer needs two available serial ports or USB adapters
   - One for connecting to the machine
   - One for connecting to the original software

2. **Null Modem Cable/Adapter**: Required to connect the two ports together
   - Connects the software-side port to EmbroideryCommunicator
   - Pin configuration: TX→RX, RX→TX, Ground→Ground

3. **Machine Connection**: Standard serial cable from the null modem to the machine

### Hardware Setup Diagram

![image](https://github.com/Ylianst/EmbroideryCommunicator/blob/main/docs/images/serial-setup.png)

```
[Computer]
    |
    ├── COMx (EmbroideryCommunicator) → [Null Modem] → [original software]
    |
    └── COMx → [Serial Cable] → [Embroidery Machine]
```

### Software Requirements

- EmbroideryCommunicator with debug mode enabled (`-debug` flag)
- Original Bernina software (ArtLink, DesignerPlus, Editor, etc.)
- Must be **disconnected** from the machine before starting capture

## Step-by-Step Capture Process

### Phase 1: Prepare EmbroideryCommunicator

#### Step 1: Enable Debug Mode

Launch EmbroideryCommunicator with the `-debug` flag:

**Windows:**
```cmd
EmbroideryCommunicator.exe -debug
```

The Debug menu will appear in the menu bar.

#### Step 2: Connect and Set Baud Rate

**Important**: Before capturing, connect to the machine to set the baud rate to 57600:

1. Select your machine's COM port (e.g., COM4)
2. Click **Connect**
3. Wait for connection to complete
4. The application automatically switches to 57600 baud
5. Verify in status bar: "Connected: COM4 @ 57600 baud"
6. Click **Disconnect**

**Why this step is necessary**: The original software typically communicates at 57600 baud for faster file transfers. Setting this speed first ensures smooth capture.

#### Step 3: Open Serial Capture Tool

1. From the menu bar, select **Debug → Serial Capture**
2. The Serial Capture window will open

**Note**: You must be **disconnected** to use this tool. If connected, you'll see an error message.

### Phase 2: Configure Capture Settings

#### Step 1: Select COM Port

1. In the "COM Port" dropdown, select the port connected to the null modem
   - This should be the same port your machine normally uses (e.g., COM4)
   - **Not** the port the original software will connect to (e.g., COM3)

#### Step 2: Set Baud Rate

1. In the "Baud Rate" dropdown, select **57600**
   - This matches the speed you just configured
   - Original software will communicate at this speed
   - Lower speeds (9600, 19200) can be used but are less common

#### Step 3: Choose Output File

1. Click the **Browse** button
2. Navigate to your desired save location
3. Enter a descriptive filename
4. Click **Save**

**Recommended naming convention:**
```
Capture-[Operation]-[Date]-[Time].txt

Examples:
Capture-FileUpload-20251212-1530.txt
Capture-FileRead-20251212-1545.txt
Capture-MemoryRead-20251212-1600.txt
```

### Phase 3: Start Capture

#### Step 1: Begin Monitoring

1. Click the **Start Capture** button
2. Status will show: "Listening on COM4 at 57600 baud"
3. The capture is now active and waiting for traffic

#### Step 2: Use Original Software

1. Launch your Bernina software (ArtLink, DesignerPlus, etc.)
2. Configure it to use the **other** COM port (e.g., COM3 - the one connected via null modem)
3. Connect the original software to the "machine"
   - It will actually connect to EmbroideryCommunicator through the null modem
   - EmbroideryCommunicator forwards traffic to the real machine
4. Perform the operation you want to capture:
   - Upload a file
   - Download a file
   - Read machine information
   - Delete a file
   - Any other operation

#### Step 3: Monitor Progress

Watch the Serial Capture window:
- **Bytes Sent**: Data from software to machine
- **Bytes Received**: Data from machine to software
- Numbers increase as traffic flows
- Status shows current activity

### Phase 4: Complete Capture

#### Step 1: Finish Operation

1. Complete the operation in the original software
2. Wait for it to finish completely
3. Disconnect the original software
4. Close the original software (optional)

#### Step 2: Stop Capture

1. Click the **Stop** button in Serial Capture window
2. Status changes to "Capture stopped"
3. Final statistics are displayed

#### Step 3: Review Capture File

The capture file contains:
- Complete log of all traffic
- Timestamps for each event
- Sent data (highlighted)
- Received data (highlighted)
- Protocol commands and responses
- Error conditions (if any)

## Captured Data Format

### File Structure

The capture file is a timestamped text log:

```
[2025-12-12 15:30:45.123] Connected: COM4 @ 57600 baud
[2025-12-12 15:30:45.234] → RF?
[2025-12-12 15:30:45.256] ← !RF
[2025-12-12 15:30:45.345] → R200100?
[2025-12-12 15:30:45.367] ← !200100v2.05.00...
[2025-12-12 15:30:45.456] → TrMEYQ
[2025-12-12 15:30:45.478] ← !TrMEYQ
[2025-12-12 15:30:46.123] → Function 0x0011
[2025-12-12 15:30:46.567] ← $FFFED00002
...
```

### Arrow Indicators

- **→** Sent from software to machine
- **←** Received from machine to software
