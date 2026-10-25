// The settings: the shortcut, opening at login and searching with embeddings; the folders, each indexed up to a phase;
// how far indexing is, the models, and what goes on on battery. The window and its views exist only while it's open.

import ServiceManagement
import SiftItKit
import SwiftUI

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

    func show() {
        if window == nil {
            let view = SettingsView(engine: engine, setup: setup, hotkey: hotkey) { [weak self] in
                self?.window?.close()
                self?.openWelcome()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Sift It"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
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
    let openWelcome: () -> Void

    var body: some View {
        TabView {
            GeneralSettings(engine: engine, hotkey: hotkey)
                .tabItem { Label("General", systemImage: "gearshape") }
            FolderSettings(engine: engine, setup: setup)
                .tabItem { Label("Folders", systemImage: "folder") }
            IndexSettings(engine: engine, setup: setup, openWelcome: openWelcome)
                .tabItem { Label("Index", systemImage: "chart.bar.doc.horizontal") }
        }
        .frame(width: 520, height: 500)
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
            PermissionSettings()
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

/// What opening a result at its place needs from macOS, and where to allow it.
private struct PermissionSettings: View {
    @State private var canType = Permissions.canType
    private let checks = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Section("Opening results where they matched") {
            LabeledContent {
                if canType {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Allow…") { Permissions.askToType() }
                }
            } label: {
                Text("PDFs at the page")
                Text("Sift It types Preview's Go to Page for you (Accessibility).")
            }
            LabeledContent {
                Button("Automation Settings…") { Permissions.openAutomationSettings() }
            } label: {
                Text("Recordings and videos at the moment")
                Text("macOS asks once whether Sift It may control QuickTime Player, Preview and System Events.")
            }
        }
        // System Settings doesn't say when it changes: look again while the settings are open.
        .onReceive(checks) { _ in canType = Permissions.canType }
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
    @State private var problem: String?

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
        .task { change(nil, []) }
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
            await engine.refreshStatus()
            await setup.look()
        }
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
