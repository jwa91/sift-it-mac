# Changelog

## [0.5.2] — 2026-10-25

A real settings window, a say in which kinds of files are indexed, and conversations with Claude Code and Codex to
search and resume.

- **Settings with a sidebar:** General, Folders, Index, Permissions and About, as a Mac settings window.
  - **Index** shows the embeddings as a grid of cells, one per percent, coloured by the kind of file they're from, with
    each kind's count and share, beside the three-phase bar.
  - **Permissions** shows whether Sift It may open PDFs at the page and play audio and video from the moment, and
    follows a grant made in System Settings while the window is open. The welcome window has the same page, which can
    be skipped.
  - **About** has the version, janwillemaltink.com, the GitHub page and the parts Sift It is made with.
- **Kinds of files**, one list for every folder (Settings → Folders): Documents, Text, Data, Pictures, Audio, Videos,
  Code and Conversations. What's always left out says so in one line. Leaving out a kind with indexed files asks first,
  with how many files leave the index.
- **Conversations:** Claude Code's and Codex's sessions are found by what was asked and answered, shown with their
  title and day, and ↩ resumes one in the terminal, in the folder it started in (⌘C copies the command). The welcome
  window and Settings → Folders offer their folders when they're there.
- **Audio, not recordings,** everywhere.
- **Fixes:** the shortcut works again after the shortcut button was clicked and its page left; the welcome window
  shows whenever the models or the folders aren't there, even with settings left behind; no separator at zero results.
- **iCloud:** files kept only in iCloud are found by name and read once they're downloaded; Sift It never downloads
  them, and keeps what it indexed when macOS removes a download.
- **The app ships with sift-it 0.4.3** (`ENGINE_VERSION`), which also brings `sift-it mcp`: Sift It as a read-only
  MCP server for agents such as Claude Code, Claude Desktop and Codex, with a skill beside it (see sift-it's README).

## [0.5.1] — 2026-10-25

One language, one flow: the app says how far indexing is in three words, everywhere, and asks for nothing before
you've chosen it.

- **Exact, Embeddings, Transcribed.** Exact finds files by their name and exact words, text in screenshots and scans
  included; Embeddings finds documents, photos, sounds and video scenes by what they mean; Transcribed finds what's
  said in recordings and videos. The welcome window, the menu bar, the search panel and the settings use these words,
  and explain each in the same sentence. The engine's six rounds map onto them in one place (SiftItKit's Phases).
- **One bar that fills three times**, labelled with the phase at work and its time left, in the welcome window and in
  Settings → Index. The menu bar says "Exact ✓ · Embeddings 60% · about 12 min", with a second line only when
  something waits. The search panel's quiet line names only the phases that aren't done.
- **The same words in every setting:** Search with embeddings (General), Index up to Exact, Embeddings or Transcribed,
  for each folder (Folders), and On battery: Exact only, Everything or Pause (Index).
- **The models, by name:** EmbeddingGemma 2 by Google DeepMind for embeddings (865 MB), and Parakeet Ultra for
  transcription (632 MB). Text in screenshots and scans is read by macOS itself.
- **Choosing folders asks nothing unasked.** No folder is ticked or read beforehand: Add Folder…, or a click on
  Documents, Desktop or Downloads, adds one and counts it (its files and one time), and that's when macOS asks, once,
  as Sift It. The background indexer reads the folder as Sift It too, so there's no second prompt. The per-folder
  breakdown and the depth drop-down are gone from the welcome window (the depth is in Settings → Folders).
- **Where things are:** the welcome window says Sift It lives in the menu bar, that its settings are there and in the
  search, and that opening Sift It again opens the search when the icon hides on a full menu bar. The search panel
  has a gear for the settings, beside ⌘,.
- **The app ships with sift-it 0.4.1** (`ENGINE_VERSION`). On battery, Exact means the same as everywhere else:
  every file's words and the text in screenshots and scans go on, and Embeddings and Transcribed wait for a charger.
- Settings → Index counts files in the plural ("900 documents").

## [0.5.0] — 2026-10-25

Progress you can read: what can be found already, and what comes next. With sift-it 0.4.0, which indexes in rounds:
every file is found by its words within seconds of choosing the folders.

- The app ships with sift-it 0.4.0 (`ENGINE_VERSION`), and with the licenses of what's built into it in
  `Contents/Resources/THIRD_PARTY_NOTICES`.
- Indexing goes in rounds, and the app says each as a milestone: every file by its name and words (within seconds),
  documents by meaning, text in screenshots and scans, photos by what's in them, what sounds and video scenes
  contain, and what's said in recordings.
- The menu bar says what can be searched by already and how far the next milestone is, with its time left ("Searchable
  by words · documents by meaning 60% · about 12 min"), and what the rest waits for: a charger, memory, a model.
- While rounds are left, a quiet line under the search results says what can't be found yet ("Recordings: 40%
  written down").
- The welcome window shows what each milestone takes for each folder before indexing starts, and offers to leave the
  slow ones out of a huge folder (its depth, in `reading.rules`). Once indexing starts, it shows the milestones as
  they're reached.
- Settings → Index shows the milestones, and what indexing does on battery: read new files' words, everything, or
  wait for a charger.
- The models are 1.5 GB, kept in the shared Hugging Face cache. Uninstalling with `--zap` leaves them there, and now
  removes the compiled speech and text recognition models in `~/Library/Caches`.
- About Sift It lists the parts it's made with, and their licences.

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
