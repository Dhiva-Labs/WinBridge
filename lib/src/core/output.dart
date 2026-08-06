import 'dart:io' as io;

/// Whether [error] is the operating system saying "nobody is reading this any
/// more" — the normal end of `winbridge ... | head`, not a fault.
///
/// Dart disables `SIGPIPE`, so a closed pipe surfaces as `EPIPE` (errno 32 on
/// Linux and macOS) rather than killing the process the way it would a C
/// program. Windows reports the same condition as `ERROR_BROKEN_PIPE` (109) or
/// `ERROR_NO_DATA` (232).
bool isBrokenPipe(Object error) {
  final int? code;
  if (error is io.FileSystemException) {
    code = error.osError?.errorCode;
  } else if (error is io.StdoutException) {
    code = error.osError?.errorCode;
  } else {
    return false;
  }
  if (code == 32 || code == 109 || code == 232) return true;
  return error.toString().contains('Broken pipe');
}

/// Console writer with two levels: normal, and everything.
///
/// [detail] and [trace] are the verbose channel — command lines, resolved
/// paths, timings. Nothing written here may contain environment values; see
/// `ProcessRunner`, which logs overlay keys but never their contents.
///
/// A stream whose reader has gone away is retired rather than reported: the
/// first broken-pipe error on a sink stops further writes to it, and the other
/// sink keeps working, so `winbridge build 2>err.log | head` still gets its
/// diagnostics. See `WinBridgeRunner.execute` for the asynchronous half of
/// this — `io.stdout` reports most write failures through the zone rather than
/// from `writeln` itself.
class Output {
  Output({this.verbose = false, StringSink? out, StringSink? err})
      : _outOverride = out,
        _errOverride = err;

  final bool verbose;
  final StringSink? _outOverride;
  final StringSink? _errOverride;

  // Resolved on first use, never in the constructor. Touching `io.stdout`
  // binds its internal stream subscription — and therefore where its write
  // errors are delivered — to whatever zone is current at that moment. Doing
  // it lazily keeps that binding inside `WinBridgeRunner.execute`'s guarded
  // zone no matter where the Output itself was built.
  StringSink get _out => _outOverride ?? io.stdout;
  StringSink get _err => _errOverride ?? io.stderr;

  var _outClosed = false;
  var _errClosed = false;

  /// Whether every stream this writes to has gone away.
  bool get isSilenced => _outClosed && _errClosed;

  void info(String message) => _writeOut(message);

  void blank() => _writeOut('');

  /// Verbose-only commentary.
  void detail(String message) {
    if (verbose) _writeOut(message);
  }

  /// Verbose-only passthrough of a child process line, written unchanged.
  void trace(String line, {bool stderr = false}) {
    if (!verbose) return;
    stderr ? _writeErr(line) : _writeOut(line);
  }

  void warn(String message) => _writeErr('warning: $message');

  void error(String message) => _writeErr('error: $message');

  void _writeOut(String message) {
    if (_outClosed) return;
    if (!_write(_out, message)) _outClosed = true;
  }

  void _writeErr(String message) {
    if (_errClosed) return;
    if (!_write(_err, message)) _errClosed = true;
  }

  /// Returns false when the sink is gone. Any other failure is a real fault
  /// and is rethrown — this swallows a closed reader, not bugs.
  static bool _write(StringSink sink, String message) {
    try {
      sink.writeln(message);
      return true;
    } on Object catch (error) {
      if (isBrokenPipe(error)) return false;
      rethrow;
    }
  }
}
