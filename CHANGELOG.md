## Unreleased

- Replace `--open-in-zed` with `--editor` and `--editor-arg` for any editor CLI.
- Launch `flutter run` directly and forward its terminal commands.
- Add a `z` key command to toggle 5x slow animations.
- Print inspector and Flutter command guidance in separate sections.
- Keep the original pipeline workflow for backward compatibility and identify it clearly when active.
- Drain Flutter output during Ctrl-C shutdown to avoid broken-pipe exceptions.

## 0.1.0

- Connect to native and web Flutter VM service output.
- Print app-owned widget source locations and descriptions.
- Optionally open selected locations directly in Zed.
- Reattach the widget inspector after Flutter hot restarts.
