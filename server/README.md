# Embroidery Server

A single Node.js process that **hosts the Embroidery Communicator web app** and
**relays** the browser back to your embroidery machine over serial — no separate
relay needed. Great for a Raspberry Pi: open a browser on any device on your
network and use the machine directly.

```
Browser (Flutter web app)  <--HTTP-->  Embroidery Server  <--serial-->  Machine
                           <--WebSocket relay-->
```

## How it works

- The server serves the built Flutter web app from `../docs/app`.
- When it serves `index.html` it rewrites the `<base href>` and injects a small
  script: `window.embroideryServerConfig = { hosted: true, wsPath: "/ws" }`.
- The Flutter app detects that flag on startup and automatically connects back
  to the server's WebSocket (`/ws`) instead of asking for a relay host/port.
- The WebSocket uses the same framed protocol as the TCP relay
  (see `../docs/TcpProtocol.md`), using the bundled `SerialStack.js` and
  `TcpProtocol.js` for the machine communication.

Only **one** machine session is allowed at a time (the serial port is a single
physical resource); additional WebSocket clients are rejected until the active
one disconnects.

## What you'll need

- A machine with Node.js 16+ (a Raspberry Pi works well)
- A USB-to-serial cable to your embroidery machine
- The built web app in `docs/app` (already included in this repo)

## Install

The server is self-contained (it bundles the serial stack). Install its
dependencies (`ws` and `serialport`):

```bash
cd server
npm install
```

The first `serialport` build can take a few minutes. On Linux you may need
build tools: `sudo apt-get install build-essential`.

## Configure (optional)

Defaults live in `config.ini`. Edit if your setup differs:

```ini
[http]
port = 8080
host = 0.0.0.0
webRoot = ../docs/app

[ws]
path = /ws

[serial]
port = /dev/ttyUSB0
```

## Run

### Foreground (testing)

```bash
node Server.js --run
```

Then browse to `http://<host>:8080/`. You should see:

```
Embroidery Server listening on http://0.0.0.0:8080
WebSocket relay available at ws://0.0.0.0:8080/ws
```

Press `Ctrl+C` to stop.

### Background service (systemd, Linux)

```bash
sudo node Server.js --install    # install + start on boot
sudo node Server.js --stop       # stop
sudo node Server.js --start       # start
sudo node Server.js --uninstall   # remove
```

Check status / logs:

```bash
sudo systemctl status embroidery-server
sudo journalctl -u embroidery-server -f
```

## Commands

| Command        | Description                                  |
| -------------- | -------------------------------------------- |
| `--run`        | Run in the foreground                        |
| `--install`    | Install and start as a systemd service       |
| `--uninstall`  | Stop and remove the systemd service          |
| `--start`      | Start the systemd service                    |
| `--stop`       | Stop the systemd service                     |
| `--help`, `-h` | Show help                                    |

## Notes

- The served app's `<base href>` is rewritten to `/`, so the app is served at
  the server root regardless of the path baked into the build.
- HTTP and the WebSocket relay share the same port.

## Memory dump tool

`DumpMemory.js` dumps the entire 16 MB memory of the machine to a file over
serial — the command-line equivalent of the app's Memory Dump feature. It reads
256-byte blocks and retries each block automatically on error (10 attempts, 3s
apart) while showing live progress.

Requires the server dependencies (`cd server && npm install`) for serial access.

```bash
# Dump the sewing machine to an auto-named file
node DumpMemory.js --port /dev/ttyUSB0 --module sewing

# Dump the embroidery module to a specific file
node DumpMemory.js -p COM3 -m embroidery -o backup.bin
```

Options:

| Option           | Description                                                    |
| ---------------- | ------------------------------------------------------------- |
| `--port`, `-p`   | Serial port (e.g. `COM3` or `/dev/ttyUSB0`) — required        |
| `--module`, `-m` | `sewing` or `embroidery` — required                           |
| `--output`, `-o` | Output file (default `MemoryDump-<Module>-<date_time>.bin`)   |
| `--start`        | Start address in hex (default `000000`)                       |
| `--end`          | End address in hex, exclusive (default `1000000`)             |
| `--help`, `-h`   | Show help                                                     |

If a block ultimately fails after all retries (or you press `Ctrl+C`), the
partial dump collected so far is still written to the output file.

