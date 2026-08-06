import 'package:test/test.dart';
import 'package:winbridge/winbridge.dart';

void main() {
  group('name', () {
    test('is read from the top level', () {
      expect(Pubspec.parse('name: my_app\n').name, 'my_app');
    });

    test('tolerates quotes', () {
      expect(Pubspec.parse('name: "my_app"\n').name, 'my_app');
      expect(Pubspec.parse("name: 'my_app'\n").name, 'my_app');
    });

    test('ignores a nested name key', () {
      const source = 'name: outer\ndependencies:\n  thing:\n    name: inner\n';
      expect(Pubspec.parse(source).name, 'outer');
    });

    test('is null when absent', () {
      expect(Pubspec.parse('dependencies:\n  args: ^2.0.0\n').name, isNull);
    });
  });

  group('flutter detection', () {
    test('finds an sdk dependency', () {
      const source = 'name: a\ndependencies:\n  flutter:\n    sdk: flutter\n';
      expect(Pubspec.parse(source).usesFlutter, isTrue);
    });

    test('finds a dev dependency', () {
      const source =
          'name: a\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n';
      expect(Pubspec.parse(source).usesFlutter, isTrue);
    });

    test('finds a top-level flutter section', () {
      expect(Pubspec.parse('name: a\nflutter:\n  assets:\n').usesFlutter,
          isTrue);
    });

    test('is not fooled by a package that merely starts with flutter', () {
      const source = 'name: a\ndev_dependencies:\n  flutter_lints: ^3.0.0\n';
      expect(Pubspec.parse(source).usesFlutter, isFalse);
    });

    test('is not fooled by a dart sdk constraint', () {
      const source = 'name: a\nenvironment:\n  sdk: ^3.8.0\n';
      expect(Pubspec.parse(source).usesFlutter, isFalse);
    });

    test('ignores commented-out dependencies', () {
      const source = 'name: a\ndependencies:\n  # flutter:\n  args: ^2.0.0\n';
      expect(Pubspec.parse(source).usesFlutter, isFalse);
    });

    test('handles CRLF line endings', () {
      const source = 'name: a\r\ndependencies:\r\n  flutter:\r\n';
      final pubspec = Pubspec.parse(source);
      expect(pubspec.usesFlutter, isTrue);
      expect(pubspec.name, 'a');
    });

    test('an empty pubspec is not a flutter project', () {
      expect(Pubspec.parse('').usesFlutter, isFalse);
    });
  });
}
