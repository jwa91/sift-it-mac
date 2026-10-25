// The search panel: a bar until there's something to show, then the results beside a preview of the selected one, and
// while indexing has rounds left, a line under them that says what can't be found yet.
//
// Every keystroke asks for results by words, answered at once. Once typing pauses, the same query is asked by meaning,
// and those results replace the others. A reply for an older query is dropped.

import AppKit
import Observation
import Quartz
import SiftItKit
import os

/// How long searches take: `log stream --level debug --predicate 'subsystem == "dev.sift-it.mac"'` shows it.
private let timings = Logger(subsystem: "dev.sift-it.mac", category: "search")

@MainActor
final class SearchController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let width: CGFloat = 760
    static let barHeight: CGFloat = 56
    static let expandedHeight: CGFloat = 480
    static let listWidth: CGFloat = 300
    static let cornerRadius: CGFloat = 26
    static let footerHeight: CGFloat = 26
    /// How long typing pauses before the query is asked by meaning.
    static let typingPause: Duration = .milliseconds(80)

    let engine: Engine
    var openSettings: () -> Void = {}

    private let panel = SearchPanel()
    private let field = NSTextField()
    private let note = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let separator = NSBox()
    private let body = NSView()
    private let list = ResultsList()
    private let preview = PreviewView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let footer = NSView()
    private let notYet = NSTextField(labelWithString: "")
    private var footerHeight: NSLayoutConstraint!

    private var query = ""
    /// Counts the queries asked: a reply for an older one is dropped.
    private var generation = 0
    /// The newest query whose results by meaning are showing: its results by words, coming late, are dropped.
    private var answered = -1
    private var meaningTask: Task<Void, Never>?
    private var expanded = false
    /// The panel's top edge on screen: it grows and shrinks downward from there.
    private var top: CGFloat = 0
    /// The selection was moved since the query last changed: Space plays rather than types.
    private var navigated = false
    private var keyMonitor: Any?
    private var hiding = false

    init(engine: Engine) {
        self.engine = engine
        super.init()
        build()
        preview.engine = engine
        list.onSelect = { [weak self] hit in
            guard let self else { return }
            preview.show(hit, query: query)
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().reloadData()
            }
        }
        list.onOpen = { [weak self] hit in self?.open(hit) }
        engine.onMeaningReady = { [weak self] in
            guard let self, isShown, !query.isEmpty else { return }
            search()
        }
        panel.quickLookItem = { [weak self] in self?.list.selectedHit?.url }
        panel.quickLookKey = { [weak self] event in self?.quickLookKey(event) ?? false }
        followIndexing()
    }

    /// Says what can't be found yet while the indexer has rounds left, so a missing hit isn't taken for a bad result:
    /// "Recordings: 40% written down". The line is laid out only when it comes or goes.
    private func followIndexing() {
        withObservationTracking {
            let line = engine.isConnected ? engine.indexer.flatMap(Milestones.notYet) : nil
            notYet.stringValue = line ?? ""
            notYet.toolTip = line
            footer.isHidden = line == nil
            footerHeight.constant = line == nil ? 0 : Self.footerHeight
        } onChange: {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.followIndexing() } }
        }
    }

    var isShown: Bool { panel.isVisible && !hiding }

    // MARK: - Showing and hiding

    func toggle() {
        isShown ? hide() : show()
    }

    func show() {
        guard !isShown else { return }
        hiding = false
        engine.start()
        place()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        // The last query stays, selected, so typing replaces it.
        field.currentEditor()?.selectAll(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === panel else { return event }
            return handleKey(event) ? nil : event
        }
        // The index may have changed while the panel was away.
        if !query.isEmpty { search() }
    }

    /// Shows the panel searching for `text`.
    func show(query text: String) {
        field.stringValue = text
        query = text
        navigated = false
        if isShown { search() } else { show() }
        field.currentEditor()?.moveToEndOfDocument(nil)
    }

    func hide() {
        guard isShown else { return }
        hiding = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        preview.stop()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hiding else { return }
                self.panel.orderOut(nil)
                self.hiding = false
            }
        }
    }

    /// Centred on the screen with the pointer, a fifth of the way down, as Spotlight sits.
    private func place() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        top = visible.maxY - (visible.height * 0.2).rounded()
        let height = expanded ? Self.expandedHeight : Self.barHeight
        panel.setFrame(
            NSRect(x: (visible.midX - Self.width / 2).rounded(), y: top - height, width: Self.width, height: height),
            display: false)
    }

    private func setExpanded(_ value: Bool) {
        guard value != expanded else { return }
        expanded = value
        separator.isHidden = !value
        body.isHidden = !value
        let height = value ? Self.expandedHeight : Self.barHeight
        let frame = NSRect(x: panel.frame.minX, y: top - height, width: Self.width, height: height)
        panel.setFrame(frame, display: true, animate: panel.isVisible)
        panel.invalidateShadow()
    }

    // MARK: - Searching

    func controlTextDidChange(_ notification: Notification) {
        navigated = false
        query = field.stringValue
        search()
    }

    private func search() {
        generation += 1
        let generation = generation
        meaningTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            spinner.stopAnimation(nil)
            note.stringValue = ""
            preview.show(nil, query: "")
            list.show([], keeping: nil)
            setExpanded(false)
            return
        }
        spinner.startAnimation(nil)
        Task {
            let asked = ContinuousClock.now
            let results = try? await engine.search(Search(q: q, mode: .words, prefixLast: true))
            guard let results else { return }
            Self.log(results, by: "words", since: asked)
            guard generation == self.generation, answered < generation else { return }
            show(results, final: false)
        }
        meaningTask = Task {
            try? await Task.sleep(for: Self.typingPause)
            guard !Task.isCancelled else { return }
            do {
                let asked = ContinuousClock.now
                let results = try await engine.search(Search(q: q, prefixLast: true))
                Self.log(results, by: "meaning", since: asked)
                guard generation == self.generation else { return }
                answered = generation
                show(results, final: true)
            } catch {
                guard generation == self.generation else { return }
                showProblem(error)
            }
        }
    }

    private static func log(_ results: Results, by mode: String, since asked: ContinuousClock.Instant) {
        let (seconds, attoseconds) = asked.duration(to: .now).components
        let ms = Double(seconds) * 1000 + Double(attoseconds) / 1e15
        timings.debug(
            "by \(mode, privacy: .public): \(results.hits.count) hits, engine \(results.ms, format: .fixed(precision: 1)) ms, round trip \(ms, format: .fixed(precision: 1)) ms"
        )
    }

    private func show(_ results: Results, final: Bool) {
        if final { spinner.stopAnimation(nil) }
        // Results by words can be empty while those by meaning are on their way: the last ones stay meanwhile.
        if results.hits.isEmpty, !final { return }
        note.stringValue = final && !results.meaning ? meaningNote : ""
        list.show(results.hits, keeping: navigated ? list.selectedHit?.path : nil)
        message.isHidden = !results.hits.isEmpty
        message.stringValue = "Nothing stands out.\nDescribe it differently, or type words that are in it."
        if results.hits.isEmpty { preview.show(nil, query: query) }
        setExpanded(true)
    }

    /// Why a search was by words only.
    private var meaningNote: String {
        switch engine.meaning {
        case .unavailable: engine.meaningError.map { "Words only: \($0)" } ?? "Words only"
        default: "Words only, while the model loads…"
        }
    }

    private func showProblem(_ error: any Error) {
        spinner.stopAnimation(nil)
        list.show([], keeping: nil)
        preview.show(nil, query: "")
        message.isHidden = false
        message.stringValue =
            switch engine.connection {
            case .missing: "sift-it isn't installed.\nInstall it with Homebrew: brew install jwa91/tap/sift-it"
            default: error.localizedDescription
            }
        setExpanded(true)
    }

    // MARK: - Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): move(by: -5)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): move(by: 5)
        case #selector(NSResponder.insertNewline(_:)): list.selectedHit.map(open)
        case #selector(NSResponder.insertTab(_:)): preview.togglePlayback()
        case #selector(NSResponder.cancelOperation(_:)): hide()
        default: return false
        }
        return true
    }

    private func move(by step: Int) {
        navigated = true
        list.move(by: step)
    }

    /// The keys with ⌘, and Space once the selection was moved. True when handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([
            .capsLock, .numericPad, .function,
        ])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let hit = list.selectedHit
        if flags.isEmpty, event.keyCode == 49, navigated, hit?.kind.plays == true {
            return preview.togglePlayback()
        }
        guard flags.contains(.command) else { return false }
        switch (key, flags.contains(.shift)) {
        case ("\r", _): hit.map(Actions.reveal)
        case ("o", false): hit.map(open)
        case ("y", false): toggleQuickLook()
        case ("c", false):
            // Copying text in the field stays copying text.
            if let editor = field.currentEditor(), editor.selectedRange.length > 0 { return false }
            hit.map(Actions.copyFile)
        case ("c", true): hit.map(Actions.copyPath)
        case (",", false):
            hide()
            openSettings()
        case ("w", false): hide()
        default: return false
        }
        return true
    }

    private func open(_ hit: Hit) {
        hide()
        Actions.open(hit, cli: engine.cli)
    }

    // MARK: - Quick Look

    private func toggleQuickLook() {
        guard list.selectedHit != nil else { return }
        let quickLook = QLPreviewPanel.shared()!
        if quickLook.isVisible {
            quickLook.orderOut(nil)
        } else {
            preview.player.av.pause()
            quickLook.makeKeyAndOrderFront(nil)
        }
    }

    /// Keys while Quick Look has the keyboard: up and down go through the results, Space and ⌘Y close it.
    private func quickLookKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 126: move(by: -1)
        case 125: move(by: 1)
        case 49: QLPreviewPanel.shared().orderOut(nil)
        case 53:
            QLPreviewPanel.shared().orderOut(nil)
            hide()
        default:
            guard event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "y" else { return false }
            QLPreviewPanel.shared().orderOut(nil)
        }
        return true
    }

    // MARK: - NSWindowDelegate

    /// A click elsewhere puts the panel away, as Spotlight's; Quick Look taking the keyboard doesn't.
    func windowDidResignKey(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isKeyWindow { return }
        hide()
    }

    // MARK: - Layout

    private func build() {
        let root = NSView()
        let icon = NSImageView(
            image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!
                .withSymbolConfiguration(.init(pointSize: 19, weight: .medium))!)
        icon.contentTintColor = .secondaryLabelColor

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.placeholderAttributedString = NSAttributedString(
            string: "Describe it, or type the words",
            attributes: [.foregroundColor: NSColor.placeholderTextColor, .font: NSFont.systemFont(ofSize: 22)])
        field.delegate = self

        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.setContentCompressionResistancePriority(.required, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        separator.boxType = .separator
        separator.isHidden = true
        body.isHidden = true

        let divider = NSBox()
        divider.boxType = .separator
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 13)
        message.isHidden = true
        notYet.font = .systemFont(ofSize: 11)
        notYet.textColor = .tertiaryLabelColor
        notYet.lineBreakMode = .byTruncatingTail
        // A long line is cut short, rather than widening the panel; its tooltip says all of it.
        notYet.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        notYet.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(notYet)
        footer.isHidden = true

        for view in [icon, field, note, spinner, separator, body] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        for view in [list.view, divider, preview, message, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
        }
        let bar = Self.barHeight
        footerHeight = footer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: root.topAnchor, constant: bar / 2),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: note.leadingAnchor, constant: -8),
            note.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -8),
            note.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            separator.topAnchor.constraint(equalTo: root.topAnchor, constant: bar),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            // The body keeps its height while the panel grows over it: nothing lays out again as it animates.
            body.topAnchor.constraint(equalTo: separator.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.heightAnchor.constraint(equalToConstant: Self.expandedHeight - bar - 1),

            list.view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            list.view.topAnchor.constraint(equalTo: body.topAnchor),
            list.view.bottomAnchor.constraint(equalTo: footer.topAnchor),
            list.view.widthAnchor.constraint(equalToConstant: Self.listWidth),
            divider.leadingAnchor.constraint(equalTo: list.view.trailingAnchor),
            divider.topAnchor.constraint(equalTo: body.topAnchor),
            divider.bottomAnchor.constraint(equalTo: footer.topAnchor),
            preview.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            preview.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            preview.topAnchor.constraint(equalTo: body.topAnchor),
            preview.bottomAnchor.constraint(equalTo: footer.topAnchor),
            message.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: body.centerYAnchor, constant: -20),
            message.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor, constant: -80),

            footer.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            footerHeight,
            notYet.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20),
            notYet.trailingAnchor.constraint(lessThanOrEqualTo: footer.trailingAnchor, constant: -20),
            notYet.centerYAnchor.constraint(equalTo: footer.centerYAnchor, constant: -2),
        ])

        panel.contentView = panelBackground(cornerRadius: Self.cornerRadius, content: root)
        panel.delegate = self
        place()
    }
}
