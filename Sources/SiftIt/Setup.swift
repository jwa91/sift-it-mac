// Getting started, done through the sift-it the app ships with: the models downloaded, the folders chosen, the index
// kept up to date in the background from login on. The welcome window walks through it once; Settings changes it later.

import AppKit
import Observation
import ServiceManagement
import SiftItKit

@MainActor @Observable
final class Setup {
    /// The models Sift It runs, as the welcome window and the settings name them. Text in screenshots and scans is read
    /// by macOS itself.
    enum Model: CaseIterable {
        case embeddings, transcription

        var name: String {
            switch self {
            case .embeddings: "EmbeddingGemma 2"
            case .transcription: "Parakeet Ultra"
            }
        }

        /// Who made it, where that's said.
        var maker: String? {
            switch self {
            case .embeddings: "Google DeepMind"
            case .transcription: nil
            }
        }

        var use: String {
            switch self {
            case .embeddings: "For embeddings"
            case .transcription: "For transcription"
            }
        }

        /// Who made it and what it's for: "Google DeepMind · For embeddings".
        var about: String {
            [maker, use].compactMap { $0 }.joined(separator: " · ")
        }

        /// What it takes to download: what `sift-it model download` says.
        var bytes: Int64 {
            switch self {
            case .embeddings: 865_000_000
            case .transcription: 632_000_000
            }
        }

        static var bytes: Int64 { allCases.reduce(0) { $0 + $1.bytes } }
    }

    enum Models: Equatable {
        case unknown
        case missing
        case downloading(done: Int64, total: Int64)
        case ready
        case failed(String)
    }

    private(set) var models = Models.unknown
    /// The folders sift-it indexes now.
    private(set) var indexed: [String] = []
    /// What indexing each folder takes, by path, once counted.
    private(set) var estimates: [String: Estimate] = [:]
    /// The folders being counted: it takes a while for a big one, which has each recording, video and PDF looked into.
    private(set) var counting: Set<String> = []
    /// Whether sift-it's background indexer is installed and running.
    private(set) var inBackground = false

    @ObservationIgnored private let engine: Engine
    @ObservationIgnored private var downloading = false
    /// Each model file's bytes so far, and its size, while they download.
    @ObservationIgnored private var files: [String: (done: Int64, total: Int64)] = [:]
    /// The model files there are, and what they take together.
    private var present = ModelFiles(text: false, media: false, speech: false, bytes: 0)

    init(engine: Engine) {
        self.engine = engine
    }

    /// Went through the welcome window once: what it offers from then on starts from what's there.
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

    /// The models, the folders and the background indexer, as they are now.
    func look() async {
        if !downloading, let cli = try? cli {
            let status = await Run.run(cli, ["model", "status"])
            let files = try? JSONDecoder().decode(ModelFiles.self, from: Data(status.output.utf8))
            if let files { present = files }
            models = files.map { $0.complete ? .ready : .missing } ?? .failed(status.problem)
        }
        indexed = (try? await engine.folders().folders) ?? indexed
        inBackground = await Self.indexerRuns()
    }

    /// `sift-it model status`: which model files are in the Hugging Face cache (EmbeddingGemma 2's for text and for
    /// pictures and sound, Parakeet Ultra's for speech), and what they take together.
    private struct ModelFiles: Decodable {
        let text: Bool
        let media: Bool
        let speech: Bool
        let bytes: Int64
        var complete: Bool { text && media && speech }
        var none: Bool { !(text || media || speech) }
    }

    /// Whether the welcome window has something to do, from what's there: the preferences can outlive the rest
    /// (`brew uninstall --zap` while cfprefsd still serves them). Searching needs the models and a folder, and indexing
    /// in the background has to have been chosen, on or off: a background indexer found running counts as on, and one
    /// an upgrade took away `restoreBackground` puts back.
    func needsWelcome() async -> Bool {
        await look()
        if inBackground, Self.chosenBackground == nil { Self.chosenBackground = true }
        return models != .ready || indexed.isEmpty || Self.chosenBackground == nil
    }

    /// The indexer's LaunchAgent is loaded.
    static func indexerRuns() async -> Bool {
        await Run.status("/bin/launchctl", ["print", "gui/\(getuid())/local.sift-it.indexer"]) == 0
    }

    // MARK: - The models

    /// Whether a model is downloaded.
    func has(_ model: Model) -> Bool {
        switch model {
        case .embeddings: present.text && present.media
        case .transcription: present.speech
        }
    }

    /// Downloads the models that aren't there yet (1.5 GB in all), following their progress. The engine lets go of
    /// what it tried to load meanwhile, so the next search loads them.
    func downloadModels() {
        guard !downloading, models != .ready, let cli = try? cli else { return }
        downloading = true
        files = [:]
        models = .downloading(done: 0, total: 0)
        Task {
            let ran = await Run.run(cli, ["model", "download", "--json"]) { [weak self] line in
                guard let self, let step = try? JSONDecoder().decode(DownloadStep.self, from: Data(line.utf8)),
                    step.event == "downloading", let file = step.file
                else { return }
                files[file] = (step.done ?? 0, step.total ?? 0)
                // Each model says its size when it starts: with none there before, the whole is known at once.
                let done = files.values.reduce(0) { $0 + $1.done }
                let total = files.values.reduce(0) { $0 + $1.total }
                models = .downloading(done: done, total: present.none ? max(present.bytes, total) : total)
            }
            downloading = false
            models = ran.ok ? .ready : .failed(ran.problem)
            if ran.ok {
                present = ModelFiles(text: true, media: true, speech: true, bytes: present.bytes)
                _ = try? await engine.ask(.unload, as: Done.self)
            }
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
    /// protects: right after the folder was chosen.
    func estimate(_ folder: String) async {
        guard estimates[folder] == nil, !counting.contains(folder), let cli = try? cli else { return }
        counting.insert(folder)
        let ran = await Run.run(cli, ["estimate", "--json", folder])
        if let estimate = try? JSONDecoder().decode([Estimate].self, from: Data(ran.output.utf8)).first {
            estimates[folder] = estimate
        }
        counting.remove(folder)
    }

    /// Indexes these folders, and stops indexing the ones it did that aren't among them.
    func index(_ folders: Set<String>) async throws {
        let current = Set(indexed)
        let added = folders.subtracting(current)
        let removed = current.subtracting(folders)
        if !added.isEmpty { indexed = try await engine.folders(.add, paths: added.sorted()).folders }
        if !removed.isEmpty { indexed = try await engine.folders(.remove, paths: removed.sorted()).folders }
    }

    /// The phase each folder is indexed up to, from `reading.rules`.
    func phases(of folders: [String]) async throws -> [String: Phase] {
        let rules = try await engine.setting("reading.rules", as: [JSON].self)
        return Dictionary(uniqueKeysWithValues: folders.map { ($0, Phase.indexing($0, in: rules)) })
    }

    /// Indexes these folders up to the phase given, through `reading.rules`: a folder indexed through Transcribed has
    /// its rule taken away. Other rules stay as they are.
    func index(upTo phases: [String: Phase]) async throws {
        guard !phases.isEmpty else { return }
        let rules = try await engine.setting("reading.rules", as: [JSON].self)
        let changed = Phase.rules(rules, indexing: phases)
        guard changed != rules else { return }
        try await engine.set("reading.rules", to: JSON.array(changed).text)
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
    /// indexing in the background was chosen. After `needsWelcome`, which looked.
    func restoreBackground() async {
        guard Self.chosenBackground == true, !inBackground else { return }
        try? await indexInBackground(true)
    }

    // MARK: - At login

    static var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func openAtLogin(_ on: Bool) throws {
        guard on != opensAtLogin else { return }
        try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
    }
}
