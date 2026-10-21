// The settings: the shortcut, opening at login, how to search, and the folders to index. The window and its views
// exist only while it's open.

import ServiceManagement
import SiftItKit
import SwiftUI

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let engine: Engine
    private let hotkey: Hotkey
    private var window: NSWindow?

    init(engine: Engine, hotkey: Hotkey) {
        self.engine = engine
        self.hotkey = hotkey
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: SettingsView(engine: engine, hotkey: hotkey)))
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
    let hotkey: Hotkey

    var body: some View {
        TabView {
            GeneralSettings(engine: engine, hotkey: hotkey)
                .tabItem { Label("General", systemImage: "gearshape") }
            FolderSettings(engine: engine)
                .tabItem { Label("Folders", systemImage: "folder") }
            IndexSettings(engine: engine)
                .tabItem { Label("Index", systemImage: "chart.bar.doc.horizontal") }
        }
        .frame(width: 500, height: 380)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let engine: Engine
    let hotkey: Hotkey
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var mode = "meaning"
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
            Picker("Search by", selection: $mode) {
                Text("Meaning and words").tag("meaning")
                Text("Words only").tag("words")
            }
            .onChange(of: mode) { _, mode in
                Task { try? await engine.set("search.mode", to: mode) }
            }
            if let problem {
                Text(problem).foregroundStyle(.secondary)
            }
            PermissionSettings()
        }
        .formStyle(.grouped)
        .task {
            if let mode = try? await engine.setting("search.mode", as: String.self) { self.mode = mode }
        }
    }
}

/// A button that shows the shortcut, and takes the next one typed after a click.
private struct ShortcutRecorder: NSViewRepresentable {
    let hotkey: Hotkey

    func makeNSView(context: Context) -> RecorderButton {
        RecorderButton(hotkey: hotkey)
    }

    func updateNSView(_ view: RecorderButton, context: Context) {}
}

private final class RecorderButton: NSButton {
    private let hotkey: Hotkey
    private var recording = false {
        didSet { title = recording ? "Type a shortcut…" : Shortcut.saved.display }
    }

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
        // The shortcut being replaced mustn't open the panel while it's typed again.
        hotkey.unregister()
        recording = true
        window?.makeFirstResponder(self)
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
        if recording { finish(nil) }
        return super.resignFirstResponder()
    }

    private func finish(_ shortcut: Shortcut?) {
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
    @State private var folders: Folders?
    @State private var selected: String?
    @State private var skipped: String?
    @State private var problem: String?

    var body: some View {
        Form {
            Section("Search the files in") {
                FolderList(paths: folders?.folders ?? [], selection: $selected)
                HStack {
                    Button("Add Folders…") { choose { change(.add, $0) } }
                    Button("Remove") { selected.map { change(.remove, [$0]) } }
                        .disabled(selected == nil)
                }
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

    private func change(_ action: FolderAction?, _ paths: [String]) {
        Task {
            do {
                folders = try await engine.folders(action, paths: paths)
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
    @State private var downloading = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Engine", value: engineState)
                LabeledContent("Search by meaning", value: meaningState)
                if let stats = engine.status?.stats {
                    LabeledContent("Files", value: stats.files.formatted())
                    LabeledContent("Of which", value: kinds(stats))
                    LabeledContent("On disk", value: Format.bytes(stats.bytes))
                }
            }
            if engine.meaning == .unavailable, engine.cli != nil {
                Section {
                    Button(downloading ? "Downloading the model…" : "Download the Model (1.6 GB)") {
                        download()
                    }
                    .disabled(downloading)
                }
            }
        }
        .formStyle(.grouped)
        .task { await engine.refreshStatus() }
    }

    private var engineState: String {
        switch engine.connection {
        case .connected(let version): "sift-it \(version)"
        case .connecting: "Connecting…"
        case .missing: "sift-it isn't installed"
        case .down(let why): why
        }
    }

    private var meaningState: String {
        switch engine.meaning {
        case .ready: "Ready"
        case .loading: "Loading…"
        case .unavailable: engine.meaningError ?? "Unavailable"
        default: "Loads with the first search"
        }
    }

    private func kinds(_ stats: Stats) -> String {
        stats.byKind.sorted { $0.value > $1.value }
            .map { "\($0.value) \(Format.kindName(Kind(rawValue: $0.key)).lowercased())" }
            .joined(separator: ", ")
    }

    private func download() {
        guard let cli = engine.cli else { return }
        downloading = true
        Task {
            _ = await Run.output(cli, ["model", "download"])
            downloading = false
            await engine.refreshStatus()
        }
    }
}
