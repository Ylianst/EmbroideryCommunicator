# Dump Memory Tool Documentation

`DumpMemory.js` is a command-line tool that downloads the entire 16 MB memory of
an embroidery machine to a binary file over a serial port. It is the
command-line equivalent of the app's [Memory Dump](MemoryDump.md) feature and
lives in the [server](../server) folder.

Like the app, it reads the memory in 256-byte blocks and **retries each block
automatically** on error (10 attempts, 3 seconds apart) while showing live
progress. Output is written incrementally, so a partial file is preserved if a
block ultimately fails or you cancel.

Use it for backups, analysis, debugging, or reverse engineering — without
launching the GUI.

## What you'll need

- A computer with Node.js 16+
- A USB-to-serial cable connecting it to your embroidery machine

## Installation

The tool lives in the [server](../server) folder, which is self-contained and
bundles the serial stack (it depends on `serialport`). Install the server
dependencies once:

```bash
cd server
npm install
```

> The first `serialport` build can take a few minutes. On Linux you may need
> build tools first: `sudo apt-get install build-essential`.

## Command-line switches

Run the tool from the `server` folder with
`node DumpMemory.js <options>`:

| Option           | Alias | Required | Default                                   | Description                                              |
| ---------------- | ----- | -------- | ----------------------------------------- | -------------------------------------------------------- |
| `--port`         | `-p`  | Yes      | —                                         | Serial port (e.g. `COM3` or `/dev/ttyUSB0`).             |
| `--module`       | `-m`  | Yes      | —                                         | Which memory to dump: `sewing` or `embroidery`.          |
| `--output`       | `-o`  | No       | `MemoryDump-<Module>-<date_time>.bin`     | Output file name.                                        |
| `--start`        |       | No       | `000000`                                  | Start address in hex.                                    |
| `--end`          |       | No       | `1000000`                                 | End address in hex, **exclusive**.                       |
| `--help`         | `-h`  | No       | —                                         | Show help (also shown when run with no arguments).       |

### `--module` values

- **`sewing`** — dumps the main **sewing machine** controller. Accepted forms:
  `sewing`, `sewing-machine`, `machine`, `s`. Before reading, the tool makes sure
  any embroidery session is closed.
- **`embroidery`** — dumps the **embroidery module** (if attached). Accepted
  forms: `embroidery`, `embroidery-module`, `module`, `e`. Before reading, the
  tool starts an embroidery session so the module's memory is visible, and ends
  it when finished.

### Output file naming

If you omit `--output`, the tool creates a file named after the module and the
current date/time, for example:

```
MemoryDump-SewingMachine-2026-08-16_14-30-05.bin
MemoryDump-EmbroideryModule-2026-08-16_14-31-42.bin
```

### Address range

The defaults cover the entire 16 MB address space: `--start 000000` and
`--end 1000000`, which reads every byte from `0x000000` through `0xFFFFFF`
inclusive (the end address is exclusive). Narrow the range only if you need a
specific region.

## Getting started

1. Connect the machine to your computer with the USB-to-serial cable and power
   it on.
2. Identify the serial port:
   - **Windows**: something like `COM3` (see Device Manager).
   - **Linux/macOS**: usually `/dev/ttyUSB0` or `/dev/ttyACM0`
     (run `ls /dev/ttyUSB*`).
3. Make sure no other program is using the port — close the desktop app, the
   [relay](../relay), and the [Embroidery Server](Server.md) if they are running.
4. Run the tool.

### Examples

Dump the sewing machine to an auto-named file:

```bash
cd server
node DumpMemory.js --port /dev/ttyUSB0 --module sewing
```

Dump the embroidery module to a specific file (using short aliases):

```bash
node DumpMemory.js -p COM3 -m embroidery -o backup.bin
```

Dump only a small region for analysis:

```bash
node DumpMemory.js -p COM3 -m sewing --start 200000 --end 210000
```

You can also use the npm script wrapper:

```bash
npm run dump -- --port COM3 --module sewing
```

## What you'll see

The tool prints the configuration, opens the port (auto-detecting the baud rate
and upgrading to the fastest supported speed), selects the module, then shows a
live progress line:

```
Serial port: /dev/ttyUSB0
Module:      SewingMachine
Range:       0x000000 .. 0x1000000 (16.00 MB)
Output:      /home/pi/MemoryDump-SewingMachine-2026-08-16_14-30-05.bin

Opening serial port (auto-detecting baud rate)...
Serial port open at 19200 baud
Upgraded to 57600 baud
Selecting sewing machine (ensuring embroidery session is closed)...

Dumping memory:
   42.7%  6.83 MB / 16.00 MB  @ 0x6D5A00
```

When a block errors, the progress line shows the retry status, for example
`read error, retrying 2/10…`, and continues automatically once the read
succeeds.

On completion:

```
✓ Done. Saved 16.00 MB to MemoryDump-SewingMachine-2026-08-16_14-30-05.bin
```

## Notes and troubleshooting

- **Reading over serial is slow.** A full 16 MB dump can take a long time. This
  is expected — the machine's serial link is the bottleneck.
- **Partial dumps are preserved.** If a block still fails after all retries, or
  you press `Ctrl+C`, whatever was read so far is already written to the output
  file. The tool exits with a non-zero status and reports how much was saved.
- **"Missing or invalid --module".** Use `sewing` or `embroidery` (or one of the
  accepted aliases listed above).
- **"could not load the serial stack".** Install the server dependencies first:
  `cd server && npm install`.
- **Port is busy / cannot open.** Another program is using the serial port.
  Close the desktop app, relay, or server and try again.

## Related

- [MemoryDump.md](MemoryDump.md) — the in-app Memory Dump feature (GUI).
- [Server.md](Server.md) — HTTP + WebSocket server that hosts the web app.
- [SerialProtocol.md](SerialProtocol.md) — the low-level serial protocol.
