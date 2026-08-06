import 'package:test/test.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

const _echo = '/bin/echo';
const _env = '/usr/bin/env';
const _pwd = '/bin/pwd';
const _false = '/bin/false';

void main() {
  final runner = ProcessRunner();

  group('argv is never a shell command', () {
    test('substitutions and operators come back literal', () async {
      // If any part of the stack handed this to a shell, `$(whoami)` would be
      // replaced, `;` would split the command, and `rm` would be reached.
      const hostile = r'$(whoami) `id` && echo pwned; rm -rf / | tee "x" > y';
      final result = await runner.run(_echo, [hostile]);

      expect(result.ok, isTrue);
      expect(result.stdout.trimRight(), hostile);
    });

    test('arguments with spaces stay one argument', () async {
      final result = await runner.run(_echo, ['one two   three', 'four']);
      expect(result.stdout.trimRight(), 'one two   three four');
    });

    test('quotes, backslashes and newlines survive unchanged', () async {
      const argument = 'a"b\'c\\d\te';
      final result = await runner.run(_echo, ['-n', argument]);
      expect(result.stdout, argument);
    });

    test('a leading tilde is not expanded', () async {
      final result = await runner.run(_echo, ['-n', r'~/secrets/*']);
      expect(result.stdout, r'~/secrets/*');
    });

    test('glob characters are not expanded', () async {
      final result = await runner.run(_echo, ['-n', '*'], workingDirectory: '/');
      expect(result.stdout, '*');
    });
  });

  group('results', () {
    test('exit codes are reported, not thrown', () async {
      final result = await runner.run(_false, const []);
      expect(result.ok, isFalse);
      expect(result.exitCode, 1);
    });

    test('stdout and stderr are captured separately', () async {
      final result = await runner.run('/bin/ls', ['/winbridge/nonexistent']);
      expect(result.ok, isFalse);
      expect(result.stderr, isNotEmpty);
      expect(result.stdout, isEmpty);
      expect(result.diagnostics, result.stderr);
    });

    test('diagnostics falls back to stdout', () async {
      final result = await runner.run(_echo, ['hello']);
      expect(result.diagnostics.trim(), 'hello');
    });

    test('duration is measured', () async {
      final result = await runner.run(_echo, ['x']);
      expect(result.duration, greaterThanOrEqualTo(Duration.zero));
    });
  });

  group('working directory', () {
    test('is honoured', () async {
      final directory = tempDir();
      final result = await runner.run(_pwd, const [],
          workingDirectory: directory);
      expect(realPath(result.stdout.trim()), realPath(directory));
    });

    test('defaults to the current directory', () async {
      final result = await runner.run(_pwd, const []);
      expect(realPath(result.stdout.trim()), realPath('.'));
    });

    test('a missing one is a clean failure', () async {
      expect(
        () => runner.run(_pwd, const [], workingDirectory: '/no/such/dir'),
        throwsA(isA<BuildFailure>()
            .having((e) => e.message, 'message', contains('/no/such/dir'))),
      );
    });
  });

  group('environment overlay', () {
    test('adds variables without dropping the parent environment', () async {
      final result = await runner.run(
        _env,
        const [],
        environment: {'WINBRIDGE_TEST_VAR': 'overlay-value'},
      );
      expect(result.stdout, contains('WINBRIDGE_TEST_VAR=overlay-value'));
      expect(result.stdout, contains('PATH='));
    });

    test('overrides an inherited variable', () async {
      final result = await runner.run(
        _env,
        const [],
        environment: {'HOME': '/winbridge/fake-home'},
      );
      expect(result.stdout, contains('HOME=/winbridge/fake-home'));
    });

    test('rejects malformed variable names', () async {
      // A NUL would truncate the KEY=VALUE string execve builds; whitespace
      // makes a variable no shell or tool can address.
      for (final key in ['A=B', '', 'A B', 'A\tB', 'A\u0000B']) {
        expect(
          () => runner.run(_echo, const [], environment: {key: 'c'}),
          throwsArgumentError,
          reason: 'accepted "$key" as a variable name',
        );
      }
    });

    test('values never reach the log', () async {
      final log = StringBuffer();
      final verbose = ProcessRunner(output: Output(verbose: true, out: log));
      await verbose.run(
        _echo,
        ['-n', ''],
        environment: {'WINBRIDGE_TOKEN': 'super-secret-value'},
      );
      expect(log.toString(), contains('WINBRIDGE_TOKEN'));
      expect(log.toString(), isNot(contains('super-secret-value')));
    });
  });

  group('executables', () {
    test('must be absolute so nothing resolves via the ambient PATH', () async {
      expect(() => runner.run('echo', ['hi']), throwsArgumentError);
      expect(() => runner.run('./echo', ['hi']), throwsArgumentError);
    });

    test('a missing executable is a clean failure', () async {
      expect(
        () => runner.run('/winbridge/not-a-real-binary', const []),
        throwsA(isA<BuildFailure>().having(
            (e) => e.message, 'message', contains('not-a-real-binary'))),
      );
    });
  });

  group('runOrThrow', () {
    test('returns the result on success', () async {
      final result = await runner.runOrThrow(_echo, ['ok']);
      expect(result.stdout.trim(), 'ok');
    });

    test('throws ProcessFailure carrying the exit code and output', () async {
      expect(
        () => runner.runOrThrow('/bin/ls', ['/winbridge/nonexistent'],
            what: 'listing'),
        throwsA(isA<ProcessFailure>()
            .having((e) => e.message, 'message', contains('listing'))
            .having((e) => e.message, 'message', contains('exit'))
            .having((e) => e.processExitCode, 'processExitCode', isNot(0))
            .having((e) => e.details, 'details', isNotNull)
            .having((e) => e.exitCode, 'exitCode', 1)),
      );
    });
  });

  group('verbose output', () {
    test('streams the command and the child output', () async {
      final log = StringBuffer();
      final verbose = ProcessRunner(output: Output(verbose: true, out: log));
      await verbose.run(_echo, ['streamed line']);

      final text = log.toString();
      expect(text, contains(_echo));
      expect(text, contains("'streamed line'"), reason: 'quoted for display');
      expect(text, contains('streamed line\n'));
      expect(text, contains('exit 0'));
    });

    test('stays quiet otherwise', () async {
      final log = StringBuffer();
      final quiet = ProcessRunner(output: Output(out: log));
      await quiet.run(_echo, ['nothing to see']);
      expect(log.toString(), isEmpty);
    });

    test('child stderr is streamed to stderr', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final verbose =
          ProcessRunner(output: Output(verbose: true, out: out, err: err));
      await verbose.run('/bin/ls', ['/winbridge/nonexistent']);
      expect(err.toString(), isNotEmpty);
    });
  });

  test('commandLine is display-only and quotes hostile arguments', () async {
    final result = await runner.run(_echo, ['-n', r'a b; rm -rf /']);
    expect(result.commandLine, "$_echo -n 'a b; rm -rf /'");
  });
}
