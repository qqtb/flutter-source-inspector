import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'monitor.dart';
import 'vm_service.dart';

const flutterSourceInspectorUsage = '''
Inspect Flutter widgets from the terminal and print their source locations.

Usage:
  flutter_source_inspector [options] [-- flutter run options]
  flutter run | flutter_source_inspector [options]

Inspector options:
  --project-root=<path>  App source root. Defaults to lib.
  --package-name=<name>  Dart package name. Defaults to the source root's
                         parent directory name.
  --editor=<executable>  Open each selection with this executable.
  --editor-arg=<arg>     Repeat to pass arguments using {file}, {line}, and
                         {column}. Appends the file if no arg uses {file}.
  -h, --help             Show this help.

Key commands (when launched directly):
  z                      Toggle 5x slow animations.

Arguments after -- are passed to flutter run in direct mode.
''';

const _outputDecoder = Utf8Decoder(allowMalformed: true);

Future<void> runFlutterSourceInspector(List<String> arguments) async {
  final separator = arguments.indexOf('--');
  final inspectorArguments = separator < 0
      ? arguments
      : arguments.sublist(0, separator);
  final flutterArguments = separator < 0
      ? const <String>[]
      : arguments.sublist(separator + 1);
  if (inspectorArguments.any(
    (argument) => argument == '-h' || argument == '--help',
  )) {
    stdout.write(flutterSourceInspectorUsage);
    return;
  }
  final options = FlutterSourceInspectorOptions.parse(inspectorArguments);
  final monitor = FlutterSourceInspectorMonitor(
    projectRoot: options.projectRoot,
    packageName: options.packageName,
    writeStatus: stdout.writeln,
    writeError: stderr.writeln,
    openSource: options.openSource,
  );

  if (stdin.hasTerminal) {
    await _runFlutter(monitor, flutterArguments);
  } else {
    await _monitorPipedFlutterOutput(monitor);
  }
}

Stream<String> _outputLines(Stream<List<int>> output) =>
    output.transform(_outputDecoder).transform(const LineSplitter());

void _connectFromOutput(FlutterSourceInspectorMonitor monitor, String line) {
  final serviceUri = vmServiceUriFromFlutterOutput(line);
  if (serviceUri != null) {
    monitor.connect(serviceUri);
  }
}

Future<void> _monitorPipedFlutterOutput(
  FlutterSourceInspectorMonitor monitor,
) async {
  stderr.writeln(
    '[flutter-source-inspector] Pipeline mode: the z shortcut is unavailable. '
    'Run flutter_source_inspector directly to enable tool key commands.',
  );
  final interrupt = _keepProcessAliveOnInterrupt();
  try {
    await for (final line in _outputLines(stdin)) {
      stdout.writeln(line);
      _connectFromOutput(monitor, line);
    }
  } finally {
    await interrupt?.cancel();
    await monitor.close();
  }
}

StreamSubscription<ProcessSignal>? _keepProcessAliveOnInterrupt() {
  if (Platform.isWindows) {
    return null;
  }
  // Ctrl-C reaches both processes in the terminal's foreground process group.
  // Stay alive to drain Flutter's output rather than closing its output pipe.
  return ProcessSignal.sigint.watch().listen((_) {});
}

Future<void> _runFlutter(
  FlutterSourceInspectorMonitor monitor,
  List<String> flutterArguments,
) async {
  stdout.write('''
Flutter Source Inspector key commands:
  z  Toggle 5x slow animations

Flutter key commands (forwarded):
  i  Toggle widget inspector
  r  Hot reload
  R  Hot restart
  h  Show all Flutter commands
  q  Quit

''');

  final process = await Process.start('flutter', ['run', ...flutterArguments]);
  final interrupt = _keepProcessAliveOnInterrupt();
  final outputDone = _outputLines(
    process.stdout.map((bytes) {
      stdout.add(bytes);
      return bytes;
    }),
  ).forEach((line) => _connectFromOutput(monitor, line));
  final errorDone = process.stderr.forEach(stderr.add);

  final oldLineMode = stdin.lineMode;
  final oldEchoMode = stdin.echoMode;
  stdin.echoMode = false;
  stdin.lineMode = false;
  final input = stdin.listen((bytes) {
    final forwarded = <int>[];
    for (final byte in bytes) {
      if (byte == 0x7a) {
        unawaited(monitor.toggleSlowAnimations());
      } else {
        forwarded.add(byte);
      }
    }
    if (forwarded.isNotEmpty) {
      process.stdin.add(forwarded);
    }
  });

  try {
    final childExitCode = await process.exitCode;
    exitCode = childExitCode;
    await Future.wait([outputDone, errorDone]);
  } finally {
    try {
      // Canceling the stdin subscription can close the terminal descriptor.
      stdin.lineMode = oldLineMode;
      stdin.echoMode = oldEchoMode;
    } on StdinException {
      // The terminal may already have disconnected.
    }
    await input.cancel();
    await interrupt?.cancel();
    await process.stdin.close();
    await monitor.close();
  }
}

class FlutterSourceInspectorOptions {
  const FlutterSourceInspectorOptions({
    required this.projectRoot,
    required this.packageName,
    this.openSource,
  });

  final Uri projectRoot;
  final String packageName;
  final SourceOpener? openSource;

  static FlutterSourceInspectorOptions parse(List<String> arguments) {
    var projectRoot = 'lib';
    String? packageName;
    String? editor;
    final editorArguments = <String>[];
    for (final argument in arguments) {
      if (argument.startsWith('--project-root=')) {
        projectRoot = argument.substring('--project-root='.length);
        if (projectRoot.isEmpty) {
          throw const FormatException('--project-root requires a path.');
        }
      } else if (argument.startsWith('--package-name=')) {
        packageName = argument.substring('--package-name='.length);
        if (packageName.isEmpty) {
          throw const FormatException('--package-name requires a name.');
        }
      } else if (argument.startsWith('--editor=')) {
        if (editor != null) {
          throw const FormatException('--editor can only be set once.');
        }
        editor = argument.substring('--editor='.length);
        if (editor.trim().isEmpty) {
          throw const FormatException('--editor requires an executable.');
        }
      } else if (argument.startsWith('--editor-arg=')) {
        editorArguments.add(argument.substring('--editor-arg='.length));
      } else if (argument == '--hot-reload-on-save' ||
          argument.startsWith('--exclude=')) {
        // Removed options remain accepted as no-ops for existing scripts.
      } else {
        throw FormatException('Unknown argument: $argument');
      }
    }

    if (editor == null && editorArguments.isNotEmpty) {
      throw const FormatException('--editor-arg requires --editor.');
    }

    final projectRootDirectory = Directory(projectRoot).absolute;
    if (packageName == null) {
      final names = projectRootDirectory.parent.uri.pathSegments.where(
        (segment) => segment.isNotEmpty,
      );
      if (names.isEmpty) {
        throw const FormatException(
          'Could not infer a package name. Pass --package-name=<name>.',
        );
      }
      packageName = names.last;
    }
    return FlutterSourceInspectorOptions(
      projectRoot: projectRootDirectory.uri,
      packageName: packageName,
      openSource: editor == null
          ? null
          : _sourceOpener(editor, editorArguments),
    );
  }
}

final _editorPlaceholder = RegExp(r'\{(file|line|column)\}');

SourceOpener _sourceOpener(String executable, List<String> templates) {
  final appendFile = !templates.any((arg) => arg.contains('{file}'));
  return (file, line, column) async {
    final values = {'file': file, 'line': '$line', 'column': '$column'};
    final arguments = [
      for (final template in templates)
        template.replaceAllMapped(_editorPlaceholder, (m) => values[m[1]]!),
      if (appendFile) file,
    ];
    final result = await Process.run(executable, arguments);
    if (result.exitCode != 0) {
      final error = result.stderr.toString().trim();
      throw ProcessException(
        executable,
        arguments,
        error.isEmpty ? 'Exited with code ${result.exitCode}' : error,
        result.exitCode,
      );
    }
  };
}
