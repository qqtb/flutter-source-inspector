import 'dart:io';

bool sourceIsWithinProject(
  String sourceUri,
  Uri projectRoot,
  String packageName,
) =>
    projectSourcePath(sourceUri, projectRoot, packageName) != null;

String terminalSourcePath(
  String sourceUri,
  Uri projectRoot,
  String packageName,
) =>
    projectSourcePath(sourceUri, projectRoot, packageName) ??
    _localPath(Uri.tryParse(sourceUri)) ??
    sourceUri;

/// Resolves an inspector URI to a local path only if it belongs to the app.
String? projectSourcePath(
  String sourceUri,
  Uri projectRoot,
  String packageName,
) {
  final uri = Uri.tryParse(sourceUri);
  if (uri == null) {
    return null;
  }
  final rootPath = _withTrailingSlash(
    _forwardSlashes(Directory.fromUri(projectRoot).absolute.path),
  );
  final segments = uri.pathSegments;
  if (uri.scheme == 'package' || uri.scheme == 'org-dartlang-app') {
    final isAppUri = uri.scheme == 'package'
        ? segments.isNotEmpty && segments.first == packageName
        : uri.path.startsWith('/lib/');
    if (!isAppUri || segments.length < 2) {
      return null;
    }
    final relative = segments.skip(1);
    if (relative.any(
      (part) =>
          part.isEmpty ||
          part == '.' ||
          part == '..' ||
          part.contains('/') ||
          part.contains('\\'),
    )) {
      return null;
    }
    return '$rootPath${relative.join('/')}';
  }

  if (uri.scheme.isNotEmpty && uri.scheme != 'file') {
    return null;
  }
  final path = _localPath(uri);
  return path != null && path.startsWith(rootPath) ? path : null;
}

String? _localPath(Uri? uri) {
  if (uri == null) {
    return null;
  }
  try {
    return _forwardSlashes(uri.scheme == 'file' ? uri.toFilePath() : uri.path);
  } on UnsupportedError {
    return null;
  }
}

String _forwardSlashes(String path) => path.replaceAll('\\', '/');

String _withTrailingSlash(String path) => path.endsWith('/') ? path : '$path/';
