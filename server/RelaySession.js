/**
 * RelaySession.js
 *
 * Encapsulates a single client's relay session: owns a SerialStack, decodes the
 * framed relay protocol (see docs/TcpProtocol.md), and dispatches commands to
 * the embroidery machine. It is transport-agnostic — responses are delivered
 * through the `send(buffer)` callback, so the same logic drives both a raw TCP
 * socket and a WebSocket connection.
 *
 * The serial + framing implementation is reused from the sibling `relay/`
 * package so there is a single source of truth for the machine protocol.
 */

const SerialStack = require('../relay/SerialStack');
const TcpProtocol = require('../relay/TcpProtocol');

const RELAY_VERSION = '1.0.0';
const MAX_BUFFER_BYTES = 1048576; // 1 MB guard against runaway input.

class RelaySession {
  /**
   * @param {object} options
   * @param {(data: Buffer) => void} options.send  Delivers bytes back to the client.
   * @param {string} options.serialPort             Serial device path.
   * @param {number} [options.baudRate]             Initial baud rate.
   * @param {Console} [options.logger]              Logger (defaults to console).
   */
  constructor({ send, serialPort, baudRate = 19200, logger = console }) {
    this.send = send;
    this.config = { serialPort, baudRate };
    this.log = logger;
    this.protocol = new TcpProtocol();
    this.serialStack = null;
    this.receiveBuffer = Buffer.alloc(0);
    this.isInitialized = false;
    this.messageQueue = [];
    this.closed = false;
  }

  /**
   * Opens the serial port, closes any stale embroidery session, and upgrades to
   * the maximum baud rate. Queued messages received during init are flushed
   * once ready. Throws (and disposes) if the serial port cannot be opened.
   */
  async init() {
    try {
      this.serialStack = new SerialStack(this.config.serialPort, this.config.baudRate);
      await this.serialStack.open();
      this.log.log(`Serial port opened at ${this.serialStack.baudRate} baud`);

      try {
        if (await this.serialStack.IsEmbroiderySessionOpen()) {
          this.log.log('Closing existing embroidery session...');
          await this.serialStack.EndEmbroiderySession();
        }
      } catch (error) {
        this.log.log(`Could not check/close embroidery session: ${error.message}`);
      }

      if (this.serialStack.baudRate !== 57600) {
        try {
          await this.serialStack.upgradeSpeed();
          this.log.log(`Upgraded to ${this.serialStack.baudRate} baud`);
        } catch (error) {
          this.log.log(`Staying at ${this.serialStack.baudRate} baud: ${error.message}`);
        }
      }

      this.isInitialized = true;

      const queued = this.messageQueue;
      this.messageQueue = [];
      for (const message of queued) {
        if (this.closed) break;
        this._handleMessage(message);
      }
    } catch (error) {
      this.log.error(`Failed to initialize serial connection: ${error.message}`);
      await this.dispose();
      throw error;
    }
  }

  /**
   * Feeds raw bytes received from the client. Frames are buffered and decoded,
   * then dispatched (or queued until init completes).
   */
  handleData(data) {
    if (this.closed) return;
    this.receiveBuffer = Buffer.concat([this.receiveBuffer, Buffer.from(data)]);

    if (this.receiveBuffer.length > MAX_BUFFER_BYTES) {
      this.log.error('Receive buffer overflow, closing session');
      this.dispose();
      return;
    }

    while (this.receiveBuffer.length > 0) {
      const message = this.protocol.decodeMessage(this.receiveBuffer);
      if (!message) break; // Incomplete frame; wait for more bytes.

      this.receiveBuffer = this.receiveBuffer.slice(message.totalLength);

      if (!this.isInitialized) {
        this.messageQueue.push(message);
      } else {
        this._handleMessage(message);
      }
    }
  }

  /** Ends any open embroidery session and releases the serial port. */
  async dispose() {
    if (this.closed) return;
    this.closed = true;
    this.receiveBuffer = Buffer.alloc(0);
    this.messageQueue = [];

    if (this.serialStack) {
      try {
        if (this.serialStack.isOpen) {
          await this.serialStack.EndEmbroiderySession();
        }
        await this.serialStack.close();
      } catch (error) {
        this.log.error(`Error closing serial stack: ${error.message}`);
      }
      this.serialStack = null;
    }
  }

  _send(buffer) {
    if (this.closed) return;
    try {
      this.send(buffer);
    } catch (error) {
      this.log.error(`Failed to send response: ${error.message}`);
    }
  }

  _sendError(requestId, message, code) {
    this._send(this.protocol.createErrorResponse(requestId, message, code));
  }

  _requireSerial(requestId) {
    if (!this.serialStack || !this.serialStack.isOpen) {
      this._sendError(
        requestId,
        'Serial port not connected',
        this.protocol.ErrorCodes.PORT_NOT_CONNECTED,
      );
      return false;
    }
    return true;
  }

  _handleMessage(message) {
    const { messageType, requestId, payload } = message;
    const types = this.protocol.MessageTypes;

    try {
      switch (messageType) {
        case types.GCFG:
          this._handleGetConfig(requestId);
          break;
        case types.SCFG:
          this._handleSetConfig(requestId);
          break;
        case types.STAT:
          this._handleGetStatus(requestId);
          break;
        case types.READ:
          this._handleRead(requestId, payload);
          break;
        case types.LRED:
          this._handleLargeRead(requestId, payload);
          break;
        case types.WRIT:
          this._handleWrite(requestId, payload);
          break;
        case types.UPLD:
          this._handleUpload(requestId, payload);
          break;
        case types.CSUM:
          this._handleChecksum(requestId, payload);
          break;
        case types.SOPE:
          this._handleSessionOpen(requestId);
          break;
        case types.SCLO:
          this._handleSessionClose(requestId);
          break;
        case types.BAUD:
          this._handleBaudChange(requestId);
          break;
        case types.RSET:
          this._handleReset(requestId);
          break;
        default:
          this._sendError(
            requestId,
            `Unknown message type: ${messageType}`,
            this.protocol.ErrorCodes.INVALID_FORMAT,
          );
      }
    } catch (error) {
      this.log.error(`Error handling ${messageType}: ${error.message}`);
      this._sendError(requestId, error.message, this.protocol.ErrorCodes.INVALID_PARAMETERS);
    }
  }

  _handleGetConfig(requestId) {
    this._send(
      this.protocol.createConfigResponse(requestId, {
        serialPort: this.config.serialPort,
        baudRate: this.serialStack ? this.serialStack.baudRate : this.config.baudRate,
        relayVersion: RELAY_VERSION,
      }),
    );
  }

  _handleSetConfig(requestId) {
    // Configuration is fixed server-side; acknowledge without changing anything.
    this._send(this.protocol.createConfigResponse(requestId, { success: true }));
  }

  async _handleGetStatus(requestId) {
    let sessionOpen = false;
    if (this.serialStack && this.serialStack.isOpen) {
      try {
        sessionOpen = await this.serialStack.IsEmbroiderySessionOpen();
      } catch (error) {
        this.log.error(`Error checking session status: ${error.message}`);
      }
    }
    this._send(
      this.protocol.createStatusResponse(requestId, {
        connected: this.serialStack ? this.serialStack.isOpen : false,
        baudRate: this.serialStack ? this.serialStack.baudRate : this.config.baudRate,
        sessionOpen,
        lastError: '',
      }),
    );
  }

  async _handleRead(requestId, payload) {
    if (!this._requireSerial(requestId)) return;
    try {
      const address = this.protocol.parseAddress(payload);
      const hexData = await this.serialStack.read(address);
      this._send(this.protocol.createReadDataResponse(requestId, hexData));
    } catch (error) {
      this._sendError(requestId, `Read failed: ${error.message}`, this.protocol.ErrorCodes.MACHINE_ERROR);
    }
  }

  async _handleLargeRead(requestId, payload) {
    if (!this._requireSerial(requestId)) return;
    try {
      const address = this.protocol.parseAddress(payload);
      const binaryData = await this.serialStack.largeRead(address);
      const dataBuffer = Buffer.from(binaryData, 'latin1');
      this._send(this.protocol.createLargeDataResponse(requestId, dataBuffer));
    } catch (error) {
      this._sendError(requestId, `Large read failed: ${error.message}`, this.protocol.ErrorCodes.MACHINE_ERROR);
    }
  }

  async _handleWrite(requestId, payload) {
    if (!this._requireSerial(requestId)) return;
    try {
      const { address, data } = this.protocol.parseWritePayload(payload);
      await this.serialStack.write(address, data);
      this._send(this.protocol.createWriteAckResponse(requestId, 'O'));
    } catch (error) {
      this._sendError(requestId, `Write failed: ${error.message}`, this.protocol.ErrorCodes.MACHINE_ERROR);
    }
  }

  async _handleUpload(requestId, payload) {
    if (!this._requireSerial(requestId)) return;
    try {
      const { address, data } = this.protocol.parseUploadPayload(payload);
      await this.serialStack.upload(address, data);
      this._send(this.protocol.createUploadAckResponse(requestId, 'O'));
    } catch (error) {
      this._sendError(requestId, `Upload failed: ${error.message}`, this.protocol.ErrorCodes.MACHINE_ERROR);
    }
  }

  async _handleChecksum(requestId, payload) {
    if (!this._requireSerial(requestId)) return;
    try {
      const { address, length } = this.protocol.parseChecksumPayload(payload);
      const sumValue = await this.serialStack.sum(address, length);
      const checksumHex = sumValue.toString(16).toUpperCase().padStart(8, '0');
      this._send(this.protocol.createChecksumResponse(requestId, checksumHex));
    } catch (error) {
      this._sendError(requestId, `Checksum failed: ${error.message}`, this.protocol.ErrorCodes.MACHINE_ERROR);
    }
  }

  async _handleSessionOpen(requestId) {
    if (!this._requireSerial(requestId)) return;
    try {
      await this.serialStack.StartEmbroiderySession();
      this._send(this.protocol.createSessionAckResponse(requestId, 'O'));
    } catch (error) {
      this._sendError(requestId, `Session open failed: ${error.message}`, this.protocol.ErrorCodes.SESSION_ALREADY_OPEN);
    }
  }

  async _handleSessionClose(requestId) {
    if (!this._requireSerial(requestId)) return;
    try {
      await this.serialStack.EndEmbroiderySession();
      this._send(this.protocol.createSessionAckResponse(requestId, 'O'));
    } catch (error) {
      this._sendError(requestId, `Session close failed: ${error.message}`, this.protocol.ErrorCodes.SESSION_NOT_OPEN);
    }
  }

  async _handleBaudChange(requestId) {
    // Client's requested rate is ignored; the server always auto-detects and
    // upgrades to the maximum supported rate.
    if (!this.serialStack) {
      this._sendError(requestId, 'Serial stack not initialized', this.protocol.ErrorCodes.PORT_NOT_CONFIGURED);
      return;
    }
    try {
      if (!this.serialStack.isOpen) {
        await this.serialStack.open();
      }
      if (this.serialStack.baudRate !== 57600) {
        try {
          await this.serialStack.upgradeSpeed();
        } catch (error) {
          this.log.log(`Could not upgrade baud rate: ${error.message}`);
        }
      }
      this._send(this.protocol.createBaudAckResponse(requestId, 'O'));
    } catch (error) {
      this._sendError(requestId, `Baud rate change failed: ${error.message}`, this.protocol.ErrorCodes.BAUD_CHANGE_FAILED);
    }
  }

  async _handleReset(requestId) {
    if (!this._requireSerial(requestId)) return;
    try {
      await this.serialStack.resync();
      this._send(this.protocol.createResetAckResponse(requestId, 'O'));
    } catch (error) {
      this._sendError(requestId, `Reset failed: ${error.message}`, this.protocol.ErrorCodes.MACHINE_ERROR);
    }
  }
}

module.exports = RelaySession;
