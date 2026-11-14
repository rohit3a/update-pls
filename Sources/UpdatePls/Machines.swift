import Foundation

enum OSKind: String { case mac, linux, windows }

struct Machine: Identifiable, Hashable {
    let id: String
    let name: String
    /// Other ~/.ssh/config aliases that reach the same machine, tried in order when `id` can't run commands there.
    var fallbacks: [String] = []
    var isLocal: Bool { id == Machine.local.id }
    static let local = Machine(id: "local", name: Host.current().localizedName ?? "This Mac")

    // One machine is one alias, whatever its fallbacks.
    static func == (a: Machine, b: Machine) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
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

    /// Where an alias really connects, "user@host:port", as `ssh -G` works it out from the whole config.
    static func target(_ alias: String) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-G", alias]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var f: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, ["hostname", "user", "port"].contains(parts[0]) { f[parts[0]] = parts[1] }
        }
        guard let host = f["hostname"] else { return nil }
        return "\(f["user"] ?? "")@\(host.lowercased()):\(f["port"] ?? "22")"
    }

    static func targets(_ aliases: [String]) -> [String: String] {
        var t: [String: String] = [:]
        for a in aliases { t[a] = target(a) ?? a }
        return t
    }

    /// The alias that last worked for each target, so a check starts with it.
    static var preferred: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "preferredHosts") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "preferredHosts") }
    }

    /// One machine per place the turned-on aliases reach, in config order. Each uses the alias that last worked
    /// there, else the first one; the other aliases for it become its fallbacks.
    static func machines(hosts: [String], disabled: Set<String>, targets: [String: String], preferred: [String: String]) -> [Machine] {
        var order: [String] = [], groups: [String: [String]] = [:]
        for h in hosts where !disabled.contains(h) {
            let t = targets[h] ?? h
            if groups[t] == nil { order.append(t) }
            groups[t, default: []].append(h)
        }
        return order.map { t in
            let aliases = groups[t]!
            let primary = preferred[t].flatMap { aliases.contains($0) ? $0 : nil } ?? aliases[0]
            return Machine(id: primary, name: primary, fallbacks: aliases.filter { $0 != primary })
        }
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
