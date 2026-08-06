import 'package:winbridge/src/vm/vm.dart';
import 'package:winbridge/winbridge.dart';

import 'fake_process_runner.dart';

/// One call [FakeVmTransport] recorded: `run`, `send` or `fetch`.
class RecordedCall {
  const RecordedCall.run(List<String> args)
      : kind = 'run',
        remoteArgs = args,
        localDir = null,
        remoteDir = null;

  const RecordedCall.send(this.localDir, this.remoteDir)
      : kind = 'send',
        remoteArgs = null;

  const RecordedCall.fetch(this.remoteDir, this.localDir)
      : kind = 'fetch',
        remoteArgs = null;

  final String kind;
  final List<String>? remoteArgs;
  final String? localDir;
  final String? remoteDir;
}

/// A [VmTransport] that never touches ssh or rsync. Every call is recorded in
/// order in [calls]; the result for call *n* comes from [results] if
/// [results] is long enough, otherwise a canned success.
class FakeVmTransport implements VmTransport {
  final calls = <RecordedCall>[];
  final List<RunResult> results = [];

  RunResult _next() =>
      calls.length <= results.length ? results[calls.length - 1] : okResult();

  @override
  Future<RunResult> run(List<String> remoteArgs) async {
    calls.add(RecordedCall.run(remoteArgs));
    return _next();
  }

  @override
  Future<RunResult> sendTree(
    String localDir,
    String remoteDir, {
    List<String> excludes = defaultSendExcludes,
  }) async {
    calls.add(RecordedCall.send(localDir, remoteDir));
    return _next();
  }

  @override
  Future<RunResult> fetchTree(String remoteDir, String localDir) async {
    calls.add(RecordedCall.fetch(remoteDir, localDir));
    return _next();
  }
}
