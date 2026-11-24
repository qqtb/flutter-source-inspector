# Flutter Source Inspector

Quick terminal access to Flutter DevTools’ **Select Widget** and **Slow
Animations** features, without opening DevTools. Select a widget in a running
Flutter debug app to print its source location or jump to it in your editor.

## Quick start

```sh
dart pub global activate --source path /path/to/flutter-source-inspector

# From your Flutter app directory, in a terminal:
flutter_source_inspector
```

The inspector starts `flutter run` for you. You don’t need to start Flutter
separately.

- Wait for `Ready`, press `i`, then tap a widget. The terminal prints its source
  location, such as `/path/to/app/lib/home.dart:42:7 — HomePage`.
- Press `z` to toggle 5× slow animations. Flutter shortcuts like `r`, `R`, and `q`
  still work.
- Pass `flutter run` options after `--`, for example
  `flutter_source_inspector -- -d chrome`.

In pipeline mode (`flutter run | flutter_source_inspector`), the inspector
uses Flutter’s piped output instead of starting its own run. Widget inspection
still works, but `z` is unavailable. Run `flutter_source_inspector --help` to
see all options.

## Open in an editor

The commands below also start `flutter run`. They print the selected widget’s
source location and open it in your editor. Make sure `code` or `zed` is on
`PATH`.

```sh
# VS Code
flutter_source_inspector --editor=code --editor-arg=--goto --editor-arg='{file}:{line}:{column}'

# Zed
flutter_source_inspector --editor=zed --editor-arg=-e --editor-arg='{file}:{line}:{column}'
```

For other editors, use `--editor=<executable>` and repeat `--editor-arg` as
needed. Arguments can use `{file}`, `{line}`, and `{column}`. If no argument
contains `{file}`, the inspector appends the file path.

## How it works (TL;DR)

- The inspector reads the Dart VM service URL from `flutter run` output and
  connects over WebSocket. No app code changes are needed.
- Flutter’s built-in widget picker sends a source location when you tap a
  widget. The inspector resolves it to a file in your app, prints the line and
  column, and opens the file if you configured an editor.
- In direct mode, `z` uses the same connection to toggle Flutter’s animation
  speed. Other keystrokes are passed through to `flutter run`.

[MIT License](LICENSE)
