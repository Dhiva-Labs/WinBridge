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

  // redactHome only rewrites paths that sit *under* $HOME, but not every path
  // a report carries does: a WINBRIDGE_WINE override, a tool found on a PATH
  // entry elsewhere, or an XDG directory pointed outside the home all reach
  // the report with the reporter's account name intact.
  group('redactPath also removes the account name outside \$HOME', () {
    test('an override path elsewhere on the filesystem', () {
      expect(
        redactPath('/opt/alice/wine/bin/wine', '/home/alice'),
        '/opt/<user>/wine/bin/wine',
      );
    });

    test('an XDG directory outside the home', () {
      expect(
        redactPath('/mnt/fast/alice/cache/winbridge', '/home/alice'),
        '/mnt/fast/<user>/cache/winbridge',
      );
    });

    test('still prefers ~ for paths under the home', () {
      expect(redactPath('/home/alice/.cache/x', '/home/alice'), '~/.cache/x');
    });

    test('only whole segments match, so a user named bin is survivable', () {
      expect(redactPath('/usr/bin/vulkaninfo', '/home/binary'),
          '/usr/bin/vulkaninfo');
      expect(redactPath('/opt/bin/tool', '/home/bin'), '/opt/<user>/tool');
    });

    test('unrelated paths are untouched', () {
      expect(redactPath('/usr/lib/libvulkan.so.1', '/home/alice'),
          '/usr/lib/libvulkan.so.1');
    });

    test('no home means nothing to redact against', () {
      expect(redactPath('/opt/alice/x', null), '/opt/alice/x');
      expect(redactPath('/opt/alice/x', ''), '/opt/alice/x');
    });
  });
}
