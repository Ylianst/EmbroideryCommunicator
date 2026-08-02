/// Timing parameters for the character-echo serial protocol.
///
/// Defaults mirror the legacy C# implementation. Tests use [ProtocolTiming.fast]
/// to remove artificial delays when driving a synchronous fake machine.
class ProtocolTiming {
  /// Delay between individual characters when sending a queued command.
  final Duration interCharDelay;

  /// Small settle delay after marking a transmission complete.
  final Duration postTransmitDelay;

  /// Poll interval while waiting for a single character echo.
  final Duration echoPollInterval;

  /// Poll interval while waiting for a specific character to appear.
  final Duration charPollInterval;

  /// Interval between repeated 'R'/'E' probes (protocol reset, baud confirm).
  final Duration probeInterval;

  /// Maximum number of 'R'/'E' probe attempts.
  final int probeAttempts;

  /// Timeout for a single character echo.
  final Duration echoTimeout;

  /// Timeout waiting for a confirmation character (e.g. 'O').
  final Duration confirmationTimeout;

  /// Timeout for Read (R) and Large Read (N) commands.
  final Duration readTimeout;

  /// Timeout for Write (W) commands.
  final Duration writeTimeout;

  /// Timeout for all other commands.
  final Duration defaultTimeout;

  /// Delay between characters of a PS upload command header.
  final Duration uploadHeaderCharDelay;

  /// Timeout waiting for the upload "OE" acknowledgement.
  final Duration uploadAckTimeout;

  /// Timeout waiting for the final upload "O" confirmation.
  final Duration uploadConfirmTimeout;

  const ProtocolTiming({
    this.interCharDelay = const Duration(milliseconds: 10),
    this.postTransmitDelay = const Duration(milliseconds: 5),
    this.echoPollInterval = const Duration(milliseconds: 10),
    this.charPollInterval = const Duration(milliseconds: 10),
    this.probeInterval = const Duration(milliseconds: 50),
    this.probeAttempts = 30,
    this.echoTimeout = const Duration(milliseconds: 500),
    this.confirmationTimeout = const Duration(milliseconds: 1000),
    this.readTimeout = const Duration(seconds: 10),
    this.writeTimeout = const Duration(seconds: 14),
    this.defaultTimeout = const Duration(seconds: 5),
    this.uploadHeaderCharDelay = const Duration(milliseconds: 20),
    this.uploadAckTimeout = const Duration(seconds: 5),
    this.uploadConfirmTimeout = const Duration(seconds: 3),
  });

  /// Near-instant timing for tests driving a synchronous fake machine.
  static const ProtocolTiming fast = ProtocolTiming(
    interCharDelay: Duration.zero,
    postTransmitDelay: Duration.zero,
    echoPollInterval: Duration(milliseconds: 1),
    charPollInterval: Duration(milliseconds: 1),
    probeInterval: Duration(milliseconds: 1),
    probeAttempts: 30,
    echoTimeout: Duration(milliseconds: 200),
    confirmationTimeout: Duration(milliseconds: 200),
    readTimeout: Duration(seconds: 2),
    writeTimeout: Duration(seconds: 2),
    defaultTimeout: Duration(seconds: 2),
    uploadHeaderCharDelay: Duration.zero,
    uploadAckTimeout: Duration(seconds: 2),
    uploadConfirmTimeout: Duration(seconds: 2),
  );
}
