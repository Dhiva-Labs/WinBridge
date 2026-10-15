import 'package:winbridge/winbridge.dart';

/// A host WinBridge has no builds for (neither x64 nor arm64).
///
/// `WinBridgeConfig` detects the real architecture whenever none is passed, so
/// a subclass is the only way to describe a machine that is not either of the
/// two the test runners themselves are.
class UnknownCpuConfig extends WinBridgeConfig {
  UnknownCpuConfig({super.environment});

  @override
  HostArch? get hostArch => null;
}
