const net = require('net');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

// Note: SerialStack and TcpProtocol will be required after checking for serialport module
let SerialStack;
let TcpProtocol;

// Default configuration
const RELAY_VERSION = '1.0.0';
const SERVICE_NAME = 'relay';

// Configuration defaults
let PORT = 8888;
let HOST = '0.0.0.0';
let DEFAULT_SERIAL_PORT = '/dev/ttyUSB0';
let DEFAULT_BAUD_RATE = 19200;

/**
 * Parse INI file format
 */
function parseIniFile(filePath) {
  try {
    const content = fs.readFileSync(filePath, 'utf8');
    const config = {};
    let currentSection = null;

    for (const line of content.split('\n')) {
      const trimmed = line.trim();
      
      // Skip comments and empty lines
      if (!trimmed || trimmed.startsWith('#') || trimmed.startsWith(';')) {
        continue;
      }

      // Section header
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        currentSection = trimmed.slice(1, -1);
        config[currentSection] = {};
        continue;
      }

      // Key-value pair
      const equalIndex = trimmed.indexOf('=');
      if (equalIndex > 0 && currentSection) {
        const key = trimmed.slice(0, equalIndex).trim();
        const value = trimmed.slice(equalIndex + 1).trim();
        config[currentSection][key] = value;
      }
    }

    return config;
  } catch (error) {
    // If file doesn't exist or can't be read, return empty config
    return {};
  }
}

/**
 * Load configuration from config.ini
 */
function loadConfig() {
  const configPath = path.join(__dirname, 'config.ini');
  const config = parseIniFile(configPath);

  // Load network settings
  if (config.network) {
    if (config.network.port) {
      const port = parseInt(config.network.port, 10);
      if (!isNaN(port) && port > 0 && port <= 65535) {
        PORT = port;
      }
    }
    if (config.network.host) {
      HOST = config.network.host;
    }
  }

  // Load serial settings
  if (config.serial) {
    if (config.serial.port) {
      DEFAULT_SERIAL_PORT = config.serial.port;
    }
  }

  console.log(`Loaded configuration:`);
  console.log(`  TCP: ${HOST}:${PORT}`);
  console.log(`  Serial: ${DEFAULT_SERIAL_PORT} (baud rate auto-detected)`);
}

// Load configuration before processing arguments
loadConfig();

/**
 * Check if serialport module is available
 */
function checkSerialportModule() {
  try {
    // Try to require the serialport module
    require('serialport');
    return true;
  } catch (error) {
    return false;
  }
}

/**
 * Show setup instructions for serialport module
 */
function showSerialportSetup() {
  console.error('\n❌ ERROR: The "serialport" module is not installed.\n');
  console.error('Relay.js requires the serialport module to communicate with the embroidery machine.');
  console.error('\nTo install the required dependencies, run:\n');
  console.error('  npm install\n');
  console.error('Or install serialport specifically:\n');
  console.error('  npm install serialport\n');
  console.error('If you encounter build errors, you may need to install build tools:');
  console.error('  - On Linux: sudo apt-get install build-essential');
  console.error('  - On macOS: xcode-select --install');
  console.error('  - On Windows: npm install --global windows-build-tools\n');
  process.exit(1);
}

// Check for serialport module before running
if (!checkSerialportModule()) {
  showSerialportSetup();
}

// Now it's safe to require modules that depend on serialport
SerialStack = require('./SerialStack');
TcpProtocol = require('./TcpProtocol');

// Process command line arguments
const args = process.argv.slice(2);

// Show help if no arguments provided
if (args.length === 0) {
  showHelp();
  process.exit(0);
}

const command = args[0];

switch (command) {
  case '--help':
  case '-h':
    showHelp();
    process.exit(0);
    break;
    
  case '--run':
    // Run server in foreground - continue execution
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

/**
 * Show help information
 */
function showHelp() {
  console.log(`
Relay.js v${RELAY_VERSION} - TCP to Serial Relay Server

USAGE:
  node Relay.js [COMMAND]

COMMANDS:
  --help, -h        Show this help message
  --run             Run server in foreground
  --install         Install as systemd service and start it
  --uninstall       Stop and uninstall systemd service
  --start           Start the systemd service
  --stop            Stop the systemd service

CONFIGURATION:
  Settings are loaded from config.ini (optional). If the file doesn't exist,
  defaults are used. Edit config.ini to customize:
  
  [network]
  port = ${PORT}              # TCP port (default: 8888)
  host = ${HOST}        # Host address (default: 0.0.0.0)
  
  [serial]
  port = ${DEFAULT_SERIAL_PORT}    # Serial device (default: /dev/ttyUSB0)

DESCRIPTION:
  Relay.js provides a TCP server on port ${PORT} that relays commands to
  an embroidery machine via serial connection. It automatically initializes
  the serial connection, closes any active sessions, and upgrades to maximum
  baud rate when a client connects.

EXAMPLES:
  node Relay.js --run           # Run in foreground
  node Relay.js --install       # Install and start as service
  node Relay.js --stop          # Stop the service
  node Relay.js --uninstall     # Uninstall the service
`);
}

/**
 * Install systemd service
 */
function installService() {
  console.log('Installing Relay.js as systemd service...');
  
  try {
    // Get absolute paths
    const scriptPath = path.resolve(__filename);
    const workingDir = path.dirname(scriptPath);
    const nodePath = execSync('which node').toString().trim();
    
    // Create systemd service file content
    const serviceContent = `[Unit]
Description=Relay.js TCP to Serial Relay Server
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

    // Write service file
    const serviceFile = `/etc/systemd/system/${SERVICE_NAME}.service`;
    console.log(`Creating service file: ${serviceFile}`);
    
    try {
      fs.writeFileSync(serviceFile, serviceContent);
    } catch (error) {
      console.error(`Failed to write service file. You may need to run with sudo.`);
      console.error(`Error: ${error.message}`);
      process.exit(1);
    }
    
    // Reload systemd
    console.log('Reloading systemd daemon...');
    execSync('systemctl daemon-reload');
    
    // Enable service
    console.log('Enabling service to start on boot...');
    execSync(`systemctl enable ${SERVICE_NAME}.service`);
    
    // Start service
    console.log('Starting service...');
    execSync(`systemctl start ${SERVICE_NAME}.service`);
    
    console.log(`\n✓ Service installed and started successfully!`);
    console.log(`\nUseful commands:`);
    console.log(`  sudo systemctl status ${SERVICE_NAME}   # Check service status`);
    console.log(`  sudo journalctl -u ${SERVICE_NAME} -f   # View live logs`);
    console.log(`  node Relay.js --stop                    # Stop the service`);
    console.log(`  node Relay.js --uninstall               # Uninstall the service`);
    
  } catch (error) {
    console.error(`Failed to install service: ${error.message}`);
    console.error('Make sure you run this command with sudo if needed.');
    process.exit(1);
  }
}

/**
 * Uninstall systemd service
 */
function uninstallService() {
  console.log('Uninstalling Relay.js systemd service...');
  
  try {
    // Stop service
    console.log('Stopping service...');
    try {
      execSync(`systemctl stop ${SERVICE_NAME}.service`);
    } catch (error) {
      console.log('Service was not running');
    }
    
    // Disable service
    console.log('Disabling service...');
    try {
      execSync(`systemctl disable ${SERVICE_NAME}.service`);
    } catch (error) {
      console.log('Service was not enabled');
    }
    
    // Remove service file
    const serviceFile = `/etc/systemd/system/${SERVICE_NAME}.service`;
    console.log(`Removing service file: ${serviceFile}`);
    try {
      fs.unlinkSync(serviceFile);
    } catch (error) {
      console.error(`Failed to remove service file. You may need to run with sudo.`);
      console.error(`Error: ${error.message}`);
      process.exit(1);
    }
    
    // Reload systemd
    console.log('Reloading systemd daemon...');
    execSync('systemctl daemon-reload');
    
    console.log('\n✓ Service uninstalled successfully!');
    
  } catch (error) {
    console.error(`Failed to uninstall service: ${error.message}`);
    console.error('Make sure you run this command with sudo if needed.');
    process.exit(1);
  }
}

/**
 * Start systemd service
 */
function startService() {
  console.log('Starting Relay.js service...');
  
  try {
    execSync(`systemctl start ${SERVICE_NAME}.service`);
    console.log('✓ Service started successfully!');
    console.log(`\nCheck status with: sudo systemctl status ${SERVICE_NAME}`);
    console.log(`View logs with: sudo journalctl -u ${SERVICE_NAME} -f`);
  } catch (error) {
    console.error(`Failed to start service: ${error.message}`);
    console.error('Make sure the service is installed first with: node Relay.js --install');
    process.exit(1);
  }
}

/**
 * Stop systemd service
 */
function stopService() {
  console.log('Stopping Relay.js service...');
  
  try {
    execSync(`systemctl stop ${SERVICE_NAME}.service`);
    console.log('✓ Service stopped successfully!');
  } catch (error) {
    console.error(`Failed to stop service: ${error.message}`);
    process.exit(1);
  }
}

// Track active connection and serial stack
let activeConnection = null;
let serialStack = null;

// Configuration state (use loaded values from config.ini)
let config = {
  serialPort: DEFAULT_SERIAL_PORT,
  baudRate: DEFAULT_BAUD_RATE
};

// Create protocol handler
const protocol = new TcpProtocol();

// Create TCP server
const server = net.createServer((socket) => {
  // Check if there's already an active connection
  if (activeConnection) {
    console.log(`Connection rejected from ${socket.remoteAddress}:${socket.remotePort} - server already has an active connection`);
    socket.end('Server busy - only one connection allowed\n');
    return;
  }

  // Accept the connection
  activeConnection = socket;
  console.log(`Connection accepted from ${socket.remoteAddress}:${socket.remotePort}`);

  // Buffer for accumulating incoming data
  let receiveBuffer = Buffer.alloc(0);
  
  // Track initialization state
  let isInitialized = false;
  let messageQueue = [];

  // Create and initialize SerialStack instance for this connection
  (async () => {
    try {
      console.log('Creating SerialStack instance...');
      serialStack = new SerialStack(config.serialPort, config.baudRate);
      console.log('SerialStack instance created');

      // Open the serial port with auto-detection
      console.log('Opening serial port with auto-detection...');
      await serialStack.open();
      console.log(`Serial port opened at ${serialStack.baudRate} baud`);

      // Close any existing embroidery session
      try {
        const isSessionOpen = await serialStack.IsEmbroiderySessionOpen();
        if (isSessionOpen) {
          console.log('Closing existing embroidery session...');
          await serialStack.EndEmbroiderySession();
          console.log('Embroidery session closed');
        } else {
          console.log('No active embroidery session to close');
        }
      } catch (error) {
        console.log('Could not check/close embroidery session:', error.message);
      }

      // Upgrade to maximum speed (57600)
      if (serialStack.baudRate !== 57600) {
        console.log(`Upgrading speed from ${serialStack.baudRate} to 57600 baud...`);
        try {
          await serialStack.upgradeSpeed();
          console.log(`Successfully upgraded to ${serialStack.baudRate} baud`);
        } catch (error) {
          console.log(`Could not upgrade to 57600, staying at ${serialStack.baudRate} baud:`, error.message);
        }
      } else {
        console.log('Already at maximum speed (57600 baud)');
      }

      console.log('SerialStack fully initialized and ready');
      isInitialized = true;

      // Process any queued messages
      if (messageQueue.length > 0) {
        console.log(`Processing ${messageQueue.length} queued message(s)...`);
        for (const queuedMessage of messageQueue) {
          handleMessage(socket, queuedMessage);
        }
        messageQueue = [];
      }
    } catch (error) {
      console.error(`Failed to initialize SerialStack: ${error.message}`);
      socket.end('Failed to initialize serial connection\n');
      activeConnection = null;
      if (serialStack) {
        try {
          await serialStack.close();
        } catch (closeError) {
          console.error(`Error closing SerialStack: ${closeError.message}`);
        }
        serialStack = null;
      }
    }
  })();

  // Handle incoming data
  socket.on('data', (data) => {
    // Append new data to receive buffer
    receiveBuffer = Buffer.concat([receiveBuffer, data]);
    console.log(`Received ${data.length} bytes, buffer now ${receiveBuffer.length} bytes`);

    // Protect against buffer overflow (max 1MB)
    if (receiveBuffer.length > 1048576) {
      console.error('Receive buffer overflow, closing connection');
      socket.destroy();
      return;
    }

    // Try to decode messages from the buffer
    while (receiveBuffer.length > 0) {
      const message = protocol.decodeMessage(receiveBuffer);
      
      if (!message) {
        // Incomplete message, wait for more data
        console.log('Incomplete message, waiting for more data...');
        break;
      }

      // Complete message received
      console.log(`Decoded message: ${message.messageType} (RequestID: ${message.requestId}, Payload: ${message.payloadLength} bytes)`);

      // Remove the decoded message from the buffer
      receiveBuffer = receiveBuffer.slice(message.totalLength);

      // Check if initialization is complete
      if (!isInitialized) {
        console.log(`Queueing message ${message.messageType} until initialization completes...`);
        messageQueue.push(message);
      } else {
        // Handle the message immediately
        handleMessage(socket, message);
      }
    }
  });

  // Handle connection close
  socket.on('end', async () => {
    console.log(`Connection closed from ${socket.remoteAddress}:${socket.remotePort}`);
    
    // Clear the receive buffer
    receiveBuffer = Buffer.alloc(0);
    
    // Close SerialStack if it exists
    if (serialStack) {
      try {
        // End embroidery session if one is open
        if (serialStack.isOpen) {
          console.log('Ending embroidery session...');
          await serialStack.EndEmbroiderySession();
        }
        
        console.log('Closing SerialStack instance...');
        await serialStack.close();
        console.log('SerialStack instance closed');
      } catch (error) {
        console.error(`Error closing SerialStack: ${error.message}`);
      }
      serialStack = null;
    }
    
    activeConnection = null;
  });

  // Handle errors
  socket.on('error', async (err) => {
    console.error(`Socket error: ${err.message}`);
    
    // Clear the receive buffer
    receiveBuffer = Buffer.alloc(0);
    
    // Close SerialStack if it exists
    if (serialStack) {
      try {
        // End embroidery session if one is open
        if (serialStack.isOpen) {
          console.log('Ending embroidery session...');
          await serialStack.EndEmbroiderySession();
        }
        
        console.log('Closing SerialStack instance due to socket error...');
        await serialStack.close();
        console.log('SerialStack instance closed');
      } catch (error) {
        console.error(`Error closing SerialStack: ${error.message}`);
      }
      serialStack = null;
    }
    
    activeConnection = null;
  });
});

// Handle server errors
server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`Port ${PORT} is already in use`);
  } else {
    console.error(`Server error: ${err.message}`);
  }
  process.exit(1);
});

// Start listening
server.listen(PORT, HOST, () => {
  console.log(`Relay.js TCP server listening on ${HOST}:${PORT}`);
  console.log('Accepting only one connection at a time');
  console.log('Press Ctrl+C to stop');
});

/**
 * Handle a decoded protocol message
 */
function handleMessage(socket, message) {
  const { messageType, requestId, payload } = message;

  try {
    switch (messageType) {
      case protocol.MessageTypes.GCFG: // Get Configuration
        handleGetConfig(socket, requestId);
        break;

      case protocol.MessageTypes.SCFG: // Set Configuration
        handleSetConfig(socket, requestId, payload);
        break;

      case protocol.MessageTypes.STAT: // Get Status
        handleGetStatus(socket, requestId);
        break;

      case protocol.MessageTypes.READ: // Read Memory
        handleRead(socket, requestId, payload);
        break;

      case protocol.MessageTypes.LRED: // Large Read Memory
        handleLargeRead(socket, requestId, payload);
        break;

      case protocol.MessageTypes.WRIT: // Write Memory
        handleWrite(socket, requestId, payload);
        break;

      case protocol.MessageTypes.UPLD: // Upload Block
        handleUpload(socket, requestId, payload);
        break;

      case protocol.MessageTypes.CSUM: // Calculate Checksum
        handleChecksum(socket, requestId, payload);
        break;

      case protocol.MessageTypes.SOPE: // Session Open
        handleSessionOpen(socket, requestId);
        break;

      case protocol.MessageTypes.SCLO: // Session Close
        handleSessionClose(socket, requestId);
        break;

      case protocol.MessageTypes.BAUD: // Change Baud Rate
        handleBaudChange(socket, requestId, payload);
        break;

      case protocol.MessageTypes.RSET: // Protocol Reset
        handleReset(socket, requestId);
        break;

      default:
        console.warn(`Unknown message type: ${messageType}`);
        const errorMsg = `Unknown message type: ${messageType}`;
        const errorResponse = protocol.createErrorResponse(
          requestId,
          errorMsg,
          protocol.ErrorCodes.INVALID_FORMAT
        );
        console.log(`→ Sending error response (${errorResponse.length} bytes): ${errorMsg}`);
        socket.write(errorResponse);
        break;
    }
  } catch (error) {
    console.error(`Error handling message ${messageType}:`, error.message);
    const errorResponse = protocol.createErrorResponse(
      requestId,
      error.message,
      protocol.ErrorCodes.INVALID_PARAMETERS
    );
    console.log(`→ Sending error response (${errorResponse.length} bytes): ${error.message}`);
    socket.write(errorResponse);
  }
}

/**
 * Handle GCFG - Get Configuration
 */
function handleGetConfig(socket, requestId) {
  console.log('Handling GCFG - Get Configuration');
  const responseData = {
    serialPort: config.serialPort,
    baudRate: config.baudRate,
    relayVersion: RELAY_VERSION
  };
  const response = protocol.createConfigResponse(requestId, responseData);
  console.log(`→ Sending GCFG response (${response.length} bytes):`, JSON.stringify(responseData, null, 2));
  socket.write(response);
}

/**
 * Handle SCFG - Set Configuration
 * Note: Always returns success, ignores payload
 */
function handleSetConfig(socket, requestId, payload) {
  console.log('Handling SCFG - Set Configuration (ignoring payload, always returning success)');
  
  const responseData = {
    success: true
  };
  const response = protocol.createConfigResponse(requestId, responseData);
  console.log(`→ Sending SCFG response (${response.length} bytes):`, JSON.stringify(responseData, null, 2));
  socket.write(response);
}

/**
 * Handle STAT - Get Status
 */
async function handleGetStatus(socket, requestId) {
  console.log('Handling STAT - Get Status');
  
  let sessionOpen = false;
  if (serialStack && serialStack.isOpen) {
    try {
      sessionOpen = await serialStack.IsEmbroiderySessionOpen();
    } catch (error) {
      console.error('Error checking session status:', error.message);
    }
  }
  
  const status = {
    connected: serialStack ? serialStack.isOpen : false,
    baudRate: serialStack ? serialStack.baudRate : config.baudRate,
    sessionOpen: sessionOpen,
    lastError: ''
  };

  const response = protocol.createStatusResponse(requestId, status);
  console.log(`→ Sending STAT response (${response.length} bytes):`, JSON.stringify(status, null, 2));
  socket.write(response);
}

/**
 * Handle READ - Read Memory
 */
async function handleRead(socket, requestId, payload) {
  console.log('Handling READ - Read Memory');
  try {
    if (!serialStack || !serialStack.isOpen) {
      const errorMsg = 'Serial port not connected';
      const errorResponse = protocol.createErrorResponse(
        requestId,
        errorMsg,
        protocol.ErrorCodes.PORT_NOT_CONNECTED
      );
      console.log(`→ Sending READ error response (${errorResponse.length} bytes): ${errorMsg}`);
      socket.write(errorResponse);
      return;
    }

    const address = protocol.parseAddress(payload);
    const hexData = await serialStack.read(address);
    
    const response = protocol.createReadDataResponse(requestId, hexData);
    console.log(`→ Sending READ response (${response.length} bytes): Address ${address}, Data: ${hexData}`);
    socket.write(response);
  } catch (error) {
    console.error('Read error:', error.message);
    const errorResponse = protocol.createErrorResponse(
      requestId,
      `Read failed: ${error.message}`,
      protocol.ErrorCodes.MACHINE_ERROR
    );
    console.log(`→ Sending READ error response (${errorResponse.length} bytes): ${error.message}`);
    socket.write(errorResponse);
  }
}

/**
 * Handle LRED - Large Read Memory
 */
async function handleLargeRead(socket, requestId, payload) {
  console.log('Handling LRED - Large Read Memory');
  try {
    if (!serialStack || !serialStack.isOpen) {
      const errorMsg = 'Serial port not connected';
      const errorResponse = protocol.createErrorResponse(
        requestId,
        errorMsg,
        protocol.ErrorCodes.PORT_NOT_CONNECTED
      );
      console.log(`→ Sending LRED error response (${errorResponse.length} bytes): ${errorMsg}`);
      socket.write(errorResponse);
      return;
    }

    const address = protocol.parseAddress(payload);
    const binaryData = await serialStack.largeRead(address);
    
    // Convert string to Buffer for binary data
    const dataBuffer = Buffer.from(binaryData, 'latin1');
    const response = protocol.createLargeDataResponse(requestId, dataBuffer);
    console.log(`→ Sending LRED response (${response.length} bytes): Address ${address}, Data length: ${dataBuffer.length} bytes`);
    socket.write(response);
  } catch (error) {
    console.error('Large read error:', error.message);
    const errorResponse = protocol.createErrorResponse(
      requestId,
      `Large read failed: ${error.message}`,
      protocol.ErrorCodes.MACHINE_ERROR
    );
    console.log(`→ Sending LRED error response (${errorResponse.length} bytes): ${error.message}`);
    socket.write(errorResponse);
  }
}

/**
 * Handle WRIT - Write Memory
 */
async function handleWrite(socket, requestId, payload) {
  console.log('Handling WRIT - Write Memory');
  try {
    if (!serialStack || !serialStack.isOpen) {
      const errorMsg = 'Serial port not connected';
      const errorResponse = protocol.createErrorResponse(
        requestId,
        errorMsg,
        protocol.ErrorCodes.PORT_NOT_CONNECTED
      );
      console.log(`→ Sending WRIT error response (${errorResponse.length} bytes): ${errorMsg}`);
      socket.write(errorResponse);
      return;
    }

    const { address, data } = protocol.parseWritePayload(payload);
    await serialStack.write(address, data);
    
    const response = protocol.createWriteAckResponse(requestId, 'O');
    console.log(`→ Sending WRIT response (${response.length} bytes): Success - Address ${address}, Data: ${data}`);
    socket.write(response);
  } catch (error) {
    console.error('Write error:', error.message);
    const errorResponse = protocol.createErrorResponse(
      requestId,
      `Write failed: ${error.message}`,
      protocol.ErrorCodes.MACHINE_ERROR
    );
    console.log(`→ Sending WRIT error response (${errorResponse.length} bytes): ${error.message}`);
    socket.write(errorResponse);
  }
}

/**
 * Handle UPLD - Upload Block
 */
async function handleUpload(socket, requestId, payload) {
  console.log('Handling UPLD - Upload Block');
  try {
    if (!serialStack || !serialStack.isOpen) {
      const errorMsg = 'Serial port not connected';
      const errorResponse = protocol.createErrorResponse(
        requestId,
        errorMsg,
        protocol.ErrorCodes.PORT_NOT_CONNECTED
      );
      console.log(`→ Sending UPLD error response (${errorResponse.length} bytes): ${errorMsg}`);
      socket.write(errorResponse);
      return;
    }

    const { address, data } = protocol.parseUploadPayload(payload);
    await serialStack.upload(address, data);
    
    const response = protocol.createUploadAckResponse(requestId, 'O');
    console.log(`→ Sending UPLD response (${response.length} bytes): Success - Address ${address}, Data length: ${data.length} bytes`);
    socket.write(response);
  } catch (error) {
    console.error('Upload error:', error.message);
    const errorResponse = protocol.createErrorResponse(
      requestId,
      `Upload failed: ${error.message}`,
      protocol.ErrorCodes.MACHINE_ERROR
    );
    console.log(`→ Sending UPLD error response (${errorResponse.length} bytes): ${error.message}`);
    socket.write(errorResponse);
  }
}

/**
 * Handle CSUM - Calculate Checksum
 */
async function handleChecksum(socket, requestId, payload) {
  console.log('Handling CSUM - Calculate Checksum');
  try {
    if (!serialStack || !serialStack.isOpen) {
      const errorMsg = 'Serial port not connected';
      const errorResponse = protocol.createErrorResponse(
        requestId,
        errorMsg,
        protocol.ErrorCodes.PORT_NOT_CONNECTED
      );
      console.log(`→ Sending CSUM error response (${errorResponse.length} bytes): ${errorMsg}`);
      socket.write(errorResponse);
      return;
    }

    const { address, length } = protocol.parseChecksumPayload(payload);
    const sumValue = await serialStack.sum(address, length);
    
    // Convert sum value to 8-character hex string
    const checksumHex = sumValue.toString(16).toUpperCase().padStart(8, '0');
    const response = protocol.createChecksumResponse(requestId, checksumHex);
    console.log(`→ Sending CSUM response (${response.length} bytes): Address ${address}, Length ${length}, Checksum: ${checksumHex}`);
    socket.write(response);
  } catch (error) {
    console.error('Checksum error:', error.message);
    const errorResponse = protocol.createErrorResponse(
      requestId,
      `Checksum failed: ${error.message}`,
      protocol.ErrorCodes.MACHINE_ERROR
    );
    console.log(`→ Sending CSUM error response (${errorResponse.length} bytes): ${error.message}`);
    socket.write(errorResponse);
  }
}

/**
 * Handle SOPE - Session Open
 */
async function handleSessionOpen(socket, requestId) {
  console.log('Handling SOPE - Session Open');
  try {
    if (!serialStack || !serialStack.isOpen) {
      const errorMsg = 'Serial port not connected';
      const errorResponse = protocol.createErrorResponse(
        requestId,
        errorMsg,
        protocol.ErrorCodes.PORT_NOT_CONNECTED
      );
      console.log(`→ Sending SOPE error response (${errorResponse.length} bytes): ${errorMsg}`);
      socket.write(errorResponse);
      return;
    }

    const wasStarted = await serialStack.StartEmbroiderySession();
    
    const response = protocol.createSessionAckResponse(requestId, 'O');
    console.log(`→ Sending SOPE response (${response.length} bytes): Session opened successfully`);
    socket.write(response);
  } catch (error) {
    console.error('Session open error:', error.message);
    const errorResponse = protocol.createErrorResponse(
      requestId,
      `Session open failed: ${error.message}`,
      protocol.ErrorCodes.SESSION_ALREADY_OPEN
    );
    console.log(`→ Sending SOPE error response (${errorResponse.length} bytes): ${error.message}`);
    socket.write(errorResponse);
  }
}

/**
 * Handle SCLO - Session Close
 */
async function handleSessionClose(socket, requestId) {
  console.log('Handling SCLO - Session Close');
  try {
    if (!serialStack || !serialStack.isOpen) {
      const errorMsg = 'Serial port not connected';
      const errorResponse = protocol.createErrorResponse(
        requestId,
        errorMsg,
        protocol.ErrorCodes.PORT_NOT_CONNECTED
      );
      console.log(`→ Sending SCLO error response (${errorResponse.length} bytes): ${errorMsg}`);
      socket.write(errorResponse);
      return;
    }

    const wasEnded = await serialStack.EndEmbroiderySession();
    
    const response = protocol.createSessionAckResponse(requestId, 'O');
    console.log(`→ Sending SCLO response (${response.length} bytes): Session closed successfully`);
    socket.write(response);
  } catch (error) {
    console.error('Session close error:', error.message);
    const errorResponse = protocol.createErrorResponse(
      requestId,
      `Session close failed: ${error.message}`,
      protocol.ErrorCodes.SESSION_NOT_OPEN
    );
    console.log(`→ Sending SCLO error response (${errorResponse.length} bytes): ${error.message}`);
    socket.write(errorResponse);
  }
}

/**
 * Handle BAUD - Change Baud Rate
 * Note: Ignores client's baud rate request. Always auto-detects and upgrades to 57600.
 */
async function handleBaudChange(socket, requestId, payload) {
  console.log('Handling BAUD - Auto-detect and upgrade to maximum baud rate');
  try {
    if (!serialStack) {
      const errorMsg = 'Serial stack not initialized';
      const errorResponse = protocol.createErrorResponse(
        requestId,
        errorMsg,
        protocol.ErrorCodes.PORT_NOT_CONFIGURED
      );
      console.log(`→ Sending BAUD error response (${errorResponse.length} bytes): ${errorMsg}`);
      socket.write(errorResponse);
      return;
    }

    // If port is not open, open it with auto-detection
    if (!serialStack.isOpen) {
      console.log('Opening serial port with auto-detection...');
      await serialStack.open(); // Auto-detects baud rate
      
      // Try to upgrade to 57600 if not already there
      if (serialStack.baudRate !== 57600) {
        console.log(`Currently at ${serialStack.baudRate} baud, upgrading to 57600...`);
        try {
          await serialStack.upgradeSpeed();
          console.log(`Successfully upgraded to ${serialStack.baudRate} baud`);
        } catch (error) {
          console.log(`Could not upgrade to 57600, staying at ${serialStack.baudRate} baud`);
        }
      } else {
        console.log('Already at 57600 baud');
      }
    } else {
      // Port is already open, try to upgrade if not at 57600
      if (serialStack.baudRate !== 57600) {
        console.log(`Port already open at ${serialStack.baudRate} baud, upgrading to 57600...`);
        try {
          await serialStack.upgradeSpeed();
          console.log(`Successfully upgraded to ${serialStack.baudRate} baud`);
        } catch (error) {
          console.log(`Could not upgrade to 57600, staying at ${serialStack.baudRate} baud`);
        }
      } else {
        console.log('Already at 57600 baud');
      }
    }
    
    const response = protocol.createBaudAckResponse(requestId, 'O');
    console.log(`→ Sending BAUD response (${response.length} bytes): Successfully set to ${serialStack.baudRate} baud`);
    socket.write(response);
  } catch (error) {
    console.error('Baud rate change error:', error.message);
    const errorResponse = protocol.createErrorResponse(
      requestId,
      `Baud rate change failed: ${error.message}`,
      protocol.ErrorCodes.BAUD_CHANGE_FAILED
    );
    console.log(`→ Sending BAUD error response (${errorResponse.length} bytes): ${error.message}`);
    socket.write(errorResponse);
  }
}

/**
 * Handle RSET - Protocol Reset
 */
async function handleReset(socket, requestId) {
  console.log('Handling RSET - Protocol Reset');
  try {
    if (!serialStack || !serialStack.isOpen) {
      const errorMsg = 'Serial port not connected';
      const errorResponse = protocol.createErrorResponse(
        requestId,
        errorMsg,
        protocol.ErrorCodes.PORT_NOT_CONNECTED
      );
      console.log(`→ Sending RSET error response (${errorResponse.length} bytes): ${errorMsg}`);
      socket.write(errorResponse);
      return;
    }

    await serialStack.resync();
    
    const response = protocol.createResetAckResponse(requestId, 'O');
    console.log(`→ Sending RSET response (${response.length} bytes): Protocol reset successful`);
    socket.write(response);
  } catch (error) {
    console.error('Reset error:', error.message);
    const errorResponse = protocol.createErrorResponse(
      requestId,
      `Reset failed: ${error.message}`,
      protocol.ErrorCodes.MACHINE_ERROR
    );
    console.log(`→ Sending RSET error response (${errorResponse.length} bytes): ${error.message}`);
    socket.write(errorResponse);
  }
}

// Handle graceful shutdown
process.on('SIGINT', async () => {
  console.log('\nShutting down server...');
  
  // Set a timeout to force exit if graceful shutdown hangs
  const forceExitTimeout = setTimeout(() => {
    console.log('Force exiting after timeout...');
    process.exit(0);
  }, 2000); // 2 second timeout
  
  // Close SerialStack if it exists
  if (serialStack) {
    try {
      // End embroidery session if one is open
      if (serialStack.isOpen) {
        console.log('Ending embroidery session...');
        await serialStack.EndEmbroiderySession();
      }
      
      console.log('Closing SerialStack instance...');
      await serialStack.close();
      console.log('SerialStack instance closed');
    } catch (error) {
      console.error(`Error closing SerialStack: ${error.message}`);
    }
    serialStack = null;
  }
  
  // Destroy active connection immediately instead of graceful end
  if (activeConnection) {
    activeConnection.destroy();
    activeConnection = null;
  }
  
  // Close the server
  server.close(() => {
    console.log('Server closed');
    clearTimeout(forceExitTimeout);
    process.exit(0);
  });
  
  // If server.close() callback doesn't fire, the timeout will handle it
});
