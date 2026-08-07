import 'package:test/test.dart';
import 'package:winbridge/src/recipes/recipe.dart';

Map<String, dynamic> validSha256Recipe({
  String id = 'some-app-1.0',
  Map<String, dynamic>? apply,
}) =>
    {
      'id': id,
      'match': {
        'sha256':
            '9c538924110a7cdef871ca36dee218c0774124374ffdeb38af4b76be55bdf7c2',
      },
      'apply': ?apply,
    };

Recipe parse(Map<String, dynamic> json, {String path = 'r.json'}) =>
    Recipe.fromJson(json, sourcePath: path, sourceKind: RecipeSourceKind.bundled);

void expectRejected(Map<String, dynamic> json, {Object? messageContains}) {
  expect(
    () => parse(json),
    throwsA(isA<RecipeValidationError>().having(
      (e) => e.messages.join('\n'),
      'messages',
      messageContains == null ? anything : contains(messageContains),
    )),
  );
}

void main() {
  group('id', () {
    test('a well-formed recipe parses', () {
      final recipe = parse(validSha256Recipe());
      expect(recipe.id, 'some-app-1.0');
      expect(recipe.sourceKind, RecipeSourceKind.bundled);
      expect(recipe.apply.isEmpty, isTrue);
    });

    test('missing id is rejected', () {
      final json = validSha256Recipe()..remove('id');
      expectRejected(json, messageContains: '"id"');
    });

    for (final bad in ['', '-leading-dash', '../escape', 'a/b', 'a\\b']) {
      test('rejects unsafe id "$bad"', () {
        expectRejected(validSha256Recipe(id: bad));
      });
    }
  });

  group('match', () {
    test('accepts a lowercase 64-hex sha256', () {
      final recipe = parse(validSha256Recipe());
      expect(recipe.match.kind, MatchKind.sha256);
      expect(recipe.match.sha256, hasLength(64));
    });

    test('normalizes an uppercase sha256 to lowercase', () {
      final json = {
        'id': 'x',
        'match': {
          'sha256':
              '9C538924110A7CDEF871CA36DEE218C0774124374FFDEB38AF4B76BE55BDF7C2',
        },
      };
      expect(parse(json).match.sha256,
          '9c538924110a7cdef871ca36dee218c0774124374ffdeb38af4b76be55bdf7c2');
    });

    test('rejects a sha256 that is too short', () {
      expectRejected({
        'id': 'x',
        'match': {'sha256': 'abc123'},
      });
    });

    test('rejects a sha256 with non-hex characters', () {
      expectRejected({
        'id': 'x',
        'match': {'sha256': 'g' * 64},
      });
    });

    test('accepts fileName + sizeBytes', () {
      final recipe = parse({
        'id': 'x',
        'match': {'fileName': 'Setup.exe', 'sizeBytes': 12345},
      });
      expect(recipe.match.kind, MatchKind.fileNameAndSize);
      expect(recipe.match.fileName, 'Setup.exe');
      expect(recipe.match.sizeBytes, 12345);
    });

    test('rejects fileName without sizeBytes', () {
      expectRejected({
        'id': 'x',
        'match': {'fileName': 'Setup.exe'},
      });
    });

    test('rejects sizeBytes without fileName', () {
      expectRejected({
        'id': 'x',
        'match': {'sizeBytes': 12345},
      });
    });

    test('rejects a non-positive sizeBytes', () {
      expectRejected({
        'id': 'x',
        'match': {'fileName': 'Setup.exe', 'sizeBytes': 0},
      });
    });

    test('rejects an unsafe fileName', () {
      expectRejected({
        'id': 'x',
        'match': {'fileName': '../../etc/passwd', 'sizeBytes': 100},
      });
    });

    test('rejects both sha256 and fileName/sizeBytes at once', () {
      expectRejected({
        'id': 'x',
        'match': {
          'sha256':
              '9c538924110a7cdef871ca36dee218c0774124374ffdeb38af4b76be55bdf7c2',
          'fileName': 'Setup.exe',
          'sizeBytes': 100,
        },
      });
    });

    test('rejects a match with neither shape', () {
      expectRejected({'id': 'x', 'match': <String, dynamic>{}});
    });

    test('rejects a missing match entirely', () {
      final json = validSha256Recipe()..remove('match');
      expectRejected(json);
    });

    test('rejects a match that is not an object', () {
      expectRejected({'id': 'x', 'match': 'sha256:abc'});
    });
  });

  group('apply.tricks', () {
    test('accepts winetricks-shaped verbs', () {
      final recipe = parse(validSha256Recipe(apply: {
        'tricks': ['corefonts', 'vcrun2019', 'dotnet48'],
      }));
      expect(recipe.apply.tricks.map((v) => v.value),
          ['corefonts', 'vcrun2019', 'dotnet48']);
    });

    for (final bad in [
      'corefonts; rm -rf /',
      '-rf',
      '--prefix=/etc',
      r'$(whoami)',
      'core fonts',
      '../../etc/passwd',
      '',
    ]) {
      test('rejects hostile verb "$bad"', () {
        expectRejected(validSha256Recipe(apply: {
          'tricks': [bad],
        }));
      });
    }

    test('rejects tricks that is not a list', () {
      expectRejected(validSha256Recipe(apply: {'tricks': 'corefonts'}));
    });

    test('rejects a non-string entry in tricks', () {
      expectRejected(validSha256Recipe(apply: {
        'tricks': [42],
      }));
    });
  });

  group('apply.dllOverrides', () {
    test('accepts every value in the closed set', () {
      final recipe = parse(validSha256Recipe(apply: {
        'dllOverrides': {
          'd3d9': 'n',
          'd3d11': 'b',
          'dxgi': 'n,b',
          'mfc140': 'b,n',
          'quartz': '',
        },
      }));
      expect(recipe.apply.dllOverrides, {
        'd3d9': 'n',
        'd3d11': 'b',
        'dxgi': 'n,b',
        'mfc140': 'b,n',
        'quartz': '',
      });
    });

    test('rejects an override value outside the closed set', () {
      expectRejected(validSha256Recipe(apply: {
        'dllOverrides': {'d3d9': 'yes'},
      }));
    });

    for (final bad in ['D3D9', 'd3d9/x', 'd3d9;x', 'd3d9 ']) {
      test('rejects invalid dll name "$bad"', () {
        expectRejected(validSha256Recipe(apply: {
          'dllOverrides': {bad: 'n'},
        }));
      });
    }

    test('a leading dash is allowed in a dll name (the charset spec has no '
        'leading-character exception for it, unlike verbs and ids — a dll '
        'name never becomes its own argv element)', () {
      final recipe = parse(validSha256Recipe(apply: {
        'dllOverrides': {'-oddname': 'n'},
      }));
      expect(recipe.apply.dllOverrides, {'-oddname': 'n'});
    });

    test('rejects dllOverrides that is not an object', () {
      expectRejected(validSha256Recipe(apply: {'dllOverrides': 'd3d9=n'}));
    });
  });

  group('apply.dxvk', () {
    test('accepts a boolean', () {
      expect(parse(validSha256Recipe(apply: {'dxvk': true})).apply.dxvk,
          isTrue);
    });

    test('rejects a non-boolean', () {
      expectRejected(validSha256Recipe(apply: {'dxvk': 'true'}));
    });
  });

  group('apply as a whole', () {
    test('an absent apply block is empty, not an error', () {
      final recipe = parse(validSha256Recipe());
      expect(recipe.apply.isEmpty, isTrue);
    });

    test('an empty apply object is also empty', () {
      final recipe = parse(validSha256Recipe(apply: const {}));
      expect(recipe.apply.isEmpty, isTrue);
    });

    test('rejects apply that is not an object', () {
      expectRejected({...validSha256Recipe(), 'apply': 'do-stuff'});
    });
  });

  group('notes and source', () {
    test('both are optional and pass through verbatim', () {
      final recipe = parse({
        ...validSha256Recipe(),
        'notes': 'works great',
        'source': 'https://example.com',
      });
      expect(recipe.notes, 'works great');
      expect(recipe.source, 'https://example.com');
    });

    test('rejects a non-string notes', () {
      expectRejected({...validSha256Recipe(), 'notes': 123});
    });

    test('rejects a non-string source', () {
      expectRejected({...validSha256Recipe(), 'source': 123});
    });
  });

  test('every problem is reported, not just the first', () {
    try {
      parse({
        'id': '-bad',
        'match': <String, dynamic>{},
        'apply': {
          'tricks': ['-rf'],
          'dxvk': 'nope',
        },
      });
      fail('expected RecipeValidationError');
    } on RecipeValidationError catch (error) {
      expect(error.messages.length, greaterThanOrEqualTo(4));
    }
  });

  test('an unknown extra top-level field does not fail validation', () {
    final recipe = parse({...validSha256Recipe(), 'extra': 'whatever'});
    expect(recipe.id, 'some-app-1.0');
  });
}
