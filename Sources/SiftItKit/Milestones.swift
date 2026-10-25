// What can be found already, said as milestones people understand. Each round of indexing makes another kind of search
// work: the menu bar, the search panel, the welcome window and the settings say how far in these words.

import Foundation

extension Round {
    /// What can be found once the round is done: "documents by meaning".
    public var milestone: String {
        switch self {
        case .words: "every file by its name and words"
        case .text: "documents by meaning"
        case .ocr: "text in screenshots and scans"
        case .pictures: "photos by what's in them"
        case .sound: "what sounds and video scenes contain"
        case .speech: "what's said in recordings"
        default: rawValue
        }
    }

    /// What can't be found yet while it runs, and how far it is: "Recordings: 40% written down".
    func notYet(_ percent: Int) -> String {
        switch self {
        case .words: "Files: \(percent)% read"
        case .text: "Documents: \(percent)% by meaning"
        case .ocr: "Screenshots: \(percent)% read"
        case .pictures: "Photos: \(percent)% looked at"
        case .sound: "Sounds: \(percent)% listened to"
        case .speech: "Recordings: \(percent)% written down"
        default: "\(rawValue.capitalized): \(percent)%"
        }
    }
}

public enum Milestones {
    /// The next milestone that isn't reached, after what can be searched by already:
    /// "Searchable by words · documents by meaning 60% · about 12 min". nil when every round is done.
    public static func next(_ indexer: IndexerStatus) -> String? {
        guard let next = indexer.rounds.first(where: { $0.state != .done }) else { return nil }
        var parts = [reached(indexer.rounds)].compactMap { $0 }
        parts.append(next.round.milestone + (next.progress.map { " \(percent($0))%" } ?? ""))
        if next.state == .running, indexer.state != .paused, let left = next.secondsLeft {
            parts.append(Format.duration(left))
        }
        return capitalized(parts.joined(separator: " · "))
    }

    /// What can't be found yet, while rounds are left: "Photos: 10% looked at · Recordings: 40% written down".
    public static func notYet(_ indexer: IndexerStatus) -> String? {
        let left = indexer.rounds.filter { $0.state != .done }
        guard !left.isEmpty else { return nil }
        return left.map { $0.round.notYet(percent($0.progress ?? 0)) }.joined(separator: " · ")
    }

    /// How far a milestone is, for a list of them: nil once it's reached, "60% · about 12 min" while it runs,
    /// "Starting…" until it has done something (a model loading, the speech model compiling the first time), or what
    /// it waits for.
    public static func state(of round: RoundStatus, in indexer: IndexerStatus) -> String? {
        let done = round.progress.flatMap { round.done > 0 ? "\(percent($0))%" : nil }
        let state: String?
        switch round.state {
        case .done: return nil
        case _ where indexer.state == .paused: state = "Paused"
        case .running:
            guard done != nil else { return "Starting…" }
            state = round.secondsLeft.map(Format.duration)
        case .queued: state = "Waiting for its turn"
        default: state = indexer.detail ?? "Waiting"
        }
        guard let done else { return state }
        return [done, state.map(lowercasedFirst)].compactMap { $0 }.joined(separator: " · ")
    }

    /// What can be searched by already: by words once every file's are read, and by meaning once documents' are too.
    static func reached(_ rounds: [RoundStatus]) -> String? {
        func done(_ round: Round) -> Bool { rounds.first { $0.round == round }?.state == .done }
        guard done(.words) else { return nil }
        return done(.text) ? "Searchable by words and meaning" : "Searchable by words"
    }

    /// Down, so 100% means done.
    public static func percent(_ progress: Double) -> Int {
        Int((progress * 100).rounded(.down))
    }

    public static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    static func lowercasedFirst(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }
}
