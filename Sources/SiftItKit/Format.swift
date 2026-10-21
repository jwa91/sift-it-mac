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

    /// The stretch a recording's match covers, "0:50–1:18", or its moment.
    public static func span(of hit: Hit) -> String? {
        guard let start = hit.loc else { return nil }
        guard let end = hit.locEnd, end > start else { return timestamp(start) }
        return "\(timestamp(start))–\(timestamp(end))"
    }

    public static let kindNames: [Kind: String] = [
        .plaintext: "Text", .document: "Document", .structured: "Data", .image: "Picture",
        .screenshot: "Screenshot", .audio: "Recording", .video: "Video", .code: "Code",
    ]

    public static func kindName(_ kind: Kind) -> String {
        kindNames[kind] ?? kind.rawValue.capitalized
    }

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
