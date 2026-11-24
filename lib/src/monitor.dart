import 'dart:async';
import 'dart:io';

import 'source_location.dart';
import 'vm_service.dart';

const _addProjectRootsExtension = 'ext.flutter.inspector.addPubRootDirectories';
const _disposeGroupExtension = 'ext.flutter.inspector.disposeGroup';
const _getSelectionExtension = 'ext.flutter.inspector.getSelectedSummaryWidget';
const _timeDilationExtension = 'ext.flutter.timeDilation';
const _objectGroup = 'flutter-source-inspector';
const _slowAnimationFactor = 5.0;

typedef SourceOpener = Future<void> Function(
  String absolutePath,
  int line,
  int column,
);

class FlutterSourceInspectorMonitor {
  FlutterSourceInspectorMonitor({
    required this.projectRoot,
    required this.packageName,
    required this.writeStatus,
    required this.writeError,
    this.openSource,
  });

  final Uri projectRoot;
  final String packageName;
  final void Function(String message) writeStatus;
  final void Function(String message) writeError;
  final SourceOpener? openSource;

  VmServiceClient? _client;
  Uri? _connectedUri;
  Future<void>? _connection;
  String? _activeIsolateId;
  final Set<String> _configuringIsolates = {};
  bool _slowAnimationsEnabled = false;

  bool get slowAnimationsEnabled => _slowAnimationsEnabled;

  Future<void> toggleSlowAnimations() async {
    final enabled = !_slowAnimationsEnabled;
    _slowAnimationsEnabled = enabled;
    final isolateId = _activeIsolateId;
    final client = _client;
    if (isolateId == null || client == null) {
      writeStatus(
        '[flutter-source-inspector] Slow animations will be '
        '${enabled ? 'enabled' : 'disabled'} when the app is ready.',
      );
      return;
    }

    try {
      await _setTimeDilation(client, isolateId, enabled);
      writeStatus(
        '[flutter-source-inspector] Slow animations '
        '${enabled ? 'enabled (5x).' : 'disabled.'}',
      );
    } catch (error) {
      writeError(
        '[flutter-source-inspector] Could not change animation speed: $error',
      );
    }
  }

  Future<void> _setTimeDilation(
    VmServiceClient client,
    String isolateId,
    bool enabled,
  ) => client.call(_timeDilationExtension, {
    'isolateId': isolateId,
    'timeDilation': (enabled ? _slowAnimationFactor : 1.0).toString(),
  });

  void connect(Uri serviceUri) {
    if (_connectedUri == serviceUri || _connection != null) {
      return;
    }
    _connection = _connect(serviceUri).whenComplete(() => _connection = null);
  }

  Future<void> _connect(Uri serviceUri) async {
    try {
      final socket = await WebSocket.connect(
        vmServiceWebSocketUri(serviceUri).toString(),
      );
      final client = VmServiceClient(socket, onEvent: _handleEvent);
      _client = client;
      _connectedUri = serviceUri;

      await client.call('streamListen', {'streamId': 'ToolEvent'});
      await client.call('streamListen', {'streamId': 'Isolate'});
      final vm = await client.call('getVM');
      final isolates = vm['isolates'];
      if (isolates is List) {
        for (final isolate in isolates.whereType<Map>()) {
          final isolateId = isolate['id'];
          if (isolateId is String && await _configureIsolate(isolateId)) {
            break;
          }
        }
      }
    } catch (error) {
      writeError(
        '[flutter-source-inspector] Could not connect to the VM service: $error',
      );
      await _client?.close();
      _client = null;
      _connectedUri = null;
    }
  }

  Future<bool> _configureIsolate(String isolateId) async {
    final client = _client;
    if (client == null || !_configuringIsolates.add(isolateId)) {
      return false;
    }

    try {
      // The isolate may start before Flutter registers its inspector RPCs.
      for (var attempt = 0; attempt < 50; attempt++) {
        final isolate = await client.call('getIsolate', {
          'isolateId': isolateId,
        });
        final extensions = isolate['extensionRPCs'];
        if (extensions is List &&
            extensions.contains(_addProjectRootsExtension)) {
          await client.call(_addProjectRootsExtension, {
            'isolateId': isolateId,
            'arg0': projectRoot.toString(),
          });
          final wasReady = _activeIsolateId != null;
          _activeIsolateId = isolateId;
          if (_slowAnimationsEnabled) {
            try {
              await _setTimeDilation(client, isolateId, true);
            } catch (error) {
              writeError(
                '[flutter-source-inspector] Could not restore slow animations: $error',
              );
            }
          }
          writeStatus(
            wasReady
                ? '[flutter-source-inspector] Reattached after hot restart.'
                : '[flutter-source-inspector] Ready — press i, then tap a widget.',
          );
          return true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } catch (_) {
      // An isolate can exit during restart; its replacement sends IsolateStart.
    } finally {
      _configuringIsolates.remove(isolateId);
    }
    return false;
  }

  void _handleEvent(Map<String, dynamic> message) {
    final params = message['params'];
    if (params is! Map) {
      return;
    }
    final streamId = params['streamId'];
    final event = params['event'];
    if (event is! Map) {
      return;
    }
    final isolate = event['isolate'];
    final id = isolate is Map ? isolate['id'] : null;
    final isolateId = id is String ? id : null;

    if (streamId == 'Isolate' && event['kind'] == 'IsolateStart') {
      if (isolateId != null) {
        unawaited(_configureIsolate(isolateId));
      }
      return;
    }

    if (streamId != 'ToolEvent' || event['extensionKind'] != 'navigate') {
      return;
    }
    final data = event['extensionData'];
    final selectionIsolateId = isolateId ?? _activeIsolateId;
    if (data is Map && selectionIsolateId != null) {
      unawaited(_reportSelection(selectionIsolateId, data));
    }
  }

  Future<void> _reportSelection(
    String isolateId,
    Map<dynamic, dynamic> navigation,
  ) async {
    final fileUri = navigation['fileUri'];
    final line = navigation['line'];
    final column = navigation['column'];
    if (fileUri is! String || line is! int || column is! int) {
      return;
    }
    final path = projectSourcePath(fileUri, projectRoot, packageName);
    if (path == null) {
      return;
    }

    final description = await _selectedWidgetDescription(isolateId);
    final suffix = description == null ? '' : ' — $description';
    writeStatus('[flutter-source-inspector] $path:$line:$column$suffix');

    final opener = openSource;
    if (opener == null) {
      return;
    }
    try {
      await opener(path, line, column);
    } catch (error) {
      writeError(
        '[flutter-source-inspector] Could not open selection in editor: $error',
      );
    }
  }

  Future<String?> _selectedWidgetDescription(String isolateId) async {
    final client = _client;
    if (client == null) {
      return null;
    }
    final parameters = {'isolateId': isolateId, 'objectGroup': _objectGroup};
    try {
      final response = await client.call(_getSelectionExtension, parameters);
      final selection = response['result'];
      final description = selection is Map ? selection['description'] : null;
      return description is String ? description : null;
    } catch (_) {
      // The navigate event still provides the source location.
      return null;
    } finally {
      try {
        await client.call(_disposeGroupExtension, parameters);
      } catch (_) {
        // The isolate may have exited during a hot restart.
      }
    }
  }

  Future<void> close() async {
    await _connection;
    await _client?.close();
  }
}
