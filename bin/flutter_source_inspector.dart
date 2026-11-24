import 'dart:io';

import 'package:flutter_source_inspector/flutter_source_inspector.dart';

Future<void> main(List<String> arguments) async {
  try {
    await runFlutterSourceInspector(arguments);
  } on FormatException catch (error) {
    stderr.writeln('flutter_source_inspector: ${error.message}');
    stderr.write(flutterSourceInspectorUsage);
    exitCode = 64;
  }
}
