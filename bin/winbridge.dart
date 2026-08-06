import 'dart:io';

import 'package:winbridge/src/cli/runner.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await WinBridgeRunner().execute(arguments);
}
