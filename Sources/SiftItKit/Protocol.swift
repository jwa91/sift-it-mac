// What the app and sift-it's engine say to each other: JSON lines over the engine's Unix socket. The engine's
// docs/protocol.md describes the wire; these are the parts the app uses.
//
// Names the engine sends (kinds, segments, states) are open sets: a newer engine can add one without breaking the app,
// which shows what it doesn't know as it would a plain file.

import Foundation

/// What a file is, for a search to filter by.
public struct Kind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let plaintext = Kind(rawValue: "plaintext")
    public static let document = Kind(rawValue: "document")
    public static let structured = Kind(rawValue: "structured")
    public static let image = Kind(rawValue: "image")
    public static let screenshot = Kind(rawValue: "screenshot")
    public static let audio = Kind(rawValue: "audio")
    public static let video = Kind(rawValue: "video")
    public static let code = Kind(rawValue: "code")

    /// A picture of some sort: shown as itself.
    public var isPicture: Bool { self == .image || self == .screenshot }
    /// A recording or a video: it plays from a moment.
    public var plays: Bool { self == .audio || self == .video }
}

/// The part of a file that matched best.
public struct Segment: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// A stretch of a text file or document.
    public static let passage = Segment(rawValue: "passage")
    /// A PDF page's text.
    public static let page = Segment(rawValue: "page")
    /// A picture, as a picture.
    public static let picture = Segment(rawValue: "picture")
    /// The text in a picture or a scanned page.
    public static let ocr = Segment(rawValue: "ocr")
    /// 30 seconds of sound.
    public static let sound = Segment(rawValue: "sound")
    /// A video frame.
    public static let frame = Segment(rawValue: "frame")
    /// What's said in a recording or video, written down.
    public static let speech = Segment(rawValue: "speech")
}

/// Where search by meaning is: it loads on the first search that needs it.
public struct MeaningState: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let unloaded = MeaningState(rawValue: "unloaded")
    public static let loading = MeaningState(rawValue: "loading")
    public static let ready = MeaningState(rawValue: "ready")
    /// The model isn't downloaded, or couldn't load: searches are by words.
    public static let unavailable = MeaningState(rawValue: "unavailable")
}

/// What the background indexer is doing.
public struct IndexerState: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let starting = IndexerState(rawValue: "starting")
    /// Comparing the folders with the index.
    public static let syncing = IndexerState(rawValue: "syncing")
    /// Reading files.
    public static let indexing = IndexerState(rawValue: "indexing")
    /// Writing down what's said in recordings and videos, everything else being read.
    public static let transcribing = IndexerState(rawValue: "transcribing")
    /// For a charger, for Low Power Mode to end, or for the model to download.
    public static let waiting = IndexerState(rawValue: "waiting")
    public static let paused = IndexerState(rawValue: "paused")
    /// Everything is done.
    public static let idle = IndexerState(rawValue: "idle")
    public static let stopped = IndexerState(rawValue: "stopped")
}

/// What a search is by.
public enum Mode: String, Sendable {
    /// The full-text index alone: no model, answered at once.
    case words
    /// Meaning too, with the words still counting.
    case meaning
}

public enum FolderAction: String, Sendable {
    case add, remove, include, exclude
}

// MARK: - Requests

public struct Search: Sendable, Equatable {
    public var q: String
    /// config.json's `search.mode` when nil.
    public var mode: Mode?
    /// All but code when empty.
    public var kinds: [Kind]
    public var limit: Int
    /// Match the last word as a prefix: the user is still typing it.
    public var prefixLast: Bool

    public init(q: String, mode: Mode? = nil, kinds: [Kind] = [], limit: Int = 40, prefixLast: Bool = false) {
        self.q = q
        self.mode = mode
        self.kinds = kinds
        self.limit = limit
        self.prefixLast = prefixLast
    }
}

public enum Request: Sendable, Equatable {
    case search(Search)
    /// A segment's whole text.
    case segmentText(Int64)
    case status
    /// The settings, or the one at a dotted key, set first when there's a value (read as JSON, else as a string).
    case config(key: String?, value: String?)
    /// The folders indexed, changed first when there's an action.
    case folders(FolderAction?, paths: [String])
    /// Lets the model and the vectors go, until a search by meaning needs them: after the model is downloaded, the
    /// next search loads it.
    case unload
    /// Ends the engine.
    case stop

    /// The request as a line, without its newline.
    public func line(id: Int) -> Data {
        var fields: [String: Any] = ["id": id]
        switch self {
        case .search(let search):
            fields["op"] = "search"
            fields["q"] = search.q
            fields["limit"] = search.limit
            if let mode = search.mode { fields["mode"] = mode.rawValue }
            if !search.kinds.isEmpty { fields["kinds"] = search.kinds.map(\.rawValue) }
            if search.prefixLast { fields["prefix_last"] = true }
        case .segmentText(let segment):
            fields["op"] = "text"
            fields["segment_id"] = segment
        case .status:
            fields["op"] = "status"
        case .config(let key, let value):
            fields["op"] = "config"
            if let key { fields["key"] = key }
            if let value { fields["value"] = value }
        case .folders(let action, let paths):
            fields["op"] = "folders"
            if let action { fields["action"] = action.rawValue }
            if !paths.isEmpty { fields["paths"] = paths }
        case .unload:
            fields["op"] = "unload"
        case .stop:
            fields["op"] = "stop"
        }
        // Only strings, numbers and arrays of them: this can't fail.
        return try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

// MARK: - Replies

/// A search's results, best first: one per file.
public struct Results: Decodable, Sendable, Equatable {
    public let hits: [Hit]
    /// Meaning was part of this search (false: words only, as while the model loads).
    public let meaning: Bool
    public let ms: Double

    public init(hits: [Hit], meaning: Bool, ms: Double) {
        self.hits = hits
        self.meaning = meaning
        self.ms = ms
    }
}

/// A file found, and where in it.
public struct Hit: Decodable, Sendable, Equatable, Identifiable {
    public let path: String
    public let name: String
    public let kind: Kind
    /// The segment that matched best: where the result opens.
    public let segment: Segment
    public let segmentId: Int64
    /// Where in the file: a line, a page or a second, by the segment.
    public let loc: Double?
    public let locEnd: Double?
    public let score: Double
    /// It matched by meaning.
    public let meaning: Bool
    /// All of the query's words are in it.
    public let words: Bool
    public let strong: Bool
    /// About 300 characters around the query's words.
    public let excerpt: String?
    /// Seconds since 1970.
    public let modified: Double
    public let size: UInt64
    public let info: Info

    /// A search has one result per file.
    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }

    enum CodingKeys: String, CodingKey {
        case path, name, kind, segment, loc, score, meaning, words, strong, excerpt, modified, size, info
        case segmentId = "segment_id"
        case locEnd = "loc_end"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        segment = try c.decode(Segment.self, forKey: .segment)
        segmentId = try c.decode(Int64.self, forKey: .segmentId)
        loc = try c.decodeIfPresent(Double.self, forKey: .loc)
        locEnd = try c.decodeIfPresent(Double.self, forKey: .locEnd)
        score = try c.decode(Double.self, forKey: .score)
        meaning = try c.decode(Bool.self, forKey: .meaning)
        words = try c.decode(Bool.self, forKey: .words)
        strong = try c.decode(Bool.self, forKey: .strong)
        excerpt = try c.decodeIfPresent(String.self, forKey: .excerpt)
        modified = try c.decode(Double.self, forKey: .modified)
        size = try c.decode(UInt64.self, forKey: .size)
        info = (try? c.decode(Info.self, forKey: .info)) ?? Info()
    }
}

/// What the reader found out about a file. Each field is read on its own, so one of an unexpected type costs only
/// that field.
public struct Info: Decodable, Sendable, Equatable {
    /// Seconds, for recordings and videos.
    public var duration: Double?
    public var pages: Int?
    /// In pixels, for pictures and videos.
    public var width: Int?
    public var height: Int?
    /// A recording's tags: title, artist, album.
    public var tags: [String: String] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case duration, pages, width, height, tags
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        pages = try? c.decodeIfPresent(Int.self, forKey: .pages)
        width = try? c.decodeIfPresent(Int.self, forKey: .width)
        height = try? c.decodeIfPresent(Int.self, forKey: .height)
        tags = (try? c.decodeIfPresent([String: String].self, forKey: .tags)) ?? [:]
    }
}

/// A segment's text.
public struct Text: Decodable, Sendable {
    public let text: String?
}

/// What the engine holds, and how far the indexer is.
public struct Status: Decodable, Sendable, Equatable {
    public let meaning: MeaningState
    /// Why search by meaning is unavailable, when it is.
    public let error: String?
    public let vectors: Int
    public let stats: Stats
    /// nil when the indexer never ran for this data folder.
    public let indexer: IndexerStatus?
}

/// What's in the index.
public struct Stats: Decodable, Sendable, Equatable {
    public let files: Int
    public let done: Int
    public let pending: Int
    public let failed: Int
    public let vectors: Int
    public let byKind: [String: Int]
    /// The index's size on disk.
    public let bytes: UInt64

    enum CodingKeys: String, CodingKey {
        case files, done, pending, failed, vectors, bytes
        case byKind = "by_kind"
    }
}

/// The background indexer's progress, as it last said it.
public struct IndexerStatus: Decodable, Sendable, Equatable {
    public let pid: Int32
    public let state: IndexerState
    /// What it waits for, or how far into a recording it is.
    public let detail: String?
    /// Files done of the ones in this run (or recordings written down, while that's what it does).
    public let done: Int
    public let total: Int
    /// The file it did last.
    public let current: String?
    public let lastError: String?
    public let speechDone: Int
    public let speechTotal: Int

    enum CodingKeys: String, CodingKey {
        case pid, state, detail, done, total, current
        case lastError = "last_error"
        case speechDone = "speech_done"
        case speechTotal = "speech_total"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        state = try c.decode(IndexerState.self, forKey: .state)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        done = try c.decodeIfPresent(Int.self, forKey: .done) ?? 0
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        current = try c.decodeIfPresent(String.self, forKey: .current)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        speechDone = try c.decodeIfPresent(Int.self, forKey: .speechDone) ?? 0
        speechTotal = try c.decodeIfPresent(Int.self, forKey: .speechTotal) ?? 0
    }

    /// How far the work it's doing now is, from 0 to 1, when it's counting.
    public var progress: Double? {
        switch state {
        case .indexing, .syncing:
            return total > 0 ? Double(done) / Double(total) : nil
        case .transcribing:
            return speechTotal > 0 ? Double(speechDone) / Double(speechTotal) : nil
        default:
            return nil
        }
    }

    /// It's reading or writing down: work is going on.
    public var isWorking: Bool {
        [.starting, .syncing, .indexing, .transcribing].contains(state)
    }
}

/// The folders indexed, and the folders inside them left out.
public struct Folders: Decodable, Sendable, Equatable {
    public let folders: [String]
    public let excluded: [String]
}

/// It's done.
public struct Done: Decodable, Sendable {
    public let ok: Bool
}

/// A setting's value.
public struct Setting<Value: Decodable & Sendable>: Decodable, Sendable {
    public let config: Value
}

// MARK: - Events

/// The first line on connecting: the engine's build, and the state of search by meaning.
public struct Ready: Decodable, Sendable, Equatable {
    public let version: String
    public let build: String
    public let index: String
    public let meaning: MeaningState
}

/// What the engine says unasked, to every client.
public enum Event: Sendable, Equatable {
    case ready(Ready)
    /// Search by meaning loads, is ready, can't be had, or was let go.
    case meaning(MeaningState, error: String?)
    /// config.json can't be read: the settings stay as they were.
    case config(error: String)
    /// The background indexer's progress changed.
    case indexer(IndexerStatus)

    private struct Name: Decodable { let event: String? }
    private struct MeaningChange: Decodable {
        let state: MeaningState
        let error: String?
    }
    private struct ConfigError: Decodable { let error: String }

    /// An event's line, or nil for a line that isn't one (or one this app doesn't know).
    public static func decode(_ line: Data) -> Event? {
        let decoder = JSONDecoder()
        guard let name = (try? decoder.decode(Name.self, from: line))?.event else { return nil }
        switch name {
        case "ready":
            return (try? decoder.decode(Ready.self, from: line)).map(Event.ready)
        case "meaning":
            return (try? decoder.decode(MeaningChange.self, from: line)).map { .meaning($0.state, error: $0.error) }
        case "config":
            return (try? decoder.decode(ConfigError.self, from: line)).map { .config(error: $0.error) }
        case "indexer":
            return (try? decoder.decode(IndexerStatus.self, from: line)).map(Event.indexer)
        default:
            return nil
        }
    }
}
