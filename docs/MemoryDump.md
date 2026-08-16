# Memory Dump Documentation

![image](https://github.com/Ylianst/EmbroideryCommunicator/blob/main/docs/images/memory-dump.png)

## Overview

The Memory Dump feature allows advanced users to download the entire 16MB memory contents from either the Sewing Machine or Embroidery Module and save it to a binary file. This can be useful for:

- **Backup and Recovery**: Create complete backups of machine memory
- **Analysis and Research**: Study the internal memory structure and data organization
- **Debugging**: Diagnose issues by examining raw memory contents
- **Reverse Engineering**: Understand machine protocols and data formats

## How to Create a Memory Dump

### Step 1: Connect to the Machine

1. Launch EmbroideryCommunicator
2. Select your connection method:
   - **Serial Port**: Choose **Connection → Select COM Port** and select your COM port
   - **Network**: Choose **Connection → Select COM Port → Network** and enter hostname/port
3. Click **Connect** or use **Connection → Connect**

### Step 2: Open Memory Dump Tool

1. From the menu bar, select **Help → Memory Dump...**
2. The Memory Dump window will open

### Step 3: Configure Settings

**Select Memory Source:**
- **Sewing Machine**: Downloads memory from the main sewing machine controller
- **Embroidery Module**: Downloads memory from the embroidery module (if attached)

**Set the Address Range:**
- **Start (hex)** and **End (hex, exclusive)** define the range to download.
- The defaults cover the entire 16MB address space: Start `000000` and End `1000000`, which reads every byte from `0x000000` through `0xFFFFFF` inclusive.
- Narrow the range if you only need a specific region.

**Choose Output File:**
1. Click the **Browse** button
2. Navigate to your desired save location
3. Enter a filename (suggested format: `MemoryDump-[Device]-[Date].bin`)
4. Click **Save**

### Step 4: Start the Download

1. Click the **Start** button to begin the memory dump
2. Monitor the progress bar and status text
3. The process will take about an hour.
4. If a read error occurs, the app automatically retries the failed block up to 10 times, pausing a few seconds between attempts. The status text shows the address and retry count.
5. When complete, a confirmation message will appear

### Step 5: Cancel (Optional)

- If you need to abort the download, click the **Cancel** button
- Whatever has been downloaded so far is saved to the output file, so the transfer can be resumed later.

### Step 6: Resume a Failed or Cancelled Download

If a download is interrupted (cancelled, disconnected, or unable to recover after retrying), you can pick up where it left off:

1. Reopen the Memory Dump tool and use the **same Start address** as the original download.
2. Click **Browse** and select the **same output file** you used before.
3. Click **Start**. The file is assumed to begin at the Start address, so the download resumes at `Start + <existing file length>` and the new bytes are appended to the existing file.

If the selected file already covers the requested range, the tool reports that no further data is needed.

