// The welcome window: what Sift It is, the model, the folders to search, and indexing in the background. It does what
// the command line's setup did, so installing the app is all there is to it. Its views exist only while it's open.

import SiftItKit
import SwiftUI

@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    private let setup: Setup
    private let hotkey: Hotkey
    private var window: NSWindow?
    /// The welcome is done: the search is next.
    var onFinish: () -> Void = {}

    init(setup: Setup, hotkey: Hotkey) {
        self.setup = setup
        self.hotkey = hotkey
    }

    func show() {
        if window == nil {
            let view = WelcomeView(setup: setup, hotkey: hotkey) { [weak self] in
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
    @Bindable var setup: Setup
    let hotkey: Hotkey
    let finish: () -> Void

    private enum Page: Int, CaseIterable {
        case hello, model, folders, ready
    }

    @State private var page = Page.hello
    /// The folders offered: the usual ones in the home folder, those indexed already, and those added here.
    @State private var offered: [String] = []
    @State private var chosen: Set<String> = []
    @State private var inBackground = true
    @State private var atLogin = true
    @State private var starting = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .hello: hello
                case .model: modelPage
                case .folders: foldersPage
                case .ready: readyPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 56)
            .padding(.top, 44)
            footer
        }
        .frame(width: 620, height: 580)
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

    private var modelPage: some View {
        PageLayout(
            symbol: "arrow.down.circle", title: "Download the model",
            text: """
                Sift It understands your files with Google DeepMind's EmbeddingGemma 2, running on this Mac. \
                It's downloaded once: 1.6 GB.
                """
        ) {
            VStack(alignment: .leading, spacing: 10) {
                switch setup.model {
                case .unknown:
                    ProgressView().controlSize(.small)
                case .missing:
                    Button("Download (1.6 GB)") { setup.downloadModel() }
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
                    Label("The model is ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                case .failed(let why):
                    Label(why, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Try Again") { setup.downloadModel() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if setup.model == .missing { setup.downloadModel() } }
    }

    private var foldersPage: some View {
        PageLayout(
            symbol: "folder", title: "Choose what to search",
            text: "Sift It reads each file once, then keeps up as files change. You can change this later in Settings."
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(offered, id: \.self) { folder in
                        FolderRow(
                            folder: folder, indexed: setup.indexed.contains(folder),
                            estimate: setup.estimates[folder],
                            chosen: Binding(
                                get: { chosen.contains(folder) },
                                set: { on in
                                    if on { chosen.insert(folder) } else { chosen.remove(folder) }
                                    if on { Task { await setup.estimate(folder) } }
                                }))
                        if folder != offered.last { Divider() }
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(maxHeight: 252)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            Button("Add Folder…", action: addFolder)
        }
        // Counting what's chosen is what has macOS ask about protected folders: on the page that explains them.
        .task(id: offered) { await estimateChosen() }
    }

    private var readyPage: some View {
        PageLayout(
            symbol: "checkmark.seal", title: "You're all set",
            text: firstPass.map { "Indexing everything once takes \($0). You can search while it goes." }
                ?? "You can search while Sift It indexes."
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
                        When indexing starts, macOS asks whether sift-it, Sift It's indexer, may read your \
                        Documents, Desktop and Downloads. Allow it, so those files can be found.
                        """)
                } icon: {
                    Image(systemName: "hand.raised")
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
            if page != .hello {
                Button("Back") { go(-1) }
                    .controlSize(.large)
            }
            Button(page == .ready ? "Start Searching" : "Continue") {
                page == .ready ? start() : go(1)
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        let usual = ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music"]
            .map { home.appendingPathComponent($0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
        offered = usual + setup.indexed.filter { !usual.contains($0) }
        chosen = Set(setup.indexed.isEmpty ? Array(usual.prefix(3)) : setup.indexed)
        inBackground = setup.inBackground || !Setup.isDone
        atLogin = Setup.opensAtLogin || !Setup.isDone
    }

    private func go(_ step: Int) {
        guard let next = Page(rawValue: page.rawValue + step) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { page = next }
    }

    /// Counts the chosen folders that aren't indexed yet, one after the other.
    private func estimateChosen() async {
        for folder in offered where chosen.contains(folder) && !setup.indexed.contains(folder) {
            await setup.estimate(folder)
        }
    }

    private func start() {
        starting = true
        problem = nil
        Task {
            do {
                try await setup.index(chosen)
                try await setup.indexInBackground(inBackground)
                try Setup.openAtLogin(atLogin)
                Setup.isDone = true
                finish()
            } catch {
                problem = error.localizedDescription
            }
            starting = false
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for folder in panel.urls.map(\.path) where !offered.contains(folder) {
            offered.append(folder)
            chosen.insert(folder)
            Task { await setup.estimate(folder) }
        }
    }

    /// How long indexing the chosen folders that aren't indexed yet takes, in words, once each is counted.
    private var firstPass: String? {
        let new = chosen.filter { !setup.indexed.contains($0) }
        let counted = new.compactMap { setup.estimates[$0] }
        guard !counted.isEmpty, counted.count == new.count else { return nil }
        return duration(counted.reduce(0) { $0 + $1.duration })
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

private struct FolderRow: View {
    let folder: String
    let indexed: Bool
    let estimate: Estimate?
    @Binding var chosen: Bool

    var body: some View {
        Toggle(isOn: $chosen) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: folder))
                    .resizable()
                    .frame(width: 22, height: 22)
                Text(FileManager.default.displayName(atPath: folder))
                Spacer()
                Text(summary)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 6)
    }

    private var summary: String {
        guard chosen else { return "" }
        if indexed { return "Indexed" }
        guard let estimate else { return "Counting…" }
        if estimate.unreadable { return "Not readable yet" }
        let files = estimate.files == 1 ? "1 file" : "\(estimate.files.formatted()) files"
        return "\(files) · \(duration(estimate.duration))"
    }
}

/// "under a minute", "about 12 min", "about 2 h".
private func duration(_ seconds: Double) -> String {
    switch seconds {
    case ..<60: "under a minute"
    case ..<5400: "about \(Int((seconds / 60).rounded())) min"
    default: "about \(Int((seconds / 3600).rounded())) h"
    }
}

private func megabytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
