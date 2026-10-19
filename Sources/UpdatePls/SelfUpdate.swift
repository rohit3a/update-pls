import AppKit
import Foundation

/// Keeps Update pls itself current: compares with VERSION on GitHub and rebuilds from the local clone.
enum SelfUpdate {
    static let repo = "rohit3a/update-pls"

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// The git clone this app was built from (written into Info.plist by scripts/build-app.sh).
    static var source: String? {
        guard let dir = Bundle.main.infoDictionary?["UpdatePlsSource"] as? String,
              FileManager.default.fileExists(atPath: dir + "/.git") else { return nil }
        return dir
    }

    static func latest() async -> String? {
        guard let d = await LatestResolver.get("https://raw.githubusercontent.com/\(repo)/main/VERSION") else { return nil }
        let v = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Version.extract(v)
    }

    /// Pulls and rebuilds the clone, then swaps the new app in once this one has quit, and reopens it.
    /// Returns only on failure; on success the app quits.
    @MainActor
    static func update() async -> String? {
        guard let src = source else {
            NSWorkspace.shared.open(URL(string: "https://github.com/\(repo)")!)
            return nil
        }
        let r = await Shell.run("/bin/bash", ["-c", "cd \(Shell.q(src)) && git pull --ff-only && ./scripts/build-app.sh"], timeout: 900)
        guard r.ok else {
            return r.timedOut ? "Timed out" : r.combined.split(separator: "\n").last.map(String.init) ?? "Update failed"
        }
        let built = src + "/build/Update pls.app", dest = Bundle.main.bundlePath
        let swap = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf \(Shell.q(dest + ".new")) && ditto \(Shell.q(built)) \(Shell.q(dest + ".new")) \
          && rm -rf \(Shell.q(dest)) && mv \(Shell.q(dest + ".new")) \(Shell.q(dest))
        open \(Shell.q(dest))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", swap]
        do { try p.run() } catch { return error.localizedDescription }
        NSApp.terminate(nil)
        return nil
    }
}
