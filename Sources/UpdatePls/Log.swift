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

    /// Appends with O_APPEND, so the menu and the command line writing at once never overwrite each other.
    private static func append(_ text: String, to url: URL, rotate: Bool) {
        var fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        if fd < 0 {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = Array(text.utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        var st = stat()
        guard rotate, fstat(fd, &st) == 0, UInt64(st.st_size) > maxBytes, flock(fd, LOCK_EX) == 0 else { return }
        // Under the lock, and only if no other process rotated it first.
        var now = stat()
        if stat(url.path, &now) == 0, now.st_ino == st.st_ino {
            rename(url.path, url.deletingPathExtension().appendingPathExtension("1.log").path)
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
