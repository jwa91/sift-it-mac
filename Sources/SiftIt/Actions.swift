// What can be done with a result: open it where it matched, show it in Finder, copy it or its path.
//
// Opening at the place goes through `sift-it open`, so the app and the CLI agree on where that is and how to get
// there: QuickTime at the second, Preview at the page, an editor at the line.

import AppKit
import SiftItKit

@MainActor
enum Actions {
    /// Where opening a result takes you, beyond the file itself.
    enum Place: Equatable {
        case moment(Double)
        case page(Int)
        case line(Int)
        case file
    }

    /// The same rule as the CLI's (clients/open.rs).
    static func place(of hit: Hit) -> Place {
        guard let loc = hit.loc else { return .file }
        switch hit.kind {
        case .audio, .video:
            return .moment(loc)
        case .document where loc > 1 && Format.isPDF(hit.path):
            return .page(Int(loc))
        case .plaintext, .structured, .code:
            return hit.path.hasSuffix(".ipynb") ? .file : .line(max(1, Int(loc)))
        default:
            return .file
        }
    }

    /// What ↩ does, in words: "Play from 0:42", "Open at page 3".
    static func openTitle(_ hit: Hit) -> String {
        switch place(of: hit) {
        case .moment(let seconds): "Play from \(Format.timestamp(seconds))"
        case .page(let page): "Open at page \(page)"
        case .line(let line): "Open at line \(line)"
        case .file: "Open"
        }
    }

    static func open(_ hit: Hit, cli: URL?) {
        let place = place(of: hit)
        if case .page = place, !Permissions.explainTypingOnce() { return }
        let at: Double? =
            switch place {
            case .moment(let seconds): seconds
            case .page(let page): Double(page)
            case .line(let line): Double(line)
            case .file: nil
            }
        guard let at, let cli else {
            NSWorkspace.shared.open(hit.url)
            return
        }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["open", hit.path, "--at", String(at)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(hit.url)
        }
    }

    static func reveal(_ hit: Hit) {
        NSWorkspace.shared.activateFileViewerSelecting([hit.url])
    }

    static func copyFile(_ hit: Hit) {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([hit.url as NSURL])
    }

    static func copyPath(_ hit: Hit) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(hit.path, forType: .string)
    }
}
