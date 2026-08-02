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

**Choose Output File:**
1. Click the **Browse** button
2. Navigate to your desired save location
3. Enter a filename (suggested format: `MemoryDump-[Device]-[Date].bin`)
4. Click **Save**

### Step 4: Start the Download

1. Click the **Start** button to begin the memory dump
2. Monitor the progress bar and status text
3. The process will take about an hour.
4. When complete, a confirmation message will appear

### Step 5: Cancel (Optional)

- If you need to abort the download, click the **Cancel** button
- The partial file will be automatically deleted
