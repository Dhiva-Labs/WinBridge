import 'dart:io';

import 'package:test/test.dart';
import 'package:winbridge/winbridge.dart';

/// A sink whose reader has gone away, the way `winbridge ... | head` leaves
/// stdout once head exits.
class _ClosedSink implements StringSink {
  _ClosedSink([this.error = const FileSystemException(
    'writeFrom failed',
    '',
    OSError('Broken pipe', 32),
  )]);

  final Object error;
  int attempts = 0;

  Never _fail() {
    attempts++;
    throw error;
  }

  @override
  void write(Object? object) => _fail();

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) => _fail();

  @override
  void writeCharCode(int charCode) => _fail();

  @override
  void writeln([Object? object = '']) => _fail();
}

void main() {
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    out = StringBuffer();
    err = StringBuffer();
  });

  Output output({bool verbose = false}) =>
      Output(verbose: verbose, out: out, err: err);

  test('info always prints', () {
    output().info('built app.exe');
    expect(out.toString(), 'built app.exe\n');
  });

  test('detail is verbose only', () {
    output().detail('resolved /usr/bin/go');
    expect(out.toString(), isEmpty);

    output(verbose: true).detail('resolved /usr/bin/go');
    expect(out.toString(), 'resolved /usr/bin/go\n');
  });

  test('trace is verbose only and routes stderr separately', () {
    output().trace('compiler noise');
    expect(out.toString(), isEmpty);

    final verbose = output(verbose: true);
    verbose.trace('to stdout');
    verbose.trace('to stderr', stderr: true);
    expect(out.toString(), 'to stdout\n');
    expect(err.toString(), 'to stderr\n');
  });

  test('warnings and errors are labelled and go to stderr', () {
    output()
      ..warn('using a stale cache')
      ..error('build failed');
    expect(out.toString(), isEmpty);
    expect(err.toString(), 'warning: using a stale cache\nerror: build failed\n');
  });

  group('a reader that went away', () {
    test('a broken pipe on stdout is not an error the caller sees', () {
      final closed = _ClosedSink();
      final output = Output(out: closed, err: err);

      expect(() => output.info('first'), returnsNormally);
      expect(() => output.info('second'), returnsNormally);
      expect(output.blank, returnsNormally);
    });

    test('the sink is retired after the first failure', () {
      final closed = _ClosedSink();
      final output = Output(out: closed, err: err);

      for (var i = 0; i < 5; i++) {
        output.info('line $i');
      }
      expect(closed.attempts, 1, reason: 'kept writing to a dead pipe');
    });

    test('stderr still works when stdout has gone', () {
      final closed = _ClosedSink();
      final output = Output(out: closed, err: err);

      output.info('swallowed');
      output.error('build failed');
      expect(err.toString(), 'error: build failed\n');
      expect(output.isSilenced, isFalse);
    });

    test('losing both streams silences the output', () {
      final output = Output(out: _ClosedSink(), err: _ClosedSink());
      output.info('swallowed');
      output.error('also swallowed');
      expect(output.isSilenced, isTrue);
    });

    test('verbose channels tolerate it too', () {
      final output = Output(verbose: true, out: _ClosedSink(), err: err);
      expect(() => output.detail('resolved /usr/bin/go'), returnsNormally);
      expect(() => output.trace('compiler noise'), returnsNormally);
    });

    test('any other write failure is still a bug and propagates', () {
      final broken = _ClosedSink(StateError('sink misuse'));
      final output = Output(out: broken, err: err);
      expect(() => output.info('boom'), throwsStateError);
    });
  });

  group('isBrokenPipe', () {
    test('recognises EPIPE by errno', () {
      expect(
        isBrokenPipe(const FileSystemException(
          'writeFrom failed',
          '',
          OSError('Broken pipe', 32),
        )),
        isTrue,
      );
    });

    test('recognises the Windows broken-pipe codes', () {
      for (final code in [109, 232]) {
        expect(
          isBrokenPipe(
            FileSystemException('write failed', '', OSError('closed', code)),
          ),
          isTrue,
          reason: 'errno $code',
        );
      }
    });

    test('falls back to the message when there is no errno', () {
      expect(
        isBrokenPipe(const FileSystemException('Broken pipe')),
        isTrue,
      );
    });

    test('does not claim unrelated failures', () {
      expect(
        isBrokenPipe(const FileSystemException(
          'no space left',
          '/tmp/x',
          OSError('No space left on device', 28),
        )),
        isFalse,
      );
      expect(isBrokenPipe(StateError('nope')), isFalse);
      expect(isBrokenPipe(const FormatException('bad')), isFalse);
    });
  });
}
