import 'dart:typed_data';

/// Result of a single protocol command or higher-level operation.
class CommandResult {
  final bool success;
  final String? response;
  final String? errorMessage;
  final Uint8List? binaryData;

  const CommandResult({
    required this.success,
    this.response,
    this.errorMessage,
    this.binaryData,
  });

  factory CommandResult.ok({String? response, Uint8List? binaryData}) =>
      CommandResult(success: true, response: response, binaryData: binaryData);

  factory CommandResult.failure(String message) =>
      CommandResult(success: false, errorMessage: message);

  @override
  String toString() => success
      ? 'CommandResult.ok(response: $response, ${binaryData?.length ?? 0} bytes)'
      : 'CommandResult.failure($errorMessage)';
}
