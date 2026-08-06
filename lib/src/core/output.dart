import 'dart:io' as io;

/// Console writer with two levels: normal, and everything.
///
/// [detail] and [trace] are the verbose channel — command lines, resolved
/// paths, timings. Nothing written here may contain environment values; see
/// `ProcessRunner`, which logs overlay keys but never their contents.
class Output {
  Output({this.verbose = false, StringSink? out, StringSink? err})
      : _out = out ?? io.stdout,
        _err = err ?? io.stderr;

  final bool verbose;
  final StringSink _out;
  final StringSink _err;

  void info(String message) => _out.writeln(message);

  void blank() => _out.writeln();

  /// Verbose-only commentary.
  void detail(String message) {
    if (verbose) _out.writeln(message);
  }

  /// Verbose-only passthrough of a child process line, written unchanged.
  void trace(String line, {bool stderr = false}) {
    if (!verbose) return;
    (stderr ? _err : _out).writeln(line);
  }

  void warn(String message) => _err.writeln('warning: $message');

  void error(String message) => _err.writeln('error: $message');
}
