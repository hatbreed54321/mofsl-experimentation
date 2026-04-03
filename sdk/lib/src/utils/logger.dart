import 'dart:developer' as developer;

/// Lightweight debug logger that routes to [developer.log].
///
/// Tag: `MofslExperiment` (visible in Dart DevTools / Flutter console).
///
/// When [debugMode] is false:
/// - [debug] and [warning] calls are no-ops (zero overhead in production).
/// - [error] always logs, regardless of [debugMode].
class Logger {
  final bool debugMode;

  const Logger({required this.debugMode});

  /// Log a debug-level message. No-op when [debugMode] is false.
  void debug(String message) {
    if (!debugMode) return;
    developer.log(message, name: 'MofslExperiment');
  }

  /// Log a warning. No-op when [debugMode] is false.
  void warning(String message, [Object? error]) {
    if (!debugMode) return;
    developer.log(
      '[WARNING] $message',
      name: 'MofslExperiment',
      error: error,
    );
  }

  /// Log an error. Always logs, regardless of [debugMode].
  void error(String message, [Object? error, StackTrace? stackTrace]) {
    developer.log(
      '[ERROR] $message',
      name: 'MofslExperiment',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
