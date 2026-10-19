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

    enum Detect { case os(OSKind), offline(String) }

    static func detectOS(_ m: Machine) async -> Detect {
        if m.isLocal { return .os(.mac) }
        let r = await Shell.run("/usr/bin/ssh", sshOptions + [m.id, "uname -s"], timeout: 20)
        if r.status == 255 || r.timedOut {
            let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .offline(msg.isEmpty ? "Unreachable" : msg)
        }
        let s = r.stdout.lowercased()
        if r.ok && s.contains("darwin") { return .os(.mac) }
        if r.ok && s.contains("linux") { return .os(.linux) }
        return .os(.windows)
    }

    static func run(_ m: Machine, os: OSKind, script: String, timeout: TimeInterval) async -> ShellResult {
        if m.isLocal { return await Shell.run("/bin/bash", ["-s"], input: script, timeout: timeout) }
        let remote = os == .windows ? psBootstrap : "bash -s"
        return await Shell.run("/usr/bin/ssh", sshOptions + [m.id, remote], input: script, timeout: timeout)
    }
}
