# Sift It

**Sift It: the blazingly fast document searcher for your Mac, built in Rust.**

One search bar for everything on your Mac. Press a shortcut in any app, describe what you're looking for or type
the words, and the results come as you type: the page of a PDF, the photo, the minute of a podcast, the frame of a
video where it happens. Recordings and videos play right there, from the moment that matched. Everything runs on
your Mac, with Google DeepMind's EmbeddingGemma 2.

This app is a thin native front end, in Swift and AppKit. The work happens in
[sift-it](https://github.com/jwa91/sift-it), the Rust engine and background indexer, which the app ships with.

## Install

Apple silicon, macOS 14 or later:

```sh
brew install jwa91/tap/sift-it
```

Open Sift It from Applications. A welcome window downloads its models (1.5 GB, once), asks which folders to search,
and starts indexing them in the background. After that it lives in the menu bar, and **⌃⇧Space** opens the search
from any app.

The same install puts the `sift-it` command on your path, for the terminal and the Raycast extension.

`brew uninstall --zap sift-it` removes the app, the index and its settings. It leaves the models (1.5 GB) in the
Hugging Face cache, `~/.cache/huggingface/hub`, which other apps may share; delete them there when nothing else uses
them.

## While it indexes

A big folder, or a whole drive, can take hours to index, and searching is useful long before that. Indexing goes in
rounds, and each one makes more of your files findable:

1. every file by its name and words, within seconds;
2. documents by meaning;
3. text in screenshots and scans;
4. photos by what's in them;
5. what sounds and video scenes contain;
6. what's said in recordings.

The menu bar says what can be found already and how long the next milestone takes ("Searchable by words · documents
by meaning 60% · about 12 min"), and what the rest waits for: a charger, memory, a model. While rounds are left, a
line under the search results says what can't be found yet ("Recordings: 40% written down"), so a missing result
isn't taken for a bad one. The welcome window shows what each milestone will take for each folder before it starts,
and for a huge folder offers to leave the slow ones out. Settings → Index shows the milestones, and what indexing does
on battery.

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

macOS asks before your Documents, Desktop and Downloads are read, twice: for Sift It, which shows previews (the
welcome window asks when it counts those folders), and for sift-it, its indexer, when indexing starts.

Opening a result at its place goes through `sift-it open`. That command drives other apps, and macOS counts it as
Sift It's doing:

- **Recordings and videos at the moment.** Sift It controls QuickTime Player (Automation). macOS asks the first
  time.
- **PDFs at the page.** Preview has no way to be told a page, so Sift It types Go to Page for it (Accessibility).
  macOS doesn't ask for this by itself. The first time it's needed, Sift It explains why and takes you to System
  Settings. Settings → General shows whether it's allowed.

The shortcut needs no permission. It's a system hot key, which costs nothing until you press it.

## How it's built

- **It ships with its engine.** The app carries a sift-it release (`ENGINE_VERSION`) in `Contents/Helpers`, its
  binaries signed and notarized as sift-it released them. App and engine are a pair that's tested together, and the
  cask links the `sift-it` command from there.
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

`make release VERSION=X.Y.Z` signs, notarizes and publishes a release, and updates the `sift-it` cask in
[jwa91/homebrew-tap](https://github.com/jwa91/homebrew-tap). The sift-it it ships with is the version in
`ENGINE_VERSION`; `scripts/fetch-engine.sh` fetches it and checks it. What the releasing Mac needs is in the header of
`scripts/codesign.sh`.

`SiftItKit` holds the protocol and the socket and is tested on its own (`swift test`), against a fake engine on a
real socket. `SiftIt` is the app.

How long searches take:

```sh
log stream --level debug --predicate 'subsystem == "dev.sift-it.mac"'
```

## Credits

About Sift It, in its menu, lists the parts it's made with:

- [sift-it](https://github.com/jwa91/sift-it), its engine, under the MIT License;
- [llama.cpp](https://github.com/ggml-org/llama.cpp), which runs the model in it, under the MIT License;
- [FluidAudio](https://github.com/FluidInference/FluidAudio), by FluidInference, compiled into `sift-it-transcribe`,
  under the Apache License 2.0;
- [EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2), by Google DeepMind, under the Apache License
  2.0;
- [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra), by Moondream (from NVIDIA's Parakeet TDT 0.6B v3),
  in [FluidInference's Core ML conversion](https://huggingface.co/FluidInference/parakeet-ultra-coreml), under CC BY
  4.0.

Sift It uses the [MIT License](LICENSE). Gemma is a trademark of Google LLC.
