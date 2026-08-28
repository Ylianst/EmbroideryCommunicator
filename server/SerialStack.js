const { SerialPort } = require('serialport');
const { EventEmitter } = require('events');

/**
 * Command letters understood by the Bernina boot loader (v2 BIOS 1.10 and
 * v3 BIOS 1.20) and by the running application, which services the same command
 * set through the boot ROM. See docs/SerialProtocol.md for the full byte
 * level reference; both ROM revisions share this command layer.
 *
 * Every command is a single ASCII letter. Addresses are 6 hex digits (24-bit),
 * data bytes are 2 hex digits, the machine echoes each character it accepts,
 * and most replies end in a status byte (see STATUS).
 */
const COMMANDS = Object.freeze({
  IDENTIFY: 'I',       // identity banner
  READ_BYTE: 'r',      // read 1 byte (hex)
  READ_BLOCK: 'R',     // read 32 bytes (hex)
  DUMP_BLOCK: 'N',     // read 256 raw bytes
  WRITE_BYTE: 'w',     // write 1 byte (verified)
  WRITE_STREAM: 'W',   // write stream, '?' ends it
  ACK_PING: 'K',       // ack/ping -> 'O'
  GO: 'G',             // jump to application (alt entry)
  RESET: 'X',          // restart the boot ROM
  HALT: 'H',           // halt, keep the link alive
  START_APP: 'S',      // start application (primary entry)
  CONFIRM: 'Y',        // confirm (host then sends 'Q')
  VERSION: 'V',        // BIOS version byte
  BAUD: 'J',           // set SCI bit rate (2 hex BRR)
  TO_PC_PORT: 'T',     // "TrME" switch to SCI1
  FLASH_BYTE: 'Z',     // program 1 byte into flash
  DOWNLOAD: 'P',       // PB bank / PS sector loader
  MODIFY: 'M',         // stream bytes into flash
  CHECKSUM: 'L'        // 32-bit sum of a range
});

/** Single-byte status / error replies from the machine. */
const STATUS = Object.freeze({
  OK: 'O',              // success
  NEGATIVE: 'N',        // refused / verify failed
  VERIFY_FAIL: 'V',     // not writable flash / no verify
  UNKNOWN_COMMAND: 'Q', // unknown command letter
  BAD_HEX: '?',         // non-hex where hex expected
  LINE_ERROR: '!'       // serial line error (NAK)
});

/**
 * Low-level driver for the Bernina character-echo serial protocol.
 *
 * Implements the full boot-loader command set reconstructed in
 * docs/SerialProtocol.md: memory access
 * (read/readByte/largeRead/write/writeByte/upload/sum), identity/status
 * (identify/biosVersion/ping), link control (resync/upgradeSpeed and the
 * embroidery session start/stop), and the DANGEROUS boot-loader commands
 * (confirm/flashByte/modifyFlash/downloadBank/startApplication/go/
 * resetBootRom/halt) that reprogram firmware or transfer execution.
 */
class SerialStack extends EventEmitter {
  constructor(portPath = '/dev/ttyUSB0', baudRate = 19200) {
    super();
    this.portPath = portPath;
    this.baudRate = baudRate;
    this.port = null;
    this.isOpen = false;
    this.maxRetries = 3;
    this.charTimeout = 500; // ms to wait for echo
    this.commandTimeout = 5000; // ms for entire command
    this.readBuffer = Buffer.alloc(0); // Internal buffer for extra bytes
  }

  /**
   * Open the serial port connection at a specific baud rate
   */
  async openAtBaudRate(baudRate) {
    return new Promise((resolve, reject) => {
      // Close existing port if open
      if (this.port && this.isOpen) {
        this.port.close(() => {
          this._openPort(baudRate, resolve, reject);
        });
      } else {
        this._openPort(baudRate, resolve, reject);
      }
    });
  }

  /**
   * Internal method to open the port
   */
  _openPort(baudRate, resolve, reject) {
    this.port = new SerialPort({
      path: this.portPath,
      baudRate: baudRate,
      dataBits: 8,
      parity: 'none',
      stopBits: 1,
      autoOpen: false
    });

    this.port.open((err) => {
      if (err) {
        reject(new Error(`Failed to open port: ${err.message}`));
        return;
      }
      this.baudRate = baudRate;
      this.isOpen = true;
      resolve();
    });

    this.port.on('error', (err) => {
      console.error('Serial port error:', err.message);
      this.emit('error', err);
    });
  }

  /**
   * Open the serial port connection with automatic baud rate detection
   */
  async open() {
    const baudRates = [19200, 57600, 115200, 4800];
    
    console.log('Attempting to detect baud rate...');
    
    for (const baudRate of baudRates) {
      try {
        console.log(`Trying baud rate: ${baudRate}...`);
        await this.openAtBaudRate(baudRate);
        
        // Try to send RF? command with a shorter timeout
        const originalTimeout = this.charTimeout;
        this.charTimeout = 200; // Shorter timeout for detection
        
        try {
          const echo = await this.sendCommand('RF?');
          this.charTimeout = originalTimeout; // Restore original timeout
          
          if (echo === 'RF?') {
            console.log(`✓ Successfully connected at ${baudRate} baud`);
            return;
          }
        } catch (error) {
          this.charTimeout = originalTimeout; // Restore original timeout
          // This baud rate didn't work, try the next one
          console.log(`  No response at ${baudRate} baud`);
        }
      } catch (error) {
        console.log(`  Failed to open at ${baudRate} baud: ${error.message}`);
      }
    }
    
    // If we get here, none of the baud rates worked
    throw new Error('Failed to connect at any supported baud rate (19200, 57600, 115200, 4800)');
  }

  /**
   * Close the serial port connection
   */
  async close() {
    return new Promise((resolve, reject) => {
      if (!this.port || !this.isOpen) {
        resolve();
        return;
      }

      this.port.close((err) => {
        if (err) {
          reject(new Error(`Failed to close port: ${err.message}`));
          return;
        }
        this.isOpen = false;
        console.log('Serial port closed');
        resolve();
      });
    });
  }

  /**
   * Private method to flush/clear any pending data from the serial port buffer
   * This prevents leftover data from interfering with new commands
   */
  async _flushSerialBuffer() {
    return new Promise((resolve) => {
      if (!this.port || !this.isOpen) {
        resolve();
        return;
      }

      // Clear the internal read buffer as well
      if (this.readBuffer.length > 0) {
        console.log(`Clearing ${this.readBuffer.length} bytes from internal buffer`);
        this.readBuffer = Buffer.alloc(0);
      }

      let flushedData = Buffer.alloc(0);
      const flushTimeout = 50; // Short timeout to check for pending data
      let timeout;
      let dataHandler;

      const cleanup = () => {
        clearTimeout(timeout);
        if (dataHandler) {
          this.port.removeListener('data', dataHandler);
        }
      };

      // Set up data handler to collect any pending data
      dataHandler = (data) => {
        flushedData = Buffer.concat([flushedData, data]);
        // Reset timeout each time we receive data
        clearTimeout(timeout);
        timeout = setTimeout(() => {
          cleanup();
          if (flushedData.length > 0) {
            console.log(`Flushed ${flushedData.length} pending bytes from buffer`);
          }
          resolve();
        }, flushTimeout);
      };

      this.port.on('data', dataHandler);

      // Initial timeout to wait for any pending data
      timeout = setTimeout(() => {
        cleanup();
        resolve();
      }, flushTimeout);
    });
  }

  /**
   * Send a command character by character, waiting for echo after each character
   * @param {string} command - The command string to send
   * @returns {Promise<string>} - Returns the full echo response
   */
  async sendCommand(command) {
    if (!this.isOpen) {
      throw new Error('Serial port is not open');
    }

    // Flush any pending data from the serial buffer before sending command
    await this._flushSerialBuffer();

    console.log(`Sending command: ${command}`);
    let echoBuffer = '';
    
    for (let i = 0; i < command.length; i++) {
      const char = command[i];
      
      // Send the character
      await this.writeChar(char);
      
      // Wait for echo
      const echo = await this.readChar();
      echoBuffer += echo;
      
      // Verify echo matches sent character
      if (echo !== char) {
        throw new Error(`Echo mismatch: sent '${char}', received '${echo}'`);
      }
      
      // Check if we got an unexpected error response
      // Note: '?', '!' and 'Q' are only errors if they DON'T match what we sent
      // (i.e., they appear when we didn't expect them)
      if ((echo === 'Q' || echo === '?' || echo === '!') && echo !== char) {
        throw new Error(`Machine returned unexpected error character: ${echo}`);
      }
    }
    
    console.log(`Command sent successfully, echo: ${echoBuffer}`);
    return echoBuffer;
  }

  /**
   * Write a single character to the serial port
   */
  async writeChar(char) {
    return new Promise((resolve, reject) => {
      this.port.write(char, (err) => {
        if (err) {
          reject(new Error(`Failed to write character: ${err.message}`));
          return;
        }
        resolve();
      });
    });
  }

  /**
   * Read a single character from the serial port with timeout
   * Uses internal readBuffer to handle extra bytes from previous reads
   */
  async readChar() {
    return new Promise((resolve, reject) => {
      // Check if we already have data in our internal buffer
      if (this.readBuffer.length >= 1) {
        const char = this.readBuffer.toString('ascii', 0, 1);
        this.readBuffer = this.readBuffer.slice(1);
        resolve(char);
        return;
      }

      let buffer = Buffer.alloc(0);
      let timeout;
      let dataHandler;

      const cleanup = () => {
        clearTimeout(timeout);
        this.port.removeListener('data', dataHandler);
      };

      timeout = setTimeout(() => {
        cleanup();
        reject(new Error('Timeout waiting for character echo'));
      }, this.charTimeout);

      dataHandler = (data) => {
        buffer = Buffer.concat([buffer, data]);
        
        if (buffer.length >= 1) {
          cleanup();
          // Return only the first character
          const char = buffer.toString('ascii', 0, 1);
          
          // If we received more than 1 byte, store extras in internal buffer
          if (buffer.length > 1) {
            this.readBuffer = Buffer.concat([this.readBuffer, buffer.slice(1)]);
            console.log(`Buffered ${buffer.length - 1} extra bytes for next read (total buffered: ${this.readBuffer.length})`);
          }
          
          resolve(char);
        }
      };

      this.port.on('data', dataHandler);
    });
  }

  /**
   * Read multiple bytes from the serial port with timeout
   * Uses internal readBuffer to handle extra bytes from previous reads
   * @param {number} count - Number of bytes to read
   * @param {string} encoding - Encoding to use ('ascii' or 'latin1'). Default 'ascii'
   */
  async readBytes(count, encoding = 'ascii') {
    return new Promise((resolve, reject) => {
      // Start with any data we have buffered from previous reads
      let buffer = this.readBuffer;
      this.readBuffer = Buffer.alloc(0); // Clear the internal buffer
      
      // If we already have enough data, return immediately
      if (buffer.length >= count) {
        const result = buffer.slice(0, count).toString(encoding);
        // Put any extra bytes back into the buffer
        if (buffer.length > count) {
          this.readBuffer = buffer.slice(count);
          console.log(`Used ${count} bytes from buffer, ${this.readBuffer.length} bytes remain buffered`);
        }
        resolve(result);
        return;
      }

      let timeout;
      let dataHandler;

      const cleanup = () => {
        clearTimeout(timeout);
        this.port.removeListener('data', dataHandler);
      };

      timeout = setTimeout(() => {
        cleanup();
        // Include the received data in the error message for debugging
        const receivedHex = buffer.toString('hex').toUpperCase();
        const receivedAscii = buffer.toString('ascii').replace(/[\x00-\x1F\x7F-\xFF]/g, '.');
        reject(new Error(
          `Timeout waiting for ${count} bytes (received ${buffer.length})\n` +
          `  HEX: ${receivedHex}\n` +
          `  ASCII: ${receivedAscii}`
        ));
      }, this.commandTimeout);

      dataHandler = (data) => {
        buffer = Buffer.concat([buffer, data]);
        
        if (buffer.length >= count) {
          cleanup();
          const result = buffer.slice(0, count).toString(encoding);
          // Put any extra bytes back into internal buffer
          if (buffer.length > count) {
            this.readBuffer = buffer.slice(count);
            console.log(`Buffered ${buffer.length - count} extra bytes for next read`);
          }
          resolve(result);
        }
      };

      this.port.on('data', dataHandler);
    });
  }

  /**
   * Perform a Resync operation (RF?)
   * This resets the protocol state on the machine
   */
  async resync() {
    console.log('Performing resync...');
    try {
      const echo = await this.sendCommand('RF?');
      if (echo === 'RF?') {
        console.log('Resync successful');
        return true;
      }
      console.warn('Resync echo mismatch');
      return false;
    } catch (error) {
      console.error('Resync failed:', error.message);
      throw error;
    }
  }

  /**
   * Upgrade serial speed to 57600 baud
   * Uses the TrMEJ05 command to switch baud rates
   * Does nothing if already at 57600 baud
   */
  async upgradeSpeed() {
    // Check if already at 57600 baud
    if (this.baudRate === 57600) {
      console.log('Already at 57600 baud, no upgrade needed');
      return true;
    }

    console.log(`Upgrading from ${this.baudRate} to 57600 baud...`);
    
    try {
      // Send TrMEJ05 command - after last char echo, baud rate changes
      console.log('Sending TrMEJ05 command...');
      await this.sendCommand('TrMEJ05');
      
      // Immediately after receiving the last echo, switch to 57600 baud
      console.log('Switching to 57600 baud...');
      await this.openAtBaudRate(57600);
      
      // Wait for "BOS" message from machine (3 bytes: 42 4F 53)
      console.log('Waiting for BOS confirmation...');
      const bos = await this.readBytes(3, 'ascii');
      
      if (bos !== 'BOS') {
        throw new Error(`Expected "BOS", received "${bos}"`);
      }
      console.log('Received BOS confirmation');
      
      // Send EBYQ to confirm speed change
      console.log('Sending EBYQ confirmation...');
      const ebyqEcho = await this.sendCommand('EBYQ');
      
      // Read the 'O' confirmation
      const confirm = await this.readChar();
      if (confirm !== 'O') {
        throw new Error(`Expected "O" confirmation, received "${confirm}"`);
      }
      console.log('Received O confirmation');
      
      // For good measure, send RF? to verify everything is ok
      console.log('Verifying connection with RF?...');
      await this.resync();
      
      console.log('✓ Successfully upgraded to 57600 baud');
      return true;
      
    } catch (error) {
      console.error('Speed upgrade failed:', error.message);
      throw new Error(`Failed to upgrade speed: ${error.message}`);
    }
  }

  /**
   * Read 32 bytes from the specified address
   * Returns 64 HEX characters + 'O'
   * @param {string} address - 6 character HEX address (e.g., "200100")
   * @returns {Promise<string>} - 64 HEX characters (32 bytes of data)
   */
  async read(address, retryCount = 0) {
    if (address.length !== 6) {
      throw new Error('Address must be 6 characters');
    }

    const command = `R${address.toUpperCase()}`;
    
    try {
      // Send the command
      await this.sendCommand(command);
      
      // Read 65 bytes (64 HEX chars + 'O')
      const response = await this.readBytes(65);
      
      // Verify response ends with 'O'
      if (response[64] !== 'O') {
        throw new Error(`Invalid response terminator: expected 'O', got '${response[64]}'`);
      }
      
      // Return the data portion (without the 'O')
      const data = response.substring(0, 64);
      console.log(`Read from ${address}: ${data.substring(0, 32)}...`);
      return data;
      
    } catch (error) {
      console.error(`Read failed (attempt ${retryCount + 1}):`, error.message);
      
      if (retryCount < this.maxRetries) {
        console.log('Attempting resync and retry...');
        try {
          await this.resync();
          // Retry the read
          return await this.read(address, retryCount + 1);
        } catch (resyncError) {
          throw new Error(`Read failed after resync: ${resyncError.message}`);
        }
      }
      
      throw new Error(`Read failed after ${this.maxRetries} retries: ${error.message}`);
    }
  }

  /**
   * Large Read - Read 256 bytes from the specified address
   * Returns 256 binary characters + 'O'
   * @param {string} address - 6 character HEX address (e.g., "0240F5")
   * @returns {Promise<string>} - 256 characters of binary data
   */
  async largeRead(address, retryCount = 0) {
    if (address.length !== 6) {
      throw new Error('Address must be 6 characters');
    }

    const command = `N${address.toUpperCase()}`;
    
    try {
      // Send the command
      await this.sendCommand(command);
      
      // Read 257 bytes (256 data + 'O') using 'latin1' encoding to preserve binary data
      const response = await this.readBytes(257, 'latin1');
      
      // Verify response ends with 'O'
      if (response[256] !== 'O') {
        throw new Error(`Invalid response terminator: expected 'O', got '${response[256]}'`);
      }
      
      // Return the data portion (without the 'O')
      const data = response.substring(0, 256);
      console.log(`Large read from ${address}: ${data.substring(0, 50)}... (${data.length} bytes)`);
      return data;
      
    } catch (error) {
      console.error(`Large read failed (attempt ${retryCount + 1}):`, error.message);
      
      if (retryCount < this.maxRetries) {
        console.log('Attempting resync and retry...');
        try {
          await this.resync();
          // Retry the large read
          return await this.largeRead(address, retryCount + 1);
        } catch (resyncError) {
          throw new Error(`Large read failed after resync: ${resyncError.message}`);
        }
      }
      
      throw new Error(`Large read failed after ${this.maxRetries} retries: ${error.message}`);
    }
  }

  /**
   * Sum Command - Calculate checksum of memory region
   * @param {string} address - 6 character HEX address (e.g., "200100")
   * @param {string} length - 6 character HEX length (e.g., "000020")
   * @returns {Promise<number>} - The sum value as a number
   */
  async sum(address, length, retryCount = 0) {
    if (address.length !== 6) {
      throw new Error('Address must be 6 characters');
    }
    if (length.length !== 6) {
      throw new Error('Length must be 6 characters');
    }

    const command = `L${address.toUpperCase()}${length.toUpperCase()}`;
    
    try {
      // Send the command
      await this.sendCommand(command);
      
      // Read 9 bytes (8 HEX chars + 'O')
      const response = await this.readBytes(9);
      
      // Verify response ends with 'O'
      if (response[8] !== 'O') {
        throw new Error(`Invalid response terminator: expected 'O', got '${response[8]}'`);
      }
      
      // Return the sum value (8 HEX characters as a number)
      const sumHex = response.substring(0, 8);
      const sumValue = parseInt(sumHex, 16);
      console.log(`Sum from ${address} length ${length}: 0x${sumHex} (${sumValue})`);
      return sumValue;
      
    } catch (error) {
      console.error(`Sum failed (attempt ${retryCount + 1}):`, error.message);
      
      if (retryCount < this.maxRetries) {
        console.log('Attempting resync and retry...');
        try {
          await this.resync();
          // Retry the sum
          return await this.sum(address, length, retryCount + 1);
        } catch (resyncError) {
          throw new Error(`Sum failed after resync: ${resyncError.message}`);
        }
      }
      
      throw new Error(`Sum failed after ${this.maxRetries} retries: ${error.message}`);
    }
  }

  /**
   * Write Command - Write data to a specific memory address
   * @param {string} address - 6 character HEX address (e.g., "0201E1")
   * @param {string} data - HEX data to write (e.g., "01" for single byte, "0061" for two bytes)
   * @returns {Promise<void>}
   */
  async write(address, data, retryCount = 0) {
    if (address.length !== 6) {
      throw new Error('Address must be 6 characters');
    }
    
    // Data should be valid HEX characters (even number of characters)
    if (data.length % 2 !== 0) {
      throw new Error('Data must have an even number of HEX characters');
    }

    const command = `W${address.toUpperCase()}${data.toUpperCase()}?`;
    
    try {
      // Flush any pending data from the serial buffer before sending command
      await this._flushSerialBuffer();
      
      // Send the command
      console.log(`Writing ${data.length / 2} byte(s) to ${address}...`);
      
      // Send all characters except the last '?' using normal timeout
      const commandWithoutLastChar = command.slice(0, -1);
      let echoBuffer = '';
      
      console.log(`Sending command: ${command}`);
      for (let i = 0; i < commandWithoutLastChar.length; i++) {
        const char = commandWithoutLastChar[i];
        
        // Send the character
        await this.writeChar(char);
        
        // Wait for echo
        const echo = await this.readChar();
        echoBuffer += echo;
        
        // Verify echo matches sent character
        if (echo !== char) {
          throw new Error(`Echo mismatch: sent '${char}', received '${echo}'`);
        }
      }
      
      // Send the last '?' with extended timeout (10 seconds)
      const originalTimeout = this.charTimeout;
      this.charTimeout = 2000; // 2 second timeout for final '?'
      
      try {
        await this.writeChar('?');
        const echo = await this.readChar();
        this.charTimeout = originalTimeout; // Restore original timeout
        
        if (echo !== '?') {
          throw new Error(`Echo mismatch: sent '?', received '${echo}'`);
        }
        echoBuffer += echo;
      } catch (error) {
        this.charTimeout = originalTimeout; // Restore original timeout on error
        throw error;
      }
      
      console.log(`Write to ${address} completed`);
      
    } catch (error) {
      console.error(`Write failed (attempt ${retryCount + 1}):`, error.message);
      
      if (retryCount < this.maxRetries) {
        console.log('Attempting resync and retry...');
        try {
          await this.resync();
          // Retry the write
          return await this.write(address, data, retryCount + 1);
        } catch (resyncError) {
          throw new Error(`Write failed after resync: ${resyncError.message}`);
        }
      }
      
      throw new Error(`Write failed after ${this.maxRetries} retries: ${error.message}`);
    }
  }

  /**
   * Upload Command - Upload 256 bytes of binary data to a specific address
   * The address must be aligned to 256-byte boundary (last 2 hex digits are 00)
   * @param {string} address - 4 character HEX address prefix (e.g., "028F" for address 0x028F00)
   * @param {Buffer|string} data - 256 bytes of binary data to upload
   * @returns {Promise<void>}
   */
  async upload(address, data, retryCount = 0) {
    if (address.length !== 4) {
      throw new Error('Address must be 4 characters (last 2 digits assumed to be 00)');
    }
    
    // Convert string to Buffer if needed
    let dataBuffer;
    if (typeof data === 'string') {
      dataBuffer = Buffer.from(data, 'latin1');
    } else if (Buffer.isBuffer(data)) {
      dataBuffer = data;
    } else {
      throw new Error('Data must be a Buffer or string');
    }
    
    if (dataBuffer.length !== 256) {
      throw new Error('Data must be exactly 256 bytes');
    }

    const command = `PS${address.toUpperCase()}`;
    
    try {
      console.log(`Uploading 256 bytes to ${address}00...`);
      
      // Send the PS command
      await this.sendCommand(command);
      
      // Wait for "OE" confirmation
      console.log('Waiting for OE confirmation...');
      const oeConfirm = await this.readBytes(2);
      if (oeConfirm !== 'OE') {
        throw new Error(`Expected "OE" confirmation, received "${oeConfirm}"`);
      }
      console.log('Received OE confirmation');
      
      // Send 256 bytes of binary data
      console.log('Sending 256 bytes of data...');
      await this._writeBytes(dataBuffer);
      
      // Wait for "O" final confirmation
      console.log('Waiting for O confirmation...');
      const confirm = await this.readChar();
      if (confirm !== 'O') {
        throw new Error(`Expected "O" confirmation, received "${confirm}"`);
      }
      console.log('Received O confirmation');
      
      console.log(`✓ Upload to ${address}00 completed successfully`);
      
    } catch (error) {
      console.error(`Upload failed (attempt ${retryCount + 1}):`, error.message);
      
      if (retryCount < this.maxRetries) {
        console.log('Attempting resync and retry...');
        try {
          await this.resync();
          // Retry the upload
          return await this.upload(address, data, retryCount + 1);
        } catch (resyncError) {
          throw new Error(`Upload failed after resync: ${resyncError.message}`);
        }
      }
      
      throw new Error(`Upload failed after ${this.maxRetries} retries: ${error.message}`);
    }
  }

  /**
   * Private method to write raw bytes to the serial port
   * Used by upload() to send binary data without echoing
   */
  async _writeBytes(buffer) {
    return new Promise((resolve, reject) => {
      this.port.write(buffer, (err) => {
        if (err) {
          reject(new Error(`Failed to write bytes: ${err.message}`));
          return;
        }
        // Wait for the write to complete
        this.port.drain((drainErr) => {
          if (drainErr) {
            reject(new Error(`Failed to drain write buffer: ${drainErr.message}`));
            return;
          }
          resolve();
        });
      });
    });
  }

  /**
   * Check if an embroidery session is open
   * Reads address 57FF80 and checks if the first byte is 0
   * @returns {Promise<boolean>} - true if session is open (first byte is 0), false otherwise
   */
  async IsEmbroiderySessionOpen() {
    try {
      // Read 32 bytes from address 57FF80
      const data = await this.read('57FF80');
      
      // Get the first byte (first 2 HEX characters)
      const firstByteHex = data.substring(0, 2);
      const firstByte = parseInt(firstByteHex, 16);
      
      // Session is closed when the first bytes read the 0xB4A5 sentinel;
      // any other value means a session is open.
      const isOpen = firstByte !== 0xB4;
      console.log(`Embroidery session status: ${isOpen ? 'OPEN' : 'CLOSED'} (first byte: 0x${firstByteHex})`);
      
      return isOpen;
    } catch (error) {
      console.error('Failed to check embroidery session status:', error.message);
      throw error;
    }
  }

  /**
   * Start an embroidery session
   * Sends TrMEYQ command to start a session
   * Only executes if an embroidery session is not already open
   * @returns {Promise<boolean>} - true if session was started, false if already open
   */
  async StartEmbroiderySession() {
    try {
      // Check if session is already open
      const isOpen = await this.IsEmbroiderySessionOpen();
      
      if (isOpen) {
        console.log('Embroidery session is already open, no action needed');
        return false;
      }
      
      // Send TrMEYQ command to start the session
      console.log('Starting embroidery session...');
      await this.sendCommand('TrMEYQ');
      
      // Wait for the 'O' confirmation with extended timeout (4 seconds)
      console.log('Waiting for O confirmation...');
      const originalTimeout = this.charTimeout;
      this.charTimeout = 4000; // 4 second timeout for session start
      
      try {
        const confirm = await this.readChar();
        this.charTimeout = originalTimeout; // Restore original timeout
        
        if (confirm !== 'O') {
          throw new Error(`Expected "O" confirmation, received "${confirm}"`);
        }
        console.log('Received O confirmation');
      } catch (error) {
        this.charTimeout = originalTimeout; // Restore original timeout on error
        throw error;
      }
      
      console.log('✓ Embroidery session started successfully');
      return true;
      
    } catch (error) {
      console.error('Failed to start embroidery session:', error.message);
      throw error;
    }
  }

  /**
   * End an embroidery session
   * Sends RF? command first, then TrME command to end a session
   * Retries up to 3 times if the session fails to close
   * Only executes if an embroidery session is currently open
   * @returns {Promise<boolean>} - true if session was ended, false if already closed
   */
  async EndEmbroiderySession() {
    try {
      // Check if session is currently open
      const isOpen = await this.IsEmbroiderySessionOpen();
      
      if (!isOpen) {
        console.log('Embroidery session is already closed, no action needed');
        return false;
      }
      
      // Retry up to 3 times to close the session
      const maxRetries = 3;
      
      for (let attempt = 1; attempt <= maxRetries; attempt++) {
        try {
          console.log(`Ending embroidery session (attempt ${attempt}/${maxRetries})...`);
          
          // Send RF? command first to reset protocol state
          console.log('Sending RF? to reset protocol state...');
          await this.resync();
          
          // Send TrME command to end the session
          console.log('Sending TrME command...');
          await this.sendCommand('TrME');
          
          // Verify the session was closed
          const stillOpen = await this.IsEmbroiderySessionOpen();
          
          if (!stillOpen) {
            console.log('✓ Embroidery session ended successfully');
            return true;
          } else {
            console.warn(`Session still open after attempt ${attempt}`);
            if (attempt < maxRetries) {
              console.log('Retrying...');
              // Small delay before retry
              await new Promise(resolve => setTimeout(resolve, 500));
            }
          }
          
        } catch (attemptError) {
          console.error(`Attempt ${attempt} failed:`, attemptError.message);
          if (attempt < maxRetries) {
            console.log('Retrying...');
            // Small delay before retry
            await new Promise(resolve => setTimeout(resolve, 500));
          } else {
            throw attemptError;
          }
        }
      }
      
      // If we get here, all retries failed
      throw new Error('Failed to end embroidery session after 3 attempts');
      
    } catch (error) {
      console.error('Failed to end embroidery session:', error.message);
      throw error;
    }
  }

  // ==========================================================================
  // Full boot-loader command set (v2/v3). See docs/SerialProtocol.md.
  // The read/identify/version/ping/confirm commands are safe; the flash and
  // execution-control commands are DANGEROUS and unused in normal operation.
  // ==========================================================================

  /**
   * Read a single byte (r + 6 hex). Where read() always returns 32 bytes, this
   * returns exactly one, as 2 HEX characters.
   * @param {string} address - 6 character HEX address
   * @returns {Promise<string>} - 2 HEX characters
   */
  async readByte(address) {
    if (address.length !== 6) throw new Error('Address must be 6 characters');
    await this.sendCommand(`r${address.toUpperCase()}`);
    const response = await this.readBytes(3); // 2 hex + 'O'
    if (response[2] !== 'O') {
      throw new Error(`Invalid response terminator: expected 'O', got '${response[2]}'`);
    }
    return response.substring(0, 2);
  }

  /**
   * Write a single byte (w + 6 hex + 2 hex) with machine read-back verify.
   * Resolves on 'O', throws on 'N' (verify failed).
   * @param {string} address - 6 character HEX address
   * @param {string} value - 2 character HEX byte
   */
  async writeByte(address, value) {
    if (address.length !== 6) throw new Error('Address must be 6 characters');
    if (value.length !== 2) throw new Error('Value must be 2 HEX characters');
    await this.sendCommand(`w${address.toUpperCase()}${value.toUpperCase()}`);
    const status = await this.readChar();
    if (status !== 'O') {
      throw new Error(`Write not verified (got '${status}', expected 'O')`);
    }
  }

  /**
   * Read the boot ROM identity banner (I). Returns the three banner lines
   * joined by ' | ' (e.g. "BERNINA Electronic AG | BiosVersion: 1.20 | July 97").
   * @returns {Promise<string>}
   */
  async identify() {
    await this.sendCommand('I');
    // Banner: three carriage-return-terminated lines.
    let banner = '';
    let crs = 0;
    while (crs < 3) {
      const ch = await this.readChar();
      if (ch === '\r') crs++;
      banner += ch;
    }
    return banner.split('\r').map(l => l.trim()).filter(l => l.length > 0).join(' | ');
  }

  /**
   * Read the boot ROM BIOS version byte (V). 0x0C = v3 (1.20), 0x0B = v2 (1.10);
   * this is the reliable way to tell the two boot ROMs apart over the wire.
   * @returns {Promise<number>} - the version byte value
   */
  async biosVersion() {
    await this.sendCommand('V');
    const hex = await this.readBytes(2); // two version nibbles, no status byte
    return parseInt(hex, 16);
  }

  /**
   * Ping the machine (K); it replies 'O' and changes no protocol state. Note
   * the machine answers 'O' rather than echoing 'K', so sendCommand is not used.
   * @returns {Promise<boolean>}
   */
  async ping() {
    await this._flushSerialBuffer();
    await this.writeChar('K');
    const status = await this.readChar();
    if (status !== 'O') {
      throw new Error(`Ping not acknowledged (got '${status}', expected 'O')`);
    }
    return true;
  }

  /**
   * Confirm to the machine (Y then Q), raising its "confirmed" flag.
   * @returns {Promise<boolean>}
   */
  async confirm() {
    await this.sendCommand('YQ');
    return true;
  }

  // ---- DANGEROUS: firmware programming and execution control ---------------
  // These reprogram firmware or hand over execution and can brick a machine.

  /**
   * Program a single byte into flash (Z + 6 hex + 2 hex). Resolves on 'O',
   * throws on 'V' (bank not writable flash, or programming did not verify).
   * DANGEROUS - modifies firmware.
   */
  async flashByte(address, value) {
    if (address.length !== 6) throw new Error('Address must be 6 characters');
    if (value.length !== 2) throw new Error('Value must be 2 HEX characters');
    await this.sendCommand(`Z${address.toUpperCase()}${value.toUpperCase()}`);
    const status = await this.readChar();
    if (status !== 'O') {
      throw new Error(`Flash write failed (got '${status}', expected 'O')`);
    }
  }

  /**
   * Stream bytes into flash from an address (M), committing each 256-byte page
   * as the cursor crosses it and on completion. DANGEROUS.
   * @param {string} address - 6 character HEX start address
   * @param {Buffer|string} data - bytes to program
   */
  async modifyFlash(address, data) {
    if (address.length !== 6) throw new Error('Address must be 6 characters');
    const buf = Buffer.isBuffer(data) ? data : Buffer.from(data, 'latin1');
    if (buf.length === 0) throw new Error('Data cannot be empty');
    await this._flushSerialBuffer();
    // M + address, each character echoed.
    for (const ch of `M${address.toUpperCase()}`) {
      await this.writeChar(ch);
      const echo = await this.readChar();
      if (echo !== ch) throw new Error(`Modify echo mismatch: sent '${ch}', got '${echo}'`);
    }
    // Stream the data as HEX pairs, each character echoed. A 'V' means the
    // bank is not writable flash.
    for (const b of buf) {
      const hex = b.toString(16).toUpperCase().padStart(2, '0');
      for (const ch of hex) {
        await this.writeChar(ch);
        const echo = await this.readChar();
        if (echo === 'V') throw new Error('Modify rejected (V) - not writable flash');
        if (echo !== ch) throw new Error(`Modify echo mismatch: sent '${ch}', got '${echo}'`);
      }
    }
    // Any non-hex character commits the final page and ends the command.
    await this.writeChar('?');
    await this.readChar();
  }

  /**
   * Bulk-program a whole 64 KB flash bank (PB). DANGEROUS and advanced.
   * @param {string} bank - 2 character HEX bank number
   * @param {Buffer[]} pages - 256-byte pages, programmed in order
   * @returns {Promise<boolean>}
   */
  async downloadBank(bank, pages) {
    if (bank.length !== 2) throw new Error('Bank must be 2 HEX characters');
    if (!Array.isArray(pages) || pages.length === 0) {
      throw new Error('No pages to program');
    }
    for (const p of pages) {
      if (!Buffer.isBuffer(p) || p.length !== 256) {
        throw new Error('Every page must be a 256-byte Buffer');
      }
    }
    await this.sendCommand(`PB${bank.toUpperCase()}`);
    const ready = await this.readChar(); // 'O' when ready
    if (ready !== 'O') throw new Error(`Bank download not ready (got '${ready}')`);
    let failures = 0;
    for (const page of pages) {
      const req = await this.readChar(); // 'E' = send a page
      if (req !== 'E') throw new Error(`Expected page request 'E', got '${req}'`);
      await this.writeChar('Y'); // a page follows
      const yes = await this.readChar(); // machine confirms with 'Y'
      if (yes !== 'Y') throw new Error(`Expected 'Y' confirm, got '${yes}'`);
      await this._writeBytes(page);
      const status = await this.readChar(); // 'O'/'V' status (lags one page)
      if (status === 'V') failures++;
    }
    // Final 'E' request; any non-'Y' answer ends the stream (machine acks 'N').
    const finalReq = await this.readChar();
    if (finalReq === 'E') {
      await this.writeChar('N');
      await this.readChar();
    }
    if (failures > 0) {
      throw new Error(`Bank download finished with ${failures} verify failure(s)`);
    }
    return true;
  }

  /** Start the application via its primary entry (S). Hands over execution. DANGEROUS. */
  async startApplication() { await this.sendCommand('S'); }

  /** Jump to the application via its alternate entry (G). DANGEROUS. */
  async go() { await this.sendCommand('G'); }

  /** Restart the boot ROM (X); the machine re-announces "BOS". DANGEROUS. */
  async resetBootRom() { await this.sendCommand('X'); }

  /** Halt the machine (H) while keeping the serial link alive. DANGEROUS. */
  async halt() { await this.sendCommand('H'); }

  /**
   * Helper method to convert HEX string to ASCII
   */
  hexToAscii(hexString) {
    let result = '';
    for (let i = 0; i < hexString.length; i += 2) {
      const hex = hexString.substr(i, 2);
      const charCode = parseInt(hex, 16);
      result += String.fromCharCode(charCode);
    }
    return result;
  }

  /**
   * Helper method to convert ASCII to HEX string
   */
  asciiToHex(asciiString) {
    let result = '';
    for (let i = 0; i < asciiString.length; i++) {
      const hex = asciiString.charCodeAt(i).toString(16).padStart(2, '0').toUpperCase();
      result += hex;
    }
    return result;
  }
}

SerialStack.COMMANDS = COMMANDS;
SerialStack.STATUS = STATUS;

module.exports = SerialStack;
