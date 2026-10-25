import Foundation
import Testing

@testable import SiftItKit

private func indexer(_ rounds: RoundStatus..., state: IndexerState = .indexing) -> IndexerStatus {
    IndexerStatus(pid: 7, state: state, rounds: rounds)
}

@Test func theSixRoundsMapOntoThreePhases() {
    #expect(
        Round.all.map { Phase.of($0, transcribing: true) } == [
            .exact, .embeddings, .exact, .embeddings, .transcribed, .transcribed,
        ])
    // Without speech to wait for, sound is listened to with the other embeddings.
    #expect(Phase.of(.sound, transcribing: false) == .embeddings)
    #expect(Phase.of(Round(rawValue: "smell"), transcribing: true) == nil)
    #expect(Phase.allCases.map(\.name) == ["Exact", "Embeddings", "Transcribed"])
    #expect(Phase.allCases.map(\.depth) == ["words", "meaning", "speech"])
    #expect(Phase(depth: "meaning") == .embeddings)
    #expect(Phase(depth: "deep") == nil)
}

@Test func theIndexersProgressIsSaidInPhases() throws {
    // Words done, text running at 60%, pictures waiting for their turn, speech waiting for a charger.
    guard case .indexer(let status)? = Event.decode(Data(indexerLine.utf8)) else {
        Issue.record("not an indexer event")
        return
    }
    let phases = status.phases
    #expect(phases.map(\.phase) == [.exact, .embeddings, .transcribed])
    #expect(phases.map(\.state) == [RoundState.done, .running, .waiting])
    #expect(phases.map(\.progress) == [1, 0.3, 0.4])
    #expect(phases[1].secondsLeft == 720.5)
    #expect(status.currentPhase?.phase == .embeddings)
    #expect(Phases.summary(status) == "Exact ✓ · Embeddings 30% · about 12 min")
    #expect(Phases.notDone(status) == "Embeddings 30% · Transcribed 40%")
    #expect(
        phases.map { Phases.state(of: $0, in: status) } == [nil, "30% · about 12 min", "40% · waiting for a charger"])
}

@Test func aPhaseWithUnderAMinuteLeftDoesNotTakeTheProgressBack() {
    // What's said is written down, and its passages embedded as they come: the text round has a few seconds' work
    // again and again, while Transcribed runs.
    let transcribing = indexer(
        RoundStatus(round: .words, state: .running, done: 630, total: 631, files: 1, secondsLeft: 1),
        RoundStatus(round: .text, state: .running, done: 9590, total: 9595, files: 1, secondsLeft: 3),
        RoundStatus(round: .pictures, state: .done, done: 8370, total: 8370),
        RoundStatus(round: .sound, state: .queued, done: 0, total: 110211, files: 30),
        RoundStatus(round: .speech, state: .running, done: 44000, total: 110211, files: 30, secondsLeft: 7300))
    #expect(transcribing.phases.map(\.state) == [RoundState.done, .done, .running])
    #expect(Phases.summary(transcribing) == "Exact ✓ · Embeddings ✓ · Transcribed 19% · about 2 h")
    #expect(Phases.notDone(transcribing) == "Transcribed 19%")

    // With nothing after it, a phase's last minute is said as it is.
    let last = indexer(
        RoundStatus(round: .words, state: .done, done: 40, total: 40),
        RoundStatus(round: .text, state: .running, done: 90, total: 100, files: 2, secondsLeft: 20))
    #expect(Phases.summary(last) == "Exact ✓ · Embeddings 90% · under a minute")
}

@Test func aPhaseStartsWaitsAndPauses() {
    let starting = indexer(
        RoundStatus(round: .words, state: .running, done: 0, total: 40, files: 40),
        RoundStatus(round: .speech, state: .queued, files: 3))
    #expect(Phases.summary(starting) == "Exact 0%")
    #expect(starting.currentPhase.map { Phases.state(of: $0, in: starting) } == "Starting…")
    #expect(Phases.notDone(starting) == "Exact 0% · Transcribed waiting")

    let paused = indexer(
        RoundStatus(round: .words, state: .done, done: 40, total: 40),
        RoundStatus(round: .text, state: .running, done: 50, total: 100, files: 2, secondsLeft: 600), state: .paused)
    #expect(Phases.summary(paused) == "Exact ✓ · Embeddings 50% · paused")
    #expect(paused.currentPhase.map { Phases.state(of: $0, in: paused) } == "50% · paused")

    let queued = indexer(
        RoundStatus(round: .words, state: .done, done: 40, total: 40),
        RoundStatus(round: .pictures, state: .queued, done: 0, total: 100, files: 100))
    #expect(queued.currentPhase.map { Phases.state(of: $0, in: queued) } == "0% · waiting")
    #expect(Phases.notDone(queued) == "Embeddings waiting")
}

@Test func everyPhaseIsDoneWhenTheIndexIsUpToDate() {
    let done = indexer(
        RoundStatus(round: .words, state: .done, done: 40, total: 40),
        RoundStatus(round: .text, state: .done, done: 100, total: 100), state: .idle)
    #expect(done.phases.allSatisfy { $0.isDone })
    #expect(done.currentPhase == nil)
    #expect(Phases.summary(done) == nil)
    #expect(Phases.notDone(done) == nil)
    #expect(indexer().phases.isEmpty)
}

@Test func aFolderIndexedUpToAPhaseHasARuleOfItsOwn() throws {
    let rules = try JSONDecoder().decode(
        [JSON].self,
        from: Data(
            """
            [{"path":"*.psd","depth":"words"},{"path":"~/Movies/**","depth":"meaning"},
             {"path":"~/Movies/**","video":{"keep_every_s":10}}]
            """.utf8))
    let movies = "/Users/me/Movies"
    let music = "/Users/me/Music"
    #expect(Phase.indexing(movies, in: rules, home: "/Users/me") == .embeddings)
    #expect(Phase.indexing(music, in: rules, home: "/Users/me") == .transcribed)
    let lower = Phase.rules(rules, indexing: [movies: .exact, music: .embeddings], home: "/Users/me")
    #expect(
        JSON.array(lower).text
            == #"[{"depth":"words","path":"*.psd"},{"path":"~/Movies/**","video":{"keep_every_s":10}},"#
            + #"{"depth":"words","path":"~/Movies/**"},{"depth":"meaning","path":"~/Music/**"}]"#)
    #expect(Phase.indexing(movies, in: lower, home: "/Users/me") == .exact)
    // Indexed through Transcribed again, each loses its rule; the rules it didn't make stay.
    let full = Phase.rules(lower, indexing: [movies: .transcribed, music: .transcribed], home: "/Users/me")
    #expect(full == [rules[0], rules[2]])
}
