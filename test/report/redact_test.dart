import 'package:test/test.dart';
import 'package:winbridge/src/report/redact.dart';

void main() {
  group('redactHome', () {
    test('rewrites a path under home to start with ~', () {
      expect(
        redactHome('/home/alice/.cache/winbridge/runtimes/wine', '/home/alice'),
        '~/.cache/winbridge/runtimes/wine',
      );
    });

    test('the home directory itself becomes exactly ~', () {
      expect(redactHome('/home/alice', '/home/alice'), '~');
    });

    test('a path outside home is left untouched', () {
      expect(redactHome('/opt/wine/bin/wine', '/home/alice'), '/opt/wine/bin/wine');
    });

    test('a sibling directory that merely shares a prefix is not rewritten', () {
      // "/home/alice2" starts with the literal string "/home/alice" but is
      // not underneath it — a naive `startsWith` check would wrongly redact
      // it.
      expect(
        redactHome('/home/alice2/secret', '/home/alice'),
        '/home/alice2/secret',
      );
    });

    test('null home leaves the path untouched', () {
      expect(redactHome('/home/alice/x', null), '/home/alice/x');
    });

    test('empty home leaves the path untouched', () {
      expect(redactHome('/home/alice/x', ''), '/home/alice/x');
    });

    test('a trailing slash on home does not break the match', () {
      expect(
        redactHome('/home/alice/x', '/home/alice/'),
        '~/x',
      );
    });
  });
}
