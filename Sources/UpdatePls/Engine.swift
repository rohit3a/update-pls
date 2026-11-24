import Foundation

/// How a given install gets updated.
enum Method: Hashable {
    case npm(bin: String, prefix: String, package: String, tag: String, writable: Bool)
    case bun(package: String)
    case brewFormula(String)
    case pipx(String)
    case uv(String)
    case selfUpdate(path: String, args: String)
    case cask(String)
    case macDirect(appPath: String, bundleID: String)
    case winget(String)
    /// An apt package; with `passwordless`, sudo works without a password on that machine, so Update pls runs it.
    case deb(String, passwordless: Bool = false)
    /// A CLI wrapper script that delegates directly to a macOS `.app` bundle (e.g. `~/.t3/bin/t3` -> `T3 Code (Nightly).app`).
    case bundledWithApp(appPath: String, appName: String)
    case none

    var label: String {
        switch self {
        case .npm: "npm"
        case .bun: "bun"
        case .brewFormula, .cask: "Homebrew"
        case .pipx: "pipx"
        case .uv: "uv"
        case .selfUpdate: "built-in updater"
        case .macDirect: "direct download"
        case .winget: "winget"
        case .deb: "apt"
        case let .bundledWithApp(_, name): "bundled in \(name)"
        case .none: "manual"
        }
    }

    /// Short badge label shown inline in row subtitles.
    var shortLabel: String {
        switch self {
        case .npm: "npm"
        case .bun: "bun"
        case .brewFormula, .cask: "brew"
        case .pipx: "pipx"
        case .uv: "uv"
        case .selfUpdate: "native"
        case .macDirect: "direct"
        case .winget: "winget"
        case .deb: "apt"
        case .bundledWithApp: "bundled"
        case .none: "manual"
        }
    }
}

/// What the last check found. Updates in progress and their results live in `AppModel.activity`,
/// so a re-check never wipes them.
enum ItemState: Hashable {
    case upToDate, available, unknown
}

struct Item: Identifiable, Hashable {
    var machine: Machine
    var os: OSKind
    var defID: String
    var name: String
    var brand: String
    var isApp: Bool
    var path: String
    var installed: String?
    var latest: LatestInfo?
    var method: Method
    var running = false
    var state: ItemState = .unknown
    /// From the catalog: how to install one exact version through the tool's own installer.
    var installVersion: String?
    /// Which app, for apps that come in several (T3 Code and T3 Code Nightly), so each keeps its own key
    /// whatever else is installed.
    var variant: String?
    /// Versions of this Mac app that Update pls saved on its machine when it replaced them, newest first.
    var saved: [String] = []
    /// The machine's CPU (arm64, x86_64), for picking downloads.
    var arch = ""

    var id: String { "\(machine.id)/\(defID)/\(path)" }
    /// Stable per machine and tool; used for the skip and hide lists, rollback records and update progress.
    var key: String { "\(machine.id)/\(defID)" + (variant.map { ":\($0)" } ?? "") }

    /// The command that installs exactly version `v`, or nil when this install can't switch versions that way.
    /// Mac apps downloaded directly use saved copies and release downloads instead (see `Engine.install`).
    func rollbackCommand(to v: String) -> String? {
        guard os != .windows else { return nil }
        switch method {
        case let .npm(bin, prefix, pkg, _, w):
            var pinned = self
            pinned.method = .npm(bin: bin, prefix: prefix, package: pkg, tag: v, writable: w)
            return pinned.command
        case let .bun(pkg): return "bun add -g \(Shell.q("\(pkg)@\(v)"))"
        case let .pipx(n): return "pipx install --force \(Shell.q("\(n)==\(v)"))"
        case let .uv(n): return "uv tool install --force \(Shell.q("\(n)==\(v)"))"
        case let .selfUpdate(path, _):
            return installVersion.map { "\(Shell.q(path)) " + $0.replacingOccurrences(of: "{version}", with: v) }
        default: return nil
        }
    }

    var supportsRollback: Bool {
        if case .macDirect = method { return true }
        return rollbackCommand(to: "0").map { !$0.hasPrefix("sudo ") } ?? false
    }

    /// Shell command shown to the user and run for the update (Mac apps use the steps in Update.swift).
    var command: String? {
        switch method {
        case let .npm(bin, prefix, pkg, tag, writable):
            // --prefix pins the install to where the package already lives, whatever npm's own default is.
            let base = os == .windows
                ? "npm install -g --prefix \(Shell.psq(prefix)) --allow-scripts=\(pkg) \(Shell.psq("\(pkg)@\(tag)"))"
                : "\(Shell.q(bin)) install -g --prefix \(Shell.q(prefix)) --allow-scripts=\(Shell.q(pkg)) \(Shell.q("\(pkg)@\(tag)"))"
            return writable ? base : "sudo " + base
        case let .bun(pkg): return "bun add -g \(Shell.q(pkg + "@latest"))"
        case let .brewFormula(f): return "brew upgrade \(Shell.q(f))"
        case let .pipx(n): return "pipx upgrade \(Shell.q(n))"
        case let .uv(n): return "uv tool upgrade \(Shell.q(n))"
        case let .selfUpdate(path, args): return os == .windows ? "& \(Shell.psq(path)) \(args)" : "\(Shell.q(path)) \(args)"
        // Casks of apps that update themselves are skipped by a plain `brew upgrade` unless --greedy.
        case let .cask(t): return "brew upgrade --cask --greedy \(Shell.q(t))"
        case .macDirect: return nil
        case let .winget(id):
            return "winget upgrade --id \(Shell.psq(id)) --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"
        case let .deb(p, passwordless):
            if !passwordless { return "sudo apt-get update && sudo apt-get install --only-upgrade -y \(Shell.q(p))" }
            return "sudo -n apt-get update -q && sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y \(Shell.q(p))"
        case .bundledWithApp, .none: return nil
        }
    }

    /// Updates that need a password are shown as a command to copy instead of being run.
    var needsSudo: Bool {
        if case let .deb(_, passwordless) = method { return !passwordless }
        return command?.hasPrefix("sudo ") == true
    }

    /// Update pls can run this update itself.
    var canUpdate: Bool {
        if needsSudo { return false }
        if case .macDirect = method { return latest?.url != nil }
        return command != nil
    }

    var summary: String { "\(installed ?? "?") -> \(latest?.version ?? "?") [\(method.label)]" }
}

struct MachineStatus: Identifiable, Hashable {
    enum State: Hashable { case checking, online, offline(String) }
    var machine: Machine
    var os: OSKind?
    var state: State = .checking
    var id: String { machine.id }
}

/// Time this Mac has spent asleep: the gap between a clock that runs during sleep and one that doesn't.
enum SleepClock {
    static var asleep: TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) &- clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    /// "4.2s", or "944.4s (940.1s of it asleep)" when the Mac slept in the middle.
    static func took(since start: Date, asleep before: TimeInterval) -> String {
        let slept = asleep - before
        return String(format: "%.1fs", Date().timeIntervalSince(start)) + (slept > 1 ? String(format: " (%.1fs of it asleep)", slept) : "")
    }
}

enum Engine {
    /// Cached login PATH and OS per machine id, populated by full checks so subsequent updates and targeted
    /// verifications skip spawning an interactive login shell or an extra `uname -s` SSH handshake.
    private static let machineCacheLock = NSLock()
    private static var cachedPaths: [String: (path: String, at: Date)] = [:]
    private static var cachedOS: [String: OSKind] = [:]
    /// A login PATH older than this is read again, so a tool installed somewhere new (another nvm version) shows up.
    static let pathCacheTTL: TimeInterval = 30 * 60

    static func cachedPath(for machine: Machine, now: Date = Date()) -> String? {
        machineCacheLock.withLock {
            guard let c = cachedPaths[machine.id], now.timeIntervalSince(c.at) < pathCacheTTL else { return nil }
            return c.path
        }
    }

    static func setCachedPath(_ path: String, for machine: Machine, at: Date = Date()) {
        guard !path.isEmpty else { return }
        machineCacheLock.withLock { cachedPaths[machine.id] = (path, at) }
    }

    /// Forgets what was learned about a machine (its system and login PATH), e.g. after its alias was repointed.
    static func forget(_ machine: Machine) {
        machineCacheLock.withLock {
            cachedPaths[machine.id] = nil
            cachedOS[machine.id] = nil
        }
    }

    static func cachedOS(for machine: Machine) -> OSKind? {
        if machine.isLocal { return .mac }
        return machineCacheLock.withLock { cachedOS[machine.id] }
    }

    static func setCachedOS(_ os: OSKind, for machine: Machine) {
        machineCacheLock.withLock { cachedOS[machine.id] = os }
    }

    /// When true (the default), Mac apps installed via Homebrew Cask use direct downloads instead of `brew upgrade --cask`,
    /// enabling APFS rollback backups, signature/TeamID verification, pending-update reuse, and avoiding Homebrew quarantine/ShipIt issues.
    static var preferDirectDownloads: Bool {
        !UserDefaults.standard.bool(forKey: "useHomebrewForApps")
    }

    /// Finds what is installed on a machine and the newest version of each.
    /// `known` reuses latest versions already looked up (by item key), so a re-check after an update stays quick.
    static func check(_ m: Machine, catalog: Catalog, resolver: LatestResolver, known: [String: LatestInfo] = [:],
                      preferDirectDownloads: Bool = Engine.preferDirectDownloads,
                      forcePathRefresh: Bool = false) async -> (MachineStatus, [Item]) {
        let start = Date(), asleep = SleepClock.asleep
        var status = MachineStatus(machine: m)
        // A check you ask for learns the machine afresh: its alias may now lead somewhere else.
        if forcePathRefresh { forget(m) }
        let pathHint = forcePathRefresh ? nil : cachedPath(for: m)
        var scan = await scan(m, catalog, cachedPath: pathHint)
        // A connection that dropped mid-scan, or that the Mac's sleep cut off (a background check runs in the
        // few seconds of a dark wake), says nothing about the machine: try it once more.
        if case let .failed(what, msg, dropped) = scan, dropped || SleepClock.asleep - asleep > 1 {
            Log.info("check \(m.id): \(what): \(msg); trying again")
            scan = await self.scan(m, catalog, cachedPath: pathHint)
        }
        // This alias reaches the machine but can't run the check there (a key limited to one program, or refused):
        // try the other aliases for the same machine, and start with the one that works next time.
        func viaOtherAlias(_ msg: String) async -> (MachineStatus, [Item])? {
            for (k, alias) in m.fallbacks.enumerated() {
                Log.info("check \(m.id): \(msg); trying \(alias), the same machine")
                let alt = Machine(id: alias, name: alias, fallbacks: Array(m.fallbacks.dropFirst(k + 1)))
                let r = await check(alt, catalog: catalog, resolver: resolver, known: known,
                                    preferDirectDownloads: preferDirectDownloads, forcePathRefresh: forcePathRefresh)
                if case .online = r.0.state {
                    if let t = SSHConfig.target(alias) { SSHConfig.preferred[t] = alias }
                    return r
                }
                if !alt.fallbacks.isEmpty { break } // that check already tried the rest
            }
            return nil
        }
        let os: OSKind, out: ShellResult
        switch scan {
        case let .failed(what, msg, _):
            forget(m)
            if msg.hasPrefix("Couldn't tell what system this is") || msg.contains("Permission denied"), let r = await viaOtherAlias(msg) { return r }
            status.state = .offline(msg)
            Log.error("check \(m.id): \(what): \(msg)")
            return (status, [])
        case let .done(o, r): (os, out) = (o, r)
        }
        // Every check prints an OS line first: without one the script never ran (the key only allows one command).
        if !out.stdout.contains("OS\t") {
            // The script never ran, possibly because the machine isn't the system it was last time.
            forget(m)
            let msg = "Connected, but this key can't run the check there (it may be limited to one command)"
            if let r = await viaOtherAlias(msg) { return r }
            status.state = .offline(msg)
            Log.error("check \(m.id): \(msg)" + (out.combined.isEmpty ? "" : "\n" + out.combined.trimmingCharacters(in: .whitespacesAndNewlines)))
            return (status, [])
        }
        status.os = os
        if let full = out.stderr.split(separator: "\n").first(where: { $0.contains("Disk quota exceeded") || $0.contains("No space left on device") }) {
            Log.error("check \(m.id): its disk is full, so this check may be missing tools: \(full)")
        }
        if !out.ok {
            Log.error("check \(m.id): scan exited \(out.status)\(out.timedOut ? " (timed out, results may be partial)" : "")\n"
                      + out.stderr.split(separator: "\n").suffix(15).joined(separator: "\n"))
        }
        status.state = .online
        let probe = Probe.parse(out.stdout)
        // The script says what system it really ran on; trust that over what was remembered.
        setCachedOS(os == .windows ? os : probe.os, for: m)
        // Only a PATH read from the login shell renews the cache (a cached one is just echoed back).
        if pathHint == nil, !probe.resolvedPath.isEmpty { setCachedPath(probe.resolvedPath, for: m) }
        for line in probe.recovery { Log.error("check \(m.id): interrupted update: \(line)") }
        if probe.wingetUnreadable { Log.error("check \(m.id): couldn't read winget's list (it may not be in English), so its apps aren't shown") }
        var items = buildItems(probe, machine: m, catalog: catalog, preferDirectDownloads: preferDirectDownloads)
        await withTaskGroup(of: (Int, LatestInfo?).self) { group in
            for (i, item) in items.enumerated() where item.latest == nil {
                if let k = known[item.key] { items[i].latest = k; continue }
                group.addTask { (i, await latest(for: item, probe: probe, catalog: catalog, resolver: resolver)) }
            }
            for await (i, info) in group { items[i].latest = info }
        }
        for i in items.indices { items[i].state = state(items[i]) }
        Log.info("check \(m.id) [\(os.rawValue)]: \(items.count) tools in \(SleepClock.took(since: start, asleep: asleep))\n"
                 + items.map { "\($0.key) \($0.summary) \($0.state)\($0.running ? " open" : "")" }.joined(separator: "\n"))
        return (status, items)
    }

    /// Fast single-item verification after an update: probes only `item` (reusing cached OS + PATH + latest info)
    /// instead of re-scanning every tool on the machine. Falls back to full check on Windows.
    static func verifySingle(_ item: Item, catalog: Catalog, resolver: LatestResolver,
                             preferDirectDownloads: Bool = Engine.preferDirectDownloads) async -> (MachineStatus, Item?) {
        let m = item.machine
        if item.os == .windows {
            let known = item.latest.map { [item.key: $0] } ?? [:]
            let (st, all) = await check(m, catalog: catalog, resolver: resolver, known: known, preferDirectDownloads: preferDirectDownloads)
            return (st, all.first { $0.key == item.key })
        }
        let start = Date(), asleep = SleepClock.asleep
        let pathHint = cachedPath(for: m)
        let script = Probe.verifyScript(for: item, catalog: catalog, cachedPath: pathHint)
        let out = await Runner.run(m, os: item.os, script: script, timeout: 60)
        if out.status == 255 || (out.timedOut && out.stdout.isEmpty) {
            let msg = out.timedOut ? "Timed out" : out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return (MachineStatus(machine: m, os: item.os, state: .offline(msg)), nil)
        }
        let probe = Probe.parse(out.stdout)
        if pathHint == nil, !probe.resolvedPath.isEmpty { setCachedPath(probe.resolvedPath, for: m) }
        let built = buildItems(probe, machine: m, catalog: catalog, preferDirectDownloads: preferDirectDownloads)
        // Only this tool counts: never another one the script happened to report.
        guard var fresh = built.first(where: { $0.key == item.key })
                ?? (built.count == 1 && built[0].defID == item.defID ? built[0] : nil) else {
            return (MachineStatus(machine: m, os: item.os, state: .online), nil)
        }
        if fresh.latest == nil {
            fresh.latest = item.latest
        }
        fresh.state = state(fresh)
        Log.info("verify \(item.key) in \(SleepClock.took(since: start, asleep: asleep)): \(fresh.summary) \(fresh.state)\(fresh.running ? " open" : "")")
        return (MachineStatus(machine: m, os: item.os, state: .online), fresh)
    }

    private enum Scan {
        case done(OSKind, ShellResult)
        /// `dropped`: the machine answered, then the connection went away.
        case failed(String, String, dropped: Bool)
    }

    private static func scan(_ m: Machine, _ catalog: Catalog, cachedPath: String? = nil) async -> Scan {
        let os: OSKind
        if let known = cachedOS(for: m) {
            os = known
        } else {
            switch await Runner.detectOS(m) {
            case let .offline(msg): return .failed("offline", msg, dropped: false)
            case let .os(o): os = o
            }
        }
        let script = os == .windows ? Probe.windowsScript(catalog) : Probe.unixScript(catalog, cachedPath: cachedPath)
        let out = await Runner.run(m, os: os, script: script, timeout: 240)
        if out.status == 255 || (out.timedOut && out.stdout.isEmpty) {
            let msg = out.timedOut ? "Timed out" : out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed("scan failed", msg, dropped: out.status == 255 && !out.timedOut)
        }
        return .done(os, out)
    }

    static func state(_ item: Item) -> ItemState {
        guard let latest = item.latest?.version, let installed = item.installed,
              !Version.clean(latest).isEmpty, !Version.clean(installed).isEmpty else { return .unknown }
        // apt's candidate is only listed when dpkg says it is newer (epochs, ~rc and all).
        if case .deb = item.method { return latest != installed ? .available : .upToDate }
        return Version.isNewer(latest, than: installed) ? .available : .upToDate
    }

    static func buildItems(_ p: ProbeResult, machine: Machine, catalog: Catalog,
                           preferDirectDownloads: Bool = Engine.preferDirectDownloads) -> [Item] {
        var items: [Item] = []
        for r in p.clis {
            guard let def = catalog.clis.first(where: { $0.id == r.id }) else { continue }
            let installed = r.packageVersion.isEmpty ? Version.extract(r.versionOutput) : r.packageVersion
            items.append(Item(machine: machine, os: p.os, defID: def.id, name: def.name, brand: def.brand ?? def.name, isApp: false, path: r.path,
                              installed: installed, method: cliMethod(r, def: def, os: p.os, installed: installed), installVersion: def.installVersion))
        }
        for r in p.apps {
            guard let def = catalog.apps.first(where: { $0.id == r.id }),
                  let variant = def.mac?.first(where: { $0.app == r.appName }) else { continue }
            let method: Method = if !preferDirectDownloads, let t = variant.latest.cask, p.hasBrew, p.casks.contains(t) { .cask(t) }
                                 else { .macDirect(appPath: r.path, bundleID: r.bundleID) }
            let name = def.mac!.count == 1 ? def.name : r.appName.hasPrefix(def.name) ? r.appName : "\(def.name) (\(r.appName))"
            let saved = Set(p.saved.filter { $0.id == r.id && $0.appName == r.appName }.map(\.version))
            items.append(Item(machine: machine, os: p.os, defID: def.id, name: name, brand: def.brand ?? def.name, isApp: true, path: r.path,
                              installed: r.version, method: method, running: r.running,
                              variant: def.mac!.count > 1 ? r.appName : nil,
                              saved: saved.sorted { Version.isNewer($0, than: $1) }))
        }
        for r in p.debs {
            guard let def = catalog.apps.first(where: { $0.id == r.id }) else { continue }
            let candidate = r.candidate.isEmpty || r.candidate == "(none)" ? r.installed : r.candidate
            // "Codex App (ChatGPT)" when the package is one of several apps under one name, as on the Mac.
            let app = def.mac?.first { $0.app.caseInsensitiveCompare(r.package) == .orderedSame }?.app
            let name = app.map { (def.mac?.count ?? 0) > 1 && !$0.hasPrefix(def.name) ? "\(def.name) (\($0))" : $0 } ?? def.name
            items.append(Item(machine: machine, os: p.os, defID: def.id, name: name, brand: def.brand ?? def.name, isApp: true, path: r.package,
                              installed: r.installed, latest: LatestInfo(version: candidate), method: .deb(r.package, passwordless: p.sudo),
                              running: r.running))
        }
        for def in catalog.apps {
            let wants = def.windows ?? []
            var seen = Set<String>()
            for want in wants {
                guard let row = p.winget.first(where: {
                    $0.name.caseInsensitiveCompare(want) == .orderedSame
                        || $0.id.split(separator: ".").last.map(String.init)?.caseInsensitiveCompare(want.replacingOccurrences(of: " ", with: "")) == .orderedSame
                }), seen.insert(row.id).inserted else { continue }
                let managed = !row.id.contains("\\") && row.id.contains(".")
                let name = wants.count == 1 ? def.name : want.hasPrefix(def.name) ? want : "\(def.name) (\(want))"
                items.append(Item(machine: machine, os: p.os, defID: def.id, name: name, brand: def.brand ?? def.name, isApp: true, path: row.id,
                                  installed: row.version,
                                  latest: managed ? LatestInfo(version: row.available.isEmpty ? row.version : row.available) : nil,
                                  method: managed ? .winget(row.id) : .none, variant: wants.count > 1 ? want : nil))
            }
        }
        for i in items.indices { items[i].arch = p.arch }
        return items
    }

    static func cliMethod(_ r: CLIRecord, def: CLIDef, os: OSKind, installed: String?) -> Method {
        if os == .mac, !r.bundledApp.isEmpty {
            let appName = ((r.bundledApp as NSString).lastPathComponent as NSString).deletingPathExtension
            return .bundledWithApp(appPath: r.bundledApp, appName: appName.isEmpty ? "the app" : appName)
        }
        let real = r.realPath.replacingOccurrences(of: "\\", with: "/")
        func component(after marker: String) -> String? {
            guard let range = real.range(of: marker) else { return nil }
            return real[range.upperBound...].split(separator: "/").first.map(String.init)
        }
        if real.contains("/.bun/") { return .bun(package: r.package.isEmpty ? (def.npm?.first ?? def.binaries[0]) : r.package) }
        if !r.package.isEmpty && !r.npmBin.isEmpty, let range = real.range(of: "/node_modules/") {
            var prefix = String(real[..<range.lowerBound])
            if prefix.hasSuffix("/lib") && os != .windows { prefix.removeLast(4) }
            if os == .windows { prefix = prefix.replacingOccurrences(of: "/", with: "\\") }
            return .npm(bin: r.npmBin, prefix: prefix, package: r.package, tag: "latest", writable: r.writable)
        }
        if let f = component(after: "/Cellar/") { return .brewFormula(f) }
        if let n = component(after: "/pipx/venvs/") { return .pipx(n) }
        if let n = component(after: "/uv/tools/") { return .uv(n) }
        if let args = def.selfUpdate { return .selfUpdate(path: r.path, args: args) }
        return .none
    }

    /// The npm or PyPI package whose published versions this tool can be switched to, if any.
    static func registryPackage(_ item: Item, catalog: Catalog) -> (npm: String?, pypi: String?) {
        let def = catalog.clis.first { $0.id == item.defID }
        switch item.method {
        case let .npm(_, _, pkg, _, _), let .bun(pkg): return (pkg, nil)
        case let .pipx(n), let .uv(n): return (nil, def?.pypi ?? n)
        case .selfUpdate where item.installVersion != nil: return (def?.latest?.npm ?? def?.npm?.first, nil)
        default: return (nil, nil)
        }
    }

    static func latest(for item: Item, probe: ProbeResult, catalog: Catalog, resolver: LatestResolver) async -> LatestInfo? {
        let arch = probe.arch
        if item.isApp {
            guard let def = catalog.apps.first(where: { $0.id == item.defID }),
                  let v = def.mac?.first(where: { item.path.hasSuffix("/\($0.app).app") }) else { return nil }
            return await resolver.resolve(v.latest, installed: item.installed, arch: arch)
        }
        let def = catalog.clis.first { $0.id == item.defID }
        switch item.method {
        case let .npm(_, _, pkg, _, _), let .bun(pkg): return await resolver.npm(pkg, installed: item.installed)
        case let .brewFormula(f): return await resolver.brewFormula(f)
        case let .pipx(n), let .uv(n): return await resolver.resolve(LatestSource(pypi: def?.pypi ?? n), installed: item.installed, arch: arch)
        default:
            guard let src = def?.latest else { return nil }
            return await resolver.resolve(src, installed: item.installed, arch: arch)
        }
    }

    /// Where the versions of a Mac app that Update pls replaced are kept, relative to $HOME on its machine:
    /// one folder per version, each holding the app.
    static func savedPath(_ item: Item) -> String {
        "Library/Application Support/Update pls/Backups/\(item.defID)"
    }

    /// Where a Mac app's download is unpacked and checked before it is installed, relative to $HOME.
    static func stagingPath(_ item: Item) -> String {
        "Library/Caches/Update pls/Staging/\(item.defID)-\((item.path as NSString).lastPathComponent)"
    }

    /// Written just before a Mac app is swapped and removed right after, relative to $HOME. If it is still
    /// there, the swap was cut off and the app may be missing (see `macRecoverScript`).
    static func swapMarkerPath(_ item: Item) -> String {
        "\(swapMarkersDir)/\(item.defID)-\((item.path as NSString).lastPathComponent)"
    }
    static let swapMarkersDir = "Library/Application Support/Update pls/Swapping"
    static let backupsDir = "Library/Application Support/Update pls/Backups"

    /// A human-readable changelog or releases page for this tool, when one can be derived from the catalog.
    static func releaseNotesURL(for item: Item, catalog: Catalog) -> URL? {
        if item.isApp {
            if let repo = LatestResolver.githubRepo(item, catalog: catalog) {
                return URL(string: "https://github.com/\(repo)/releases")
            }
            let variant = catalog.apps.first { $0.id == item.defID }?.mac?.first { item.path.hasSuffix("/\($0.app).app") }
            if let cask = variant?.latest.cask {
                return URL(string: "https://formulae.brew.sh/cask/\(cask)")
            }
            return nil
        }
        let def = catalog.clis.first { $0.id == item.defID }
        if let gh = def?.latest?.github { return URL(string: "https://github.com/\(gh)/releases") }
        let (npm, pypi) = registryPackage(item, catalog: catalog)
        if let pkg = npm ?? def?.latest?.npm { return URL(string: "https://www.npmjs.com/package/\(pkg)?activeTab=versions") }
        if let pkg = pypi ?? def?.latest?.pypi { return URL(string: "https://pypi.org/project/\(pkg)/#history") }
        return nil
    }

    /// True only for a real folder: never a symlink to one (so nothing outside the saved versions is ever
    /// counted or deleted through a link).
    static func isRealDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
    }

    /// The saved versions folder, only if every folder from `home` down to it is a real folder (none a symlink).
    static func backupsRoot(home: URL) -> URL? {
        var url = home
        for part in backupsDir.split(separator: "/") {
            url.appendPathComponent(String(part))
            guard isRealDirectory(url) else { return nil }
        }
        return url
    }

    /// Removes a folder only if it is empty (hidden files included): never recursive.
    private static func removeIfEmpty(_ url: URL) { _ = rmdir(url.path) }

    private static func children(_ url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey],
                                                       options: .skipsHiddenFiles)) ?? [])
    }

    /// Every saved app copy on this Mac: Backups/<tool>/<version>/<App>.app, plus copies from Update pls 0.3
    /// sitting at Backups/<tool>/<App>.app. Symlinks are skipped at every level.
    static func savedCopies(home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [(tool: URL, folder: URL?, app: URL, date: Date)] {
        guard let root = backupsRoot(home: home) else { return [] }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var out: [(URL, URL?, URL, Date)] = []
        for tool in children(root) where isRealDirectory(tool) {
            for entry in children(tool) where isRealDirectory(entry) {
                if entry.pathExtension == "app" {
                    out.append((tool, nil, entry, date(entry)))
                } else {
                    for app in children(entry) where app.pathExtension == "app" && isRealDirectory(app) {
                        out.append((tool, entry, app, date(entry)))
                    }
                }
            }
        }
        return out
    }

    /// Disk usage of local Mac rollback backups (bytes, total saved version count, app folder count).
    static func backupStats(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (bytes: Int64, versions: Int, apps: Int) {
        let copies = savedCopies(home: home)
        var totalBytes: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        for c in copies {
            // The enumerator doesn't follow symlinks inside the app.
            guard let e = FileManager.default.enumerator(at: c.app, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in e {
                let vals = try? url.resourceValues(forKeys: Set(keys))
                if vals?.isRegularFile == true { totalBytes += Int64(vals?.totalFileAllocatedSize ?? vals?.fileAllocatedSize ?? 0) }
            }
        }
        return (totalBytes, copies.count, Set(copies.map(\.tool)).count)
    }

    enum PruneRefusal: Error, Equatable { case updating }

    /// Prunes local rollback backups to the `keep` newest copies of each app (pass 0 to remove all). Variants of
    /// one app (T3 Code and T3 Code Nightly) share a folder but are counted apart, so one never costs the other its
    /// copies. Refused while an update is filing or relying on a saved version on this Mac.
    static func pruneBackups(keep: Int, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Result<Int, PruneRefusal> {
        // The lock first, then the markers: a swap can't start (or end half done) between the two.
        guard case let .success(lock) = ItemLock.take(ItemLock.backupsKey) else { return .failure(.updating) }
        defer { lock.release() }
        let markers = home.appendingPathComponent(swapMarkersDir)
        if FileManager.default.fileExists(atPath: markers.path) {
            // Can't tell whether a swap is waiting to be finished: touch nothing.
            guard let list = try? FileManager.default.contentsOfDirectory(atPath: markers.path), list.isEmpty else { return .failure(.updating) }
        }
        let fm = FileManager.default
        let lsreg = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        var removed = 0
        let byApp = Dictionary(grouping: savedCopies(home: home), by: { "\($0.tool.path)|\($0.app.lastPathComponent)" })
        for (_, list) in byApp {
            for old in list.sorted(by: { $0.date > $1.date }).dropFirst(max(keep, 0)) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: lsreg)
                p.arguments = ["-u", old.app.path]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                if (try? p.run()) != nil { p.waitUntilExit() }
                // Checked again just before: still a real folder, not swapped for a link meanwhile.
                guard isRealDirectory(old.app), old.folder.map(isRealDirectory) ?? true else { continue }
                if (try? fm.removeItem(at: old.app)) != nil { removed += 1 }
                if let folder = old.folder { removeIfEmpty(folder) }
            }
        }
        if let root = backupsRoot(home: home) {
            for tool in children(root) where isRealDirectory(tool) { removeIfEmpty(tool) }
        }
        return .success(removed)
    }

    /// The saved versions of one Mac app on this Mac, as `Item.saved` lists them.
    static func savedVersions(of item: Item, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let name = (item.path as NSString).lastPathComponent
        return savedCopies(home: home)
            .filter { $0.tool.lastPathComponent == item.defID && $0.app.lastPathComponent == name }
            .sorted { $0.date > $1.date }
            .compactMap { NSDictionary(contentsOf: $0.app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String }
    }
}
