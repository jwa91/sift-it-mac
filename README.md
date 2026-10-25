# Sift It

**A fast local search engine for the Mac.**

One search bar for everything on your Mac. Press a shortcut in any app, describe what you're looking for or type the
words, and the results come as you type: the page of a PDF, the photo, the minute of a podcast, the moment in a video.
Audio and video play right there, from the moment that matched. Everything runs on your Mac, and nothing you
index or search leaves it.

The app is a native front end, in Swift and AppKit. The search engine and the background indexer are
[sift-it](https://github.com/jwa91/sift-it), written in Rust, which the app ships with.

## Install

```sh
brew install jwa91/tap/sift-it
```

Apple silicon, macOS 14 or later.

Open Sift It from Applications. A welcome window downloads its two models (1.5 GB, once), asks which folders to
search, and starts indexing them in the background. After that it lives in the menu bar, and **⌃⇧Space** opens the
search from any app. Its settings are in the menu bar, and in the search: the gear, or ⌘,. If the menu bar is too
full to show the icon, open Sift It again.

The same install puts the `sift-it` command on your path, for the terminal and other front ends.

`brew uninstall --zap sift-it` removes the app, the index and its settings. It leaves the models in the Hugging Face
cache, `~/.cache/huggingface/hub`, which other apps may share; delete them there when nothing else uses them.

## Three phases

Indexing comes in three phases, and you can search all along:

| Phase | Finds |
|---|---|
| **Exact** | files by their name and exact words, text in screenshots and scans included |
| **Embeddings** | documents, photos, sounds and video scenes by what they mean |
| **Transcribed** | what's said in audio and video |

Exact needs no model, so every file is found by its words within seconds of adding a folder. Embeddings uses
EmbeddingGemma 2, by Google DeepMind, and Transcribed uses Parakeet Ultra. Text in screenshots and scans is read by
macOS itself.

One bar fills once for each phase, with the phase at work and its time left. The menu bar says it in a line ("Exact ✓
· Embeddings 60% · about 12 min"), and what the rest waits for, if anything: a charger, memory, a model. While phases
are left, a quiet line under the search results names them ("Embeddings 60% · Transcribed waiting"), so a missing
result isn't taken for a bad one. New and changed files go through every phase first, so they're found in seconds.

## Searching

| Key | |
|---|---|
| ↑ ↓ | Move through the results |
| ↩ | Open where it matched: audio or video at its moment, a PDF at its page, code at its line |
| ⇥ | Play or pause audio or video in the preview (Space too, once you've moved with ↑ ↓) |
| ⌘↩ | Show in Finder |
| ⌘Y | Quick Look |
| ⌘C, ⇧⌘C | Copy the file, copy its path |
| ⌘, | Settings |
| ⎋ | Close |

Every keystroke is answered by its words at once. When typing pauses, the same query is asked by meaning, and those
results replace the others. Strong matches come first, and the weaker ones follow under a heading.

The preview fits the result: a picture, the PDF page that matched, a video at its moment, an audio file's waveform
around the moment, and the passage, page or transcript with your words in bold.

`sift-it://search?q=…` opens the search with a query, and `sift-it://settings` opens the settings.

## Settings

- **General:** the shortcut, opening at login, and searching with embeddings (off, searches are Exact only). It also
  shows whether results may open at their page and moment (below).
- **Folders:** the folders to search, each indexed up to a phase (Exact, Embeddings or Transcribed), and the folders
  inside them to skip.
- **Index:** the three phases, the files indexed and the space they take, keeping the index up to date in the
  background, what happens on battery (Exact only, Everything, or Pause), and the models.

On battery, Exact only is the default: every file stays findable by its exact words, new files still go through every
phase, and the rest waits for a charger.

## Permissions

macOS asks once for each folder that needs it, such as Documents, Desktop or Downloads, as Sift It, right after you
add the folder. The indexer is part of the app, so it reads the folder without asking again.

Opening a result at its place goes through `sift-it open`. That command drives other apps, and macOS counts it as
Sift It's doing:

- **Audio and video at the moment.** Sift It controls QuickTime Player (Automation). macOS asks the first
  time.
- **PDFs at the page.** Preview has no way to be told a page, so Sift It types Go to Page for it (Accessibility).
  macOS doesn't ask for this by itself. The first time it's needed, Sift It explains why and takes you to System
  Settings.

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

`SiftItKit` holds the protocol, the socket, and the three phases (`Phases.swift`, where the engine's rounds map onto
them), and is tested on its own (`swift test`), against a fake engine on a real socket. `SiftIt` is the app.

How long searches take:

```sh
log stream --level debug --predicate 'subsystem == "dev.sift-it.mac"'
```

## Credits

About Sift It, in its menu, lists the parts it's made with:

- [sift-it](https://github.com/jwa91/sift-it), its engine, under the MIT License;
- [llama.cpp](https://github.com/ggml-org/llama.cpp), which runs the embedding model in it, under the MIT License;
- [FluidAudio](https://github.com/FluidInference/FluidAudio), by FluidInference, which runs the speech model on the
  Neural Engine in `sift-it-transcribe`, under the Apache License 2.0;
- [EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2), by Google DeepMind, under the Apache License
  2.0;
- [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra), by Moondream (from NVIDIA's Parakeet TDT 0.6B v3),
  in [FluidInference's Core ML conversion](https://huggingface.co/FluidInference/parakeet-ultra-coreml), under CC BY
  4.0.

The engine's THIRD_PARTY_NOTICES ships inside the app. Sift It uses the [MIT License](LICENSE). Gemma is a trademark
of Google LLC.
