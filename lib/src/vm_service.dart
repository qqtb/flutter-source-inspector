import 'dart:async';
import 'dart:convert';
import 'dart:io';

class VmServiceClient {
  VmServiceClient(this._socket, {required this.onEvent}) {
    _subscription = _socket.listen(
      _handleMessage,
      onError: _handleError,
      onDone: _handleDone,
      cancelOnError: true,
    );
  }

  final WebSocket _socket;
  final void Function(Map<String, dynamic> event) onEvent;
  late final StreamSubscription<dynamic> _subscription;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  var _nextRequestId = 1;
  var _closed = false;

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, Object?> parameters = const {},
  ]) async {
    if (_closed) {
      throw StateError('VM service connection closed');
    }
    final id = _nextRequestId++;
    final request = jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (parameters.isNotEmpty) 'params': parameters,
    });
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      _socket.add(request);
      return await completer.future.timeout(const Duration(seconds: 5));
    } finally {
      _pending.remove(id);
    }
  }

  void _handleMessage(dynamic message) {
    if (message is! String) {
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(message);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      return;
    }

    final id = decoded['id'];
    if (id is int) {
      final completer = _pending.remove(id);
      if (completer == null) {
        return;
      }
      final error = decoded['error'];
      if (error != null) {
        completer.completeError(VmServiceException(error.toString()));
        return;
      }
      final result = decoded['result'];
      completer.complete(
        result is Map<String, dynamic> ? result : <String, dynamic>{},
      );
      return;
    }

    if (decoded['method'] == 'streamNotify') {
      onEvent(decoded);
    }
  }

  void _handleError(Object error, StackTrace stackTrace) {
    _closed = true;
    for (final completer in _pending.values) {
      completer.completeError(error, stackTrace);
    }
    _pending.clear();
  }

  void _handleDone() => _handleError(
        StateError('VM service connection closed'),
        StackTrace.current,
      );

  Future<void> close() async {
    _handleDone();
    try {
      await _socket.close();
    } finally {
      await _subscription.cancel();
    }
  }
}

class VmServiceException implements Exception {
  const VmServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

final _ansiEscape = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
final _httpUrl = RegExp(r'https?://[^\s]+');

Uri? vmServiceUriFromFlutterOutput(String line) {
  final plainLine = line.replaceAll(_ansiEscape, '');
  if (!plainLine.toLowerCase().contains('dart vm service')) {
    return null;
  }
  final match = _httpUrl.firstMatch(plainLine);
  return match == null ? null : Uri.tryParse(match.group(0)!);
}

Uri vmServiceWebSocketUri(Uri serviceUri) {
  final path = serviceUri.path.endsWith('/')
      ? '${serviceUri.path}ws'
      : '${serviceUri.path}/ws';
  return serviceUri.replace(
    scheme: serviceUri.scheme == 'https' ? 'wss' : 'ws',
    path: path,
  );
}
