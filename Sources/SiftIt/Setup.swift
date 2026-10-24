// Getting started, done through the sift-it the app ships with: the model downloaded, the folders chosen, the index
// kept up to date in the background from login on. The welcome window walks through it once; Settings changes it later.

import AppKit
import Observation
import ServiceManagement
import SiftItKit

/// A folder, and what indexing it takes (`sift-it estimate --json`).
struct Estimate: Decodable, Sendable, Equatable {
    let folder: String
    let files: Int
    let seconds: Double
    let speechSeconds: Double
    /// macOS didn't let it be read (yet).
    let unreadable: Bool

    enum CodingKeys: String, CodingKey {
        case folder, files, seconds, unreadable
        case speechSeconds = "speech_seconds"
    }

    /// The first pass, all of it.
    var duration: Double { seconds + speechSeconds }
}

@MainActor @Observable
final class Setup {
    enum Model: Equatable {
        case unknown
        case missing
        case downloading(done: Int64, total: Int64)
        case ready
        case failed(String)
    }

    private(set) var model = Model.unknown
    /// The folders sift-it indexes now.
    private(set) var indexed: [String] = []
    /// What indexing each folder takes, by path, once counted.
    private(set) var estimates: [String: Estimate] = [:]
    /// Whether sift-it's background indexer is installed and running.
    private(set) var inBackground = false

    @ObservationIgnored private let engine: Engine
    @ObservationIgnored private var downloading = false
    /// Each model file's bytes so far, and its size, while they download.
    @ObservationIgnored private var files: [String: (done: Int64, total: Int64)] = [:]

    init(engine: Engine) {
        self.engine = engine
    }

    /// Went through the welcome window once (or sift-it was set up before the app came).
    static var isDone: Bool {
        get { UserDefaults.standard.bool(forKey: "setUp") }
        set { UserDefaults.standard.set(newValue, forKey: "setUp") }
    }

    /// Indexing in the background, as chosen here; nil before anything was chosen.
    private static var chosenBackground: Bool? {
        get { UserDefaults.standard.object(forKey: "backgroundIndexing") as? Bool }
        set { UserDefaults.standard.set(newValue, forKey: "backgroundIndexing") }
    }

    private var cli: URL {
        get throws {
            guard let cli = engine.cli else { throw EngineError.unreachable("sift-it is missing from the app") }
            return cli
        }
    }

    // MARK: - What's there

    /// The model, the folders and the background indexer, as they are now.
    func look() async {
        if !downloading, let cli = try? cli {
            let status = await Run.run(cli, ["model", "status"])
            let files = try? JSONDecoder().decode(ModelFiles.self, from: Data(status.output.utf8))
            model = files.map { $0.complete ? .ready : .missing } ?? .failed(status.problem)
        }
        indexed = (try? await engine.folders().folders) ?? indexed
        inBackground = await Self.indexerRuns()
    }

    private struct ModelFiles: Decodable {
        let text: Bool
        let media: Bool
        let speech: Bool
        var complete: Bool { text && media && speech }
    }

    /// Whether the welcome window has something to do: the first time, unless sift-it was set up already (through its
    /// command line, before the app).
    func needsWelcome() async -> Bool {
        guard !Self.isDone else { return false }
        await look()
        if model == .ready, !indexed.isEmpty, inBackground {
            Self.isDone = true
            return false
        }
        return true
    }

    /// The indexer's LaunchAgent is loaded.
    static func indexerRuns() async -> Bool {
        await Run.status("/bin/launchctl", ["print", "gui/\(getuid())/local.sift-it.indexer"]) == 0
    }

    // MARK: - The model

    /// Downloads what's missing of the model (1.6 GB at most), following its progress. The engine lets go of what it
    /// tried to load meanwhile, so the next search loads the model.
    func downloadModel() {
        guard !downloading, model != .ready, let cli = try? cli else { return }
        downloading = true
        files = [:]
        model = .downloading(done: 0, total: 0)
        Task {
            let ran = await Run.run(cli, ["model", "download", "--json"]) { [weak self] line in
                guard let self, let step = try? JSONDecoder().decode(DownloadStep.self, from: Data(line.utf8)),
                    step.event == "downloading", let file = step.file
                else { return }
                files[file] = (step.done ?? 0, step.total ?? 0)
                model = .downloading(
                    done: files.values.reduce(0) { $0 + $1.done }, total: files.values.reduce(0) { $0 + $1.total })
            }
            downloading = false
            model = ran.ok ? .ready : .failed(ran.problem)
            if ran.ok { _ = try? await engine.ask(.unload, as: Done.self) }
        }
    }

    private struct DownloadStep: Decodable {
        let event: String
        let file: String?
        let done: Int64?
        let total: Int64?
    }

    // MARK: - Folders

    /// Counts what indexing a folder takes. Reading it is when macOS asks whether Sift It may, for the folders it
    /// protects.
    func estimate(_ folder: String) async {
        guard estimates[folder] == nil, let cli = try? cli else { return }
        let ran = await Run.run(cli, ["estimate", "--json", folder])
        if let estimate = try? JSONDecoder().decode([Estimate].self, from: Data(ran.output.utf8)).first {
            estimates[folder] = estimate
        }
    }

    /// Indexes these folders, and stops indexing the ones it did that aren't among them.
    func index(_ folders: Set<String>) async throws {
        let current = Set(indexed)
        let added = folders.subtracting(current)
        let removed = current.subtracting(folders)
        if !added.isEmpty { indexed = try await engine.folders(.add, paths: added.sorted()).folders }
        if !removed.isEmpty { indexed = try await engine.folders(.remove, paths: removed.sorted()).folders }
    }

    // MARK: - In the background

    /// Indexing in the background from login on, through sift-it's LaunchAgents. Before they're installed, an engine
    /// the app started itself goes, so launchd's takes its place; the app connects to that one when it's up.
    func indexInBackground(_ on: Bool) async throws {
        Self.chosenBackground = on
        let cli = try cli
        if on {
            await engine.stopIfRunning()
            let ran = await Run.run(cli, ["service", "install"])
            guard ran.ok else { throw EngineError.failed("Can't start indexing in the background: \(ran.problem)") }
        } else {
            _ = await Run.run(cli, ["service", "uninstall"])
        }
        inBackground = await Self.indexerRuns()
        engine.start()
    }

    /// Homebrew takes the LaunchAgents away when it upgrades the app (the cask's uninstall step). They come back when
    /// indexing in the background was chosen here, or, with nothing chosen yet, when sift-it was set up before the app.
    func restoreBackground() async {
        guard Self.chosenBackground != false, !(await Self.indexerRuns()) else { return }
        if Self.chosenBackground == nil {
            await look()
            guard model == .ready, !indexed.isEmpty else { return }
        }
        try? await indexInBackground(true)
    }

    // MARK: - At login

    static var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func openAtLogin(_ on: Bool) throws {
        guard on != opensAtLogin else { return }
        try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
    }
}
