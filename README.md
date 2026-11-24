# Flutter Source Inspector

Quick terminal access to Flutter DevTools’ **Select Widget** and **Slow
Animations** features, without opening DevTools. Select a widget in a running
Flutter debug app to print its source location or jump to it in your editor.

## Quick start

```sh
dart pub global activate --source path /path/to/flutter-source-inspector

# From your Flutter app directory:
flutter_source_inspector
```

- Wait for `Ready`, press `i`, then tap a widget. The terminal prints its source
  location, such as `/path/to/app/lib/home.dart:42:7 — HomePage`.
- Press `z` to toggle 5× slow animations. Flutter shortcuts like `r`, `R`, and `q`
  still work.
- Pass `flutter run` options after `--`, for example
  `flutter_source_inspector -- -d chrome`.

`flutter run | flutter_source_inspector` also works for inspection, but without
`z`. Run `flutter_source_inspector --help` to see all options.

## Open in an editor

Pass `--editor=<executable>` to open each selected file. Repeat `--editor-arg`
to pass arguments with `{file}`, `{line}`, and `{column}` placeholders. The file
path is appended if no argument contains `{file}`.

```sh
# VS Code
flutter_source_inspector --editor=code --editor-arg=--goto --editor-arg='{file}:{line}:{column}'

# Zed
flutter_source_inspector --editor=zed --editor-arg=-e --editor-arg='{file}:{line}:{column}'
```

[MIT License](LICENSE)
