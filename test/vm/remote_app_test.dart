import 'package:test/test.dart';
import 'package:winbridge/src/vm/vm.dart';
import 'package:winbridge/winbridge.dart';

const _config = VmConfig(
  host: 'winvm.local',
  user: 'builder',
  remoteWorkspace: 'C:/winbridge',
  port: 2222,
);

void main() {
  group('remoteAppArguments', () {
    test('the golden argv, in order, for the common case', () {
      final args = remoteAppArguments(const RemoteAppRequest(
        config: _config,
        remoteExecutablePath: 'C:/apps/App/app.exe',
      ));
      expect(args, [
        '/v:winvm.local:2222',
        '/u:builder',
        '/app:program:"C:/apps/App/app.exe"',
        '/cert:tofu',
        '+clipboard',
      ]);
    });

    test('the /app token embeds the path in literal double quotes — this is '
        "FreeRDP's own sub-parsing, not a shell, but it is exactly what the "
        'golden argv proves is present', () {
      final args = remoteAppArguments(const RemoteAppRequest(
        config: _config,
        remoteExecutablePath: 'C:/apps/App/app.exe',
      ));
      final appToken = args.firstWhere((a) => a.startsWith('/app:'));
      expect(appToken, '/app:program:"C:/apps/App/app.exe"');
      expect(appToken, startsWith('/app:program:"'));
      expect(appToken, endsWith('"'));
    });

    test('/sound is appended only when asked for', () {
      final withoutSound = remoteAppArguments(const RemoteAppRequest(
        config: _config,
        remoteExecutablePath: 'C:/apps/App/app.exe',
      ));
      expect(withoutSound, isNot(contains('/sound')));

      final withSound = remoteAppArguments(const RemoteAppRequest(
        config: _config,
        remoteExecutablePath: 'C:/apps/App/app.exe',
        sound: true,
      ));
      expect(withSound.last, '/sound');
      expect(withSound, hasLength(withoutSound.length + 1));
    });

    test('/v combines host and port from config, not any default', () {
      final args = remoteAppArguments(const RemoteAppRequest(
        config: VmConfig(host: 'other.local', user: 'x', remoteWorkspace: 'C:/w'),
        remoteExecutablePath: 'C:/app.exe',
      ));
      expect(args.first, '/v:other.local:22');
    });

    test('never emits a password flag or anything that looks like one', () {
      final args = remoteAppArguments(const RemoteAppRequest(
        config: _config,
        remoteExecutablePath: 'C:/apps/App/app.exe',
      ));
      for (final token in args) {
        expect(token, isNot(startsWith('/p:')));
        expect(token.toLowerCase(), isNot(contains('password')));
      }
    });

    test('always uses /cert:tofu, never /cert:ignore', () {
      final args = remoteAppArguments(const RemoteAppRequest(
        config: _config,
        remoteExecutablePath: 'C:/apps/App/app.exe',
      ));
      expect(args, contains('/cert:tofu'));
      expect(args, isNot(contains('/cert:ignore')));
    });
  });

  group('isValidRemoteExecutablePath', () {
    for (final good in [
      'C:/apps/App/app.exe',
      'C:/App.exe',
      'C:/apps/App-2.0/app_v2.exe',
      'D:/tools/thing.exe',
    ]) {
      test('accepts "$good"', () {
        expect(isValidRemoteExecutablePath(good), isTrue);
      });
    }

    for (final bad in [
      'C:/apps/../../etc/passwd',
      'C:/Program Files/App/app.exe', // spaces — see docs/remoteapp.md
      r'C:\apps\app.exe', // backslashes are not in VmConfig's own charset
      'app.exe; rm -rf /',
      r'C:/apps/$(whoami)/app.exe',
      '',
    ]) {
      test('rejects "$bad"', () {
        expect(isValidRemoteExecutablePath(bad), isFalse);
      });
    }

    test('matches exactly what VmConfig applies to remoteWorkspace — same '
        'charset, same ".." rule, not a restated copy of it', () {
      for (final value in ['C:/winbridge', 'C:/winbridge/..', 'weird chars!!']) {
        expect(isValidRemoteExecutablePath(value), VmConfig.isValidWindowsPath(value));
      }
    });
  });

  group('RemoteAppToolNotFound', () {
    test('names the package to install and points at the docs', () {
      final cause = ToolNotFound(
        remoteAppClientCandidates,
        ['/usr/bin', '/usr/local/bin'],
        reason: 'launches a Windows app from the VM as a seamless window',
      );
      final error = RemoteAppToolNotFound(cause);
      expect(error.exitCode, 1);
      expect(error.message, contains('xfreerdp'));
      expect(error.details, contains('freerdp3-x11'));
      expect(error.details, contains('freerdp2-x11'));
      expect(error.details, contains('docs/remoteapp.md'));
      // The original ToolNotFound's own search-directory detail is not lost.
      expect(error.details, contains('/usr/bin'));
      expect(error.details, contains('/usr/local/bin'));
    });
  });
}
