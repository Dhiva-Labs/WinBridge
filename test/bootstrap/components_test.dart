import 'package:test/test.dart';
import 'package:winbridge/src/bootstrap/components.dart';
import 'package:winbridge/src/run/asset_cache.dart';

void main() {
  group('every pinned component', () {
    for (final component in installableComponents) {
      group(component.id, () {
        test('pins an exact version with a checksum', () {
          expect(component.asset.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
          expect(component.asset.version, isNotEmpty);
          expect(component.asset.url, startsWith('https://'));
        });

        test('the url names the version it claims', () {
          // Catches a bump that changed the constant but not the link.
          expect(component.asset.url, contains(component.asset.version));
        });

        test('says how big the download is before anyone starts it', () {
          expect(component.downloadSize, isNotEmpty);
          expect(component.downloadSize, matches(RegExp(r'\d')));
        });

        test('has a usable summary', () {
          expect(component.summary, isNotEmpty);
        });
      });
    }
  });

  test('ids are unique and lookup works', () {
    final ids = installableComponents.map((c) => c.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
    for (final id in ids) {
      expect(findComponent(id)!.id, id);
    }
    expect(findComponent('nope'), isNull);
  });

  group('install roots', () {
    test('compilers land where ToolResolver looks for them', () {
      // ToolResolver only ever searches toolchains/*/bin.
      expect(goToolchain.root, AssetRoot.toolchains);
      expect(zigToolchain.root, AssetRoot.toolchains);
      expect(goToolchain.name, 'go', reason: 'resolved by bare name');
      expect(zigToolchain.name, 'zig');
    });

    test('zig gets its binary linked into bin/, because it ships it at root',
        () {
      expect(zigToolchain.exposeBinaries, contains('zig'));
      expect(goToolchain.exposeBinaries, isEmpty,
          reason: 'go already ships bin/go');
    });

    test('runtimes keep their version in the directory name', () {
      expect(nsisDistribution.root, AssetRoot.runtimes);
      expect(nsisDistribution.name, contains(nsisDistribution.version));
      expect(xwinTool.name, contains(xwinTool.version));
    });
  });

  group('the Microsoft SDK is treated as the special case it is', () {
    final msvc = findComponent('msvc')!;

    test('states the licence before anything downloads', () {
      expect(msvc.licenceNote, isNotNull);
      expect(msvc.licenceNote!.toLowerCase(), contains('microsoft'));
      expect(msvc.licenceNote!, contains('accept'));
    });

    test('is honest that the real download dwarfs the pinned one', () {
      // The pin is a 3 MB tool; what it fetches is gigabytes, from Microsoft,
      // unpinned. Saying "3 MB" alone would be misleading.
      expect(msvc.downloadSize, contains('GB'));
    });

    test('says what is still needed afterwards', () {
      expect(msvc.followUp, contains('lld-link'));
    });
  });

  test('NSIS is fetched as a zip, not a tarball', () {
    expect(nsisDistribution.archiveFormat, ArchiveFormat.zip);
    expect(nsisDistribution.archiveTopLevel, 'nsis-3.12');
  });
}
