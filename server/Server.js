/**
 * Server.js
 *
 * HTTP + WebSocket server for the Embroidery Communicator.
 *
 *  - Serves the built Flutter web app (docs/app) and injects a hosted-mode flag.
 *  - Exposes a WebSocket endpoint that relays the framed machine protocol to the
 *    embroidery machine over serial (reusing the relay's SerialStack).
 *
 * CLI switches mirror the relay server (--run / --install / --uninstall /
 * --start / --stop) so it can run in the foreground or as a systemd service.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const { createStaticHandler } = require('./StaticServer');

const SERVER_VERSION = '1.0.0';
const SERVICE_NAME = 'embroidery-server';

// Configuration defaults (overridable via config.ini).
let PORT = 8080;
let HOST = '0.0.0.0';
let WEB_ROOT = path.join(__dirname, '..', 'docs', 'app');
let WS_PATH = '/ws';
let SERIAL_PORT = '/dev/ttyUSB0';
let BAUD_RATE = 19200;

/** Minimal INI parser (sections + key=value). */
function parseIniFile(filePath) {
  try {
    const content = fs.readFileSync(filePath, 'utf8');
    const config = {};
    let section = null;
    for (const line of content.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#') || trimmed.startsWith(';')) continue;
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        section = trimmed.slice(1, -1);
        config[section] = {};
        continue;
      }
      const eq = trimmed.indexOf('=');
      if (eq > 0 && section) {
        config[section][trimmed.slice(0, eq).trim()] = trimmed.slice(eq + 1).trim();
      }
    }
    return config;
  } catch {
    return {};
  }
}

function loadConfig() {
  const config = parseIniFile(path.join(__dirname, 'config.ini'));

  if (config.http) {
    const port = parseInt(config.http.port, 10);
    if (!isNaN(port) && port > 0 && port <= 65535) PORT = port;
    if (config.http.host) HOST = config.http.host;
    if (config.http.webRoot) {
      WEB_ROOT = path.isAbsolute(config.http.webRoot)
        ? config.http.webRoot
        : path.resolve(__dirname, config.http.webRoot);
    }
  }
  if (config.ws && config.ws.path) {
    WS_PATH = config.ws.path.startsWith('/') ? config.ws.path : `/${config.ws.path}`;
  }
  if (config.serial && config.serial.port) {
    SERIAL_PORT = config.serial.port;
  }

  console.log('Loaded configuration:');
  console.log(`  HTTP:    ${HOST}:${PORT}`);
  console.log(`  Web root: ${WEB_ROOT}`);
  console.log(`  WS path: ${WS_PATH}`);
  console.log(`  Serial:  ${SERIAL_PORT} (baud rate auto-detected)`);
}

function showHelp() {
  console.log(`
Embroidery Server v${SERVER_VERSION} - HTTP + WebSocket host for the web app

USAGE:
  node Server.js [COMMAND]

COMMANDS:
  --help, -h        Show this help message
  --run             Run server in foreground
  --install         Install as systemd service and start it
  --uninstall       Stop and uninstall systemd service
  --start           Start the systemd service
  --stop            Stop the systemd service

CONFIGURATION (config.ini, optional):
  [http]
  port = ${PORT}
  host = ${HOST}
  webRoot = ../docs/app
  [ws]
  path = ${WS_PATH}
  [serial]
  port = ${SERIAL_PORT}

DESCRIPTION:
  Serves the Flutter web app and relays the embroidery machine protocol over a
  WebSocket on the same port. The served app is flagged as server-hosted so it
  connects back to ${WS_PATH} automatically.
`);
}

function systemctl(cmd, { ignoreErrors = false } = {}) {
  try {
    execSync(cmd);
  } catch (error) {
    if (!ignoreErrors) throw error;
  }
}

function installService() {
  console.log(`Installing ${SERVICE_NAME} as systemd service...`);
  try {
    const scriptPath = path.resolve(__filename);
    const workingDir = path.dirname(scriptPath);
    const nodePath = execSync('which node').toString().trim();

    const serviceContent = `[Unit]
Description=Embroidery Server (HTTP + WebSocket relay)
After=network.target

[Service]
Type=simple
User=${process.env.USER || 'root'}
WorkingDirectory=${workingDir}
ExecStart=${nodePath} ${scriptPath} --run
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
`;

    const serviceFile = `/etc/systemd/system/${SERVICE_NAME}.service`;
    console.log(`Creating service file: ${serviceFile}`);
    try {
      fs.writeFileSync(serviceFile, serviceContent);
    } catch (error) {
      console.error('Failed to write service file. You may need to run with sudo.');
      console.error(`Error: ${error.message}`);
      process.exit(1);
    }

    systemctl('systemctl daemon-reload');
    systemctl(`systemctl enable ${SERVICE_NAME}.service`);
    systemctl(`systemctl start ${SERVICE_NAME}.service`);

    console.log('\n\u2713 Service installed and started successfully!');
    console.log('\nUseful commands:');
    console.log(`  sudo systemctl status ${SERVICE_NAME}   # Check service status`);
    console.log(`  sudo journalctl -u ${SERVICE_NAME} -f   # View live logs`);
    console.log('  node Server.js --stop                   # Stop the service');
    console.log('  node Server.js --uninstall              # Uninstall the service');
  } catch (error) {
    console.error(`Failed to install service: ${error.message}`);
    console.error('Make sure you run this command with sudo if needed.');
    process.exit(1);
  }
}

function uninstallService() {
  console.log(`Uninstalling ${SERVICE_NAME} systemd service...`);
  try {
    systemctl(`systemctl stop ${SERVICE_NAME}.service`, { ignoreErrors: true });
    systemctl(`systemctl disable ${SERVICE_NAME}.service`, { ignoreErrors: true });

    const serviceFile = `/etc/systemd/system/${SERVICE_NAME}.service`;
    console.log(`Removing service file: ${serviceFile}`);
    try {
      fs.unlinkSync(serviceFile);
    } catch (error) {
      if (error.code !== 'ENOENT') {
        console.error('Failed to remove service file. You may need to run with sudo.');
        console.error(`Error: ${error.message}`);
        process.exit(1);
      }
    }

    systemctl('systemctl daemon-reload');
    console.log('\n\u2713 Service uninstalled successfully!');
  } catch (error) {
    console.error(`Failed to uninstall service: ${error.message}`);
    console.error('Make sure you run this command with sudo if needed.');
    process.exit(1);
  }
}

function startService() {
  console.log(`Starting ${SERVICE_NAME} service...`);
  try {
    execSync(`systemctl start ${SERVICE_NAME}.service`);
    console.log('\u2713 Service started successfully!');
  } catch (error) {
    console.error(`Failed to start service: ${error.message}`);
    console.error('Make sure the service is installed first with: node Server.js --install');
    process.exit(1);
  }
}

function stopService() {
  console.log(`Stopping ${SERVICE_NAME} service...`);
  try {
    execSync(`systemctl stop ${SERVICE_NAME}.service`);
    console.log('\u2713 Service stopped successfully!');
  } catch (error) {
    console.error(`Failed to stop service: ${error.message}`);
    process.exit(1);
  }
}

/** Lazily require optional dependencies with a friendly error if missing. */
function requireOrExplain(moduleName, hint) {
  try {
    return require(moduleName);
  } catch {
    console.error(`\n\u274C ERROR: the "${moduleName}" module is not available.\n`);
    console.error(hint);
    process.exit(1);
  }
}

function runServer() {
  const { WebSocketServer } = requireOrExplain(
    'ws',
    'Install server dependencies with:\n\n  cd server && npm install\n',
  );
  // RelaySession pulls in the bundled serialport-backed SerialStack.
  const RelaySession = requireOrExplain(
    './RelaySession',
    'Install dependencies with:\n\n  cd server && npm install\n',
  );

  if (!fs.existsSync(WEB_ROOT)) {
    console.warn(`\u26A0 Web root not found: ${WEB_ROOT}`);
    console.warn('  The relay will still work, but the web app will 404 until it is built.');
  }

  const staticHandler = createStaticHandler({
    webRoot: WEB_ROOT,
    basePath: '/',
    wsPath: WS_PATH,
  });

  const server = http.createServer(staticHandler);
  const wss = new WebSocketServer({ server, path: WS_PATH });

  // The serial port is a single physical resource; allow one session at a time.
  let activeSession = null;

  wss.on('connection', (ws, req) => {
    const peer = req.socket.remoteAddress;
    if (activeSession) {
      console.log(`WebSocket rejected from ${peer} - a session is already active`);
      ws.close(1013, 'Server busy - only one connection allowed');
      return;
    }

    console.log(`WebSocket connected from ${peer}`);
    const session = new RelaySession({
      send: (data) => ws.send(data),
      serialPort: SERIAL_PORT,
      baudRate: BAUD_RATE,
    });
    activeSession = session;

    ws.on('message', (data) => session.handleData(data));

    const cleanup = async (reason) => {
      if (activeSession !== session) return;
      console.log(`WebSocket ${reason} from ${peer}`);
      activeSession = null;
      await session.dispose();
    };
    ws.on('close', () => cleanup('closed'));
    ws.on('error', (err) => {
      console.error(`WebSocket error from ${peer}: ${err.message}`);
      cleanup('errored');
    });

    session.init().catch((err) => {
      console.error(`Session init failed: ${err.message}`);
      ws.close(1011, 'Failed to initialize serial connection');
    });
  });

  server.on('error', (err) => {
    if (err.code === 'EADDRINUSE') {
      console.error(`Port ${PORT} is already in use`);
    } else {
      console.error(`Server error: ${err.message}`);
    }
    process.exit(1);
  });

  server.listen(PORT, HOST, () => {
    console.log(`Embroidery Server listening on http://${HOST}:${PORT}`);
    console.log(`WebSocket relay available at ws://${HOST}:${PORT}${WS_PATH}`);
    console.log('Press Ctrl+C to stop');
  });

  const shutdown = () => {
    console.log('\nShutting down server...');
    const force = setTimeout(() => process.exit(0), 2000);
    const done = () => {
      clearTimeout(force);
      process.exit(0);
    };
    const disposal = activeSession ? activeSession.dispose() : Promise.resolve();
    Promise.resolve(disposal).finally(() => {
      wss.close(() => server.close(done));
    });
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

function main() {
  loadConfig();

  const args = process.argv.slice(2);
  const command = args[0];

  switch (command) {
    case undefined:
    case '--help':
    case '-h':
      showHelp();
      process.exit(0);
      break;
    case '--run':
      runServer();
      break;
    case '--install':
      installService();
      process.exit(0);
      break;
    case '--uninstall':
      uninstallService();
      process.exit(0);
      break;
    case '--start':
      startService();
      process.exit(0);
      break;
    case '--stop':
      stopService();
      process.exit(0);
      break;
    default:
      console.error(`Unknown command: ${command}`);
      console.log('Run with --help to see available commands');
      process.exit(1);
  }
}

main();
