// Where sift-it keeps its files, how the app reaches its engine, and where its command-line tool is.

import CryptoKit
import Foundation

public enum Places {
    /// The data folder: `SIFT_IT_HOME`, or ~/Library/Application Support/Sift It.
    public static var dataFolder: URL {
        if let home = ProcessInfo.processInfo.environment["SIFT_IT_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sift It")
    }

    /// The engine's LaunchAgent.
    public static let engineLabel = "local.sift-it.engine"

    /// How long a socket's name can be: sockaddr_un's sun_path, its closing NUL included.
    static let sunPath = 104

    /// The name the engine's socket is reached by. A data folder too deep for a socket's name is reached through a link
    /// in this user's temporary folder, named by a hash of the folder: what the engine does (services/engine.rs).
    public static func socketAddress(dataFolder: URL = dataFolder) throws -> String {
        let socket = dataFolder.appendingPathComponent("engine.sock").path
        if socket.utf8.count < sunPath { return socket }
        let home = dataFolder.standardizedFileURL.path
        let hash = SHA256.hash(data: Data(home.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let link = userTemporaryFolder().appendingPathComponent("sift-it-\(hash)").path
        let manager = FileManager.default
        if (try? manager.destinationOfSymbolicLink(atPath: link)) != home {
            try? manager.removeItem(atPath: link)
            do {
                try manager.createSymbolicLink(atPath: link, withDestinationPath: home)
            } catch CocoaError.fileWriteFileExists {
                // Another client made it meanwhile.
            }
        }
        return link + "/engine.sock"
    }

    /// This user's temporary folder (/var/folders/…/T/), whatever TMPDIR says.
    static func userTemporaryFolder() -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let needed = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard needed > 0, needed <= buffer.count else { return FileManager.default.temporaryDirectory }
        let path = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: path, as: UTF8.self))
    }

    /// Where Homebrew puts sift-it, on Apple silicon and on Intel.
    public static let cliCandidates = ["/opt/homebrew/bin/sift-it", "/usr/local/bin/sift-it"]

    /// sift-it's command-line tool: the one set in the settings, else where Homebrew puts it, else on the PATH.
    public static func cli(preferred: String? = nil) -> URL? {
        let manager = FileManager.default
        var candidates: [String] = []
        if let preferred, !preferred.isEmpty { candidates.append((preferred as NSString).expandingTildeInPath) }
        candidates += cliCandidates
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += path.split(separator: ":").map { "\($0)/sift-it" }
        return candidates.first { manager.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }
}
