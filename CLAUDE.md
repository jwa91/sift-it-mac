# sift-it-mac

The Mac app for sift-it: a menu bar app whose shortcut opens one search bar. Swift and AppKit, macOS 14 and later,
Apple silicon. It's a client of sift-it's engine and nothing more. The engine, the indexer and the CLI live in
`jwa91/sift-it`; the Raycast extension in `jwa91/sift-it-raycast`.

## Rules

- **The protocol is the only contract.** The app speaks JSON lines to `engine.sock` (sift-it's docs/protocol.md) and
  runs `sift-it` commands for what the protocol doesn't cover (`open`, `service install`, `model download`). It
  doesn't read the index, `status.json` or `config.json` itself, and holds no search or ranking logic.
- **Footprint and speed come first.** Use the technique that's fastest and lightest, even when it needs a
  permission; then guide the person through that permission once (Permissions.swift). Nothing decodes on the main
  thread, nothing decodes larger than it's shown, and nothing loads before it's needed (the settings' SwiftUI views
  exist only while the window is open).
- **The panel is AppKit.** SwiftUI only for the settings.
- **Say the same as the other front ends.** Labels and places ("p. 3", "0:42", "Line 12") follow the Raycast
  extension's; opening at a place goes through `sift-it open`, the same rule as the CLI's.

## Layout

```
Sources/SiftItKit/   the protocol (Protocol.swift), the socket (EngineConnection.swift), where things are
                     (Places.swift), how results are said (Format.swift). Foundation only, tested.
Sources/SiftIt/      the app: App, Engine (the connection kept up), SearchController (the panel), SearchPanel,
                     ResultsList, Preview, Playback, Images, Actions, Hotkey, StatusItem, Settings, Permissions
Tests/               SiftItKit's tests, with a fake engine on a real socket
scripts/             bundle.sh (the .app), make-icon.swift (the icon)
```

## Working on it

- `make check` before every commit: `swift format lint --strict`, a build with warnings as errors, `swift test`.
- `make run` builds the app and opens it. `open "sift-it://search?q=…"` opens the panel with a query, which is how
  to try a change without pressing keys; `sift-it://settings` opens the settings.
- `log stream --level debug --predicate 'subsystem == "dev.sift-it.mac"'` shows each search's time in the engine and
  its round trip. `footprint -p $(pgrep -x SiftIt)` shows memory: about 19 MB after launch.
- An ad hoc signed build is a new app to macOS's privacy settings each time: Accessibility has to be allowed again
  after a rebuild.
