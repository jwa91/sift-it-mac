// The app's side of sift-it's engine: one connection, kept up while the app runs, and the state the panel, the menu
// bar and the settings show.
//
// The engine runs as a LaunchAgent from login on. When it isn't running the app starts it as the CLI would
// (clients/client.rs): through launchd when its agent is installed, else as a process of its own.

import AppKit
import Observation
import SiftItKit

@MainActor @Observable
final class Engine {
    enum Connection: Equatable {
        case connecting
        case connected(version: String)
        /// sift-it's command-line tool isn't installed.
        case missing
        /// It couldn't be reached or started; why.
        case down(String)
    }

    private(set) var connection = Connection.connecting
    private(set) var meaning = MeaningState.unloaded
    private(set) var meaningError: String?
    private(set) var indexer: IndexerStatus?
    private(set) var status: Status?

    /// Called when search by meaning becomes ready, so a search answered by words can be asked again.
    @ObservationIgnored var onMeaningReady: (() -> Void)?

    @ObservationIgnored private var socket: EngineConnection?
    @ObservationIgnored private var connecting: Task<EngineConnection?, Never>?
    /// How long to wait before trying again after the engine went away; it grows while it stays away.
    @ObservationIgnored private var retry: Duration = .milliseconds(250)

    var cli: URL? { Places.cli(preferred: UserDefaults.standard.string(forKey: "cliPath")) }

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    // MARK: - Asking

    func search(_ search: Search) async throws -> Results {
        try await ask(.search(search))
    }

    func text(of segment: Int64) async -> String? {
        (try? await ask(.segmentText(segment), as: Text.self))?.text
    }

    func folders(_ action: FolderAction? = nil, paths: [String] = []) async throws -> Folders {
        try await ask(.folders(action, paths: paths))
    }

    func setting<Value: Decodable & Sendable>(_ key: String, as _: Value.Type = Value.self) async throws -> Value {
        try await ask(.config(key: key, value: nil), as: Setting<Value>.self).config
    }

    func set(_ key: String, to value: String) async throws {
        _ = try await ask(.config(key: key, value: value), as: Setting<AnyValue>.self)
    }

    @discardableResult
    func refreshStatus() async -> Status? {
        guard let status = try? await ask(.status, as: Status.self) else { return nil }
        self.status = status
        meaning = status.meaning
        meaningError = status.error
        if let indexer = status.indexer { self.indexer = indexer }
        return status
    }

    /// Sends a request on the connection, connecting first when there is none.
    func ask<Reply: Decodable & Sendable>(_ request: Request, as _: Reply.Type = Reply.self) async throws -> Reply {
        guard let socket = await connected() else {
            throw EngineError.unreachable(connectionProblem ?? "it isn't running")
        }
        return try await socket.request(request, as: Reply.self)
    }

    private var connectionProblem: String? {
        switch connection {
        case .missing: "sift-it isn't installed"
        case .down(let why): why
        default: nil
        }
    }

    // MARK: - Connecting

    /// Connects, starting the engine when it isn't running, unless it's connected or connecting already.
    func start() {
        Task { _ = await connected() }
    }

    /// Connects when the engine is running, and keeps trying while it isn't, without starting it: for the menu bar,
    /// from launch on.
    func watch() {
        Task {
            if await connected(starting: false) == nil { reconnect() }
        }
    }

    /// The connection: the one there is, or a new one, starting the engine when it isn't running and `starting`.
    func connected(starting: Bool = true) async -> EngineConnection? {
        if let socket { return socket }
        if let connecting { return await connecting.value }
        let task = Task { await connect(starting: starting) }
        connecting = task
        let socket = await task.value
        connecting = nil
        return socket
    }

    private func connect(starting: Bool) async -> EngineConnection? {
        if !isConnected { connection = .connecting }
        let address: String
        do {
            address = try Places.socketAddress()
        } catch {
            connection = .down(error.localizedDescription)
            return nil
        }
        if let socket = try? await open(address) { return socket }
        guard starting else {
            connection = cli == nil ? .missing : .down("it isn't running")
            return nil
        }
        guard let cli else {
            connection = .missing
            return nil
        }
        do {
            try await startEngine(cli)
        } catch {
            connection = .down(error.localizedDescription)
            return nil
        }
        // It takes a moment to start answering.
        let deadline = ContinuousClock.now + .seconds(10)
        var lastError: (any Error)?
        while ContinuousClock.now < deadline {
            do {
                return try await open(address)
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        connection = .down(lastError?.localizedDescription ?? "it didn't start")
        return nil
    }

    private func open(_ address: String) async throws -> EngineConnection {
        let socket = try await EngineConnection.open(
            socketAddress: address,
            onEvent: { [weak self] event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
            },
            onClose: { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.closed() } }
            })
        self.socket = socket
        connection = .connected(version: socket.ready.version)
        meaning = socket.ready.meaning
        retry = .milliseconds(250)
        Task { await refreshStatus() }
        return socket
    }

    private func handle(_ event: Event) {
        switch event {
        case .ready(let ready):
            meaning = ready.meaning
        case .meaning(let state, let error):
            let wasReady = meaning == .ready
            meaning = state
            meaningError = error
            if state == .ready, !wasReady { onMeaningReady?() }
        case .config:
            break
        case .indexer(let status):
            indexer = status
        }
    }

    /// The engine went away (stopped, upgraded, or crashed): connect again when it's back, without starting it. That's
    /// left to the next search, as for the CLI.
    private func closed() {
        socket = nil
        connection = .down("it stopped")
        reconnect()
    }

    /// Tries to connect after a pause that grows while the engine stays away.
    private func reconnect() {
        let pause = retry
        retry = min(retry * 2, .seconds(30))
        Task {
            try? await Task.sleep(for: pause)
            guard socket == nil else { return }
            if await connected(starting: false) == nil { reconnect() }
        }
    }

    /// Starts the engine as the CLI does: launchd's agent when it's installed, else `sift-it engine` in a session of
    /// its own, so it outlives the app.
    private func startEngine(_ cli: URL) async throws {
        let agent = "gui/\(getuid())/\(Places.engineLabel)"
        if await Run.status("/bin/launchctl", ["print", agent]) == 0,
            await Run.status("/bin/launchctl", ["kickstart", agent]) == 0
        {
            return
        }
        let folder = Places.dataFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Run.detached(cli, ["engine"], log: folder.appendingPathComponent("engine.log"))
    }
}

/// Any JSON value: for replies whose content the app doesn't read.
struct AnyValue: Decodable, Sendable {
    init(from decoder: any Decoder) throws {}
}

/// Running other programs.
enum Run {
    /// Runs a program to its end; its exit status (-1 when it couldn't run).
    static func status(_ path: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }

    /// Runs a program to its end; what it printed, and whether it succeeded.
    static func output(_ executable: URL, _ arguments: [String]) async -> (output: String, ok: Bool) {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (String(decoding: data, as: UTF8.self), process.terminationStatus == 0))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (error.localizedDescription, false))
            }
        }
    }

    /// Starts a program that outlives the app: in a session of its own, writing to `log`.
    static func detached(_ executable: URL, _ arguments: [String], log: URL) throws {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        guard result == 0 else {
            throw EngineError.unreachable("can't start \(executable.path): \(String(cString: strerror(result)))")
        }
        reapWhenItEnds(pid)
    }

    /// The program stays the app's child, in a session of its own: when it ends, it's waited for, so it doesn't linger
    /// as a zombie.
    private static func reapWhenItEnds(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler {
            waitpid(pid, nil, 0)
            source.cancel()
        }
        source.resume()
    }
}
