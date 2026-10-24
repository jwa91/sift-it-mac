# Changelog

## [0.4.0] — 2026-10-24

One install: `brew install jwa91/tap/sift-it` brings the app and the `sift-it` command, and the app sets up the rest.

- The app ships with sift-it 0.3.1 (`ENGINE_VERSION`): its signed and notarized binaries in `Contents/Helpers`. The
  cask links the `sift-it` command from there, so the terminal and the Raycast extension use the same engine.
- A welcome window the first time it opens: the model downloaded, with its progress; the folders to search, with how
  long each takes to index; indexing in the background, opening at login, and the shortcut. Settings → Index → Set Up
  Again… opens it later, and so does `sift-it://welcome`.
- After an upgrade, the app puts the background indexer back when it opens. Homebrew takes it away while it upgrades.
- Settings → Index turns indexing in the background on and off, and downloads the model with its progress.
- Fixed: installing from the tap failed for anyone who hadn't trusted it. Homebrew trusts only the cask named on the
  command line, and not the `sift-it` cask that `sift-it-mac` needed.
- The version follows the `sift-it` cask's (0.3.1), so `brew upgrade` takes an install of the command to the app. The
  `sift-it-mac` cask is retired: `brew uninstall sift-it-mac`, then `brew install jwa91/tap/sift-it`.

## [0.1.0] — 2026-10-21

The first version: a menu bar app whose shortcut (⌃⇧Space) opens one search bar over sift-it's engine.

- Results as you type: by words at once, by meaning when typing pauses. Strong matches first, weaker ones under a
  heading.
- A preview for each kind: the picture, the PDF page that matched, a video at its moment, a recording's waveform
  around the moment, and the passage, page or transcript with your words in bold.
- Recordings and videos play in the preview from the moment that matched (⇥, or Space after moving).
- ↩ opens where it matched (`sift-it open`), ⌘↩ shows it in Finder, ⌘Y opens Quick Look, ⌘C copies the file.
- The menu bar shows how far indexing is, and pauses, resumes or starts it.
- Settings: the shortcut, opening at login, searching by meaning or by words only, the folders to index, and the
  permissions that opening at the place needs.
- `sift-it://search?q=…` and `sift-it://settings`.
