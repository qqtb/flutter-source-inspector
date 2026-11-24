import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_source_inspector/flutter_source_inspector.dart';
import 'package:test/test.dart';

void main() {
  final projectRoot = Directory('/work/project-live-new/client/lib').uri;
  const packageName = 'client';

  test('finds native and web VM service URLs in Flutter output', () {
    expect(
      vmServiceUriFromFlutterOutput(
        'The Dart VM service is listening on http://127.0.0.1:51000/token=/',
      ),
      Uri.parse('http://127.0.0.1:51000/token=/'),
    );
    expect(
      vmServiceUriFromFlutterOutput(
        'A Dart VM Service on Chrome is available at: '
        '\x1b[32mhttp://127.0.0.1:52000/web=/\x1b[0m',
      ),
      Uri.parse('http://127.0.0.1:52000/web=/'),
    );
    expect(
      vmServiceUriFromFlutterOutput(
        'DevTools is available at: http://localhost',
      ),
      isNull,
    );
  });

  test('converts an authenticated HTTP service URL to WebSocket', () {
    expect(
      vmServiceWebSocketUri(Uri.parse('http://127.0.0.1:51000/token=/')),
      Uri.parse('ws://127.0.0.1:51000/token=/ws'),
    );
  });

  test('accepts app sources and rejects dependency sources', () {
    expect(
      sourceIsWithinProject(
        'file:///work/project-live-new/client/lib/components/example.dart',
        projectRoot,
        packageName,
      ),
      isTrue,
    );
    expect(
      sourceIsWithinProject(
        'file:///Users/dev/.pub-cache/material_ui/lib/src/circle_avatar.dart',
        projectRoot,
        packageName,
      ),
      isFalse,
    );
    expect(
      sourceIsWithinProject(
        'org-dartlang-app:///lib/components/example.dart',
        projectRoot,
        packageName,
      ),
      isTrue,
    );
  });

  test('formats app source URIs as absolute paths', () {
    expect(
      terminalSourcePath(
        'file:///work/project-live-new/client/lib/components/example.dart',
        projectRoot,
        packageName,
      ),
      '/work/project-live-new/client/lib/components/example.dart',
    );
    expect(
      terminalSourcePath(
        'package:client/components/example.dart',
        projectRoot,
        packageName,
      ),
      '/work/project-live-new/client/lib/components/example.dart',
    );
    expect(
      terminalSourcePath(
        'org-dartlang-app:///lib/components/example.dart',
        projectRoot,
        packageName,
      ),
      '/work/project-live-new/client/lib/components/example.dart',
    );
  });

  test('decodes virtual paths and rejects paths outside the source root', () {
    expect(
      terminalSourcePath(
        'org-dartlang-app:///lib/my%20widgets/home.dart',
        projectRoot,
        packageName,
      ),
      '/work/project-live-new/client/lib/my widgets/home.dart',
    );
    for (final source in [
      'file:///work/project-live-new/client/lib_extra/home.dart',
      'https://example.com/work/project-live-new/client/lib/home.dart',
      'package:another_package/home.dart',
      'package:client/..%2foutside.dart',
      'org-dartlang-app:///test/home.dart',
    ]) {
      expect(
        sourceIsWithinProject(source, projectRoot, packageName),
        isFalse,
        reason: source,
      );
    }
  });

  test('leaves editor opening disabled unless explicitly configured', () {
    final options = FlutterSourceInspectorOptions.parse([
      '--project-root=lib',
      '--package-name=example_app',
      '--hot-reload-on-save',
      '--exclude=generated',
    ]);
    expect(options.packageName, 'example_app');
    expect(options.openSource, isNull);
    for (final invalid in [
      ['--unknown'],
      ['--package-name='],
      ['--project-root='],
      ['--editor='],
      ['--editor-arg={file}'],
      ['--editor=zed', '--editor=code'],
    ]) {
      expect(
        () => FlutterSourceInspectorOptions.parse(invalid),
        throwsFormatException,
        reason: invalid.toString(),
      );
    }
  });

  test('runs any configured editor with separate location arguments', () async {
    final directory = await Directory.systemTemp.createTemp(
      'inspector editor ',
    );
    addTearDown(() => directory.delete(recursive: true));
    final script = File.fromUri(directory.uri.resolve('editor.dart'));
    final invocation = File.fromUri(directory.uri.resolve('arguments.json'));
    await script.writeAsString('''
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  File(args.first).writeAsStringSync(jsonEncode(args.sublist(1)));
}
''');
    final editor = [
      '--editor=${Platform.resolvedExecutable}',
      '--editor-arg=${script.path}',
      '--editor-arg=${invocation.path}',
    ];
    const file = '/work/my widgets/Widget {line} & friends.dart';
    final custom = FlutterSourceInspectorOptions.parse([
      ...editor,
      '--editor-arg=--goto',
      '--editor-arg={file}:{line}:{column}',
    ]);
    await custom.openSource!(file, 42, 7);
    expect(jsonDecode(await invocation.readAsString()), [
      '--goto',
      '$file:42:7',
    ]);

    final fallback = FlutterSourceInspectorOptions.parse(editor);
    await fallback.openSource!(file, 42, 7);
    expect(jsonDecode(await invocation.readAsString()), [file]);
  });

  test('fails pending and new RPC calls when the VM disconnects', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requestReceived = Completer<WebSocket>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((_) => requestReceived.complete(socket));
    });
    final socket = await WebSocket.connect('ws://127.0.0.1:${server.port}/ws');
    final client = VmServiceClient(socket, onEvent: (_) {});
    addTearDown(client.close);

    final pending = expectLater(client.call('getVM'), throwsStateError);
    final peer = await requestReceived.future;
    await peer.close();
    await pending;
    await expectLater(client.call('getVM'), throwsStateError);
  });

  test('reports selections and reattaches after restart', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final statuses = <String>[];
    final errors = <String>[];
    final configuredRoots = <String>[];
    final listenedStreams = <String>[];
    final timeDilations = <(String, String)>[];
    final openedSources = <({String path, int line, int column})>[];
    final socketReady = Completer<WebSocket>();

    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socketReady.complete(socket);
      socket.listen((message) {
        final request = jsonDecode(message as String) as Map<String, dynamic>;
        final method = request['method'];
        final parameters =
            request['params'] as Map<String, dynamic>? ?? const {};
        if (method == 'streamListen') {
          listenedStreams.add(parameters['streamId']! as String);
        } else if (method == 'ext.flutter.inspector.addPubRootDirectories') {
          configuredRoots.add(parameters['arg0']! as String);
        } else if (method == 'ext.flutter.timeDilation') {
          timeDilations.add((
            parameters['isolateId']! as String,
            parameters['timeDilation']! as String,
          ));
        }

        final result = switch (method) {
          'getVM' => {
            'isolates': [
              {'id': 'isolates/1', 'name': 'main'},
            ],
          },
          'getIsolate' => {
            'extensionRPCs': ['ext.flutter.inspector.addPubRootDirectories'],
          },
          'ext.flutter.inspector.getSelectedSummaryWidget' => {
            'result': {'description': 'AppOwnedWidget'},
          },
          _ => <String, dynamic>{},
        };
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
        );
      });
    });

    final monitor = FlutterSourceInspectorMonitor(
      projectRoot: projectRoot,
      packageName: packageName,
      writeStatus: statuses.add,
      writeError: errors.add,
      openSource: (path, line, column) async {
        openedSources.add((path: path, line: line, column: column));
      },
    );
    addTearDown(monitor.close);
    monitor.connect(
      Uri.parse('http://${server.address.address}:${server.port}/token=/'),
    );

    final socket = await socketReady.future;
    await _waitFor(() => statuses.any((message) => message.contains('Ready')));
    expect(listenedStreams, ['ToolEvent', 'Isolate']);
    expect(configuredRoots, [projectRoot.toString()]);

    await monitor.toggleSlowAnimations();
    expect(monitor.slowAnimationsEnabled, isTrue);
    expect(timeDilations, [('isolates/1', '5.0')]);
    await monitor.toggleSlowAnimations();
    expect(monitor.slowAnimationsEnabled, isFalse);
    expect(timeDilations, [('isolates/1', '5.0'), ('isolates/1', '1.0')]);

    // A malformed VM message shouldn't prevent the next selection.
    socket.add('{');
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'streamNotify',
        'params': {
          'streamId': 'ToolEvent',
          'event': {
            'kind': 'Extension',
            'extensionKind': 'navigate',
            'isolate': {'id': 'isolates/1'},
            'extensionData': {
              'fileUri': 'file:///work/project-live-new/client/lib/components/example.dart',
              'line': 42,
              'column': 7,
            },
          },
        },
      }),
    );

    await _waitFor(
      () => statuses.contains(
        '[flutter-source-inspector] '
        '/work/project-live-new/client/lib/components/example.dart:42:7 '
        '— AppOwnedWidget',
      ),
    );
    await _waitFor(() => openedSources.isNotEmpty);
    expect(openedSources, [
      (
        path: '/work/project-live-new/client/lib/components/example.dart',
        line: 42,
        column: 7,
      ),
    ]);
    await monitor.toggleSlowAnimations();
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'streamNotify',
        'params': {
          'streamId': 'Isolate',
          'event': {
            'kind': 'IsolateStart',
            'isolate': {'id': 'isolates/2'},
          },
        },
      }),
    );
    await _waitFor(
      () => statuses.any((message) => message.contains('Reattached')),
    );
    expect(configuredRoots, [projectRoot.toString(), projectRoot.toString()]);
    expect(timeDilations.last, ('isolates/2', '5.0'));
    expect(errors, isEmpty);
  });
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for the asynchronous condition');
}
