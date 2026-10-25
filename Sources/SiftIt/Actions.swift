// What can be done with a result: open it where it matched, show it in Finder, copy it or its path.
//
// Opening at the place goes through `sift-it open`, so the app and the CLI agree on where that is and how to get
// there: QuickTime at the second, Preview at the page, an editor at the line.
//
// A conversation is resumed instead, in the folder it started in, with the command the engine gives it: a .command
// file the app writes opens in the terminal that opens those (Terminal, or the one chosen for them), in a login
// shell, so `claude` and `codex` are found as they are when typed. No Apple Events, so no permission.

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

    /// What ↩ does, in words: "Play from 0:42", "Open at page 3", "Resume".
    static func openTitle(_ hit: Hit) -> String {
        guard hit.kind != .conversation else { return "Resume" }
        return switch place(of: hit) {
        case .moment(let seconds): "Play from \(Format.timestamp(seconds))"
        case .page(let page): "Open at page \(page)"
        case .line(let line): "Open at line \(line)"
        case .file: "Open"
        }
    }

    static func open(_ hit: Hit, cli: URL?) {
        if hit.kind == .conversation { return resume(hit) }
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

    /// Resumes a conversation in a terminal, in the folder it started in. A folder that's gone (a removed worktree)
    /// is said, with the command to copy.
    static func resume(_ hit: Hit) {
        guard let command = Format.resumeCommand(of: hit.info), let cwd = hit.info.cwd else {
            NSWorkspace.shared.open(hit.url)
            return
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isFolder), isFolder.boolValue else {
            let alert = NSAlert()
            alert.messageText = "The folder this conversation ran in is gone"
            alert.informativeText = "\(Format.shortPath(cwd)) isn't there any more, so it can't be resumed in it."
            alert.addButton(withTitle: "Copy Resume Command")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { copy(command) }
            return
        }
        do {
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("sift-it/resume", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = (hit.info.session ?? "conversation").filter { $0.isLetter || $0.isNumber || $0 == "-" }
            let script = folder.appendingPathComponent("\(name).command")
            try "#!/bin/sh\n\(command)\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            copy(command)
            NSSound.beep()
        }
    }

    static func copyResumeCommand(_ hit: Hit) {
        Format.resumeCommand(of: hit.info).map(copy)
    }

    private static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
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
