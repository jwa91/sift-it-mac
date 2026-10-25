// The settings, in a window with a sidebar as macOS's own: its title is the pane shown, it opens at the pane shown last,
// and it neither minimizes nor zooms. General: the shortcut, opening at login and searching with embeddings. Folders:
// each indexed up to a phase, and the kinds of files read in all of them. Index: how far indexing is, the embeddings
// by kind, the models, and what goes on on battery. Permissions: opening results where they matched. About. The window
// and its views exist only while it's open.

import ServiceManagement
import SiftItKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, folders, index, permissions, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .folders: "Folders"
        case .index: "Index"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .folders: "folder"
        case .index: "chart.bar.doc.horizontal"
        case .permissions: "hand.raised"
        case .about: "info.circle"
        }
    }

    /// The pane shown last, where the settings open again.
    static let defaultsKey = "settingsPane"
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let engine: Engine
    private let setup: Setup
    private let hotkey: Hotkey
    private var window: NSWindow?
    /// Opens the welcome window again.
    var openWelcome: () -> Void = {}

    init(engine: Engine, setup: Setup, hotkey: Hotkey) {
        self.engine = engine
        self.setup = setup
        self.hotkey = hotkey
    }

    /// Opens the settings at a pane, or at the one shown last.
    func show(_ pane: SettingsPane? = nil) {
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: SettingsPane.defaultsKey) }
        if window == nil {
            let view = SettingsView(
                engine: engine, setup: setup, hotkey: hotkey,
                showing: { [weak self] pane in self?.window?.title = pane.title },
                openWelcome: { [weak self] in
                    self?.window?.close()
                    self?.openWelcome()
                })
            let controller = NSHostingController(rootView: view)
            // The sidebar's toolbar, with the window's title beside it.
            controller.sceneBridgingOptions = [.toolbars]
            // The window is there before its view, which names the first pane.
            let window = NSWindow(
                contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered,
                defer: true)
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
            window.contentViewController = controller
            window.center()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct SettingsView: View {
    let engine: Engine
    let setup: Setup
    let hotkey: Hotkey
    /// The pane shown changed: its title is the window's.
    let showing: (SettingsPane) -> Void
    let openWelcome: () -> Void
    @AppStorage(SettingsPane.defaultsKey) private var pane = SettingsPane.general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: selection) { pane in
                Label(pane.title, systemImage: pane.symbol)
            }
            .navigationSplitViewColumnWidth(180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch pane {
            case .general: GeneralSettings(engine: engine, hotkey: hotkey)
            case .folders: FolderSettings(engine: engine, setup: setup)
            case .index: IndexSettings(engine: engine, setup: setup, openWelcome: openWelcome)
            case .permissions: PermissionsForm()
            case .about: AboutPane()
            }
        }
        .frame(width: 700, height: 560)
        .onChange(of: pane, initial: true) { showing(pane) }
    }

    private var selection: Binding<SettingsPane?> {
        Binding(get: { pane }, set: { if let chosen = $0 { pane = chosen } })
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let engine: Engine
    let hotkey: Hotkey
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var embeddings = true
    @State private var problem: String?

    var body: some View {
        Form {
            LabeledContent("Open the search with") {
                ShortcutRecorder(hotkey: hotkey).fixedSize()
            }
            Toggle("Open Sift It at login", isOn: $atLogin)
                .onChange(of: atLogin) { _, on in
                    do {
                        try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    } catch {
                        problem = error.localizedDescription
                    }
                }
            Toggle(isOn: $embeddings) {
                Text("Search with embeddings")
                Text(Phase.embeddings.explanation + " Off, searches are Exact only.")
            }
            .onChange(of: embeddings) { _, on in
                Task { try? await engine.set("search.mode", to: on ? Mode.meaning.rawValue : Mode.words.rawValue) }
            }
            if let problem {
                Text(problem).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            if let mode = try? await engine.setting("search.mode", as: String.self) {
                embeddings = mode != Mode.words.rawValue
            }
        }
    }
}

/// A button that shows the shortcut, and takes the next one typed after a click.
struct ShortcutRecorder: NSViewRepresentable {
    let hotkey: Hotkey

    func makeNSView(context: Context) -> RecorderButton {
        RecorderButton(hotkey: hotkey)
    }

    func updateNSView(_ view: RecorderButton, context: Context) {}
}

final class RecorderButton: NSButton {
    private let hotkey: Hotkey
    private var recording = false {
        didSet { title = recording ? "Type a shortcut…" : Shortcut.saved.display }
    }
    /// Watches the window while recording: it stops being key when it closes or another app comes forward.
    private var resignedKey: (any NSObjectProtocol)?

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
        super.init(frame: .zero)
        bezelStyle = .push
        title = Shortcut.saved.display
        target = self
        action = #selector(start)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc private func start() {
        guard !recording, let window else { return }
        // The shortcut being replaced mustn't open the panel while it's typed again.
        hotkey.unregister()
        recording = true
        window.makeFirstResponder(self)
        // Neither closing the window nor going to another app takes first responder away: the old shortcut comes
        // back then too.
        resignedKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        if event.keyCode == 53 {
            finish(nil)
        } else if let shortcut = Shortcut(event: event) {
            finish(shortcut)
        } else {
            NSSound.beep()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        finish(nil)
        return super.resignFirstResponder()
    }

    /// A page of the welcome window going takes the button out of its window without resigning it first responder.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { finish(nil) }
        super.viewWillMove(toWindow: newWindow)
    }

    private func finish(_ shortcut: Shortcut?) {
        guard recording else { return }
        if let resignedKey { NotificationCenter.default.removeObserver(resignedKey) }
        resignedKey = nil
        if let shortcut {
            if hotkey.register(shortcut) {
                Shortcut.saved = shortcut
            } else {
                NSSound.beep()
                hotkey.register(.saved)
            }
        } else {
            hotkey.register(.saved)
        }
        recording = false
    }
}

// MARK: - Folders

private struct FolderSettings: View {
    let engine: Engine
    let setup: Setup
    @State private var folders: Folders?
    /// The phase each folder is indexed up to.
    @State private var phases: [String: Phase] = [:]
    @State private var selected: String?
    @State private var skipped: String?
    /// Whether each kind of file is read, once known.
    @State private var reading: [Kind: Bool] = [:]
    /// A kind with files in the index, about to be left out: what leaves with it.
    @State private var leaving: (kind: Kind, files: String)?
    @State private var problem: String?

    /// The kinds of files offered, with what each takes in. Screenshots are pictures macOS marked as one.
    private static let kinds: [(kind: Kind, about: String)] = [
        (.document, "PDFs, Word and web pages"),
        (.plaintext, "Plain text and Markdown"),
        (.structured, "CSV, JSON and YAML"),
        (.image, "Photos and screenshots"),
        (.audio, "Music, podcasts and voice memos"),
        (.video, "Films and screen recordings"),
        (.code, "Source code, and notes in projects"),
        (.conversation, "Claude Code and Codex"),
    ]

    var body: some View {
        Form {
            Section {
                if let paths = folders?.folders, !paths.isEmpty {
                    List(paths, id: \.self, selection: $selected) { path in
                        HStack {
                            Label(Format.shortPath(path), systemImage: "folder")
                            Spacer()
                            Picker("Index up to", selection: phase(of: path)) {
                                ForEach(Phase.allCases, id: \.self) { Text($0.name).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    .frame(minHeight: 70, maxHeight: 130)
                } else {
                    Text("None").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Add Folders…") { choose { change(.add, $0) } }
                    Button("Remove") { selected.map { change(.remove, [$0]) } }
                        .disabled(selected == nil)
                }
                if let folders {
                    let offered = Setup.conversationFolders.filter { !folders.folders.contains($0.path) }
                    if !offered.isEmpty {
                        HStack {
                            ForEach(offered, id: \.path) { folder in
                                Button {
                                    change(.add, [folder.path])
                                } label: {
                                    Label(folder.name, systemImage: "plus")
                                }
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Search the files in")
                    Spacer()
                    Text("Index up to")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Phase.allCases, id: \.self) { phase in
                        Text("**\(phase.name)**: \(phase.explanation)")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Section {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading),
                    ],
                    alignment: .leading, spacing: 10
                ) {
                    ForEach(Self.kinds, id: \.kind) { kind, about in
                        Toggle(isOn: reads(kind)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Format.kindsName(kind))
                                Text(about).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(reading[kind] == nil)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Kinds of files")
            } footer: {
                Text(
                    "Always left out: hidden files and folders, apps and libraries, dependency and build folders, "
                        + "keys and secrets."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Section("But skip") {
                FolderList(paths: folders?.excluded ?? [], selection: $skipped)
                HStack {
                    Button("Skip a Folder…") { choose { change(.exclude, $0) } }
                    Button("Include Again") { skipped.map { change(.include, [$0]) } }
                        .disabled(skipped == nil)
                }
            }
            if let problem {
                Text(problem).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            leaving.map { "Leave out \(Format.kindsName($0.kind))?" } ?? "",
            isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }),
            titleVisibility: .visible, presenting: leaving
        ) { leaving in
            Button("Leave Out", role: .destructive) { read(leaving.kind, false) }
            Button("Cancel", role: .cancel) {}
        } message: { leaving in
            Text(leaving.files)
        }
        .task { change(nil, []) }
        .task {
            do {
                let lists = try await engine.setting("sources.kinds", as: [String: [String]].self)
                let code = try await engine.setting("sources.code", as: Bool.self)
                for (kind, _) in Self.kinds {
                    reading[kind] = kind == .code ? code : lists[kind.rawValue]?.isEmpty == false
                }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// Whether a kind is read. Leaving out one with files in the index asks first: they leave it, and coming back
    /// they're indexed again, transcripts and all.
    private func reads(_ kind: Kind) -> Binding<Bool> {
        Binding(
            get: { reading[kind] ?? false },
            set: { on in
                guard !on else { return read(kind, true) }
                Task {
                    let indexed = await engine.refreshStatus()?.stats.byKind ?? [:]
                    if let files = Format.leaving(kind, indexed: indexed) {
                        leaving = (kind, files)
                    } else {
                        read(kind, false)
                    }
                }
            })
    }

    /// Reads a kind or not, in every folder: its file types in `sources.kinds`, where an empty list reads none and null
    /// puts the types back; code has `sources.code`. The indexer follows at once, adding or taking out its files.
    private func read(_ kind: Kind, _ on: Bool) {
        reading[kind] = on
        Task {
            do {
                if kind == .code {
                    try await engine.set("sources.code", to: on ? "true" : "false")
                } else {
                    try await engine.set("sources.kinds.\(kind.rawValue)", to: on ? "null" : "[]")
                }
                problem = nil
            } catch {
                reading[kind] = !on
                problem = error.localizedDescription
            }
        }
    }

    /// A folder's phase: changing it writes its rule in `reading.rules`.
    private func phase(of path: String) -> Binding<Phase> {
        Binding(
            get: { phases[path] ?? .transcribed },
            set: { phase in
                phases[path] = phase
                Task {
                    do {
                        try await setup.index(upTo: [path: phase])
                        problem = nil
                    } catch {
                        problem = error.localizedDescription
                    }
                }
            })
    }

    private func change(_ action: FolderAction?, _ paths: [String]) {
        Task {
            do {
                let folders = try await engine.folders(action, paths: paths)
                phases = try await setup.phases(of: folders.folders)
                self.folders = folders
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func choose(_ chosen: @escaping ([String]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { chosen(panel.urls.map(\.path)) }
    }
}

private struct FolderList: View {
    let paths: [String]
    @Binding var selection: String?

    var body: some View {
        if paths.isEmpty {
            Text("None").foregroundStyle(.secondary)
        } else {
            List(paths, id: \.self, selection: $selection) { path in
                Label(Format.shortPath(path), systemImage: "folder")
            }
            .frame(minHeight: 60, maxHeight: 110)
        }
    }
}

// MARK: - Index

private struct IndexSettings: View {
    let engine: Engine
    @Bindable var setup: Setup
    let openWelcome: () -> Void
    @State private var onBattery = "words"
    @State private var problem: String?

    var body: some View {
        Form {
            if let indexer = engine.indexer, indexer.phases.contains(where: { !$0.isDone }) {
                Section("Indexing") {
                    PhaseProgress(indexer: indexer, explained: false)
                        .padding(.vertical, 4)
                }
            }
            if let stats = engine.status?.stats {
                Section {
                    EmbeddingsByKind(vectors: stats.vectorsByKind, progress: embeddingsProgress)
                        .padding(.vertical, 4)
                } header: {
                    HStack {
                        Text("Embeddings")
                        Spacer()
                        Text(stats.vectors.formatted()).monospacedDigit()
                    }
                } footer: {
                    Text(
                        "Each square is one percent, in the colour of the kind of file it's from"
                            + (embeddingsProgress < 1 ? ", and empty while it's still to embed." : ".")
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            Section {
                if let stats = engine.status?.stats {
                    LabeledContent("Files", value: stats.files.formatted())
                    LabeledContent("Of which", value: kinds(stats))
                    LabeledContent("On disk", value: Format.bytes(stats.bytes))
                }
                LabeledContent("Engine", value: engineState)
            }
            Section {
                ForEach(Setup.Model.allCases, id: \.self) { model in
                    LabeledContent {
                        Text(state(of: model))
                    } label: {
                        Text(model.name)
                        Text("\(model.about) · \(megabytes(model.bytes))")
                    }
                }
                switch setup.models {
                case .missing, .failed:
                    Button("Download the Models (\(megabytes(Setup.Model.bytes)))") { setup.downloadModels() }
                case .downloading(let done, let total):
                    ProgressView(value: Double(done), total: Double(max(total, 1))) { Text("Downloading the models…") }
                default:
                    EmptyView()
                }
            } header: {
                Text("Models")
            } footer: {
                Text("Text in screenshots and scans is read by macOS itself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(
                    isOn: Binding(
                        get: { setup.inBackground }, set: { on in change { try await setup.indexInBackground(on) } })
                ) {
                    Text("Keep the index up to date in the background")
                    Text("From login on, new and changed files are indexed as they come.")
                }
                Picker(
                    selection: Binding(
                        get: { onBattery },
                        set: { value in
                            onBattery = value
                            change { try await engine.set("indexing.on_battery", to: value) }
                        })
                ) {
                    Text("Exact only").tag("words")
                    Text("Everything").tag("all")
                    Text("Pause").tag("none")
                } label: {
                    Text("On battery")
                    Text("With Exact only, new files still go through every phase; the rest waits for a charger.")
                }
                Button("Set Up Again…", action: openWelcome)
                if let problem {
                    Text(problem).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            if let value = try? await engine.setting("indexing.on_battery", as: String.self) { onBattery = value }
            await setup.look()
        }
        // The counts change as files are indexed: look again while the pane is open.
        .task {
            while !Task.isCancelled {
                await engine.refreshStatus()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// How far Embeddings is: all of it once it's done, or when there's no indexer to say.
    private var embeddingsProgress: Double {
        guard let phase = engine.indexer?.phases.first(where: { $0.phase == .embeddings }), !phase.isDone else {
            return 1
        }
        return phase.progress
    }

    private func change(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private var engineState: String {
        switch engine.connection {
        case .connected(let version): "sift-it \(version)"
        case .connecting: "Connecting…"
        case .missing: "sift-it isn't installed"
        case .down(let why): why
        }
    }

    /// Whether a model is there, and EmbeddingGemma's state in the engine: it loads with the first search.
    private func state(of model: Setup.Model) -> String {
        guard setup.has(model) else {
            if case .downloading = setup.models { return "Downloading…" }
            return "Not downloaded"
        }
        guard model == .embeddings else { return "Ready" }
        switch engine.meaning {
        case .ready: return "Ready"
        case .loading: return "Loading…"
        case .unavailable: return engine.meaningError ?? "Unavailable"
        default: return "Loads with the first search"
        }
    }

    private func kinds(_ stats: Stats) -> String {
        stats.byKind.sorted { $0.value > $1.value }
            .map { Format.kindCount(Kind(rawValue: $0.key), $0.value) }
            .joined(separator: ", ")
    }
}
