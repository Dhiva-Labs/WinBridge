import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

void main() {
  group('realPath', () {
    test('makes paths absolute and normalized', () {
      final root = tempDir();
      expect(realPath(p.join(root, 'a', '..', 'b')), p.join(root, 'b'));
    });

    test('resolves symlinks', () {
      final root = tempDir();
      final target = writeFile(p.join(root, 'real', 'file'));
      Link(p.join(root, 'link')).createSync(p.join(root, 'real'));
      expect(realPath(p.join(root, 'link', 'file')), target);
    });

    test('tolerates paths that do not exist', () {
      expect(realPath('/winbridge/nope/../nope'), '/winbridge/nope');
    });
  });

  group('isInside', () {
    late String parent;

    setUp(() => parent = tempDir());

    test('accepts a child', () {
      expect(isInside(parent, p.join(parent, 'app.exe')), isTrue);
      expect(isInside(parent, p.join(parent, 'deep', 'app.exe')), isTrue);
    });

    test('rejects the directory itself', () {
      expect(isInside(parent, parent), isFalse);
    });

    test('rejects a sibling', () {
      expect(isInside(parent, p.join(p.dirname(parent), 'elsewhere')), isFalse);
    });

    test('rejects traversal', () {
      expect(isInside(parent, p.join(parent, '..', '..', 'etc', 'passwd')),
          isFalse);
    });

    test('rejects a prefix collision', () {
      expect(isInside('/build/out', '/build/output/app.exe'), isFalse);
    });

    test('rejects a symlink pointing out of the directory', () {
      final outside = writeFile(p.join(tempDir('outside'), 'evil'));
      final link = p.join(parent, 'app.exe');
      Link(link).createSync(outside);
      expect(isInside(parent, link), isFalse);
    });
  });

  group('requireInside', () {
    late String parent;

    setUp(() => parent = tempDir());

    void check(String child) => requireInside(
          parent: parent,
          child: child,
          what: 'artifact',
        );

    test('passes a contained path', () {
      expect(() => check(p.join(parent, 'app.exe')), returnsNormally);
    });

    test('rejects a relative path', () {
      expect(
        () => check('app.exe'),
        throwsA(isA<ArtifactFailure>()
            .having((e) => e.message, 'message', contains('absolute'))),
      );
    });

    test('rejects an escaping path', () {
      expect(
        () => check('/etc/passwd'),
        throwsA(isA<ArtifactFailure>()
            .having((e) => e.message, 'message', contains('escapes'))
            .having((e) => e.exitCode, 'exitCode', 1)),
      );
    });
  });
}
