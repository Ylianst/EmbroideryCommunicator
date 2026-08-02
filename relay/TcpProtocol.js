/**
 * TcpProtocol.js
 * 
 * Handles encoding and decoding of messages for the Embroidery Relay TCP Protocol.
 * Message format: [MessageType:4][RequestID:8][PayloadLength:8][Payload:N]
 */

class TcpProtocol {
  constructor() {
    // Message type definitions
    this.MessageTypes = {
      // Configuration Commands
      GCFG: 'GCFG', // Get Configuration
      SCFG: 'SCFG', // Set Configuration
      RCFG: 'RCFG', // Response Configuration
      STAT: 'STAT', // Get Status
      RSTA: 'RSTA', // Response Status
      
      // Machine Communication Commands
      READ: 'READ', // Read Memory
      RDAT: 'RDAT', // Response Data
      LRED: 'LRED', // Large Read Memory
      LDAT: 'LDAT', // Large Data Response
      WRIT: 'WRIT', // Write Memory
      WACK: 'WACK', // Write Acknowledge
      UPLD: 'UPLD', // Upload Block
      UACK: 'UACK', // Upload Acknowledge
      CSUM: 'CSUM', // Calculate Checksum
      RSUM: 'RSUM', // Response Sum
      
      // Session Management Commands
      SOPE: 'SOPE', // Session Open
      SCLO: 'SCLO', // Session Close
      SACK: 'SACK', // Session Acknowledge
      BAUD: 'BAUD', // Change Baud Rate
      BACK: 'BACK', // Baud Acknowledge
      RSET: 'RSET', // Protocol Reset
      RACK: 'RACK', // Reset Acknowledge
      
      // Error Handling
      ERRO: 'ERRO'  // Error Response
    };

    // Error codes
    this.ErrorCodes = {
      INVALID_FORMAT: 1001,
      PORT_NOT_CONFIGURED: 1002,
      PORT_NOT_CONNECTED: 1003,
      MACHINE_TIMEOUT: 1004,
      MACHINE_ERROR: 1005,
      INVALID_PARAMETERS: 1006,
      SESSION_ALREADY_OPEN: 1007,
      SESSION_NOT_OPEN: 1008,
      BAUD_CHANGE_FAILED: 1009
    };
  }

  /**
   * Encode a message for transmission
   * @param {string} messageType - 4 character message type
   * @param {string} requestId - 8 character hex request ID
   * @param {Buffer|string} payload - Payload data (Buffer or string)
   * @returns {Buffer} Encoded message ready to send
   */
  encodeMessage(messageType, requestId, payload = '') {
    // Validate message type
    if (messageType.length !== 4) {
      throw new Error('Message type must be exactly 4 characters');
    }

    // Validate request ID
    if (requestId.length !== 8) {
      throw new Error('Request ID must be exactly 8 hex characters');
    }

    // Convert payload to Buffer if it's a string
    const payloadBuffer = Buffer.isBuffer(payload) 
      ? payload 
      : Buffer.from(payload, 'utf8');

    // Calculate payload length
    const payloadLength = payloadBuffer.length;
    const payloadLengthHex = payloadLength.toString(16).toUpperCase().padStart(8, '0');

    // Build the message
    const header = Buffer.from(`${messageType}${requestId}${payloadLengthHex}`, 'ascii');
    const message = Buffer.concat([header, payloadBuffer]);

    return message;
  }

  /**
   * Decode a message from received data
   * @param {Buffer} buffer - Buffer containing the message
   * @returns {Object|null} Decoded message object or null if incomplete
   * {
   *   messageType: string,
   *   requestId: string,
   *   payloadLength: number,
   *   payload: Buffer,
   *   totalLength: number (total message length including header)
   * }
   */
  decodeMessage(buffer) {
    // Need at least 20 bytes for header (4 + 8 + 8)
    if (buffer.length < 20) {
      return null;
    }

    // Extract header components
    const messageType = buffer.toString('ascii', 0, 4);
    const requestId = buffer.toString('ascii', 4, 12);
    const payloadLengthHex = buffer.toString('ascii', 12, 20);
    const payloadLength = parseInt(payloadLengthHex, 16);

    // Check if we have the complete message
    const totalLength = 20 + payloadLength;
    if (buffer.length < totalLength) {
      return null; // Incomplete message
    }

    // Extract payload
    const payload = buffer.slice(20, totalLength);

    return {
      messageType,
      requestId,
      payloadLength,
      payload,
      totalLength
    };
  }

  /**
   * Create a configuration response (RCFG)
   */
  createConfigResponse(requestId, config) {
    const payload = JSON.stringify(config);
    return this.encodeMessage(this.MessageTypes.RCFG, requestId, payload);
  }

  /**
   * Create a status response (RSTA)
   */
  createStatusResponse(requestId, status) {
    const payload = JSON.stringify(status);
    return this.encodeMessage(this.MessageTypes.RSTA, requestId, payload);
  }

  /**
   * Create a read data response (RDAT)
   */
  createReadDataResponse(requestId, hexData) {
    return this.encodeMessage(this.MessageTypes.RDAT, requestId, hexData);
  }

  /**
   * Create a large read data response (LDAT)
   */
  createLargeDataResponse(requestId, binaryData) {
    return this.encodeMessage(this.MessageTypes.LDAT, requestId, binaryData);
  }

  /**
   * Create a write acknowledge response (WACK)
   */
  createWriteAckResponse(requestId, status) {
    return this.encodeMessage(this.MessageTypes.WACK, requestId, status);
  }

  /**
   * Create an upload acknowledge response (UACK)
   */
  createUploadAckResponse(requestId, status) {
    return this.encodeMessage(this.MessageTypes.UACK, requestId, status);
  }

  /**
   * Create a checksum response (RSUM)
   */
  createChecksumResponse(requestId, checksumHex) {
    return this.encodeMessage(this.MessageTypes.RSUM, requestId, checksumHex);
  }

  /**
   * Create a session acknowledge response (SACK)
   */
  createSessionAckResponse(requestId, status) {
    return this.encodeMessage(this.MessageTypes.SACK, requestId, status);
  }

  /**
   * Create a baud acknowledge response (BACK)
   */
  createBaudAckResponse(requestId, status) {
    return this.encodeMessage(this.MessageTypes.BACK, requestId, status);
  }

  /**
   * Create a reset acknowledge response (RACK)
   */
  createResetAckResponse(requestId, status) {
    return this.encodeMessage(this.MessageTypes.RACK, requestId, status);
  }

  /**
   * Create an error response (ERRO)
   */
  createErrorResponse(requestId, errorMessage, errorCode) {
    const payload = JSON.stringify({
      error: errorMessage,
      code: errorCode
    });
    return this.encodeMessage(this.MessageTypes.ERRO, requestId, payload);
  }

  /**
   * Parse a JSON payload from a message
   */
  parseJsonPayload(payload) {
    try {
      return JSON.parse(payload.toString('utf8'));
    } catch (error) {
      throw new Error(`Failed to parse JSON payload: ${error.message}`);
    }
  }

  /**
   * Parse an address from payload (6 hex characters)
   */
  parseAddress(payload) {
    const address = payload.toString('ascii', 0, 6);
    if (!/^[0-9A-Fa-f]{6}$/.test(address)) {
      throw new Error('Invalid address format: must be 6 hex characters');
    }
    return address.toUpperCase();
  }

  /**
   * Parse address and data from WRIT payload
   */
  parseWritePayload(payload) {
    if (payload.length < 6) {
      throw new Error('Write payload too short');
    }
    const address = this.parseAddress(payload);
    const data = payload.toString('ascii', 6);
    
    // Validate data is hex
    if (data.length % 2 !== 0) {
      throw new Error('Write data must have even number of hex characters');
    }
    if (!/^[0-9A-Fa-f]*$/.test(data)) {
      throw new Error('Write data must be hex characters');
    }
    
    return { address, data: data.toUpperCase() };
  }

  /**
   * Parse address and data from UPLD payload
   */
  parseUploadPayload(payload) {
    if (payload.length !== 260) { // 4 bytes address + 256 bytes data
      throw new Error('Upload payload must be exactly 260 bytes (4 address + 256 data)');
    }
    
    const address = payload.toString('ascii', 0, 4);
    if (!/^[0-9A-Fa-f]{4}$/.test(address)) {
      throw new Error('Invalid address format: must be 4 hex characters');
    }
    
    const data = payload.slice(4, 260);
    return { address: address.toUpperCase(), data };
  }

  /**
   * Parse address and length from CSUM payload
   */
  parseChecksumPayload(payload) {
    if (payload.length !== 12) { // 6 bytes address + 6 bytes length
      throw new Error('Checksum payload must be exactly 12 bytes');
    }
    
    const address = payload.toString('ascii', 0, 6);
    const length = payload.toString('ascii', 6, 12);
    
    if (!/^[0-9A-Fa-f]{6}$/.test(address)) {
      throw new Error('Invalid address format: must be 6 hex characters');
    }
    if (!/^[0-9A-Fa-f]{6}$/.test(length)) {
      throw new Error('Invalid length format: must be 6 hex characters');
    }
    
    return { address: address.toUpperCase(), length: length.toUpperCase() };
  }

  /**
   * Parse baud rate from BAUD payload
   */
  parseBaudRate(payload) {
    const rate = payload.toString('ascii', 0, 5);
    if (rate !== '19200' && rate !== '57600') {
      throw new Error('Invalid baud rate: must be 19200 or 57600');
    }
    return parseInt(rate);
  }
}

module.exports = TcpProtocol;
