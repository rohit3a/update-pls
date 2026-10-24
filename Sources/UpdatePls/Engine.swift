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
    case deb(String)
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
    /// Set when two variants of one app (T3 Code and T3 Code Nightly) are installed side by side.
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
        case let .deb(p): return "sudo apt-get update && sudo apt-get install --only-upgrade -y \(Shell.q(p))"
        case .none: return nil
        }
    }

    /// Updates that need a password are shown as a command to copy instead of being run.
    var needsSudo: Bool { command?.hasPrefix("sudo ") == true }

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

enum Engine {
    /// Finds what is installed on a machine and the newest version of each.
    /// `known` reuses latest versions already looked up (by item key), so a re-check after an update stays quick.
    static func check(_ m: Machine, catalog: Catalog, resolver: LatestResolver, known: [String: LatestInfo] = [:]) async -> (MachineStatus, [Item]) {
        let start = Date()
        var status = MachineStatus(machine: m)
        let os: OSKind
        switch await Runner.detectOS(m) {
        case let .offline(msg):
            status.state = .offline(msg)
            Log.error("check \(m.id): offline: \(msg)")
            return (status, [])
        case let .os(o): os = o
        }
        status.os = os
        let script = os == .windows ? Probe.windowsScript(catalog) : Probe.unixScript(catalog)
        let out = await Runner.run(m, os: os, script: script, timeout: 240)
        if out.status == 255 || (out.timedOut && out.stdout.isEmpty) {
            let msg = out.timedOut ? "Timed out" : out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            status.state = .offline(msg)
            Log.error("check \(m.id): scan failed: \(msg)")
            return (status, [])
        }
        if !out.ok {
            Log.error("check \(m.id): scan exited \(out.status)\(out.timedOut ? " (timed out, results may be partial)" : "")\n"
                      + out.stderr.split(separator: "\n").suffix(15).joined(separator: "\n"))
        }
        status.state = .online
        let probe = Probe.parse(out.stdout)
        var items = buildItems(probe, machine: m, catalog: catalog)
        await withTaskGroup(of: (Int, LatestInfo?).self) { group in
            for (i, item) in items.enumerated() where item.latest == nil {
                if let k = known[item.key] { items[i].latest = k; continue }
                group.addTask { (i, await latest(for: item, probe: probe, catalog: catalog, resolver: resolver)) }
            }
            for await (i, info) in group { items[i].latest = info }
        }
        for i in items.indices { items[i].state = state(items[i]) }
        Log.info("check \(m.id) [\(os.rawValue)]: \(items.count) tools in \(String(format: "%.1f", Date().timeIntervalSince(start)))s\n"
                 + items.map { "\($0.key) \($0.summary) \($0.state)\($0.running ? " open" : "")" }.joined(separator: "\n"))
        return (status, items)
    }

    static func state(_ item: Item) -> ItemState {
        guard let latest = item.latest?.version, let installed = item.installed,
              !Version.clean(latest).isEmpty, !Version.clean(installed).isEmpty else { return .unknown }
        return Version.isNewer(latest, than: installed) ? .available : .upToDate
    }

    static func buildItems(_ p: ProbeResult, machine: Machine, catalog: Catalog) -> [Item] {
        var items: [Item] = []
        for r in p.clis {
            guard let def = catalog.clis.first(where: { $0.id == r.id }) else { continue }
            let installed = r.packageVersion.isEmpty ? Version.extract(r.versionOutput) : r.packageVersion
            items.append(Item(machine: machine, os: p.os, defID: def.id, name: def.name, brand: def.brand ?? def.name, isApp: false, path: r.path,
                              installed: installed, method: cliMethod(r, def: def, os: p.os, installed: installed), installVersion: def.installVersion))
        }
        let appCounts = Dictionary(grouping: p.apps, by: \.id).mapValues(\.count)
        for r in p.apps {
            guard let def = catalog.apps.first(where: { $0.id == r.id }),
                  let variant = def.mac?.first(where: { $0.app == r.appName }) else { continue }
            let method: Method = if let t = variant.latest.cask, p.hasBrew, p.casks.contains(t) { .cask(t) }
                                 else { .macDirect(appPath: r.path, bundleID: r.bundleID) }
            let name = def.mac!.count == 1 ? def.name : r.appName.hasPrefix(def.name) ? r.appName : "\(def.name) (\(r.appName))"
            let saved = Set(p.saved.filter { $0.id == r.id && $0.appName == r.appName }.map(\.version))
            items.append(Item(machine: machine, os: p.os, defID: def.id, name: name, brand: def.brand ?? def.name, isApp: true, path: r.path,
                              installed: r.version, method: method, running: r.running,
                              variant: (appCounts[r.id] ?? 0) > 1 ? r.appName : nil,
                              saved: saved.sorted { Version.isNewer($0, than: $1) }))
        }
        for r in p.debs {
            guard let def = catalog.apps.first(where: { $0.id == r.id }) else { continue }
            let candidate = r.candidate.isEmpty || r.candidate == "(none)" ? r.installed : r.candidate
            items.append(Item(machine: machine, os: p.os, defID: def.id, name: def.name, brand: def.brand ?? def.name, isApp: true, path: r.package,
                              installed: r.installed, latest: LatestInfo(version: candidate), method: .deb(r.package)))
        }
        for def in catalog.apps {
            for want in def.windows ?? [] {
                guard let row = p.winget.first(where: {
                    $0.name.caseInsensitiveCompare(want) == .orderedSame
                        || $0.id.split(separator: ".").last.map(String.init)?.caseInsensitiveCompare(want.replacingOccurrences(of: " ", with: "")) == .orderedSame
                }) else { continue }
                let managed = !row.id.contains("\\") && row.id.contains(".")
                items.append(Item(machine: machine, os: p.os, defID: def.id, name: def.name, brand: def.brand ?? def.name, isApp: true, path: row.id,
                                  installed: row.version,
                                  latest: managed ? LatestInfo(version: row.available.isEmpty ? row.version : row.available) : nil,
                                  method: managed ? .winget(row.id) : .none))
                break
            }
        }
        for i in items.indices { items[i].arch = p.arch }
        return items
    }

    static func cliMethod(_ r: CLIRecord, def: CLIDef, os: OSKind, installed: String?) -> Method {
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
}
