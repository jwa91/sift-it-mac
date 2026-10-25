// The welcome window: what Sift It is, its models, the folders to search, opening results where they matched (which can
// be skipped), indexing in the background and where things are, then how far indexing is, in its three phases. It does what the command line's setup did, so installing the app
// is all there is to it. No folder is read before it's chosen here. Its views exist only while it's open.

import SiftItKit
import SwiftUI

@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    private let engine: Engine
    private let setup: Setup
    private let hotkey: Hotkey
    private var window: NSWindow?
    /// The welcome is done: the search is next.
    var onFinish: () -> Void = {}

    init(engine: Engine, setup: Setup, hotkey: Hotkey) {
        self.engine = engine
        self.setup = setup
        self.hotkey = hotkey
    }

    func show() {
        if window == nil {
            let view = WelcomeView(engine: engine, setup: setup, hotkey: hotkey) { [weak self] in
                self?.window?.close()
                self?.onFinish()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
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

private struct WelcomeView: View {
    let engine: Engine
    @Bindable var setup: Setup
    let hotkey: Hotkey
    let finish: () -> Void

    private enum Page: Int, CaseIterable {
        case hello, models, folders, permissions, ready, indexing
    }

    @State private var page = Page.hello
    /// The folders chosen, in the order they were: those indexed already, and those added here.
    @State private var chosen: [String] = []
    @State private var inBackground = true
    @State private var atLogin = true
    @State private var starting = false
    @State private var problem: String?

    /// The folders offered with a click: none is read, or even looked into, until it's chosen.
    private static let suggested: [String] = ["Documents", "Desktop", "Downloads"]
        .map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).path }
        .filter { FileManager.default.fileExists(atPath: $0) }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .hello: hello
                case .models: modelsPage
                case .folders: foldersPage
                case .permissions: permissionsPage
                case .ready: readyPage
                case .indexing: indexingPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 56)
            .padding(.top, 44)
            footer
        }
        .frame(width: 620, height: 600)
        .task { await begin() }
    }

    // MARK: - Pages

    private var hello: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Welcome to Sift It")
                .font(.largeTitle.weight(.bold))
            Text("One search bar for everything on your Mac, by what's in it.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 16) {
                Feature(
                    symbol: "text.magnifyingglass", title: "Describe it, or type the words",
                    text: "The page in a PDF, the photo, the minute in a podcast, the moment in a video.")
                Feature(
                    symbol: "lock.shield", title: "Private by design",
                    text: "Everything runs on this Mac. Nothing you search or index leaves it.")
                Feature(
                    symbol: "bolt", title: "Results as you type",
                    text: "From a search engine built in Rust, a shortcut away in any app.")
            }
            .padding(.top, 12)
        }
    }

    private var modelsPage: some View {
        PageLayout(
            symbol: "arrow.down.circle", title: "Download the models",
            text: "Sift It runs two models on this Mac. They're downloaded once: \(megabytes(Setup.Model.bytes))."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Setup.Model.allCases, id: \.self) { model in
                        ModelRow(model: model, ready: setup.has(model))
                    }
                    Label {
                        Text("Text in screenshots and scans is read by macOS itself.")
                    } icon: {
                        Image(systemName: "text.viewfinder")
                    }
                    .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    switch setup.models {
                    case .unknown:
                        ProgressView().controlSize(.small)
                    case .missing:
                        Button("Download (\(megabytes(Setup.Model.bytes)))") { setup.downloadModels() }
                            .controlSize(.large)
                    case .downloading(let done, let total):
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                        Text(total > 0 ? "\(megabytes(done)) of \(megabytes(total))" : "Starting…")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("It goes on downloading while you continue.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    case .ready:
                        Label("The models are ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.title3)
                    case .failed(let why):
                        Label(why, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Try Again") { setup.downloadModels() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if setup.models == .missing { setup.downloadModels() } }
    }

    private var foldersPage: some View {
        PageLayout(
            symbol: "folder", title: "Choose what to search",
            text: "Sift It reads each file once, then keeps up as files change. You can change this later in Settings."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(chosen, id: \.self) { folder in
                            FolderRow(
                                folder: folder, indexed: setup.indexed.contains(folder),
                                counting: setup.counting.contains(folder), estimate: setup.estimates[folder]
                            ) { chosen.removeAll { $0 == folder } }
                            if folder != chosen.last { Divider() }
                        }
                        if chosen.isEmpty {
                            Text("No folders yet")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                HStack(spacing: 8) {
                    // Named by their path alone: asking macOS for a folder's name or icon can read inside it.
                    ForEach(Self.suggested.filter { !chosen.contains($0) }, id: \.self) { folder in
                        Button {
                            add([folder])
                        } label: {
                            Label((folder as NSString).lastPathComponent, systemImage: "plus")
                        }
                    }
                    Spacer()
                    Button("Add Folder…", action: addFolder)
                }
                Label("macOS asks once whether Sift It may read each folder you add.", systemImage: "hand.raised")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The same as Settings → Permissions, and nothing on it has to be done.
    private var permissionsPage: some View {
        PageLayout(
            symbol: "hand.raised", title: "Open results where they matched",
            text: """
                A PDF at its page, audio and video at the moment: macOS asks once whether Sift It may. Without it, results \
                open at the start. You can skip this, and allow it later in Settings.
                """
        ) {
            PermissionsForm(explained: false)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .padding(.horizontal, -20)
                .padding(.top, -16)
        }
    }

    private var readyPage: some View {
        PageLayout(
            symbol: "checkmark.seal", title: "You're all set",
            text: firstPass.map {
                "Exact search works in \($0.exact), and all of it takes \($0.all). You can search meanwhile."
            } ?? "You can search while Sift It indexes."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $inBackground) {
                    Text("Keep the index up to date in the background")
                    Text("From login on, new and changed files are indexed as they come.")
                }
                Toggle("Open Sift It at login", isOn: $atLogin)
                LabeledContent("Search from any app with") {
                    ShortcutRecorder(hotkey: hotkey).fixedSize()
                }
                Label {
                    Text(
                        """
                        Sift It lives in the menu bar: \(Image(systemName: "sparkle.magnifyingglass")). Its settings \
                        are there, and in the search: the gear, or ⌘,. Can't see the icon on a full menu bar? Open \
                        Sift It again, and the search opens.
                        """)
                } icon: {
                    Image(systemName: "menubar.rectangle")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
    }

    /// Searching works from the start: Exact within seconds to minutes, then Embeddings and Transcribed.
    private var indexingPage: some View {
        let indexer = engine.indexer.flatMap { $0.rounds.isEmpty ? nil : $0 } ?? expected
        let text =
            !setup.inBackground
            ? "Indexing in the background is off. Turn it on in Settings, and Sift It reads your files."
            : "The bar fills once for each phase: Exact, Embeddings, then Transcribed. You can search all along."
        return PageLayout(symbol: "magnifyingglass", title: "You can search now", text: text) {
            if setup.inBackground {
                PhaseProgress(indexer: indexer)
                    .padding(.top, 4)
            }
        }
    }

    /// The phases the chosen folders will go through, before the indexer says how far each is.
    private var expected: IndexerStatus {
        let rounds = Set(chosen.flatMap { setup.estimates[$0]?.rounds.map(\.round) ?? [] })
        return IndexerStatus(
            pid: 0, state: .starting,
            rounds: Round.all.filter { $0 == .words || rounds.contains($0) }.map {
                RoundStatus(round: $0, state: $0 == .words ? .running : .queued)
            })
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 7) {
                ForEach(Page.allCases, id: \.self) { dot in
                    Circle()
                        .fill(dot == page ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if page != .hello, page != .indexing {
                Button("Back") { go(-1) }
                    .controlSize(.large)
            }
            Button(page == .ready ? "Start Indexing" : page == .indexing ? "Start Searching" : "Continue") {
                switch page {
                case .ready: start()
                case .indexing: finish()
                default: go(1)
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(page == .folders && chosen.isEmpty || starting)
        }
        .padding(20)
    }

    // MARK: - Doing it

    private func begin() async {
        await setup.look()
        chosen = setup.indexed
        inBackground = setup.inBackground || !Setup.isDone
        atLogin = Setup.opensAtLogin || !Setup.isDone
    }

    private func go(_ step: Int) {
        guard let next = Page(rawValue: page.rawValue + step) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { page = next }
    }

    private func start() {
        starting = true
        problem = nil
        Task {
            do {
                try await setup.index(Set(chosen))
                try await setup.indexInBackground(inBackground)
                try Setup.openAtLogin(atLogin)
                Setup.isDone = true
                go(1)
            } catch {
                problem = error.localizedDescription
            }
            starting = false
        }
    }

    /// Adds folders, and counts each: reading it is when macOS asks about it, right after it was chosen.
    private func add(_ folders: [String]) {
        for folder in folders where !chosen.contains(folder) {
            chosen.append(folder)
            if !setup.indexed.contains(folder) { Task { await setup.estimate(folder) } }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        add(panel.urls.map(\.path))
    }

    /// How long indexing the chosen folders that aren't indexed yet takes, once each is counted: until Exact search
    /// works, and all of it.
    private var firstPass: (exact: String, all: String)? {
        let new = chosen.filter { !setup.indexed.contains($0) }
        let counted = new.compactMap { setup.estimates[$0] }
        guard !counted.isEmpty, counted.count == new.count else { return nil }
        let exact = counted.reduce(0) { $0 + $1.seconds(of: .exact) }
        let all = counted.reduce(0) { $0 + $1.seconds }
        return (Format.duration(exact), Format.duration(all))
    }
}

// MARK: - Parts

private struct PageLayout<Content: View>: View {
    let symbol: String
    let title: String
    let text: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.largeTitle.weight(.bold))
                Text(text).font(.title3).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}

/// A folder chosen, with its files and what indexing it takes, and a way to take it out again.
private struct FolderRow: View {
    let folder: String
    let indexed: Bool
    let counting: Bool
    let estimate: Estimate?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder))
                .resizable()
                .frame(width: 22, height: 22)
            Text(FileManager.default.displayName(atPath: folder))
            Spacer()
            if !indexed, counting, estimate == nil {
                ProgressView().controlSize(.mini)
            }
            Text(summary)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(FileManager.default.displayName(atPath: folder))")
        }
        .padding(.vertical, 8)
    }

    private var summary: String {
        if indexed { return "Indexed" }
        guard let estimate else { return counting ? "Counting…" : "" }
        if estimate.unreadable { return "Not readable yet" }
        let files = estimate.files == 1 ? "1 file" : "\(estimate.files.formatted()) files"
        return "\(files) · \(Format.duration(estimate.seconds))"
    }
}

/// A model, what it's for and its size, and whether it's there.
struct ModelRow: View {
    let model: Setup.Model
    let ready: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.name).fontWeight(.medium)
                Text(model.about)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(megabytes(model.bytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

func megabytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
