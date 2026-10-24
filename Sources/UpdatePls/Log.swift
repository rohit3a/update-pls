import Foundation
import os

/// The local log: ~/Library/Logs/Update pls/update-pls.log (rotated at 5 MB, also in Console under
/// com.rohit3a.updatepls), plus one file per update in runs/ with that update's full output.
enum Log {
    static var dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Update pls")
    static var file: URL { dir.appendingPathComponent("update-pls.log") }
    static var runsDir: URL { dir.appendingPathComponent("runs") }

    private static let queue = DispatchQueue(label: "com.rohit3a.updatepls.log")
    private static let system = Logger(subsystem: "com.rohit3a.updatepls", category: "app")
    private static let maxBytes: UInt64 = 5_000_000
    private static let keepRuns = 60

    static func info(_ message: String) { write("INFO ", message) }
    static func error(_ message: String) { write("ERROR", message) }

    /// Writes synchronously, so the line is on disk even if the app dies right after.
    static func write(_ level: String, _ message: String) {
        if level == "ERROR" { system.error("\(message, privacy: .public)") } else { system.info("\(message, privacy: .public)") }
        queue.sync {
            let body = message.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "\n    | ")
            append("\(stamp()) \(level) \(body)\n", to: file, rotate: true)
        }
    }

    /// A new per-update output file, e.g. runs/2026-10-24 12.16.03 local cursor.log.
    /// Never reuses a file: two updates of the same tool in the same second (say, from the menu and the
    /// command line) each get their own.
    static func newRun(_ name: String) -> URL {
        let base = "\(fileStamp()) \(name.replacingOccurrences(of: "/", with: " "))"
        return queue.sync {
            try? FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
            var url = runsDir.appendingPathComponent(base + ".log")
            for n in 2...99 {
                let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
                if fd >= 0 { close(fd); break }
                url = runsDir.appendingPathComponent("\(base) \(n).log")
            }
            pruneRuns()
            return url
        }
    }

    static func appendRun(_ url: URL, _ text: String) {
        queue.sync { append(text, to: url, rotate: false) }
    }

    /// The last `n` lines of the main log (tests and the CLI use this).
    static func tail(_ n: Int) -> [String] {
        queue.sync {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            return Array(text.split(separator: "\n").suffix(n).map(String.init))
        }
    }

    private static func append(_ text: String, to url: URL, rotate: Bool) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.write(contentsOf: Data(text.utf8))
        try? h.close()
        if rotate && end > maxBytes {
            let old = url.deletingPathExtension().appendingPathExtension("1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
    }

    private static func pruneRuns() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: runsDir, includingPropertiesForKeys: nil) else { return }
        for f in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(keepRuns) { try? fm.removeItem(at: f) }
    }

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static let fileFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
    static func stamp() -> String { stampFormat.string(from: Date()) }
    private static func fileStamp() -> String { fileFormat.string(from: Date()) }
}
