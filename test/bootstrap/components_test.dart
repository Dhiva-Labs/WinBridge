import 'package:test/test.dart';
import 'package:winbridge/src/bootstrap/components.dart';
import 'package:winbridge/src/run/asset_cache.dart';
import 'package:winbridge/winbridge.dart';

void main() {
  group('every pinned component, on every host architecture', () {
    for (final component in installableComponents) {
      for (final arch in HostArch.values) {
        final asset = component.assetFor(arch)!;
        group('${component.id} (${arch.slug})', () {
          test('pins an exact version with a checksum', () {
            expect(asset.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
            expect(asset.version, isNotEmpty);
            expect(asset.url, startsWith('https://'));
          });

          test('the url names the version it claims', () {
            // Catches a bump that changed the constant but not the link.
            expect(asset.url, contains(asset.version));
          });

          test('unpacks to a directory named for the archive', () {
            expect(asset.archiveTopLevel, isNotEmpty);
          });
        });
      }

      group(component.id, () {
        test('says how big the download is before anyone starts it', () {
          for (final arch in HostArch.values) {
            expect(component.downloadSizeFor(arch), isNotEmpty);
            expect(component.downloadSizeFor(arch), matches(RegExp(r'\d')));
          }
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
      for (final arch in HostArch.values) {
        final go = goToolchain.forHost(arch)!;
        final zig = zigToolchain.forHost(arch)!;
        expect(go.root, AssetRoot.toolchains, reason: arch.slug);
        expect(zig.root, AssetRoot.toolchains, reason: arch.slug);
        expect(go.name, 'go', reason: 'resolved by bare name');
        expect(zig.name, 'zig');
      }
    });

    test('zig gets its binary linked into bin/, because it ships it at root',
        () {
      for (final arch in HostArch.values) {
        expect(zigToolchain.forHost(arch)!.exposeBinaries, contains('zig'),
            reason: arch.slug);
        expect(goToolchain.forHost(arch)!.exposeBinaries, isEmpty,
            reason: 'go already ships bin/go');
      }
    });

    test('runtimes keep their version in the directory name', () {
      expect(nsisDistribution.root, AssetRoot.runtimes);
      expect(nsisDistribution.name, contains(nsisDistribution.version));
      for (final arch in HostArch.values) {
        final xwin = xwinTool.forHost(arch)!;
        expect(xwin.name, contains(xwin.version), reason: arch.slug);
      }
    });
  });

  // A compiler is a host binary. The x86-64 Go does not start on an arm64
  // machine, so each pin must name the archive built for its own CPU; the
  // checksum and the URL must never be the same bytes for both.
  group('host-architecture selection', () {
    final hostBinaries = {
      'go': goToolchain,
      'zig': zigToolchain,
      'msvc': xwinTool,
    };

    hostBinaries.forEach((id, assets) {
      test('$id: arm64 and x64 are different downloads', () {
        expect(assets.arm64.url, isNot(assets.x64.url));
        expect(assets.arm64.sha256, isNot(assets.x64.sha256));
      });

      test('$id: each url names its own CPU', () {
        expect(assets.x64.url, anyOf(contains('amd64'), contains('x86_64')));
        expect(assets.arm64.url, anyOf(contains('arm64'), contains('aarch64')));
        expect(assets.arm64.url, isNot(contains('amd64')));
        expect(assets.arm64.url, isNot(contains('x86_64')));
        expect(assets.x64.url, isNot(contains('arm64')));
        expect(assets.x64.url, isNot(contains('aarch64')));
      });

      test('$id: the unpacked directory matches the archive it came from', () {
        expect(assets.arm64.archiveTopLevel,
            anyOf(equals('go'), contains('aarch64')));
        expect(assets.x64.archiveTopLevel,
            anyOf(equals('go'), contains('x86_64')));
      });

      test('$id: assetFor picks by host, and has nothing for an unknown CPU',
          () {
        final component = findComponent(id)!;
        expect(component.assetFor(HostArch.x64), same(assets.x64));
        expect(component.assetFor(HostArch.arm64), same(assets.arm64));
        expect(component.assetFor(null), isNull,
            reason: 'never fall back to the x64 archive');
      });
    });

    test('the x64 pins are unchanged', () {
      // Adding arm64 must not move what an x64 machine downloads.
      expect(goToolchain.x64.url,
          'https://go.dev/dl/go1.26.5.linux-amd64.tar.gz');
      expect(goToolchain.x64.sha256,
          '5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053');
      expect(zigToolchain.x64.url,
          'https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz');
      expect(zigToolchain.x64.sha256,
          '70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00');
      expect(xwinTool.x64.name, 'xwin-0.9.0');
      expect(xwinTool.x64.sha256,
          '31e1033f30608ba6b821d17f1461042bd54c23424813c9b4e9ae15b6d32fa4cd');
    });

    test('the arm64 pins are the publishers\' own checksums', () {
      expect(goToolchain.arm64.url,
          'https://go.dev/dl/go1.26.5.linux-arm64.tar.gz');
      expect(goToolchain.arm64.sha256,
          'fe4789e92b1f33358680864bbe8704289e7bb5fc207d80623c308935bd696d49');
      expect(zigToolchain.arm64.url,
          'https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz');
      expect(zigToolchain.arm64.sha256,
          'ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17');
      expect(xwinTool.arm64.sha256,
          '41466ca41e16fe7fc1b82a67babc7c3811021bf32de354b90b34d8c4edb153e2');
    });

    test('NSIS is the same Windows zip everywhere, and needs Wine', () {
      final nsis = findComponent('nsis')!;
      expect(nsis.assetFor(HostArch.x64), same(nsis.assetFor(HostArch.arm64)));
      expect(nsis.needsWine, isTrue);
      for (final id in ['go', 'zig', 'msvc']) {
        expect(findComponent(id)!.needsWine, isFalse, reason: id);
      }
    });

    test('the arm64 download sizes describe the arm64 archives', () {
      expect(findComponent('go')!.downloadSizeFor(HostArch.arm64), '64 MB');
      expect(findComponent('go')!.downloadSizeFor(HostArch.x64), '67 MB');
      expect(findComponent('zig')!.downloadSizeFor(HostArch.arm64), '51 MB');
      expect(findComponent('zig')!.downloadSizeFor(HostArch.x64), '56 MB');
      expect(findComponent('nsis')!.downloadSizeFor(HostArch.arm64), '2 MB');
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
