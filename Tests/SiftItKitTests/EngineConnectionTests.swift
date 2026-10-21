import Foundation
import Testing

@testable import SiftItKit

/// An engine that says it's ready and then answers as it's told: enough to test the connection against a real socket.
final class FakeEngine: @unchecked Sendable {
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
            say(#"{"event":"ready","version":"0.3.1","build":"test","index":"/i","meaning":"ready"}"#)
            accepted.signal()
        }
    }

    deinit {
        close(listener)
        unlink(address)
    }

    func waitForClient() { accepted.wait() }

    func say(_ line: String) {
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(client, $0.baseAddress!, $0.count) }
    }

    /// The next request's line.
    func heard() -> [String: Any] {
        var line = [UInt8]()
        var byte: UInt8 = 0
        while read(client, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
        return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] ?? [:]
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

@Test func repliesFindTheirRequestsInAnyOrder() async throws {
    let engine = try FakeEngine()
    let heard = Heard()
    let connection = try await EngineConnection.open(
        socketAddress: engine.address, onEvent: heard.add, onClose: heard.close)
    engine.waitForClient()
    #expect(connection.ready.build == "test")

    async let first = connection.request(.segmentText(1), as: Text.self)
    async let second = connection.request(.segmentText(2), as: Text.self)
    let a = engine.heard()
    let b = engine.heard()
    let ids = [a, b].map { ($0["id"] as! Int, $0["segment_id"] as! Int) }
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

@Test func aFailureIsThrownAndAHangUpEndsWhatWaits() async throws {
    let engine = try FakeEngine()
    let heard = Heard()
    let connection = try await EngineConnection.open(
        socketAddress: engine.address, onEvent: heard.add, onClose: heard.close)
    engine.waitForClient()

    let failing = Task { try await connection.request(.status, as: Status.self) }
    let id = engine.heard()["id"] as! Int
    engine.say(#"{"id":\#(id),"ok":false,"error":"no index yet"}"#)
    await #expect(throws: EngineError.failed("no index yet")) { try await failing.value }

    let waiting = Task { try await connection.request(.status, as: Status.self) }
    _ = engine.heard()
    engine.hangUp()
    await #expect(throws: EngineError.closed) { try await waiting.value }
    await #expect(throws: EngineError.closed) { try await connection.request(.status, as: Status.self) }
    #expect(heard.closed)
}

@Test func nothingListeningIsUnreachable() async {
    await #expect(throws: EngineError.self) {
        _ = try await EngineConnection.open(socketAddress: "/tmp/no-such-engine.sock", onEvent: { _ in }, onClose: {})
    }
}
