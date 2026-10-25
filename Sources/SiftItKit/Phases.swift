// How far indexing is, in the three words the app says everywhere: Exact, Embeddings, Transcribed. The engine's six
// rounds map onto these three phases here, and nowhere else: the welcome window, the menu bar, the search panel and the
// settings all say how far in these words.

import Foundation

/// A phase of indexing, and how deep a folder is indexed: up to and including a phase.
public enum Phase: Int, CaseIterable, Comparable, Sendable {
    case exact, embeddings, transcribed

    public var name: String {
        switch self {
        case .exact: "Exact"
        case .embeddings: "Embeddings"
        case .transcribed: "Transcribed"
        }
    }

    /// What it makes findable, in the one sentence every explanation of it uses.
    public var explanation: String {
        switch self {
        case .exact: "Find files by their name and exact words, text in screenshots and scans included."
        case .embeddings: "Find documents, photos, sounds and video scenes by what they mean."
        case .transcribed: "Find what's said in recordings and videos."
        }
    }

    /// The phase a round belongs to. A file's sound is listened to after what's said in it is written down (the
    /// engine's "speech before sound"), so in an index that transcribes, the sound round finishes with Transcribed.
    public static func of(_ round: Round, transcribing: Bool) -> Phase? {
        switch round {
        case .words, .ocr: .exact
        case .text, .pictures: .embeddings
        case .sound: transcribing ? .transcribed : .embeddings
        case .speech: .transcribed
        default: nil
        }
    }

    /// The engine's name for indexing up to this phase (`reading.depth`, and per folder in `reading.rules`).
    public var depth: String {
        switch self {
        case .exact: "words"
        case .embeddings: "meaning"
        case .transcribed: "speech"
        }
    }

    public init?(depth: String) {
        guard let phase = Self.allCases.first(where: { $0.depth == depth }) else { return nil }
        self = phase
    }

    public static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }

    /// The phase a folder is indexed up to: its rule in `reading.rules`, or all of them.
    public static func indexing(_ folder: String, in rules: [JSON], home: String = NSHomeDirectory()) -> Phase {
        let path = JSON.string(Format.shortPath(folder, home: home) + "/**")
        for case .object(let rule) in rules.reversed() where rule["path"] == path {
            if case .string(let depth)? = rule["depth"], let phase = Phase(depth: depth) { return phase }
        }
        return .transcribed
    }

    /// `reading.rules` with these folders indexed up to the phase given: a rule of its own, `{"path": "~/Movies/**",
    /// "depth": "words"}`, or none when it's indexed through Transcribed. Every other rule stays as it is.
    public static func rules(
        _ rules: [JSON], indexing folders: [String: Phase], home: String = NSHomeDirectory()
    ) -> [JSON] {
        var rules = rules
        for (folder, phase) in folders.sorted(by: { $0.key < $1.key }) {
            let path = JSON.string(Format.shortPath(folder, home: home) + "/**")
            rules.removeAll {
                guard case .object(let rule) = $0 else { return false }
                return rule["path"] == path && Set(rule.keys).isSubset(of: ["path", "depth"])
            }
            if phase != .transcribed { rules.append(.object(["path": path, "depth": .string(phase.depth)])) }
        }
        return rules
    }
}

/// How far a phase is: its rounds' together.
public struct PhaseStatus: Equatable, Sendable {
    public let phase: Phase
    /// Done; running while any of its rounds runs; waiting for what the indexer's `detail` says; else queued.
    public let state: RoundState
    /// From 0 to 1: its rounds', each counted the same.
    public let progress: Double
    /// About how long the rest takes: its slowest round's, since they run side by side. nil until one has run a while.
    public let secondsLeft: Double?
    /// Something of it was done: until then a round may be loading its model.
    public let started: Bool

    public var isDone: Bool { state == .done }
}

extension IndexerStatus {
    /// How far each phase is, in their order: the phases this index has work in. Once every round is done, every phase
    /// is.
    ///
    /// A phase with under a minute left while a later one has work counts as done: new files, and the passages
    /// later rounds write down, are kept up with, and don't take the progress back a phase.
    public var phases: [PhaseStatus] {
        let transcribing = rounds.contains { $0.round == .speech }
        let grouped = Dictionary(grouping: rounds) { Phase.of($0.round, transcribing: transcribing) }
        let present = Phase.allCases.filter { grouped[$0] != nil }
        return present.map { phase in
            let rounds = grouped[phase] ?? []
            let left = rounds.filter { $0.state != .done }
            let laterHasWork = present.contains { $0 > phase && grouped[$0]?.contains { $0.state != .done } == true }
            let nearlyDone = laterHasWork && left.allSatisfy { ($0.secondsLeft ?? .infinity) < 60 }
            let state: RoundState =
                if left.isEmpty || nearlyDone || self.state == .idle {
                    .done
                } else if left.contains(where: { $0.state == .running }) {
                    .running
                } else if left.contains(where: { $0.state == .waiting }) {
                    .waiting
                } else {
                    .queued
                }
            let progress = rounds.reduce(0) { $0 + ($1.state == .done ? 1 : $1.progress ?? 0) } / Double(rounds.count)
            return PhaseStatus(
                phase: phase, state: state, progress: state == .done ? 1 : progress,
                secondsLeft: left.compactMap(\.secondsLeft).max(),
                started: rounds.contains { $0.done > 0 || $0.state == .done })
        }
    }

    /// The phase at work: the first that isn't done. nil when every one is.
    public var currentPhase: PhaseStatus? {
        phases.first { !$0.isDone }
    }
}

/// How far indexing is, said in the phases' words.
public enum Phases {
    /// The menu bar's line: the phases done, then the one at work, with its time left: "Exact ✓ · Embeddings 60% · about
    /// 12 min". nil when every phase is done.
    public static func summary(_ indexer: IndexerStatus) -> String? {
        let phases = indexer.phases
        guard let current = phases.first(where: { !$0.isDone }) else { return nil }
        var parts = phases.prefix { $0.isDone }.map { "\($0.phase.name) ✓" }
        parts.append("\(current.phase.name) \(percent(current.progress))%")
        if indexer.state == .paused {
            parts.append("paused")
        } else if current.state == .running, let left = current.secondsLeft {
            parts.append(Format.duration(left))
        }
        return parts.joined(separator: " · ")
    }

    /// The search panel's quiet line, while phases are left: only those, so a missing hit isn't taken for a bad
    /// result. "Embeddings 60% · Transcribed waiting".
    public static func notDone(_ indexer: IndexerStatus) -> String? {
        let left = indexer.phases.filter { !$0.isDone }
        guard !left.isEmpty else { return nil }
        return left.map { phase in
            phase.started || phase.state == .running
                ? "\(phase.phase.name) \(percent(phase.progress))%" : "\(phase.phase.name) waiting"
        }
        .joined(separator: " · ")
    }

    /// How far the phase at work is, beside its name on the bar: "60% · about 12 min", "Starting…" until something is
    /// done (a model loading, the speech model compiling the first time), or what it waits for.
    public static func state(of phase: PhaseStatus, in indexer: IndexerStatus) -> String? {
        guard !phase.isDone else { return nil }
        let wait: String?
        switch phase.state {
        case _ where indexer.state == .paused: wait = "paused"
        case .running:
            guard phase.started else { return "Starting…" }
            wait = phase.secondsLeft.map(Format.duration)
        case .waiting: wait = indexer.detail.map(lowercasedFirst) ?? "waiting"
        default: wait = "waiting"
        }
        return (["\(percent(phase.progress))%"] + [wait].compactMap { $0 }).joined(separator: " · ")
    }

    /// Down, so 100% means done.
    public static func percent(_ progress: Double) -> Int {
        Int((progress * 100).rounded(.down))
    }

    static func lowercasedFirst(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }
}
