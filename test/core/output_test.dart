import 'package:test/test.dart';
import 'package:winbridge/winbridge.dart';

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
}
