// Sift It in the menu bar: its icon says whether the index is up to date (and how far the phase at work is while it
// works), and its menu says how far indexing is in its three phases, opens the search, pauses indexing, and holds the
// settings.

import AppKit
import Observation
import SiftItKit

@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let engine: Engine
    private let menu = NSMenu()
    private var menuIsOpen = false
    var openSearch: () -> Void = {}
    var openSettings: () -> Void = {}
    var openAbout: () -> Void = {}
    /// Starts indexing in the background.
    var startIndexing: () -> Void = {}

    init(engine: Engine) {
        self.engine = engine
        super.init()
        let image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Sift It")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        follow()
    }

    /// Updates the icon whenever what it shows changes.
    private func follow() {
        withObservationTracking {
            update()
        } onChange: {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.follow() } }
        }
    }

    private func update() {
        let indexer = engine.indexer
        let current = indexer.flatMap { $0.isWorking ? $0.currentPhase : nil }
        item.button?.title = current.map { " \(Phases.percent($0.progress))%" } ?? ""
        item.button?.appearsDisabled = !engine.isConnected || indexer?.state == .paused
        if menuIsOpen { fill() }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        fill()
        Task { await engine.refreshStatus() }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func fill() {
        menu.removeAllItems()
        let search = item("Search Files", #selector(search))
        let shortcut = Shortcut.saved
        search.keyEquivalent = shortcut.keyCode == 49 ? " " : shortcut.key.lowercased()
        search.keyEquivalentModifierMask = shortcut.flags
        menu.addItem(search)
        menu.addItem(.separator())
        for line in statusLines() { menu.addItem(note(line)) }
        for action in indexerActions() { menu.addItem(action) }
        menu.addItem(.separator())
        menu.addItem(item("About Sift It", #selector(about)))
        let settings = item("Settings…", #selector(settings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = item("Quit Sift It", #selector(NSApplication.terminate(_:)))
        quit.target = NSApp
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// How the index is doing: the phases done and the one at work, "Exact ✓ · Embeddings 60% · about 12 min", and
    /// under it what the rest waits for, when something does.
    private func statusLines() -> [String] {
        switch engine.connection {
        case .missing: return ["sift-it isn't installed"]
        case .connecting: return ["Connecting…"]
        case .down: return ["sift-it's engine isn't running"]
        case .connected: break
        }
        guard let indexer = engine.indexer, indexerRuns(indexer) else {
            return ["The background indexer isn't running"]
        }
        let first: String
        switch indexer.state {
        case .starting: first = "Starting…"
        case .idle:
            first = engine.status.map { "Up to date: \($0.stats.files.formatted()) files" } ?? "Up to date"
        default:
            first =
                Phases.summary(indexer)
                ?? (indexer.state == .syncing ? "Comparing the folders with the index…" : "Indexing…")
        }
        if let detail = indexer.detail { return [first, detail] }
        if engine.meaning == .unavailable {
            return [first, "Exact only: " + (engine.meaningError ?? "embeddings are unavailable")]
        }
        return [first]
    }

    private func indexerActions() -> [NSMenuItem] {
        guard engine.isConnected else {
            return engine.connection == .missing
                ? [item("Copy the Install Command", #selector(copyInstall))]
                : [item("Start the Engine", #selector(startEngine))]
        }
        guard let indexer = engine.indexer, indexerRuns(indexer) else {
            return [item("Start the Background Indexer", #selector(installIndexer))]
        }
        return [
            item(indexer.state == .paused ? "Resume Indexing" : "Pause Indexing", #selector(pause)),
            item("Index Now", #selector(indexNow)),
        ]
    }

    /// The indexer's process is still there: its status file outlives it.
    private func indexerRuns(_ indexer: IndexerStatus) -> Bool {
        indexer.state != .stopped && indexer.pid > 0 && kill(indexer.pid, 0) == 0
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func search() { openSearch() }
    @objc private func settings() { openSettings() }
    @objc private func about() { openAbout() }
    @objc private func startEngine() { engine.start() }

    /// The indexer pauses and resumes on SIGUSR2, and looks again on SIGUSR1 (services/indexer.rs).
    @objc private func pause() {
        if let pid = engine.indexer?.pid { kill(pid, SIGUSR2) }
    }

    @objc private func indexNow() {
        if let pid = engine.indexer?.pid { kill(pid, SIGUSR1) }
    }

    @objc private func installIndexer() { startIndexing() }

    @objc private func copyInstall() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install jwa91/tap/sift-it", forType: .string)
    }
}
