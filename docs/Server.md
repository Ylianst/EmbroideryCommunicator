# Embroidery Server Documentation

The **Embroidery Server** is a single Node.js process that **hosts the
Embroidery Communicator web app** and **relays** the browser back to your
embroidery machine over serial. There is no separate relay to run — the same
process serves the app and talks to the machine.

It is ideal for a Raspberry Pi (or any always-on computer) attached to the
machine: open a browser on any device on your network and use the machine
directly, with nothing to install on the client.

```
Browser (Flutter web app)  <--HTTP-->  Embroidery Server  <--serial-->  Machine
                           <--WebSocket relay-->
```

## How it works

1. The server serves the built Flutter web app from `../docs/app`.
2. When it serves `index.html`, it rewrites the app's `<base href>` to `/` and
   injects a small flag:
   `window.embroideryServerConfig = { hosted: true, wsPath: "/ws" }`.
3. The Flutter app detects that flag on startup and **automatically connects
   back** to the server's WebSocket (`/ws`) instead of prompting for a serial
   port or relay host.
4. The WebSocket uses the same framed protocol as the TCP relay (see
   [TcpProtocol.md](TcpProtocol.md)), reusing the machine communication code
   from the [relay](../relay).

Only **one** machine session is allowed at a time — the serial port is a single
physical resource, so additional WebSocket clients are rejected until the active
one disconnects.

## What you'll need

- A computer with Node.js 16+ (a Raspberry Pi works well)
- A USB-to-serial cable connecting it to your embroidery machine
- The built web app in `docs/app` (already included in this repository)

## Installation

The server depends on `ws`, and the machine communication code it reuses depends
on `serialport`. Install both:

```bash
# Serial protocol dependencies (serialport)
cd relay
npm install

# Server dependencies (ws)
cd ../server
npm install
```

> The first `serialport` build can take a few minutes. On Linux you may need
> build tools first: `sudo apt-get install build-essential`.

## Configuration

Settings are read from `server/config.ini`. The file is optional — if it is
missing, the defaults below are used. Edit it to match your setup:

```ini
[http]
# Port the HTTP + WebSocket server listens on.
port = 8080
# Host/interface to bind to (0.0.0.0 = all interfaces).
host = 0.0.0.0
# Folder containing the built Flutter web app.
# Relative paths are resolved against the server directory.
webRoot = ../docs/app

[ws]
# Path the browser app connects to for the machine relay.
path = /ws

[serial]
# Serial device the embroidery machine is attached to.
port = /dev/ttyUSB0
```

| Section    | Key       | Default        | Description                                            |
| ---------- | --------- | -------------- | ------------------------------------------------------ |
| `[http]`   | `port`    | `8080`         | HTTP + WebSocket port (both share the same port).      |
| `[http]`   | `host`    | `0.0.0.0`      | Interface to bind (`0.0.0.0` = all interfaces).        |
| `[http]`   | `webRoot` | `../docs/app`  | Folder of the built Flutter web app.                   |
| `[ws]`     | `path`    | `/ws`          | WebSocket path advertised to the app.                  |
| `[serial]` | `port`    | `/dev/ttyUSB0` | Serial device the machine is attached to.              |

On Windows the serial port looks like `COM3`; on Linux/macOS it is usually
`/dev/ttyUSB0` or `/dev/ttyACM0`.

## Command-line switches

Run the server with `node Server.js <command>`:

| Command        | Description                                    |
| -------------- | ---------------------------------------------- |
| `--run`        | Run the server in the foreground.              |
| `--install`    | Install and start it as a systemd service.     |
| `--uninstall`  | Stop and remove the systemd service.           |
| `--start`      | Start the systemd service.                     |
| `--stop`       | Stop the systemd service.                      |
| `--help`, `-h` | Show help (also shown when run with no args).  |

## Getting started

### Option 1: Run in the foreground (testing)

This keeps the server running in your terminal:

```bash
cd server
node Server.js --run
```

You should see:

```
Loaded configuration:
  HTTP:    0.0.0.0:8080
  Web root: /path/to/EmbroideryCommunicator/docs/app
  WS path: /ws
  Serial:  /dev/ttyUSB0 (baud rate auto-detected)
Embroidery Server listening on http://0.0.0.0:8080
WebSocket relay available at ws://0.0.0.0:8080/ws
Press Ctrl+C to stop
```

Then browse to `http://<host>:8080/` — for example `http://raspberrypi.local:8080/`.
The app loads in hosted mode and connects to the machine automatically.

Press `Ctrl+C` to stop.

### Option 2: Install as a background service (recommended, Linux)

This makes the server start automatically at boot and restart on crashes:

```bash
cd server
sudo node Server.js --install
```

Manage it afterwards:

```bash
sudo node Server.js --stop        # Stop
sudo node Server.js --start       # Start
sudo node Server.js --uninstall   # Remove
```

Check status and view live logs with systemd:

```bash
sudo systemctl status embroidery-server
sudo journalctl -u embroidery-server -f
```

## Notes and troubleshooting

- **HTTP and WebSocket share one port.** You only need to open a single port
  (default `8080`) on your firewall.
- **Base href is rewritten to `/`.** The app is served at the server root
  regardless of the path baked into the build, so links and assets resolve
  correctly.
- **"Web root not found" warning.** If `docs/app` is missing, the relay still
  works but the web page returns 404 until the app is built.
- **"Server busy" / connection rejected.** Another browser already holds the
  machine session. Close the other tab/device and try again.
- **Serial errors on connect.** Confirm the `[serial] port` in `config.ini`
  matches your device and that no other program (including the
  [relay](../relay) or the desktop app) is using the port.

## Related

- [Embroidery Relay](../relay) — network access to the machine over raw TCP.
- [TcpProtocol.md](TcpProtocol.md) — the framed protocol used over the WebSocket.
- [DumpMemory.md](DumpMemory.md) — command-line tool to dump machine memory.
