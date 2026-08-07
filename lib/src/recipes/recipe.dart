import 'package:winbridge/src/run/winetricks.dart' show WinetricksVerb;
import 'package:winbridge/winbridge.dart';

/// One JSON file's worth of "how to run this installer" — never code, always
/// data. See docs/recipes.md for the format and how to contribute one.
///
/// `apply.tricks` is typed as [WinetricksVerb] rather than `String`: verb
/// validation is the run module's rule (`^[a-z0-9._+][a-z0-9._+-]*$`), and
/// reusing its own type here means there is exactly one place that rule is
/// written down, not two copies that could drift apart. This is the one-way
/// import into `lib/src/run/` the M5 brief calls out for review.
class Recipe {
  const Recipe({
    required this.id,
    required this.match,
    required this.apply,
    required this.notes,
    required this.source,
    required this.sourcePath,
    required this.sourceKind,
  });

  /// A stable slug, safe as a file-name component (see [isSafeNameComponent])
  /// even though nothing currently splices it into a path — recipes are young
  /// enough that something will, eventually, and validating it now costs
  /// nothing.
  final String id;

  final RecipeMatch match;
  final RecipeApply apply;

  /// Free text. Never validated beyond "is a string" — it is shown to a
  /// human, never spliced into a command.
  final String? notes;

  /// Where the recipe's author says they got this from. Same treatment as
  /// [notes]: display only.
  final String? source;

  /// Absolute path to the file this recipe was loaded from, for error
  /// messages and `recipe list`.
  final String sourcePath;

  final RecipeSourceKind sourceKind;

  /// Parses and validates one recipe. Throws [RecipeValidationError] naming
  /// every problem found — never just the first — so a contributor fixing a
  /// rejected recipe does not have to run validation once per mistake.
  static Recipe fromJson(
    Map<String, dynamic> json, {
    required String sourcePath,
    required RecipeSourceKind sourceKind,
  }) {
    final errors = <String>[];

    final rawId = json['id'];
    String? id;
    if (rawId is! String || rawId.isEmpty) {
      errors.add('"id" must be a non-empty string');
    } else if (!isSafeNameComponent(rawId)) {
      errors.add('"id" ($rawId) is not a safe identifier — letters, digits, '
          '`.`, `-`, `_`, no leading dash, no path separators');
    } else {
      id = rawId;
    }

    final match = _parseMatch(json['match'], errors);
    final apply = _parseApply(json['apply'], errors);
    final notes = _optionalString(json, 'notes', errors);
    final source = _optionalString(json, 'source', errors);

    if (errors.isNotEmpty) {
      throw RecipeValidationError(sourcePath, errors);
    }

    return Recipe(
      id: id!,
      match: match!,
      apply: apply!,
      notes: notes,
      source: source,
      sourcePath: sourcePath,
      sourceKind: sourceKind,
    );
  }

  static RecipeMatch? _parseMatch(Object? raw, List<String> errors) {
    if (raw is! Map) {
      errors.add('"match" must be an object');
      return null;
    }
    final hasSha256 = raw.containsKey('sha256');
    final hasFileName = raw.containsKey('fileName');
    final hasSizeBytes = raw.containsKey('sizeBytes');

    if (hasSha256 && (hasFileName || hasSizeBytes)) {
      errors.add('"match" must be either {"sha256"} or '
          '{"fileName", "sizeBytes"}, not both');
      return null;
    }

    if (hasSha256) {
      final value = raw['sha256'];
      if (value is! String || !RecipeMatch.sha256Pattern.hasMatch(value)) {
        errors.add('"match.sha256" must be exactly 64 lowercase hex '
            'characters');
        return null;
      }
      return RecipeMatch.sha256(value.toLowerCase());
    }

    if (hasFileName != hasSizeBytes) {
      errors.add('"match" using fileName/sizeBytes needs both fields');
      return null;
    }
    if (!hasFileName && !hasSizeBytes) {
      errors.add('"match" needs either "sha256" or "fileName"+"sizeBytes"');
      return null;
    }

    final fileName = raw['fileName'];
    if (fileName is! String || !isSafeNameComponent(fileName)) {
      errors.add('"match.fileName" must be a single safe file-name '
          'component, e.g. "Setup.exe"');
      return null;
    }
    final sizeBytes = raw['sizeBytes'];
    if (sizeBytes is! int || sizeBytes <= 0) {
      errors.add('"match.sizeBytes" must be a positive integer');
      return null;
    }
    return RecipeMatch.fileNameAndSize(fileName: fileName, sizeBytes: sizeBytes);
  }

  static RecipeApply? _parseApply(Object? raw, List<String> errors) {
    if (raw == null) return RecipeApply.empty;
    if (raw is! Map) {
      errors.add('"apply" must be an object');
      return null;
    }

    final tricks = <WinetricksVerb>[];
    final rawTricks = raw['tricks'];
    if (rawTricks != null) {
      if (rawTricks is! List) {
        errors.add('"apply.tricks" must be a list of strings');
      } else {
        for (final entry in rawTricks) {
          if (entry is String && WinetricksVerb.isValid(entry)) {
            tricks.add(WinetricksVerb.parse(entry));
          } else {
            errors.add('"apply.tricks" has an invalid verb: '
                '${_display(entry)}');
          }
        }
      }
    }

    final dllOverrides = <String, String>{};
    final rawOverrides = raw['dllOverrides'];
    if (rawOverrides != null) {
      if (rawOverrides is! Map) {
        errors.add('"apply.dllOverrides" must be an object');
      } else {
        rawOverrides.forEach((key, value) {
          final dll = '$key';
          if (!RecipeApply.dllNamePattern.hasMatch(dll)) {
            errors.add('"apply.dllOverrides" has an invalid dll name: '
                '${_display(key)}');
            return;
          }
          if (value is! String || !RecipeApply.validOverrideValues.contains(value)) {
            errors.add('"apply.dllOverrides.$dll" must be one of '
                '${RecipeApply.validOverrideValues.map((v) => '"$v"').join(', ')}');
            return;
          }
          dllOverrides[dll] = value;
        });
      }
    }

    var dxvk = false;
    final rawDxvk = raw['dxvk'];
    if (rawDxvk != null) {
      if (rawDxvk is! bool) {
        errors.add('"apply.dxvk" must be a boolean');
      } else {
        dxvk = rawDxvk;
      }
    }

    return RecipeApply(
      tricks: List.unmodifiable(tricks),
      dllOverrides: Map.unmodifiable(dllOverrides),
      dxvk: dxvk,
    );
  }

  static String? _optionalString(
    Map<String, dynamic> json,
    String key,
    List<String> errors,
  ) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String) {
      errors.add('"$key", if present, must be a string');
      return null;
    }
    return value;
  }

  static String _display(Object? value) =>
      value == null ? 'null' : '${value.runtimeType} $value';

  @override
  String toString() => '$id (${sourceKind.label}, $sourcePath)';
}

/// Where a [Recipe] came from. `user` recipes override `bundled` ones of the
/// same id — see `recipe_loader.dart`.
enum RecipeSourceKind {
  bundled('bundled'),
  user('user');

  const RecipeSourceKind(this.label);

  final String label;
}

/// How a recipe is keyed to an installer. Exactly one of the two shapes the
/// M5 brief specifies: a sha256 digest (authoritative), or a file name plus
/// exact size (an exact-match fallback for the installers nobody has hashed
/// yet). See `recipe_matcher.dart` for why sha256 always wins when both kinds
/// of recipe exist for the same file.
class RecipeMatch {
  const RecipeMatch.sha256(String value)
      : sha256 = value,
        fileName = null,
        sizeBytes = null,
        kind = MatchKind.sha256;

  const RecipeMatch.fileNameAndSize({
    required this.fileName,
    required this.sizeBytes,
  })  : sha256 = null,
        kind = MatchKind.fileNameAndSize;

  /// Lowercase hex, exactly 64 characters. Set only when [kind] is
  /// [MatchKind.sha256].
  final String? sha256;

  /// Set only when [kind] is [MatchKind.fileNameAndSize].
  final String? fileName;
  final int? sizeBytes;

  final MatchKind kind;

  static final RegExp sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');
}

enum MatchKind {
  sha256('sha256'),
  fileNameAndSize('file name + size');

  const MatchKind(this.label);

  final String label;
}

/// What a recipe does to a prefix once it matches. All optional; a recipe
/// documenting "this app just works" is `RecipeApply.empty`.
class RecipeApply {
  const RecipeApply({
    required this.tricks,
    required this.dllOverrides,
    required this.dxvk,
  });

  static const empty = RecipeApply(tricks: [], dllOverrides: {}, dxvk: false);

  final List<WinetricksVerb> tricks;

  /// dll name (lowercase, `[a-z0-9._-]+`) to override value, one of
  /// [validOverrideValues].
  final Map<String, String> dllOverrides;

  final bool dxvk;

  bool get isEmpty => tricks.isEmpty && dllOverrides.isEmpty && !dxvk;

  static final RegExp dllNamePattern = RegExp(r'^[a-z0-9._-]+$');

  /// `WINEDLLOVERRIDES`' own closed set: native, builtin, native-then-builtin,
  /// builtin-then-native, or disabled entirely (empty).
  static const validOverrideValues = {'n', 'b', 'n,b', 'b,n', ''};
}

/// One recipe file that failed validation. Carries every problem found, not
/// just the first — see [Recipe.fromJson].
class RecipeValidationError implements Exception {
  const RecipeValidationError(this.path, this.messages);

  final String path;
  final List<String> messages;

  @override
  String toString() => '$path:\n${messages.map((m) => '  $m').join('\n')}';
}
