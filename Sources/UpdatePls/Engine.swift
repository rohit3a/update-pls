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

enum ItemState: Hashable {
    case upToDate, available, unknown, updating, updated
    case failed(String)
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
    var log = ""
    /// From the catalog: how to install one exact version through the tool's own installer.
    var installVersion: String?

    var id: String { "\(machine.id)/\(defID)/\(path)" }
    /// Stable per machine and tool; used for the Update all skip list and rollback records.
    var key: String { "\(machine.id)/\(defID)" }

    /// The command that puts back version `v`, or nil when this install can't be rolled back that way.
    /// Mac apps downloaded directly roll back from the copy kept at update time instead (see `Engine.rollback`).
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

    /// Shell command shown to the user and run for the update (apps downloaded directly use `macInstallScript`).
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
        case let .cask(t): return "brew upgrade --cask \(Shell.q(t))"
        case .macDirect: return nil
        case let .winget(id):
            return "winget upgrade --id \(Shell.psq(id)) --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"
        case let .deb(p): return "sudo apt-get update && sudo apt-get install --only-upgrade -y \(p)"
        case .none: return nil
        }
    }

    /// Updates that need a password are shown as a command to copy instead of being run.
    var needsSudo: Bool { command?.hasPrefix("sudo ") == true }

    var canUpdate: Bool {
        guard state == .available || state == .unknown || isFailed else { return false }
        if needsSudo { return false }
        if case .macDirect = method { return latest?.url != nil }
        return command != nil
    }

    var isFailed: Bool { if case .failed = state { return true }; return false }
}

struct MachineStatus: Identifiable, Hashable {
    enum State: Hashable { case checking, online, offline(String) }
    var machine: Machine
    var os: OSKind?
    var state: State = .checking
    var id: String { machine.id }
}

enum Engine {
    static func check(_ m: Machine, catalog: Catalog, resolver: LatestResolver) async -> (MachineStatus, [Item]) {
        var status = MachineStatus(machine: m)
        let os: OSKind
        switch await Runner.detectOS(m) {
        case let .offline(msg): status.state = .offline(msg); return (status, [])
        case let .os(o): os = o
        }
        status.os = os
        let script = os == .windows ? Probe.windowsScript(catalog) : Probe.unixScript(catalog)
        let out = await Runner.run(m, os: os, script: script, timeout: 240)
        if out.status == 255 { status.state = .offline(out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)); return (status, []) }
        status.state = .online
        let probe = Probe.parse(out.stdout)
        var items = buildItems(probe, machine: m, catalog: catalog)
        await withTaskGroup(of: (Int, LatestInfo?).self) { group in
            for (i, item) in items.enumerated() where item.latest == nil {
                group.addTask { (i, await latest(for: item, probe: probe, catalog: catalog, resolver: resolver)) }
            }
            for await (i, info) in group { items[i].latest = info }
        }
        for i in items.indices { items[i].state = state(items[i]) }
        return (status, items)
    }

    static func state(_ item: Item) -> ItemState {
        guard let latest = item.latest?.version, let installed = item.installed else { return .unknown }
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
        for r in p.apps {
            guard let def = catalog.apps.first(where: { $0.id == r.id }),
                  let variant = def.mac?.first(where: { $0.app == r.appName }) else { continue }
            let method: Method = if let t = variant.latest.cask, p.hasBrew, p.casks.contains(t) { .cask(t) }
                                 else { .macDirect(appPath: r.path, bundleID: r.bundleID) }
            let name = def.mac!.count == 1 ? def.name : r.appName.hasPrefix(def.name) ? r.appName : "\(def.name) (\(r.appName))"
            items.append(Item(machine: machine, os: p.os, defID: def.id, name: name, brand: def.brand ?? def.name, isApp: true, path: r.path,
                              installed: r.version, method: method, running: r.running))
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

    /// Runs the update for one item. Desktop apps are quit first and reopened if `relaunch`.
    static func update(_ item: Item, relaunch: Bool) async -> ShellResult {
        var script: String
        var item = item
        if case let .npm(bin, prefix, pkg, _, w) = item.method {
            // Install the exact version we found, so nightly users stay on nightly.
            item.method = .npm(bin: bin, prefix: prefix, package: pkg, tag: item.latest?.version ?? "latest", writable: w)
        }
        if item.os == .windows {
            guard let cmd = item.command else { return ShellResult(status: 1, stdout: "", stderr: "No update method") }
            script = Probe.windowsPrelude + cmd + "\nexit $LASTEXITCODE\n"
        } else {
            script = Probe.unixPrelude + "set -e\n"
            switch item.method {
            case let .macDirect(appPath, bundleID):
                guard let info = item.latest, let url = info.url else {
                    return ShellResult(status: 1, stdout: "", stderr: "No download available")
                }
                script += macInstallScript(app: appPath, bundleID: bundleID, url: url, info: info, backup: backupPath(item), relaunch: relaunch)
            case let .cask(token):
                if item.running { script += quitScript(bundleIDOf: item.path) }
                script += "brew upgrade --cask \(Shell.q(token))\n"
                if item.running && relaunch { script += "open \(Shell.q(item.path))\n" }
            default:
                guard let cmd = item.command else { return ShellResult(status: 1, stdout: "", stderr: "No update method") }
                script += cmd + "\n"
            }
        }
        return await Runner.run(item.machine, os: item.os, script: script, timeout: 900)
    }

    /// Puts back the version Update pls replaced. Mac apps come back from the copy kept at update time,
    /// after checking it is the same app with a valid signature; other tools reinstall that exact version.
    static func rollback(_ item: Item, to version: String, relaunch: Bool) async -> ShellResult {
        var script = Probe.unixPrelude + "set -e\n"
        if case let .macDirect(appPath, bundleID) = item.method {
            script += macRollbackScript(app: appPath, bundleID: bundleID, backup: backupPath(item), relaunch: relaunch)
        } else if let cmd = item.rollbackCommand(to: version) {
            script += cmd + "\n"
        } else {
            return ShellResult(status: 1, stdout: "", stderr: "This install can't be rolled back")
        }
        return await Runner.run(item.machine, os: item.os, script: script, timeout: 900)
    }

    /// Where a Mac app's previous version is kept, relative to $HOME on its machine. One per app.
    static func backupPath(_ item: Item) -> String {
        "Library/Application Support/Update pls/Backups/\(item.defID)/\((item.path as NSString).lastPathComponent)"
    }

    /// Quits the app at $APP (bundle id $BID) if it is running and sets WAS_RUNNING.
    static let quitIfRunning = """
    WAS_RUNNING=0
    ps -axo command= | grep -F "$APP/Contents/MacOS/" | grep -v grep >/dev/null && WAS_RUNNING=1
    if [ $WAS_RUNNING = 1 ]; then
      osascript -e "tell application id \\"$BID\\" to quit" >/dev/null 2>&1 || true
      for i in $(seq 1 60); do ps -axo command= | grep -F "$APP/Contents/MacOS/" | grep -v grep >/dev/null || break; sleep 0.5; done
      if ps -axo command= | grep -F "$APP/Contents/MacOS/" | grep -v grep >/dev/null; then echo 'The app did not quit. Close it and try again.' >&2; exit 1; fi
    fi

    """

    static func macRollbackScript(app: String, bundleID: String, backup: String, relaunch: Bool) -> String {
        """
        APP=\(Shell.q(app)); BID=\(Shell.q(bundleID)); BK="$HOME/"\(Shell.q(backup))
        [ -d "$BK" ] || { echo 'No saved previous version on this machine' >&2; exit 1; }
        [ "$(defaults read "$BK/Contents/Info" CFBundleIdentifier)" = "$BID" ] || { echo 'Saved version has a different bundle id' >&2; exit 1; }
        codesign --verify --deep --strict "$BK"
        \(quitIfRunning)
        T=$(mktemp -d /tmp/update-pls.XXXXXX)
        mv "$APP" "$T/current.app"
        if ! mv "$BK" "$APP"; then rm -rf "$APP"; mv "$T/current.app" "$APP"; echo 'Rollback failed, current version kept' >&2; exit 1; fi
        rm -rf "$T"
        echo "Rolled back to $(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
        \(relaunch ? "[ $WAS_RUNNING = 1 ] && open \"$APP\"" : ":")
        exit 0

        """
    }

    static func quitScript(bundleIDOf appPath: String) -> String {
        """
        up_bid=$(defaults read \(Shell.q(appPath + "/Contents/Info")) CFBundleIdentifier)
        osascript -e "tell application id \\"$up_bid\\" to quit" >/dev/null 2>&1 || true
        for i in $(seq 1 60); do ps -axo command= | grep -F \(Shell.q(appPath + "/Contents/MacOS/")) | grep -v grep >/dev/null || break; sleep 0.5; done
        if ps -axo command= | grep -F \(Shell.q(appPath + "/Contents/MacOS/")) | grep -v grep >/dev/null; then echo "The app did not quit. Close it and try again." >&2; exit 1; fi

        """
    }

    /// Downloads the publisher's build, checks its hash, signature, notarization and team,
    /// then swaps it in place of the installed app.
    static func macInstallScript(app: String, bundleID: String, url: String, info: LatestInfo, backup: String, relaunch: Bool) -> String {
        var verify = ""
        if let h = info.sha256 { verify = "[ \"$(shasum -a 256 \"$T/dl\" | cut -d' ' -f1)\" = \(Shell.q(h)) ] || { echo 'Checksum mismatch' >&2; exit 1; }" }
        else if let h = info.sha512Base64 { verify = "[ \"$(openssl dgst -sha512 -binary \"$T/dl\" | base64)\" = \(Shell.q(h)) ] || { echo 'Checksum mismatch' >&2; exit 1; }" }
        return """
        APP=\(Shell.q(app)); BID=\(Shell.q(bundleID)); URL=\(Shell.q(url)); BK="$HOME/"\(Shell.q(backup))
        T=$(mktemp -d /tmp/update-pls.XXXXXX)
        cleanup() { [ -d "$T/mnt" ] && hdiutil detach "$T/mnt" -quiet >/dev/null 2>&1; rm -rf "$T"; }
        trap cleanup EXIT
        echo "Downloading $URL"
        curl -fsSL --retry 2 -o "$T/dl" "$URL"
        \(verify)
        mkdir -p "$T/x"
        if [ "$(head -c 2 "$T/dl")" = "PK" ]; then
          ditto -x -k "$T/dl" "$T/x"
        else
          mkdir -p "$T/mnt"
          hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$T/mnt" "$T/dl" -quiet
          for a in "$T/mnt"/*.app; do ditto "$a" "$T/x/$(basename "$a")"; done
          hdiutil detach "$T/mnt" -quiet; rmdir "$T/mnt"
        fi
        NEW=$(find "$T/x" -maxdepth 2 -name '*.app' -type d | head -1)
        [ -n "$NEW" ] || { echo 'No app found in download' >&2; exit 1; }
        [ "$(defaults read "$NEW/Contents/Info" CFBundleIdentifier)" = "$BID" ] || { echo 'Downloaded app has a different bundle id' >&2; exit 1; }
        codesign --verify --deep --strict "$NEW"
        spctl --assess --type execute "$NEW"
        team() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
        OLD_TEAM=$(team "$APP"); NEW_TEAM=$(team "$NEW")
        [ -n "$NEW_TEAM" ] && [ "$NEW_TEAM" != "not set" ] && [ "$NEW_TEAM" = "$OLD_TEAM" ] || { echo "Signing team changed ($OLD_TEAM -> $NEW_TEAM)" >&2; exit 1; }
        \(quitIfRunning)
        # Keep the replaced version for rollback (one per app).
        rm -rf "$BK"; mkdir -p "$(dirname "$BK")"
        mv "$APP" "$BK"
        if ! ditto "$NEW" "$APP"; then rm -rf "$APP"; mv "$BK" "$APP"; echo 'Install failed, previous version restored' >&2; exit 1; fi
        echo "Installed $(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
        \(relaunch ? "[ $WAS_RUNNING = 1 ] && open \"$APP\"" : ":")
        exit 0

        """
    }
}
