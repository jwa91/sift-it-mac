# Sift It for Mac

**Sift It: the blazingly fast document searcher for your Mac, built in Rust.**

One search bar for everything on your Mac. Press a shortcut in any app, describe what you're looking for or type
the words, and the results come as you type: the page of a PDF, the photo, the minute of a podcast, the frame of a
video where it happens. Recordings and videos play right there, from the moment that matched. Everything runs on
your Mac, with Google DeepMind's EmbeddingGemma 2.

This app is a thin native front end, in Swift and AppKit. The work happens in
[sift-it](https://github.com/jwa91/sift-it), the Rust engine and background indexer. The app speaks to it over its
socket.

## Setup

Apple silicon, macOS 14 or later:

```sh
brew install jwa91/tap/sift-it-mac
```

That brings [sift-it](https://github.com/jwa91/sift-it) with it, which does the indexing and the searching. Set it up
once:

```sh
sift-it model download
sift-it folders add ~/Documents
sift-it service install
```

Then open Sift It from Applications. It lives in the menu bar. **⌃⇧Space** opens the search, and Settings changes the shortcut.

## Searching

| Key | |
|---|---|
| ↑ ↓ | Move through the results |
| ↩ | Open where it matched: a recording or video at its moment, a PDF at its page, code at its line |
| ⇥ | Play or pause a recording or video in the preview (Space too, once you've moved with ↑ ↓) |
| ⌘↩ | Show in Finder |
| ⌘Y | Quick Look |
| ⌘C, ⇧⌘C | Copy the file, copy its path |
| ⎋ | Close |

Every keystroke is answered by words at once. When typing pauses, the same query is asked by meaning, and those
results replace the others. The strong matches come first, in the engine's order, and the weaker ones follow under a
heading.

The preview fits the result: a picture, the PDF page that matched, a video at its moment, a recording's waveform
around the moment, and the passage, page or transcript with your words in bold.

`sift-it://search?q=…` opens the search with a query, and `sift-it://settings` opens the settings.

## Permissions

Opening a result at its place goes through `sift-it open`. That command drives other apps, and macOS counts it as
Sift It's doing:

- **Recordings and videos at the moment.** Sift It controls QuickTime Player (Automation). macOS asks the first
  time.
- **PDFs at the page.** Preview has no way to be told a page, so Sift It types Go to Page for it (Accessibility).
  macOS doesn't ask for this by itself. The first time it's needed, Sift It explains why and takes you to System
  Settings. Settings → General shows whether it's allowed.

The shortcut needs no permission. It's a system hot key, which costs nothing until you press it.

## How it's built

- **The engine's socket.** The app talks to the engine directly, in JSON lines over `engine.sock` in the data folder
  ([protocol](https://github.com/jwa91/sift-it/blob/main/docs/protocol.md)). Lines are read on a thread of their
  own, and replies find their request by id. When the engine isn't running, the app starts it as the CLI would: via
  its LaunchAgent, or else as a process of its own.
- **Previews are made in the app.** ImageIO for pictures, CoreGraphics for PDF pages, and AVFoundation for frames,
  waveforms and playback. Nothing is decoded on the main thread or larger than it's shown.
- **The panel is made once, at launch.** The shortcut only shows it. It takes the keyboard without making Sift It
  the active app, so the app you came from stays in front.
- **On macOS 26 the panel is Liquid Glass**, with a material inside so results stay legible over anything. Before
  macOS 26 it uses the material alone.

Measured on an M-series MacBook with the demo collection (629 files):

| | |
|---|---|
| Memory after launch | 19 MB |
| Memory after a dozen searches with previews | 35–43 MB |
| A search by words, round trip | 1–8 ms |
| A search by meaning, round trip | 4–20 ms |

## Development

```sh
make build     # build/Sift It.app, signed ad hoc
make run       # build and open it
make install   # build and put it in /Applications
make check     # swift format lint, build with warnings as errors, tests
make icon      # redraw Resources/AppIcon.icns
make snapshot  # what a release makes, in dist/, unpublished
```

`make release VERSION=X.Y.Z` signs, notarizes and publishes a release, and updates the cask in
[jwa91/homebrew-tap](https://github.com/jwa91/homebrew-tap). What the releasing Mac needs is in the header of
`scripts/codesign.sh`.

`SiftItKit` holds the protocol and the socket and is tested on its own (`swift test`), against a fake engine on a
real socket. `SiftIt` is the app.

How long searches take:

```sh
log stream --level debug --predicate 'subsystem == "dev.sift-it.mac"'
```
