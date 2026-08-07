import 'package:test/test.dart';
import 'package:winbridge/src/package/nsis_script.dart';

void main() {
  InstallerSpec specWith({
    String appName = 'hello_c',
    String version = '1.2.3',
    List<String>? files,
  }) =>
      InstallerSpec(
        appName: appName,
        version: version,
        mainExecutable: '/out/hello_c.exe',
        files: files ?? ['/out/hello_c.exe', '/out/data.bin'],
        outputFile: 'hello_c-1.2.3-setup.exe',
      );

  group('generated script', () {
    final script = generateNsisScript(specWith());

    test('names the app and version', () {
      expect(script, contains('!define APPNAME "hello_c"'));
      expect(script, contains('!define APPVERSION "1.2.3"'));
    });

    test('ships every artifact, by file name only', () {
      // NSIS uses `/` to introduce options and runs under Wine, so absolute
      // Unix paths must never appear — makensis is run from the artifact
      // directory instead.
      expect(script, contains('File "hello_c.exe"'));
      expect(script, contains('File "data.bin"'));
      expect(script, isNot(contains('/out/')));
    });

    test('writes the installer next to the script', () {
      expect(script, contains('OutFile "hello_c-1.2.3-setup.exe"'));
    });

    test('installs, registers for Add/Remove, and can uninstall itself', () {
      expect(script, contains('WriteUninstaller'));
      expect(script, contains('CurrentVersion\\Uninstall'));
      expect(script, contains('Section "Uninstall"'));
      expect(script, contains('Delete "\$INSTDIR\\hello_c.exe"'));
      expect(script, contains('Delete "\$INSTDIR\\data.bin"'));
    });

    test('shortcut points at the main executable', () {
      expect(script, contains('CreateShortcut'));
      expect(script, contains('\$INSTDIR\\hello_c.exe'));
    });
  });

  group('escaping', () {
    test('a quote cannot end a string early', () {
      expect(escapeNsis('a"b'), r'a$\"b');
    });

    test('a dollar cannot start an NSIS variable', () {
      expect(escapeNsis(r'a$INSTDIR'), r'a$$INSTDIR');
    });

    test('ordinary names are untouched', () {
      expect(escapeNsis('hello_c'), 'hello_c');
      expect(escapeNsis('My-App.v2'), 'My-App.v2');
    });

    test('a hostile app name cannot break out of its quotes', () {
      final script = generateNsisScript(specWith(appName: r'evil" ; $INSTDIR'));
      // Both dangerous characters are neutralised; nothing unescaped survives.
      expect(script, contains(r'$\"'));
      expect(script, isNot(contains('"evil" ;')));
    });
  });
}
