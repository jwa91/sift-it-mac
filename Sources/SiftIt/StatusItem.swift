// Sift It in the menu bar: its icon says whether the index is up to date (and how far indexing is while it works), and
// its menu opens the search, pauses indexing, and holds the settings.

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
        let progress = indexer.flatMap { $0.isWorking ? $0.progress : nil }
        item.button?.title = progress.map { " \(Int($0 * 100))%" } ?? ""
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
        let settings = item("Settings…", #selector(settings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = item("Quit Sift It", #selector(NSApplication.terminate(_:)))
        quit.target = NSApp
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// How the index is doing, in a line or two.
    private func statusLines() -> [String] {
        switch engine.connection {
        case .missing: return ["sift-it isn't installed"]
        case .connecting: return ["Connecting…"]
        case .down: return ["sift-it's engine isn't running"]
        case .connected: break
        }
        var lines: [String] = []
        let files = engine.status?.stats.files
        if let indexer = engine.indexer, indexerRuns(indexer) {
            switch indexer.state {
            case .indexing:
                let percent = indexer.progress.map { " (\(Int($0 * 100))%)" } ?? ""
                lines.append("Indexing \(indexer.done) of \(indexer.total) files\(percent)")
            case .syncing: lines.append("Comparing the folders with the index…")
            case .transcribing: lines.append("Writing down speech: \(indexer.speechDone) of \(indexer.speechTotal)")
            case .waiting: lines.append("Waiting" + (indexer.detail.map { ": \($0)" } ?? ""))
            case .paused: lines.append("Indexing is paused")
            case .starting: lines.append("Starting…")
            default: lines.append(files.map { "Up to date: \($0.formatted()) files" } ?? "Up to date")
            }
            if indexer.isWorking, let current = indexer.current {
                lines.append((current as NSString).lastPathComponent)
            }
        } else {
            lines.append("The background indexer isn't running")
        }
        if engine.meaning == .unavailable {
            lines.append("Words only: " + (engine.meaningError ?? "search by meaning is unavailable"))
        }
        return lines
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
    @objc private func startEngine() { engine.start() }

    /// The indexer pauses and resumes on SIGUSR2, and looks again on SIGUSR1 (services/indexer.rs).
    @objc private func pause() {
        if let pid = engine.indexer?.pid { kill(pid, SIGUSR2) }
    }

    @objc private func indexNow() {
        if let pid = engine.indexer?.pid { kill(pid, SIGUSR1) }
    }

    @objc private func installIndexer() {
        guard let cli = engine.cli else { return }
        Task { _ = await Run.output(cli, ["service", "install"]) }
    }

    @objc private func copyInstall() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install jwa91/tap/sift-it", forType: .string)
    }
}
