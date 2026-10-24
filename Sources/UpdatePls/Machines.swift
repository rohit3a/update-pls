import Foundation

enum OSKind: String { case mac, linux, windows }

struct Machine: Identifiable, Hashable {
    let id: String
    let name: String
    var isLocal: Bool { id == Machine.local.id }
    static let local = Machine(id: "local", name: Host.current().localizedName ?? "This Mac")
}

enum SSHConfig {
    /// Concrete `Host` aliases from ~/.ssh/config (wildcard patterns skipped).
    static func hosts() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [String] = []
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.lowercased().hasPrefix("host ") else { continue }
            for name in t.dropFirst(5).split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                let s = String(name)
                if s.contains(where: { "*?!".contains($0) }) || out.contains(s) { continue }
                out.append(s)
            }
        }
        return out
    }
}

enum Runner {
    static let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4"]

    /// Reads a PowerShell script from stdin and runs it, so the script never touches the remote command line.
    static let psBootstrap: String = {
        let cmd = "$s=[Console]::In.ReadToEnd(); Invoke-Expression $s"
        var data = Data()
        for u in cmd.utf16 { data.append(UInt8(u & 0xff)); data.append(UInt8(u >> 8)) }
        return "powershell -NoProfile -NonInteractive -EncodedCommand " + data.base64EncodedString()
    }()

    enum Detect: Equatable { case os(OSKind), offline(String) }

    static func detectOS(_ m: Machine) async -> Detect {
        if m.isLocal { return .os(.mac) }
        let r = await Shell.run("/usr/bin/ssh", sshOptions + [m.id, "uname -s"], timeout: 20)
        let d = classify(r)
        Log.info("\(m.id): \(d == .os(.mac) ? "macOS" : d == .os(.linux) ? "Linux" : d == .os(.windows) ? "Windows" : "offline") (ssh exit \(r.status)\(r.timedOut ? ", timed out" : ""))"
                 + (r.ok ? "" : "\n" + r.combined.trimmingCharacters(in: .whitespacesAndNewlines)))
        return d
    }

    /// Reads `ssh host uname -s`. Only a host that really looks like Windows is treated as one.
    static func classify(_ r: ShellResult) -> Detect {
        let msg = r.combined.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status == 255 || r.timedOut { return .offline(msg.isEmpty ? (r.timedOut ? "Timed out" : "Unreachable") : msg) }
        let s = r.stdout.lowercased()
        if r.ok && s.contains("darwin") { return .os(.mac) }
        if r.ok && s.contains("linux") { return .os(.linux) }
        if s.contains("mingw") || s.contains("msys") || s.contains("cygwin") { return .os(.windows) }
        let lower = msg.lowercased()
        if lower.contains("not recognized") || lower.contains("commandnotfoundexception") || lower.contains("windows") {
            return .os(.windows)
        }
        return .offline("Couldn't tell what system this is" + (msg.isEmpty ? "" : ": \(msg)"))
    }

    /// Runs a script on the machine. POSIX scripts are wrapped in `{ ... } </dev/null` so bash reads all of it
    /// before running anything, and no command inside can swallow the rest of the script from stdin.
    static func run(_ m: Machine, os: OSKind, script: String, timeout: TimeInterval,
                    onOutput: (@Sendable (String) -> Void)? = nil) async -> ShellResult {
        let body = os == .windows ? script : "{\n" + script + "\n} </dev/null\n"
        if m.isLocal { return await Shell.run("/bin/bash", ["-s"], input: body, timeout: timeout, onOutput: onOutput) }
        let remote = os == .windows ? psBootstrap : "bash -s"
        return await Shell.run("/usr/bin/ssh", sshOptions + [m.id, remote], input: body, timeout: timeout, onOutput: onOutput)
    }
}
