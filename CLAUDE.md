# sift-it-mac

The Mac app for sift-it: a menu bar app whose shortcut opens one search bar. Swift and AppKit, macOS 14 and later,
Apple silicon. It's a client of sift-it's engine and nothing more, and it ships with that engine: its release is the
`sift-it` cask, which installs the app and links the `sift-it` command from inside it. The engine, the indexer and the CLI live in
`jwa91/sift-it`; the Raycast extension in `jwa91/sift-it-raycast`.

## Rules

- **The protocol is the only contract.** The app speaks JSON lines to `engine.sock` (sift-it's docs/protocol.md) and
  runs the `sift-it` it ships with for what the protocol doesn't cover (`open`, `estimate`, `model download`,
  `service install`). It
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
                     ResultsList, Preview, Playback, Images, Actions, Hotkey, StatusItem, Settings, Permissions,
                     Setup (the model, the folders, indexing in the background) and Welcome (its first-run window)
Tests/               SiftItKit's tests, with a fake engine on a real socket
scripts/             bundle.sh (the .app), fetch-engine.sh (the sift-it release in ENGINE_VERSION, checked),
                     codesign.sh (Developer ID, notarizing, stapling), release.sh (the GitHub release and the cask),
                     make-icon.swift (the icon)
```

## Working on it

- `make check` before every commit: `swift format lint --strict`, a build with warnings as errors, `swift test`.
- `make run` builds the app and opens it. `open "sift-it://search?q=…"` opens the panel with a query, which is how
  to try a change without pressing keys; `sift-it://settings` opens the settings, `sift-it://welcome` the welcome
  window. Its last page changes this Mac's setup (folders, LaunchAgents): don't press Start Searching to try it.
- `log stream --level debug --predicate 'subsystem == "dev.sift-it.mac"'` shows each search's time in the engine and
  its round trip. `footprint -p $(pgrep -x SiftIt)` shows memory: about 19 MB after launch.
- An ad hoc signed build is a new app to macOS's privacy settings each time: Accessibility has to be allowed again
  after a rebuild.

## Releasing

As sift-it does, from the releasing Mac: bump `CFBundleShortVersionString` in Resources/Info.plist, give CHANGELOG.md a
`## [X.Y.Z] — date` section, commit, tag `vX.Y.Z` and push both, then `make release VERSION=X.Y.Z`. It checks first,
signs with the Developer ID and notarizes with the keychain's notarytool profile (scripts/codesign.sh), staples, and
publishes the zip and `Casks/sift-it.rb` with the gh login. `make snapshot` makes the same in dist/ without
publishing; CI's manual Release workflow runs it.

The `sift-it` cask is this app's (sift-it's own releases publish only its binaries). A new sift-it reaches people
through a release here: set `ENGINE_VERSION` to it, try it, and release. The app's version is the cask's, which
continued from sift-it's 0.3.1 at 0.4.0.
