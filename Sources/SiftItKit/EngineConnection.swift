// A connection to the engine's socket: requests and their replies, and the events it sends unasked.
//
// Lines are read on a thread of their own, which never waits on the app: a reply resumes the request that asked for it,
// an event goes to `onEvent`. Replies can come in another order than their requests.

import Foundation

public enum EngineError: Error, Equatable, LocalizedError {
    /// The socket isn't there, or nothing listens on it.
    case unreachable(String)
    /// The engine closed the connection.
    case closed
    /// The engine answered with a failure.
    case failed(String)
    /// A line that isn't what was asked for.
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let why): "Can't reach sift-it's engine: \(why)"
        case .closed: "sift-it's engine stopped"
        case .failed(let why): why
        case .malformed(let what): "sift-it's engine said something unexpected: \(what)"
        }
    }
}

public final class EngineConnection: @unchecked Sendable {
    /// The engine's first line.
    public let ready: Ready

    private let socket: Int32
    private let onEvent: @Sendable (Event) -> Void
    private let onClose: @Sendable () -> Void
    /// Guards `nextId`, `pending` and `closed`.
    private let lock = NSLock()
    /// Keeps lines whole when two requests are written at once.
    private let writing = NSLock()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var closed = false

    /// How long the engine has to say it's ready.
    public static let readyTimeout: Duration = .seconds(5)

    /// Connects and waits for the engine's `ready` line. `onEvent` and `onClose` are called on the reading thread.
    public static func open(
        socketAddress: String,
        onEvent: @escaping @Sendable (Event) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) async throws -> EngineConnection {
        let socket = try connect(to: socketAddress)
        let reader = LineReader(socket: socket)
        // The first line, read here before the reading thread starts, with a deadline.
        let first = try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { await reader.nextLineInBackground() }
            group.addTask {
                try await Task.sleep(for: readyTimeout)
                // Ends the read that's waiting, so the group can end too.
                Darwin.shutdown(socket, SHUT_RDWR)
                return nil
            }
            let line = try await group.next() ?? nil
            group.cancelAll()
            return line
        }
        guard let first, case .ready(let ready)? = Event.decode(first) else {
            Darwin.shutdown(socket, SHUT_RDWR)
            Darwin.close(socket)
            throw EngineError.unreachable(first == nil ? "it didn't say it was ready" : "it said something else first")
        }
        let connection = EngineConnection(socket: socket, ready: ready, onEvent: onEvent, onClose: onClose)
        let thread = Thread { connection.readLoop(reader) }
        thread.name = "sift-it engine"
        thread.qualityOfService = .userInitiated
        thread.start()
        return connection
    }

    private init(
        socket: Int32, ready: Ready, onEvent: @escaping @Sendable (Event) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.socket = socket
        self.ready = ready
        self.onEvent = onEvent
        self.onClose = onClose
    }

    /// Sends a request and waits for its reply.
    public func request<Reply: Decodable & Sendable>(_ request: Request, as _: Reply.Type = Reply.self) async throws
        -> Reply
    {
        let line = try await send(request)
        do {
            return try JSONDecoder().decode(Reply.self, from: line)
        } catch {
            throw EngineError.malformed(String(decoding: line.prefix(200), as: UTF8.self))
        }
    }

    /// Closes the connection: requests waiting for a reply fail, and `onClose` is called.
    public func close() {
        Darwin.shutdown(socket, SHUT_RDWR)
    }

    private func send(_ request: Request) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: EngineError.closed)
                return
            }
            let id = nextId
            nextId += 1
            pending[id] = continuation
            lock.unlock()

            var line = request.line(id: id)
            line.append(0x0A)
            writing.lock()
            let written = Self.writeAll(line, to: socket)
            writing.unlock()
            if !written, let continuation = take(id) {
                continuation.resume(throwing: EngineError.closed)
            }
        }
    }

    private func take(_ id: Int) -> CheckedContinuation<Data, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }

    private struct Reply: Decodable {
        let id: Int?
        let ok: Bool?
        let error: String?
    }

    private func readLoop(_ reader: LineReader) {
        let decoder = JSONDecoder()
        while let line = reader.nextLine() {
            guard let head = try? decoder.decode(Reply.self, from: line) else { continue }
            if let id = head.id {
                guard let continuation = take(id) else { continue }
                if head.ok == false {
                    continuation.resume(throwing: EngineError.failed(head.error ?? "the engine failed"))
                } else {
                    continuation.resume(returning: line)
                }
            } else if let event = Event.decode(line) {
                onEvent(event)
            }
        }
        lock.lock()
        closed = true
        let waiting = pending.values
        pending.removeAll()
        lock.unlock()
        for continuation in waiting {
            continuation.resume(throwing: EngineError.closed)
        }
        Darwin.close(socket)
        onClose()
    }

    // MARK: - The socket

    private static func connect(to address: String) throws -> Int32 {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw EngineError.unreachable(String(cString: strerror(errno))) }
        // A write to an engine that went away fails with EPIPE rather than ending the app.
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var name = sockaddr_un()
        name.sun_family = sa_family_t(AF_UNIX)
        let path = Array(address.utf8)
        let capacity = MemoryLayout.size(ofValue: name.sun_path)
        guard path.count < capacity else {
            Darwin.close(socket)
            throw EngineError.unreachable("the socket's name is too long: \(address)")
        }
        withUnsafeMutableBytes(of: &name.sun_path) { bytes in
            bytes.copyBytes(from: path)
            bytes[path.count] = 0
        }
        let connected = withUnsafePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let why = String(cString: strerror(errno))
            Darwin.close(socket)
            throw EngineError.unreachable(why)
        }
        return socket
    }

    private static func writeAll(_ data: Data, to socket: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(socket, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}

/// Lines from a socket, read as they come: blocking reads, so one reader at a time.
final class LineReader: @unchecked Sendable {
    private let socket: Int32
    private var buffer = Data()
    private var chunk = [UInt8](repeating: 0, count: 64 * 1024)

    init(socket: Int32) {
        self.socket = socket
    }

    /// The next line without its newline, nil once the socket is closed.
    func nextLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = buffer[(newline + 1)...]
                return Data(line)
            }
            let read = chunk.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress!, $0.count) }
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<read])
        }
    }

    /// The next line, read on a thread of its own so no task waits on a blocking read.
    func nextLineInBackground() async -> Data? {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: self.nextLine()) }
        }
    }
}
