import Foundation
import Testing

@testable import SiftItKit

/// An engine that says it's ready and then answers as it's told: enough to test the connection against a real socket.
///
/// Its waits block a thread of their own, never the test's: that's one of the few threads Swift runs every task on,
/// and blocking them all (three, on a CI runner) keeps the very request a test waits for from being written. They
/// give up after `patience`, so a test that goes wrong fails rather than hangs.
final class FakeEngine: @unchecked Sendable {
    static let patience: TimeInterval = 10
    let address: String
    private let listener: Int32
    private var client: Int32 = -1
    private let accepted = DispatchSemaphore(value: 0)

    init() throws {
        address =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-it-test-\(UUID().uuidString.prefix(8)).sock").path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var name = sockaddr_un()
        name.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &name.sun_path) { bytes in
            let path = Array(address.utf8)
            bytes.copyBytes(from: path)
            bytes[path.count] = 0
        }
        let bound = withUnsafePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw EngineError.unreachable("can't listen") }
        Thread.detachNewThread { [self] in
            client = accept(listener, nil, nil)
            var limit = timeval(tv_sec: Int(Self.patience), tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            say(#"{"event":"ready","version":"0.3.1","build":"test","index":"/i","meaning":"ready"}"#)
            accepted.signal()
        }
    }

    deinit {
        close(listener)
        unlink(address)
    }

    func waitForClient() async throws {
        let came = await offThread { self.accepted.wait(timeout: .now() + Self.patience) }
        if came == .timedOut { throw EngineError.unreachable("no client in \(Self.patience) s") }
    }

    func say(_ line: String) {
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(client, $0.baseAddress!, $0.count) }
    }

    /// The next request's line: empty when none comes in time.
    func heard() async -> [String: Any] {
        let line = await offThread { [client] in
            var line = Data()
            var byte: UInt8 = 0
            while read(client, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
            return line
        }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
    }

    private func offThread<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: work()) }
        }
    }

    func hangUp() {
        shutdown(client, SHUT_RDWR)
        close(client)
    }
}

/// Collects what the connection hands on.
final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [Event] = []
    private var _closed = false
    var events: [Event] { lock.withLock { _events } }
    var closed: Bool { lock.withLock { _closed } }
    func add(_ event: Event) { lock.withLock { _events.append(event) } }
    func close() { lock.withLock { _closed = true } }
}

@Test(.timeLimit(.minutes(1))) func repliesFindTheirRequestsInAnyOrder() async throws {
    let engine = try FakeEngine()
    let heard = Heard()
    let connection = try await EngineConnection.open(
        socketAddress: engine.address, onEvent: heard.add, onClose: heard.close)
    try await engine.waitForClient()
    #expect(connection.ready.build == "test")

    async let first = connection.request(.segmentText(1), as: Text.self)
    async let second = connection.request(.segmentText(2), as: Text.self)
    var ids: [(Int, Int)] = []
    for _ in 0..<2 {
        let line = await engine.heard()
        ids.append((try #require(line["id"] as? Int), try #require(line["segment_id"] as? Int)))
    }
    // The second asked is answered first, with an event between.
    for (id, segment) in ids.sorted(by: { $0.0 > $1.0 }) {
        engine.say(#"{"id":\#(id),"text":"segment \#(segment)"}"#)
        engine.say(#"{"event":"meaning","state":"loading"}"#)
    }
    #expect(try await first.text == "segment 1")
    #expect(try await second.text == "segment 2")
    #expect(heard.events.contains(.meaning(.loading, error: nil)))
    connection.close()
}

@Test(.timeLimit(.minutes(1))) func aFailureIsThrownAndAHangUpEndsWhatWaits() async throws {
    let engine = try FakeEngine()
    let heard = Heard()
    let connection = try await EngineConnection.open(
        socketAddress: engine.address, onEvent: heard.add, onClose: heard.close)
    try await engine.waitForClient()

    let failing = Task { try await connection.request(.status, as: Status.self) }
    let id = try #require(await engine.heard()["id"] as? Int)
    engine.say(#"{"id":\#(id),"ok":false,"error":"no index yet"}"#)
    await #expect(throws: EngineError.failed("no index yet")) { try await failing.value }

    let waiting = Task { try await connection.request(.status, as: Status.self) }
    _ = await engine.heard()
    engine.hangUp()
    await #expect(throws: EngineError.closed) { try await waiting.value }
    await #expect(throws: EngineError.closed) { try await connection.request(.status, as: Status.self) }
    #expect(heard.closed)
}

@Test(.timeLimit(.minutes(1))) func theStatusSaysTheEmbeddingsOfEachKind() async throws {
    let engine = try FakeEngine()
    let connection = try await EngineConnection.open(
        socketAddress: engine.address, onEvent: { _ in }, onClose: {})
    try await engine.waitForClient()

    let asked = Task { try await connection.request(.status, as: Status.self) }
    let id = try #require(await engine.heard()["id"] as? Int)
    engine.say(
        #"{"id":\#(id),"meaning":"ready","error":null,"vectors":1500,"stats":{"files":40,"done":40,"pending":0,"#
            + #""failed":0,"segments":900,"vectors":1500,"by_kind":{"document":30,"image":10},"#
            + #""vectors_by_kind":{"document":1200,"image":300},"bytes":4096},"indexer":null}"#)
    let stats = try await asked.value.stats
    #expect(stats.vectorsByKind == ["document": 1200, "image": 300])
    #expect(stats.byKind == ["document": 30, "image": 10])
    connection.close()
}

@Test func nothingListeningIsUnreachable() async {
    await #expect(throws: EngineError.self) {
        _ = try await EngineConnection.open(socketAddress: "/tmp/no-such-engine.sock", onEvent: { _ in }, onClose: {})
    }
}
