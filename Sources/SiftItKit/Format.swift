// How results are put into words: where a match is, a file's folder, sizes and times. The same as the Raycast
// extension's, so both front ends say the same.

import Foundation

public enum Format {
    /// "1:24", or "1:02:03" past the hour.
    public static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// Where in the file the match is: "Page 3", "1:24", "Line 12", "Cell 2". nil where the place says nothing.
    public static func location(of hit: Hit) -> String? {
        guard let loc = hit.loc else { return nil }
        switch hit.segment {
        case .page:
            return "Page \(Int(loc))"
        case .sound, .frame, .speech:
            return timestamp(loc)
        case .passage:
            if isPDF(hit.path) { return "Page \(Int(loc))" }
            if hit.path.hasSuffix(".ipynb") { return "Cell \(Int(loc))" }
            return loc > 1 ? "Line \(Int(loc))" : nil
        case .ocr:
            return isPDF(hit.path) ? "Page \(Int(loc))" : nil
        default:
            return nil
        }
    }

    /// The same, short, for the list: "p. 3", "1:24", "line 12".
    public static func shortLocation(of hit: Hit) -> String? {
        guard let label = location(of: hit) else { return nil }
        if label.hasPrefix("Page ") { return "p. " + label.dropFirst(5) }
        if label.hasPrefix("Line ") { return "line " + label.dropFirst(5) }
        if label.hasPrefix("Cell ") { return "cell " + label.dropFirst(5) }
        return label
    }

    /// The stretch an audio file's or video's match covers, "0:50–1:18", or its moment.
    public static func span(of hit: Hit) -> String? {
        guard let start = hit.loc else { return nil }
        guard let end = hit.locEnd, end > start else { return timestamp(start) }
        return "\(timestamp(start))–\(timestamp(end))"
    }

    public static let kindNames: [Kind: String] = [
        .plaintext: "Text", .document: "Document", .structured: "Data", .image: "Picture",
        .screenshot: "Screenshot", .audio: "Audio", .video: "Video", .code: "Code",
    ]

    public static func kindName(_ kind: Kind) -> String {
        kindNames[kind] ?? kind.rawValue.capitalized
    }

    /// A kind's files together, as a list of kinds names them: "Documents", "Text", "Audio".
    public static func kindsName(_ kind: Kind) -> String {
        kindsNames[kind] ?? kind.rawValue.capitalized
    }

    private static let kindsNames: [Kind: String] = [
        .plaintext: "Text", .document: "Documents", .structured: "Data", .image: "Pictures",
        .screenshot: "Screenshots", .audio: "Audio", .video: "Videos", .code: "Code",
    ]

    /// How many files of a kind: "1 document", "900 documents", "12 text files".
    public static func kindCount(_ kind: Kind, _ count: Int) -> String {
        let (one, many) = kindCounts[kind] ?? (kind.rawValue, kind.rawValue + "s")
        return "\(count.formatted()) \(count == 1 ? one : many)"
    }

    private static let kindCounts: [Kind: (String, String)] = [
        .plaintext: ("text file", "text files"), .document: ("document", "documents"),
        .structured: ("data file", "data files"), .image: ("picture", "pictures"),
        .screenshot: ("screenshot", "screenshots"), .audio: ("audio file", "audio files"),
        .video: ("video", "videos"), .code: ("code file", "code files"),
    ]

    /// A path with the home folder as ~.
    public static func shortPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The folder a file is in, short.
    public static func folder(of path: String, home: String = NSHomeDirectory()) -> String {
        shortPath((path as NSString).deletingLastPathComponent, home: home)
    }

    /// "812 B", "4.1 MB", "23 MB".
    public static func bytes(_ size: UInt64) -> String {
        if size < 1024 { return "\(size) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(size) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unit])
    }

    /// How long something takes, roughly: "under a minute", "about 12 min", "about 2 h".
    public static func duration(_ seconds: Double) -> String {
        switch seconds {
        case ..<60: "under a minute"
        case ..<5400: "about \(Int((seconds / 60).rounded())) min"
        default: "about \(Int((seconds / 3600).rounded())) h"
        }
    }

    /// The query's words as the engine splits them: letters and digits, two or more.
    public static func words(of query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }

    public static func isPDF(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".pdf")
    }
}
