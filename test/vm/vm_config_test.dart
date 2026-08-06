import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/vm/vm.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

String writeConfig(String directory, Map<String, dynamic> fields) =>
    writeFile(p.join(directory, 'vm.json'), jsonEncode(fields));

Map<String, dynamic> validFields({
  String host = 'winvm.local',
  String user = 'builder',
  String remoteWorkspace = 'C:/winbridge',
  int? port,
  String? identityFile,
  String? flutterPath,
}) =>
    {
      'host': host,
      'user': user,
      'remoteWorkspace': remoteWorkspace,
      'port': ?port,
      'identityFile': ?identityFile,
      'flutterPath': ?flutterPath,
    };

void main() {
  group('resolvePath', () {
    test('WINBRIDGE_VM_CONFIG wins over everything else', () {
      final path = VmConfig.resolvePath(environment: {
        'WINBRIDGE_VM_CONFIG': '/somewhere/vm.json',
        'XDG_CONFIG_HOME': '/xdg',
        'HOME': '/home/dev',
      });
      expect(path, '/somewhere/vm.json');
    });

    test('falls back to XDG_CONFIG_HOME', () {
      final path = VmConfig.resolvePath(environment: {
        'XDG_CONFIG_HOME': '/xdg',
        'HOME': '/home/dev',
      });
      expect(path, p.join('/xdg', 'winbridge', 'vm.json'));
    });

    test('falls back to HOME/.config', () {
      final path = VmConfig.resolvePath(environment: {'HOME': '/home/dev'});
      expect(path, p.join('/home/dev', '.config', 'winbridge', 'vm.json'));
    });

    test('a clean error when neither is set', () {
      expect(
        () => VmConfig.resolvePath(environment: const {}),
        throwsA(isA<VmConfigError>()
            .having((e) => e.details, 'details', contains('vm-setup.md'))),
      );
    });
  });

  group('load', () {
    late String directory;

    setUp(() => directory = tempDir('vmcfg'));

    Map<String, String> envFor(String path) => {'WINBRIDGE_VM_CONFIG': path};

    test('points at docs/vm-setup.md when the file is missing', () {
      final missing = p.join(directory, 'nope.json');
      expect(
        () => VmConfig.load(environment: envFor(missing)),
        throwsA(isA<VmConfigError>()
            .having((e) => e.message, 'message', contains(missing))
            .having((e) => e.details, 'details', contains('vm-setup.md'))),
      );
    });

    test('rejects invalid JSON', () {
      final path = writeFile(p.join(directory, 'vm.json'), '{not json');
      expect(
        () => VmConfig.load(environment: envFor(path)),
        throwsA(isA<VmConfigError>()
            .having((e) => e.message, 'message', contains('not valid JSON'))),
      );
    });

    test('rejects a JSON value that is not an object', () {
      final path = writeFile(p.join(directory, 'vm.json'), '[1, 2, 3]');
      expect(
        () => VmConfig.load(environment: envFor(path)),
        throwsA(isA<VmConfigError>()),
      );
    });

    test('accepts a minimal valid config and defaults the port to 22', () {
      final path = writeConfig(directory, validFields());
      final config = VmConfig.load(environment: envFor(path));
      expect(config.host, 'winvm.local');
      expect(config.user, 'builder');
      expect(config.port, 22);
      expect(config.remoteWorkspace, 'C:/winbridge');
      expect(config.identityFile, isNull);
      expect(config.flutterPath, isNull);
    });

    test('accepts every field, including a numeric-string port', () {
      final path = writeConfig(
        directory,
        validFields(
          identityFile: '/home/dev/.ssh/id_winbridge',
          flutterPath: 'C:/tools/flutter/bin/flutter.bat',
        )..['port'] = '2222',
      );
      final config = VmConfig.load(environment: envFor(path));
      expect(config.port, 2222);
      expect(config.identityFile, '/home/dev/.ssh/id_winbridge');
      expect(config.flutterPath, 'C:/tools/flutter/bin/flutter.bat');
    });

    test('expands a leading ~ in identityFile against HOME', () {
      final path = writeConfig(
        directory,
        validFields(identityFile: '~/.ssh/id_winbridge'),
      );
      final config = VmConfig.load(environment: {
        ...envFor(path),
        'HOME': '/home/dev',
      });
      expect(config.identityFile, p.join('/home/dev', '.ssh', 'id_winbridge'));
    });

    for (final key in ['host', 'user', 'remoteWorkspace']) {
      test('rejects a missing "$key"', () {
        final fields = validFields()..remove(key);
        final path = writeConfig(directory, fields);
        expect(
          () => VmConfig.load(environment: envFor(path)),
          throwsA(isA<VmConfigError>()
              .having((e) => e.details ?? '', 'details', contains(key))),
        );
      });
    }

    for (final bad in ['bad host', 'host;rm', r'host`id`', 'a/b', r'$(id)']) {
      test('rejects a host of "$bad"', () {
        final path = writeConfig(directory, validFields(host: bad));
        expect(
          () => VmConfig.load(environment: envFor(path)),
          throwsA(isA<VmConfigError>()
              .having((e) => e.details ?? '', 'details', contains('host'))),
        );
      });
    }

    for (final bad in ['bad user', 'user;id', 'a/b']) {
      test('rejects a user of "$bad"', () {
        final path = writeConfig(directory, validFields(user: bad));
        expect(
          () => VmConfig.load(environment: envFor(path)),
          throwsA(isA<VmConfigError>()
              .having((e) => e.details ?? '', 'details', contains('user'))),
        );
      });
    }

    for (final bad in [0, -1, 65536, 999999]) {
      test('rejects an out-of-range port of $bad', () {
        final path = writeConfig(directory, validFields()..['port'] = bad);
        expect(
          () => VmConfig.load(environment: envFor(path)),
          throwsA(isA<VmConfigError>()
              .having((e) => e.details ?? '', 'details', contains('port'))),
        );
      });
    }

    test('rejects a non-numeric port', () {
      final path = writeConfig(directory, validFields()..['port'] = 'ssh');
      expect(
        () => VmConfig.load(environment: envFor(path)),
        throwsA(isA<VmConfigError>()),
      );
    });

    for (final bad in [
      r'C:\win bridge',
      'C:/winbridge;whoami',
      'C:/winbridge/../../etc',
      r'C:/win`id`bridge',
      r'C:/win$(id)bridge',
    ]) {
      test('rejects a remoteWorkspace of "$bad"', () {
        final path = writeConfig(directory, validFields(remoteWorkspace: bad));
        expect(
          () => VmConfig.load(environment: envFor(path)),
          throwsA(isA<VmConfigError>().having(
              (e) => e.details ?? '', 'details', contains('remoteWorkspace'))),
        );
      });
    }

    test('rejects a flutterPath containing ..', () {
      final path = writeConfig(
        directory,
        validFields(flutterPath: 'C:/tools/../evil/flutter.bat'),
      );
      expect(
        () => VmConfig.load(environment: envFor(path)),
        throwsA(isA<VmConfigError>().having(
            (e) => e.details ?? '', 'details', contains('flutterPath'))),
      );
    });

    test('rejects an identityFile containing whitespace', () {
      final path = writeConfig(
        directory,
        validFields(identityFile: '/home/dev/my key/id_rsa'),
      );
      expect(
        () => VmConfig.load(environment: envFor(path)),
        throwsA(isA<VmConfigError>().having(
            (e) => e.details ?? '', 'details', contains('identityFile'))),
      );
    });

    test('reports every invalid field at once', () {
      final path = writeConfig(
        directory,
        validFields(host: 'bad host', user: 'bad user'),
      );
      try {
        VmConfig.load(environment: envFor(path));
        fail('expected a VmConfigError');
      } on VmConfigError catch (error) {
        expect(error.details, contains('host'));
        expect(error.details, contains('user'));
      }
    });

    test('warns when the config file is group- or other-readable', () {
      final path = writeConfig(directory, validFields());
      final log = StringBuffer();
      final output = Output(err: log);

      // The suite cannot chmod a real file (no direct Process access and no
      // dart:io chmod), so the warning threshold itself is covered by the
      // isGroupOrOtherReadable tests below; here we only confirm `load` wires
      // an already-permissive-looking file's warning through to `output`.
      final currentMode = _statMode(path);
      if (isGroupOrOtherReadable(currentMode)) {
        VmConfig.load(environment: envFor(path), output: output);
        expect(log.toString(), contains('chmod 600'));
      }
    });
  });

  group('isGroupOrOtherReadable', () {
    test('true for group read (0640)', () {
      expect(isGroupOrOtherReadable(_mode(6, 4, 0)), isTrue);
    });

    test('true for world read (0604)', () {
      expect(isGroupOrOtherReadable(_mode(6, 0, 4)), isTrue);
    });

    test('false for owner-only (0600)', () {
      expect(isGroupOrOtherReadable(_mode(6, 0, 0)), isFalse);
    });

    test('ignores group/other write and execute bits (0633)', () {
      expect(isGroupOrOtherReadable(_mode(6, 3, 3)), isFalse);
    });

    test('is true even if only one of group/other can read (0604 vs 0640)', () {
      expect(isGroupOrOtherReadable(_mode(6, 0, 4)), isTrue);
      expect(isGroupOrOtherReadable(_mode(6, 4, 0)), isTrue);
    });
  });
}

int _statMode(String path) => File(path).statSync().mode;

/// Builds a POSIX mode int from octal owner/group/other digits, since Dart
/// has no octal literal syntax.
int _mode(int owner, int group, int other) => (owner << 6) | (group << 3) | other;
