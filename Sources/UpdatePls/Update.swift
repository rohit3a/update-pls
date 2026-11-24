import AppKit
import Foundation

/// What an update or rollback did.
struct UpdateOutcome {
    var ok: Bool
    /// "Updated to 3.27.12", "Already on 3.27.12", or why it failed.
    var message: String
    var output = ""
    /// The version that was replaced and kept for rollback.
    var previous: String?
    /// The version reported right after installing, when the update could tell.
    var installed: String?
    /// False when nothing had to be replaced.
    var changed = true
    var timedOut = false
    var cancelled = false
    /// Something to add to whatever the result finally says (an app that couldn't be reopened).
    var note: String?

    static func fail(_ message: String, output: String = "") -> UpdateOutcome { UpdateOutcome(ok: false, message: message, output: output) }
    static func cancelledOutcome(output: String = "") -> UpdateOutcome {
        UpdateOutcome(ok: false, message: "Cancelled", output: output, changed: false, cancelled: true)
    }
}

/// Serializes the brief quit + atomic-swap + reopen critical section per machine so multiple Mac apps can
/// download, unpack, checksum and verify signatures in parallel without stepping on each other during swap.
/// Waiters are served first come, first served, and ownership passes straight to the next one, so a newcomer
/// can't slip in between. A waiter whose task is cancelled leaves the line at once instead of holding its lane.
actor SwapGate {
    static let shared = SwapGate()
    private var busy: Set<String> = []
    private var waiters: [String: [(id: UUID, cont: CheckedContinuation<Bool, Never>)]] = [:]

    func isBusy(_ machineID: String) -> Bool { busy.contains(machineID) }

    /// True once the caller owns the gate; false if its task was cancelled first (it then owns nothing).
    func acquire(machineID: String) async -> Bool {
        if Task.isCancelled { return false }
        if !busy.contains(machineID) { busy.insert(machineID); return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled { cont.resume(returning: false); return }
                waiters[machineID, default: []].append((id, cont))
            }
        } onCancel: {
            Task { await self.leave(machineID, id) }
        }
    }

    private func leave(_ machineID: String, _ id: UUID) {
        guard var list = waiters[machineID], let i = list.firstIndex(where: { $0.id == id }) else { return }
        let w = list.remove(at: i)
        waiters[machineID] = list.isEmpty ? nil : list
        w.cont.resume(returning: false)
    }

    func release(machineID: String) {
        if var list = waiters[machineID], !list.isEmpty {
            let next = list.removeFirst()
            waiters[machineID] = list.isEmpty ? nil : list
            next.cont.resume(returning: true) // stays busy: it now belongs to `next`
        } else {
            busy.remove(machineID)
        }
    }
}

/// Writes one update's output to its run file as it arrives and turns it into progress for the menu:
/// the script's `==> step` lines, curl's download percentage, and (for CLIs) the latest output line.
final class Reporter: @unchecked Sendable {
    let runFile: URL?
    /// CLIs show their latest output line as progress; app updates show only their steps.
    var showLines = false
    private let onPhase: @Sendable (String, Double?) -> Void
    private let lock = NSLock()
    private var step = ""
    private var fraction = -1.0
    private var lastLine = Date.distantPast
    private var partial = ""
    private var committed = false
    private var cancelRequested = false

    init(runFile: URL? = nil, onPhase: @escaping @Sendable (String, Double?) -> Void = { _, _ in }) {
        self.runFile = runFile
        self.onPhase = onPhase
    }

    /// The point of no return: an app is about to be quit or replaced, so from here on the job always runs to
    /// the end (including putting things back and reopening the app). False if a cancel came in first: the
    /// caller must then stop without changing anything.
    func commit() -> Bool {
        lock.withLock {
            if cancelRequested { return false }
            committed = true
            return true
        }
    }

    /// Asks to cancel. False once the job has committed, and then it must not be cancelled.
    func requestCancel() -> Bool {
        lock.withLock {
            if committed { return false }
            cancelRequested = true
            return true
        }
    }

    var isCommitted: Bool { lock.withLock { committed } }

    /// A step started by Update pls itself (quitting, reopening, ...).
    func phase(_ text: String) {
        if let runFile { Log.appendRun(runFile, "==> \(text)\n") }
        setStep(text)
    }

    /// `output` as a handler for `Shell.run`.
    var sink: @Sendable (String) -> Void { { [self] in self.output($0) } }

    func output(_ chunk: String) {
        if let runFile { Log.appendRun(runFile, chunk) }
        // Only finished lines (ended by \n, or \r for progress bars); a chunk can end mid-line ("31." then "4%").
        lock.lock()
        var text = partial + chunk
        if let end = text.lastIndex(where: { $0 == "\n" || $0 == "\r" }) {
            partial = String(text[text.index(after: end)...])
            text = String(text[...end])
        } else {
            partial = text
            text = ""
        }
        lock.unlock()
        for piece in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = piece.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("==> ") { setStep(String(line.dropFirst(4))); continue }
            if let pct = Self.percent(line) {
                lock.lock()
                let send = step.hasPrefix("Downloading") && pct > fraction && Int(pct * 100) != Int(fraction * 100)
                if send { fraction = pct }
                let s = step
                lock.unlock()
                if send { onPhase(s, pct) }
                continue
            }
            guard showLines, !line.isEmpty, !line.hasPrefix("UPFAIL"), !Engine.isProgressBar(line) else { continue }
            lock.lock()
            let send = Date().timeIntervalSince(lastLine) > 0.25
            if send { lastLine = Date() }
            lock.unlock()
            if send { onPhase(String(line.prefix(90)), nil) }
        }
    }

    private func setStep(_ text: String) {
        lock.lock(); step = text; fraction = -1; lock.unlock()
        onPhase(text, nil)
    }

    /// "######    31.4%" -> 0.314
    static func percent(_ line: String) -> Double? {
        guard let r = line.range(of: #"(\d{1,3}(\.\d+)?)%$"#, options: .regularExpression),
              let v = Double(line[r].dropLast()), v <= 100 else { return nil }
        let rest = line[..<r.lowerBound]
        guard rest.allSatisfy({ "#=O- ".contains($0) }) else { return nil }
        return v / 100
    }
}

/// Apps on this Mac: found, quit and checked through AppKit, which needs no Automation permission.
enum LocalApps {
    static func instances(_ path: String) -> [NSRunningApplication] {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.resolvingSymlinksInPath().path == target }
    }

    /// Asks the app to quit like ⌘Q and waits. If it is still open after a few seconds it is most likely
    /// showing a "Quit?" dialog, so it is brought to the front. Nil when AppKit can't see the app.
    static func quit(_ path: String, name: String, _ r: Reporter, timeout: TimeInterval = 90) async -> Bool? {
        let apps = instances(path)
        guard !apps.isEmpty else { return nil }
        r.phase("Quitting \(name)")
        Log.info("quit \(name): asking pid \(apps.map { String($0.processIdentifier) }.joined(separator: ",")) to quit")
        for a in apps { a.terminate() }
        let start = Date()
        var nudged = false
        while Date().timeIntervalSince(start) < timeout {
            if apps.allSatisfy({ kill($0.processIdentifier, 0) != 0 }) {
                Log.info("quit \(name): closed after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
                return true
            }
            if !nudged && Date().timeIntervalSince(start) > 15 {
                nudged = true
                r.phase("Waiting for \(name) to quit. It may be asking you something.")
                apps.first?.activate()
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        Log.error("quit \(name): still open after \(Int(timeout))s")
        return false
    }
}

/// What a finished update or switch leaves behind, shared by the menu and the command line: the version it
/// replaced (for rollback), and a hold on Update all while a tool is on an older version than the latest.
/// Getting back to the latest lifts that hold, but never a skip you set yourself.
enum History {
    private static let d = UserDefaults.standard
    static var previous: [String: String] { d.dictionary(forKey: "previousVersions") as? [String: String] ?? [:] }
    static var excluded: Set<String> { Set(d.stringArray(forKey: "excludedFromUpdateAll") ?? []) }
    private static var held: Set<String> { Set(d.stringArray(forKey: "heldBackByRollback") ?? []) }

    enum Hold { case added, lifted }

    /// `version` is the one switched to; nil for an update to the latest.
    @discardableResult
    static func record(_ item: Item, switchedTo version: String? = nil, _ o: UpdateOutcome) -> Hold? {
        guard o.ok else { return nil }
        let key = item.key
        if o.changed, item.supportsRollback, let p = o.previous {
            var prev = previous
            prev[key] = p
            d.set(prev, forKey: "previousVersions")
        }
        var skip = excluded, hold = held
        defer {
            d.set(Array(skip), forKey: "excludedFromUpdateAll")
            d.set(Array(hold), forKey: "heldBackByRollback")
        }
        if let v = version, item.latest.map({ Version.isNewer($0.version, than: v) }) ?? true {
            // Update all would otherwise take it straight back to the latest (with the latest unknown, stay put too).
            guard !skip.contains(key) else { return nil }
            skip.insert(key)
            hold.insert(key)
            return .added
        }
        guard hold.remove(key) != nil else { return nil }
        skip.remove(key)
        return .lifted
    }

    /// Apps that come in several variants are keyed by variant even when only one is installed (earlier builds
    /// only did once two were). Moves what was saved under the old key; true if anything moved.
    @discardableResult
    static func migrateVariantKeys(_ items: [Item]) -> Bool {
        let renames = Dictionary(grouping: items.filter { $0.variant != nil }, by: { "\($0.machine.id)/\($0.defID)" })
            .compactMapValues { $0.count == 1 ? $0[0].key : nil }
        var moved = false
        for k in ["excludedFromUpdateAll", "hiddenTools", "heldBackByRollback"] {
            guard let list = d.stringArray(forKey: k), list.contains(where: { renames[$0] != nil }) else { continue }
            d.set(Array(Set(list.map { renames[$0] ?? $0 })), forKey: k)
            moved = true
        }
        var prev = previous
        for (old, new) in renames {
            if let v = prev.removeValue(forKey: old) { prev[new] = prev[new] ?? v; moved = true }
        }
        if moved { d.set(prev, forKey: "previousVersions") }
        return moved
    }

    /// Skipping or un-skipping a tool by hand makes it your choice, not a rollback's.
    static func clearHold(_ key: String) {
        d.set(Array(held.subtracting([key])), forKey: "heldBackByRollback")
    }
}

/// One update per tool at a time across every Update pls on this Mac (the menu and the command line).
/// It is the kernel's file lock, so it goes away by itself if the process dies.
final class ItemLock {
    static var dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Update pls/Locks")
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    enum Refusal: Error { case busy, failed(String) }

    /// Fails while another update holds it, and if the lock file can't be made: nothing runs unlocked.
    static func take(_ key: String) -> Result<ItemLock, Refusal> {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = key.map { $0.isLetter || $0.isNumber || "-._".contains($0) ? String($0) : "_" }.joined()
        let fd = open(dir.appendingPathComponent(name + ".lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            let why = String(cString: strerror(errno))
            Log.error("lock \(key): \(why)")
            return .failure(.failed(why))
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return .failure(.busy) }
        return .success(ItemLock(fd: fd))
    }

    /// Like `take`, but waits up to `seconds` for whoever holds it.
    static func take(_ key: String, waitingUpTo seconds: TimeInterval) async -> Result<ItemLock, Refusal> {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let r = take(key)
            if case .failure(.busy) = r, Date() < deadline {
                // A cancelled task's sleep returns at once; never spin on it.
                if Task.isCancelled { usleep(100_000) } else { try? await Task.sleep(for: .milliseconds(100)) }
                continue
            }
            return r
        }
    }

    /// Held while anything adds to or removes from this Mac's saved versions (a swap filing the old version,
    /// or Settings cleaning them up), so a cleanup can never delete the copy a swap is about to rely on.
    static let backupsKey = "_backups"

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN); close(fd); fd = -1
    }

    deinit { release() }
}

/// Keeps the Mac from idle-sleeping while updates run (closing the lid still sleeps it).
enum KeepAwake {
    static func begin(_ reason: String) -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
    }
    static func end(_ activity: NSObjectProtocol?) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
}

extension Engine {
    /// Where another version of a tool comes from.
    enum VersionSource: Hashable {
        /// A copy Update pls saved when it replaced the app (Mac apps).
        case saved
        /// Downloaded from the publisher: the package registry for CLIs, the release feed for Mac apps.
        case published
    }

    // MARK: Running an update

    /// Runs the update for one item. Desktop apps that are open are quit first and reopened if `relaunch`.
    static func update(_ item: Item, relaunch: Bool, reporter r: Reporter, dryRun: Bool = false) async -> UpdateOutcome {
        let lock: ItemLock
        switch ItemLock.take(item.key) { case let .success(l): lock = l; case let .failure(e): return refused(item, e) }
        defer { lock.release() }
        let start = Date()
        Log.info("update \(item.key): \(item.summary)\(dryRun ? " (dry run)" : "")\(r.runFile.map { "\nrun log: \($0.path)" } ?? "")")
        var outcome: UpdateOutcome
        switch item.method {
        case .macDirect:
            let saved = item.machine.isLocal ? Engine.savedVersions(of: item) : item.saved
            if !dryRun, let info = item.latest, let copy = saved.first(where: { Version.clean($0) == Version.clean(info.version) }) {
                // Back to the latest after a rollback: that version is saved here already (its signature is checked again).
                outcome = await installMacApp(item, version: copy, from: .saved, exact: false, relaunch: relaunch, r)
            } else if let info = item.latest, info.url != nil {
                outcome = await installMacApp(item, version: info.version, from: .download(info), exact: false, relaunch: relaunch, r, dryRun: dryRun)
            } else {
                outcome = .fail("No download is published for this app")
            }
        // Only a direct download can be fetched and checked without installing it.
        case _ where dryRun:
            outcome = UpdateOutcome(ok: true, message: "Would run: \(item.command ?? "nothing") (dry run, nothing installed)", changed: false)
        case .cask where item.os == .mac: outcome = await updateCask(item, relaunch: relaunch, r)
        default: outcome = await runCommand(item, r, relaunch: relaunch)
        }
        finish(item, "update", &outcome, start)
        return outcome
    }

    private static func refused(_ item: Item, _ why: ItemLock.Refusal) -> UpdateOutcome {
        switch why {
        case .busy:
            Log.error("\(item.key): another Update pls is updating it")
            return .fail("Another Update pls is updating \(item.name) right now")
        case let .failed(e):
            return .fail("Couldn't lock \(item.name) for updating: \(e)")
        }
    }

    /// Installs one exact version: an older one to roll back, or a newer saved one to go forward again.
    /// Mac apps come from a saved copy (checked: same bundle id, valid signature) or the publisher's release;
    /// other tools reinstall that version with their package manager.
    static func install(_ item: Item, version: String, from source: VersionSource, relaunch: Bool, reporter r: Reporter) async -> UpdateOutcome {
        let lock: ItemLock
        switch ItemLock.take(item.key) { case let .success(l): lock = l; case let .failure(e): return refused(item, e) }
        defer { lock.release() }
        let start = Date()
        Log.info("install \(item.key): \(item.installed ?? "?") -> \(version) (\(source == .saved ? "saved copy" : "published"))")
        var outcome: UpdateOutcome
        if case .macDirect = item.method {
            if source == .saved {
                outcome = await installMacApp(item, version: version, from: .saved, exact: true, relaunch: relaunch, r)
            } else {
                r.phase("Finding \(item.name) \(version)")
                if let info = await LatestResolver().release(of: item, version: version) {
                    outcome = await installMacApp(item, version: version, from: .download(info), exact: true, relaunch: relaunch, r)
                } else {
                    outcome = .fail("\(version) isn't available for download")
                }
            }
        } else if let cmd = item.rollbackCommand(to: version) {
            r.showLines = true
            r.phase("Installing \(version)")
            if let f = r.runFile { Log.appendRun(f, "$ \(cmd)\n") }
            let prelude = Probe.unixPrelude(cachedPath: Engine.cachedPath(for: item.machine))
            let res = await Runner.run(item.machine, os: item.os, script: prelude + "set -e\n" + cmd + "\n", timeout: 900, onOutput: r.sink)
            if res.cancelled {
                outcome = .cancelledOutcome(output: res.combined)
            } else {
                outcome = res.ok ? UpdateOutcome(ok: true, message: "Installed \(version)", output: res.combined, previous: item.installed)
                                 : .fail(failure(res), output: res.combined)
                outcome.timedOut = res.timedOut
            }
        } else {
            outcome = .fail("This install can't switch versions")
        }
        finish(item, "install \(version)", &outcome, start)
        return outcome
    }

    private static func finish(_ item: Item, _ what: String, _ o: inout UpdateOutcome, _ start: Date) {
        let secs = String(format: "%.1f", Date().timeIntervalSince(start))
        if o.ok {
            Log.info("\(what) \(item.key): OK in \(secs)s: \(o.message)\(o.previous.map { " (kept \($0) for rollback)" } ?? "")")
        } else {
            Log.error("\(what) \(item.key): FAILED in \(secs)s: \(o.message)\n" + o.output.split(separator: "\n").suffix(30).joined(separator: "\n"))
        }
    }

    /// Checks a finished job against a fresh scan of its machine, for the menu and the command line.
    /// `version` is the one switched to (nil for an update); `fresh` is the tool as scanned again, nil if it
    /// couldn't be read (then the job's own result stands).
    static func confirm(_ item: Item, switchedTo version: String?, _ o: UpdateOutcome, fresh: Item?, offline: Bool) -> (ok: Bool, message: String) {
        let r = confirmed(item, switchedTo: version, o, fresh: fresh, offline: offline)
        guard let note = o.note, !r.message.contains(note) else { return r }
        return (r.ok, r.message + " (\(note))")
    }

    private static func confirmed(_ item: Item, switchedTo version: String?, _ o: UpdateOutcome, fresh: Item?, offline: Bool) -> (ok: Bool, message: String) {
        guard o.ok else { return (false, o.message) }
        if offline { return (true, o.message + " (machine went offline before it could be re-checked)") }
        guard let fresh, let now = fresh.installed, !now.isEmpty else {
            // Nothing to compare with before either, or nothing was meant to change: the job's own result stands.
            if !o.changed || (version == nil && (item.installed ?? "").isEmpty) { return (true, o.message) }
            // It said it worked, but the tool can't be found or read any more (a removed command, a broken install).
            return (false, "\(o.message == "Updated" ? "It updated" : o.message), but \(item.name)'s version can't be read now. Check it, then press Retry.")
        }
        if let v = version {
            let verb = Version.isNewer(item.installed ?? "", than: v) ? "Rolled back to" : "Switched to"
            return Version.clean(now) == Version.clean(v) ? (true, "\(verb) \(v)") : (false, "Still on \(now) after switching to \(v). \(o.message)")
        }
        if !o.changed { return (true, o.message) }
        if now == item.installed {
            return fresh.state == .available ? (false, "Still on \(now) after updating. \(o.message)") : (true, o.message)
        }
        let message = o.message == "Updated" ? "Updated to \(now)" : o.message
        // A tool's own updater can stop short of the latest (another channel, a staged rollout).
        if fresh.state == .available, let latest = fresh.latest?.version { return (true, "\(message), not \(latest)") }
        return (true, message)
    }

    /// CLIs and everything that has a single command: npm, brew, pipx, uv, bun, built-in updaters, winget.
    static func runCommand(_ item: Item, _ r: Reporter, relaunch: Bool = true) async -> UpdateOutcome {
        var item = item
        if case let .npm(bin, prefix, pkg, _, w) = item.method {
            // Install the exact version we found, so nightly users stay on nightly.
            item.method = .npm(bin: bin, prefix: prefix, package: pkg, tag: item.latest?.version ?? "latest", writable: w)
        }
        var command = item.command
        if case .bun = item.method, let v = item.latest?.version { command = item.rollbackCommand(to: v) ?? command }
        guard let cmd = command else { return .fail("No way to update this automatically") }
        guard !item.needsSudo else { return .fail("Needs your password; copy the sudo command instead") }
        r.showLines = true
        r.phase("Updating with \(item.method.label)")
        if let f = r.runFile { Log.appendRun(f, "$ \(cmd)\n") }
        // Over SSH a cancel can't reach the installer itself, so a running job there goes on to the end.
        if !item.machine.isLocal { guard r.commit() else { return .cancelledOutcome() } }
        let res = await Runner.run(item.machine, os: item.os, script: commandScript(item, brewRefresh(item) + cmd, relaunch: relaunch,
                                                                                    cachedPath: Engine.cachedPath(for: item.machine)),
                                   timeout: 900, onOutput: r.sink)
        if res.stdout.contains("BREW_REFRESHED\t") { noteBrewRefreshed(item) }
        guard res.ok else {
            if res.cancelled { return .cancelledOutcome(output: res.combined) }
            var o = UpdateOutcome.fail(failure(res), output: res.combined)
            o.timedOut = res.timedOut
            return o
        }
        return UpdateOutcome(ok: true, message: "Updated", output: res.combined,
                             previous: item.supportsRollback ? item.installed : nil)
    }

    private static let brewLock = NSLock()
    private static var brewRefreshed: [String: Date] = [:]

    /// Brew runs with auto-update off (Update pls already knows the latest version), but its own copy of the
    /// package list may not know that version yet, and then `brew upgrade` does nothing. So the first Homebrew
    /// job on a machine every 10 minutes refreshes it first.
    static func brewRefresh(_ item: Item, now: Date = Date()) -> String {
        switch item.method {
        case .brewFormula, .cask: break
        default: return ""
        }
        let due = brewLock.withLock {
            guard let last = brewRefreshed[item.machine.id] else { return true }
            return now.timeIntervalSince(last) >= 600
        }
        guard due else { return "" }
        return """
            echo '==> Refreshing Homebrew'
            if brew update --quiet >/dev/null 2>&1; then echo "BREW_REFRESHED\t1"; else echo "Couldn't refresh Homebrew's package list; using the one it has" >&2; fi

            """
    }

    /// Records a Homebrew refresh that worked (seen in its output), so the next 10 minutes skip it.
    static func noteBrewRefreshed(_ item: Item, now: Date = Date()) {
        brewLock.withLock { brewRefreshed[item.machine.id] = now }
    }

    static func commandScript(_ item: Item, _ cmd: String, relaunch: Bool, cachedPath: String? = nil) -> String {
        // apt would replace an open app's files under it. As with Mac apps, it is downloaded while the app keeps
        // running, then quit there, updated and opened again (whether or not the update worked).
        var before = "", after = ""
        var runCmd = cmd
        if case let .deb(pkg, passwordless) = item.method {
            let p = Shell.q(pkg), on = item.machine.name
            // Refresh apt lists at most once every 5 minutes during a batch so consecutive .deb updates don't
            // repeat `apt-get update` (or run it twice for a single open app). The time of the last refresh that
            // worked is kept on that machine: apt keeps the server's dates on its list files, so their age says nothing.
            let aptRefresh = "up_apt_refresh"
            if passwordless && runCmd.hasPrefix("sudo -n apt-get update -q && ") {
                runCmd = aptRefresh + " && " + String(runCmd.dropFirst("sudo -n apt-get update -q && ".count))
            }
            before = Probe.debFunctions + Probe.debQuitFunctions + """
            up_apt_refresh() {
              up_m="$HOME/.cache/update-pls/apt-refreshed"
              if [ -n "$(find "$up_m" -mmin -5 2>/dev/null)" ]; then return 0; fi
              sudo -n apt-get update -q || return 1
              mkdir -p "$(dirname "$up_m")" 2>/dev/null && touch "$up_m" 2>/dev/null
              return 0
            }
            UP_RL=$(mktemp -d); UP_OPEN=0
            if up_deb_running \(p); then
              echo \(Shell.q("==> Downloading \(item.name)"))
              if ! { \(aptRefresh) && sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y --download-only \(p); }; then
                rm -rf "$UP_RL"; exit 1
              fi
              echo \(Shell.q("==> Quitting \(item.name) on \(on)"))
              if ! up_deb_quit \(p) "$UP_RL"; then
                rm -rf "$UP_RL"
                echo \(Shell.q("UPFAIL \(item.name) didn't quit on \(on). It may be asking you something there; quit it and press Retry.")) >&2
                exit 1
              fi
              UP_OPEN=\(relaunch ? 1 : 0)
              echo \(Shell.q("==> Installing \(item.name)"))
            fi

            """
            after = """
            if [ $UP_OPEN = 1 ]; then
              echo \(Shell.q("==> Reopening \(item.name)"))
              up_deb_open \(p) "$UP_RL" || echo \(Shell.q("Couldn't reopen \(item.name) on \(on); open it there.")) >&2
            fi
            rm -rf "$UP_RL"

            """
        }
        let prelude = Probe.unixPrelude(cachedPath: cachedPath)
        return item.os == .windows
            ? Probe.windowsPrelude + runCmd + "\nexit $LASTEXITCODE\n"
            : after.isEmpty ? prelude + "set -e\n" + runCmd + "\n"
            : prelude + before + "(\nset -e\n" + runCmd + "\n)\nUP_ST=$?\n" + after + "exit $UP_ST\n"
    }

    // MARK: Mac apps

    /// Shared start of every Mac app script: system tools only (no login shell, so it starts instantly),
    /// a named step for every stage, and a clear UPFAIL line when anything goes wrong.
    static func macHeader(app: String, bundleID: String) -> String {
        """
        export LC_ALL=C
        PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
        set -eE
        up_fail() { echo "UPFAIL $*" >&2; exit 1; }
        up_step() { UP_STEP="$*"; echo "==> $*"; }
        trap 'echo "UPFAIL ${UP_STEP:-Update} failed (exit $?)" >&2' ERR
        APP=\(Shell.q(app)); BID=\(Shell.q(bundleID))
        [ -n "$BID" ] || BID=$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null || echo unknown.bundle.id)
        current() { defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || true; }
        app_running() { ps -axo command= | grep -F "$APP/Contents/MacOS/" | grep -v grep >/dev/null; }
        report() { echo "CURRENT	$(current)"; if app_running; then echo "RUNNING	1"; else echo "RUNNING	0"; fi; }
        # Saved copies keep the app's bundle ID; unregistered, macOS never opens one in place of the real app.
        up_unregister() { LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister; "$LSREG" -u "$1" >/dev/null 2>&1 || true; }
        # Unload any leftover Squirrel ShipIt launchd job before replacing the app bundle, so launchd doesn't
        # crash-loop ShipIt every 2 seconds after an external update replaces the app out from under it.
        up_stop_shipit() {
          if [ -n "$BID" ] && [ "$BID" != "unknown.bundle.id" ]; then
            launchctl bootout "gui/$(id -u)/$BID.ShipIt" >/dev/null 2>&1 || true
          fi
        }
        # The main process of this app running from Update pls's saved copies instead of "$APP".
        saved_copy_pids() { ps -axo pid=,command= | grep -F "/Update pls/Backups/" | grep -F "/$(basename "$APP")/Contents/MacOS/$(basename "$APP" .app)" | grep -v grep | awk '{print $1}' || true; }

        """
    }

    /// Prints the installed version, whether the app is open and whether it can be replaced without admin rights.
    /// Only the folder matters: the swap moves the whole bundle, which macOS allows even when App Management
    /// protection blocks writing inside it (so `-w "$APP"` would wrongly say no).
    /// Also lists updates the app's own updater has already downloaded (see `pending(_:)`).
    static func macStateScript(app: String, bundleID: String, marker: String? = nil) -> String {
        macHeader(app: app, bundleID: bundleID) + (marker.map(macRecoverSnippet) ?? "") + """
        [ -d "$APP" ] || up_fail "$APP is gone"
        report
        if [ -w "$(dirname "$APP")" ]; then echo "WRITABLE	1"; else echo "WRITABLE	0"; fi
        # Squirrel (ShipIt) and Sparkle keep the new version ready to install when the app quits.
        for d in "$HOME/Library/Caches/$BID.ShipIt" "$HOME/Library/Caches/$BID/org.sparkle-project.Sparkle"; do
          if [ -d "$d" ]; then
            while IFS= read -r a; do
              if [ "$(defaults read "$a/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$BID" ]; then
                echo "PENDING_APP	$(defaults read "$a/Contents/Info" CFBundleShortVersionString 2>/dev/null)	$a"
              fi
            done < <(find "$d" -maxdepth 5 -name '*.app' -type d -prune 2>/dev/null)
          fi
        done
        # electron-updater keeps the downloaded zip and its sha512.
        for f in "$HOME/Library/Caches/"*-updater/pending/update-info.json; do
          if [ -f "$f" ]; then
            z="$(dirname "$f")/$(sed -n 's/.*"fileName" *: *"\\([^"]*\\)".*/\\1/p' "$f")"
            h=$(sed -n 's/.*"sha512" *: *"\\([^"]*\\)".*/\\1/p' "$f")
            if [ -f "$z" ] && [ -n "$h" ]; then echo "PENDING_ZIP	$h	$z"; fi
          fi
        done

        """
    }

    /// `up_file_old K F`: files the previous version K (moved aside next to the app, on the app's volume) as F among
    /// the saved versions (on another volume). It is copied into a temporary folder beside F, checked, and renamed
    /// into place, so F is never a partial copy; K is removed only then.
    static let fileOldFunction = """
        up_file_old() {
          up_k=$1; up_f=$2; up_t="$2.update-pls-tmp"
          mkdir -p "$(dirname "$up_f")" || return 1
          rm -rf "$up_t"
          if ! ditto "$up_k" "$up_t"; then rm -rf "$up_t"; return 1; fi
          if [ "$(defaults read "$up_t/Contents/Info" CFBundleShortVersionString 2>/dev/null)" != "$(defaults read "$up_k/Contents/Info" CFBundleShortVersionString 2>/dev/null)" ]; then rm -rf "$up_t"; return 1; fi
          if codesign --verify --strict "$up_k" >/dev/null 2>&1 && ! codesign --verify --deep --strict "$up_t" >/dev/null 2>&1; then rm -rf "$up_t"; return 1; fi
          rm -rf "$up_f"
          if [ -e "$up_f" ] || [ -L "$up_f" ]; then rm -rf "$up_t"; return 1; fi
          if ! mv "$up_t" "$up_f"; then rm -rf "$up_t"; return 1; fi
          rm -rf "$up_k"
          return 0
        }

        """

    /// Finishes a swap that was cut off. The marker lists the app, where its previous version was moved, the tool,
    /// and (once the new version is in) where that previous version is still to be filed.
    /// - Cut off between the two moves (the app is gone), or while the app was incomplete: the previous version is
    ///   put back.
    /// - Cut off while filing the previous version under the saved versions: the filing is done again.
    /// The marker stays until that worked, so a failed attempt is tried again. Only run while holding that tool's
    /// `ItemLock` and the backups lock.
    static let macRecoverBody = fileOldFunction + """
        if [ -f "$MARK" ]; then
          A=$(sed -n 1p "$MARK"); K=$(sed -n 2p "$MARK"); F=$(sed -n 4p "$MARK"); back=1
          if [ -z "$A" ] || [ -z "$K" ]; then
            back=0; echo "RECOVER_FAILED	$MARK"
          elif [ -n "$F" ]; then
            if [ -d "$K" ] && [ ! -L "$K" ]; then
              if up_file_old "$K" "$F"; then echo "FILED	$F"; else back=0; echo "FILE_FAILED	$K"; fi
            fi
          elif [ -n "$A" ] && [ -d "$K" ]; then
            if [ ! -e "$A" ] || { ! codesign --verify --strict "$A" >/dev/null 2>&1 && codesign --verify --strict "$K" >/dev/null 2>&1; }; then
              if mkdir -p "$(dirname "$A")" && rm -rf "$A" && mv "$K" "$A"; then echo "RECOVERED	$A"; else back=0; echo "RECOVER_FAILED	$A"; fi
            fi
          elif [ -n "$A" ] && [ ! -e "$A" ]; then
            # Nothing to put back yet; keep the marker, so it is still tried once the copy turns up.
            back=0; echo "RECOVER_FAILED	$A"
          fi
          if [ $back = 1 ]; then rm -f "$MARK"; fi
        fi

        """

    static func macRecoverSnippet(marker: String) -> String {
        "MARK=\"$HOME/\"\(Shell.q(marker))\n" + macRecoverBody
    }

    static func macRecoverScript(marker: String) -> String {
        "export LC_ALL=C\nPATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH\n" + macRecoverSnippet(marker: marker)
    }

    /// Puts back any app on this Mac whose swap was cut off (Update pls killed, power lost), skipping tools
    /// another Update pls is updating right now. Returns the apps put back.
    static func recoverInterruptedSwaps(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                        run: ScriptRunner? = nil) async -> [String] {
        let dir = home.appendingPathComponent(swapMarkersDir)
        guard let markers = try? FileManager.default.contentsOfDirectory(atPath: dir.path), !markers.isEmpty else { return [] }
        let run = run ?? { script, timeout, out in await Runner.run(.local, os: .mac, script: script, timeout: timeout, onOutput: out) }
        var restored: [String] = []
        for m in markers {
            let lines = ((try? String(contentsOf: dir.appendingPathComponent(m), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            guard lines.count >= 3, case let .success(lock) = ItemLock.take(lines[2]) else { continue }
            guard case let .success(backups) = await ItemLock.take(ItemLock.backupsKey, waitingUpTo: 30) else { lock.release(); continue }
            let res = await run(macRecoverScript(marker: "\(swapMarkersDir)/\(m)"), 120, nil)
            backups.release()
            lock.release()
            let f = fields(res)
            if let a = f["RECOVERED"] { Log.error("put \(a) back after an interrupted update"); restored.append(a) }
            if let a = f["RECOVER_FAILED"] { Log.error("\(a) is missing after an interrupted update, and its previous version couldn't be put back") }
            if let a = f["FILED"] { Log.info("saved \(a) for rollback, left over from an interrupted update") }
            if let a = f["FILE_FAILED"] { Log.error("the previous version at \(a) still couldn't be saved for rollback") }
        }
        return restored
    }

    /// Updates the app's own updater already downloaded, from the state script: ready bundles by version,
    /// and zips by sha512.
    static func pending(_ r: ShellResult) -> (apps: [(version: String, path: String)], zips: [(sha512: String, path: String)]) {
        var apps: [(String, String)] = [], zips: [(String, String)] = []
        for line in r.stdout.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, !f[1].isEmpty, !f[2].isEmpty else { continue }
            if f[0] == "PENDING_APP" { apps.append((f[1], f[2])) } else if f[0] == "PENDING_ZIP" { zips.append((f[1], f[2])) }
        }
        return (apps, zips)
    }

    /// Downloads the publisher's build into a staging folder and checks its hash, bundle id, signature,
    /// notarization and signing team, all while the installed app keeps running.
    /// With `local`, takes the update the app's own updater already downloaded (a ready app, or a zip
    /// that is checked against the published hash) instead of downloading it again.
    static func macStageScript(app: String, bundleID: String, name: String, url: String, info: LatestInfo, stage: String,
                               local: String? = nil, trust: Bool = true, reserveMB: Int = 500) -> String {
        var verify = ""
        if let h = info.sha256 {
            verify = """
            up_step "Checking the download"
            [ "$(shasum -a 256 "$ST/dl" | cut -d' ' -f1)" = \(Shell.q(h)) ] || up_fail "Checksum mismatch: the download isn't what the publisher lists"
            """
        } else if let h = info.sha512Base64 {
            verify = """
            up_step "Checking the download"
            [ "$(openssl dgst -sha512 -binary "$ST/dl" | base64)" = \(Shell.q(h)) ] || up_fail "Checksum mismatch: the download isn't what the publisher lists"
            """
        }
        let trustChecks = !trust ? "" : """
        codesign --verify --deep --strict "$NEW" || up_fail "The download's code signature is broken"
        spctl --assess --type execute "$NEW" || up_fail "Gatekeeper rejected the download"
        team() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
        OLD_TEAM=$(team "$APP"); NEW_TEAM=$(team "$NEW")
        [ -n "$NEW_TEAM" ] && [ "$NEW_TEAM" != "not set" ] && [ "$NEW_TEAM" = "$OLD_TEAM" ] || up_fail "Signing team changed ($OLD_TEAM -> $NEW_TEAM), not installing"
        """
        let unpack = """
            \(verify)
            up_step "Unpacking"
            if [ "$(head -c 2 "$ST/dl")" = "PK" ]; then
              ditto -x -k "$ST/dl" "$ST/x" || up_fail "Couldn't unpack the download"
            else
              mkdir -p "$ST/mnt"
              hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$ST/mnt" "$ST/dl" -quiet || up_fail "Couldn't open the disk image"
              for a in "$ST/mnt"/*.app; do if [ -d "$a" ]; then ditto "$a" "$ST/x/$(basename "$a")"; fi; done
              unmount
            fi
            rm -f "$ST/dl"
            """
        // The archive and the unpacked app sit side by side until the swap: about 1.5x the installed app,
        // plus some room to spare. Fails before downloading anything rather than halfway through.
        let space = """
            need=$(( $(du -sk "$APP" | cut -f1) * 3 / 2 + \(reserveMB) * 1024 ))
            free=$(df -k "$HOME" | awk 'NR == 2 { print $4 }')
            size() { if [ "$1" -ge 1048576 ]; then echo "$(( ($1 + 524287) / 1048576 )) GB"; else echo "$(( ($1 + 1023) / 1024 )) MB"; fi; }
            if [ -n "$free" ] && [ "$free" -lt "$need" ]; then
              up_fail "Not enough disk space: needs about $(size "$need") free, $(size "$free") left. Free some up, or keep fewer versions for rollback in Settings."
            fi
            """
        let fetch: String
        if let local, local.hasSuffix(".app") || local.hasSuffix(".app/") {
            // Cloned, so the app's updater keeps its copy (instant and free on APFS).
            fetch = """
            up_step \(Shell.q("Using the update \(name) already downloaded"))
            SRC=\(Shell.q(local)); [ -d "$SRC" ] || up_fail "The downloaded update is gone; press Retry"
            if ! cp -cR "$SRC" "$ST/x/$(basename "$SRC")" 2>/dev/null; then rm -rf "$ST/x"/*; ditto "$SRC" "$ST/x/$(basename "$SRC")"; fi
            """
        } else if let local {
            fetch = """
            up_step \(Shell.q("Using the update \(name) already downloaded"))
            SRC=\(Shell.q(local)); [ -f "$SRC" ] || up_fail "The downloaded update is gone; press Retry"
            \(space)
            cp -c "$SRC" "$ST/dl" 2>/dev/null || cp "$SRC" "$ST/dl"
            \(unpack)
            """
        } else {
            fetch = """
            \(space)
            up_step \(Shell.q("Downloading \(name) \(info.version)"))
            curl -fL --retry 2 --connect-timeout 20 --speed-limit 4096 --speed-time 60 -# -o "$ST/dl" "$URL" || up_fail "Download failed"
            \(unpack)
            """
        }
        return macHeader(app: app, bundleID: bundleID) + """
        URL=\(Shell.q(url)); ST="$HOME/"\(Shell.q(stage))
        unmount() { if [ -d "$ST/mnt" ]; then hdiutil detach "$ST/mnt" -quiet -force >/dev/null 2>&1 || true; rmdir "$ST/mnt" 2>/dev/null || true; fi; }
        trap unmount EXIT
        # A copy of the app made before an earlier quit ("pre") may be the only one of its version: keep it.
        find "$ST" -mindepth 1 -maxdepth 1 ! -name pre -exec rm -rf {} + 2>/dev/null || true
        mkdir -p "$ST/x"
        \(fetch)
        up_step "Checking signature"
        NEW=""
        while IFS= read -r a; do
          if [ "$(defaults read "$a/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$BID" ]; then NEW="$a"; break; fi
        done < <(find "$ST/x" -maxdepth 3 -name '*.app' -type d -prune)
        [ -n "$NEW" ] || up_fail "No app with bundle id $BID in the download"
        \(trustChecks)
        echo "STAGED	$NEW"
        echo "STAGED_VERSION	$(defaults read "$NEW/Contents/Info" CFBundleShortVersionString)"
        report

        """
    }

    /// Quits the app through AppleScript (for other Macs over SSH, where AppKit can't reach it).
    static func macQuitScript(app: String, bundleID: String, name: String) -> String {
        macHeader(app: app, bundleID: bundleID) + """
        up_step \(Shell.q("Quitting \(name)"))
        if app_running; then
          out=$(osascript -e "tell application id \\"$BID\\" to quit" 2>&1) || echo "osascript: $out" >&2
          for i in $(seq 1 180); do app_running || break; sleep 0.5; done
          if app_running; then up_fail \(Shell.q("\(name) didn't quit. It may be asking you something; quit it and press Retry.")); fi
        fi
        report

        """
    }

    /// Many apps install their own pending update as they quit (Squirrel's ShipIt, Sparkle's Autoupdate).
    /// Waits until no such updater has been seen for 4 seconds, then reports the version. Fails if the updater
    /// is still at it after `seconds`, rather than swapping the app under it.
    static func macWaitUpdaterScript(app: String, bundleID: String, name: String, seconds: Int = 300) -> String {
        macHeader(app: app, bundleID: bundleID) + """
        updater_running() { ps -axo command= | grep -E 'ShipIt|Autoupdate|Updater|Installer|[Ss]parkle' | grep -F -e "$BID" -e "$APP/" | grep -v grep >/dev/null; }
        idle=0; seen=0
        for i in $(seq 1 \(seconds * 2)); do
          if updater_running; then
            idle=0
            if [ $seen = 0 ]; then seen=1; up_step \(Shell.q("\(name) is installing its own update")); fi
          else
            idle=$((idle + 1))
            if [ $idle -ge 8 ]; then break; fi
          fi
          sleep 0.5
        done
        # The deadline may fall inside the final quiet spell: give that spell its last few seconds.
        for i in 1 2 3 4 5 6 7 8; do
          if [ $idle -ge 8 ] || updater_running; then break; fi
          idle=$((idle + 1)); sleep 0.5
        done
        if [ $idle -lt 8 ]; then
          echo "UPDATER_BUSY	1"
          up_fail \(Shell.q("\(name) is still installing its own update. Let it finish, then press Retry."))
        fi
        report

        """
    }

    /// Swaps another version in: a checked download (`staged`) or a saved copy of `version`.
    /// The version it replaces is saved for rollback, and only the newest `keep` saved versions are kept.
    /// `expect` is the installed version the update was checked against: the swap refuses if it is anything else
    /// right before the app is moved. `forward` (an update, not a switch) also refuses an unreadable version.
    static func macSwapScript(app: String, bundleID: String, name: String, staged: String?, version: String,
                              stage: String, saved: String, keep: Int, marker: String? = nil, key: String = "", trust: Bool = true,
                              expect: String? = nil, forward: Bool = false) -> String {
        let appName = (app as NSString).lastPathComponent
        let source = staged.map { """
            NEW=\(Shell.q($0))
            [ -d "$NEW" ] || up_fail "The checked download is gone; press Retry"
            """ } ?? """
            NEW=""
            for c in "$SV"/*/"$AN" "$SV/$AN"; do
              if [ -d "$c" ] && [ ! -L "$c" ] && [ "$(defaults read "$c/Contents/Info" CFBundleShortVersionString 2>/dev/null)" = "$WANT" ]; then NEW="$c"; break; fi
            done
            [ -n "$NEW" ] || up_fail "No saved copy of \(name) $WANT on this machine"
            [ "$(defaults read "$NEW/Contents/Info" CFBundleIdentifier)" = "$BID" ] || up_fail "The saved copy is a different app"
            \(trust ? #"codesign --verify --deep --strict "$NEW" || up_fail "The saved copy's signature is broken""# : "")
            """
        return macHeader(app: app, bundleID: bundleID) + fileOldFunction + keepPreFunction + svSafeFunction + """
        SV="$HOME/"\(Shell.q(saved)); ST="$HOME/"\(Shell.q(stage)); AN=\(Shell.q(appName)); WANT=\(Shell.q(version))
        up_step \(Shell.q("Installing \(name) \(version)"))
        \(source)
        DEST=$(dirname "$APP")
        dev() { stat -f %d "$1" 2>/dev/null; }
        # Both moves below must be renames on the app's own volume, which are instant and can't be half done.
        # Across volumes `mv` copies, and a cut-off copy would leave half an app in place: so a download on
        # another volume is first copied next to the app and checked there.
        TMPNEW=""
        trap 'if [ -n "$TMPNEW" ]; then rm -rf "$TMPNEW"; fi' EXIT
        if [ "$(dev "$NEW")" != "$(dev "$DEST")" ]; then
          up_step \(Shell.q("Copying \(name) \(version) next to the installed app"))
          TMPNEW="$DEST/.$AN.update-pls-new"
          rm -rf "$TMPNEW"
          if [ -e "$TMPNEW" ]; then up_fail "Couldn't clear $TMPNEW"; fi
          ditto "$NEW" "$TMPNEW" || up_fail "Couldn't copy \(name) $WANT to $DEST"
          \(trust ? #"codesign --verify --deep --strict "$TMPNEW" || up_fail "The copy next to the app has a broken signature""# : "")
          [ "$(defaults read "$TMPNEW/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$BID" ] || up_fail "The copy next to the app is a different app"
          NEW="$TMPNEW"
          up_step \(Shell.q("Installing \(name) \(version)"))
        fi
        # Read again right before anything is moved: if the app's own updater changed it since it was checked,
        # what is swapped in could be older than what is installed now.
        if app_running; then up_fail \(Shell.q("\(name) is open again; quit it and press Retry")); fi
        CUR=$(current)
        EXPECT=\(Shell.q(expect ?? ""))
        if [ -n "$EXPECT" ] && [ "$CUR" != "$EXPECT" ]; then
          up_fail "\(name) changed to ${CUR:-an unreadable version} while it was being updated (expected $EXPECT); press Retry"
        fi
        if [ \(forward ? 1 : 0) = 1 ] && [ -z "$CUR" ]; then up_fail "Couldn't read which version of \(name) is installed, so nothing was replaced"; fi
        up_stop_shipit
        mkdir -p "$SV"
        up_sv_safe || up_fail "The folder for \(name)'s saved versions is a link to somewhere else; nothing was replaced"
        # Copies saved by Update pls 0.3 sit directly in the folder; file them under their version.
        if [ -d "$SV/$AN" ] && [ ! -L "$SV/$AN" ] && [ "$NEW" != "$SV/$AN" ]; then
          old=$(defaults read "$SV/$AN/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)
          rm -rf "$SV/$old/$AN"; mkdir -p "$SV/$old"; mv "$SV/$AN" "$SV/$old/$AN"
        fi
        KEEP="$SV/${CUR:-unknown}"
        if [ -L "$KEEP" ]; then rm -f "$KEEP"; fi
        rm -rf "$KEEP/$AN"; mkdir -p "$KEEP"
        if [ -e "$KEEP/$AN" ] || [ -L "$KEEP/$AN" ]; then up_fail "Couldn't clear $KEEP/$AN to save the current version there"; fi
        if [ "$(dev "$KEEP")" = "$(dev "$DEST")" ]; then
          OLD="$KEEP/$AN"
        else
          # Moved aside next to the app, then filed under the saved versions once the new version is in.
          OLD="$DEST/.$AN.update-pls-old"
          if [ -e "$OLD" ]; then up_fail "\(name)'s previous version from an earlier update is still waiting to be saved at $OLD; move it somewhere safe or delete it, then press Retry"; fi
        fi
        # If this is cut off, the next run finishes it (see macRecoverBody). Written whole or not at all.
        MARK=\(marker.map { "\"$HOME/\"" + Shell.q($0) } ?? "\"$ST/.nomark\"")
        mark() { printf "$@" > "$MARK.tmp" && mv -f "$MARK.tmp" "$MARK"; }
        mkdir -p "$(dirname "$MARK")"
        mark '%s\\n%s\\n%s\\n' "$APP" "$OLD" \(Shell.q(key)) || up_fail "Couldn't note the swap before starting it"
        # The last look, right before the move: still closed, and still the version everything was checked against.
        if app_running || [ "$(current)" != "$CUR" ]; then rm -f "$MARK"; up_fail \(Shell.q("\(name) changed while it was being updated; press Retry")); fi
        mv "$APP" "$OLD" || up_fail "Couldn't move the current version aside"
        up_unregister "$OLD"
        if ! mv "$NEW" "$APP"; then rm -rf "$APP"; mv "$OLD" "$APP"; rm -f "$MARK"; up_fail "Couldn't install \(name) $WANT; the previous version was put back"; fi
        TMPNEW=""
        if [ "$OLD" = "$KEEP/$AN" ]; then
          rm -f "$MARK"; touch "$KEEP"; echo "BACKUP	$CUR"
        else
          if mark '%s\\n%s\\n%s\\n%s\\n' "$APP" "$OLD" \(Shell.q(key)) "$KEEP/$AN" && up_file_old "$OLD" "$KEEP/$AN"; then
            rm -f "$MARK"; up_unregister "$KEEP/$AN"; touch "$KEEP"; echo "BACKUP	$CUR"
          else
            echo "Couldn't save $CUR for rollback yet (it is at $OLD); the next update tries again" >&2
          fi
        fi
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
        NOW=$(current)
        echo "INSTALLED	$NOW"
        # A saved copy of the version now installed is only a duplicate.
        if [ -n "$NOW" ] && [ "$NOW" != "$CUR" ] && [ ! -L "$SV/$NOW" ]; then rm -rf "$SV/$NOW/$AN"; rmdir "$SV/$NOW" 2>/dev/null || true; fi
        # A copy made before quitting is filed if it is the only one of its version, and only then removed.
        if ! up_keep_pre 0; then echo "Couldn't save the copy made before quitting (it is at $ST/pre)" >&2; fi
        find "$ST" -mindepth 1 -maxdepth 1 ! -name pre -exec rm -rf {} + 2>/dev/null || true
        rmdir "$ST" 2>/dev/null || true
        \(macPruneSnippet(keep: keep))

        """
    }

    /// Keeps only the newest `keep` saved versions of "$AN" in "$SV" (variants of one app share the folder).
    /// Never through a symlink: not if any folder from $HOME down to "$SV" is one, nor a version folder or app.
    static func macPruneSnippet(keep: Int) -> String {
        svSafeFunction + """
        if up_sv_safe; then
          for d in "$SV"/*; do if [ -d "$d" ] && [ ! -L "$d" ]; then rmdir "$d" 2>/dev/null || true; fi; done
          n=0
          while IFS= read -r d; do
            if [ -n "$d" ] && [ ! -L "$SV/$d" ] && [ -d "$SV/$d/$AN" ] && [ ! -L "$SV/$d/$AN" ]; then
              n=$((n + 1))
              if [ $n -gt \(max(keep, 1)) ]; then rm -rf "$SV/$d/$AN"; rmdir "$SV/$d" 2>/dev/null || true; fi
            fi
          done < <(ls -1t "$SV")
        fi
        """
    }

    /// `up_sv_safe`: true if "$SV" is a real folder and none of the folders from $HOME down to it is a link.
    static let svSafeFunction = """
        up_sv_safe() {
          up_p="$HOME"; up_rest=${SV#"$HOME"/}
          IFS=/ read -r -a up_parts <<< "$up_rest"
          for up_c in "${up_parts[@]}"; do up_p="$up_p/$up_c"; if [ -L "$up_p" ]; then return 1; fi; done
          [ -d "$SV" ]
        }

        """

    /// Clones the installed app before it quits (instant and free on APFS, a full copy elsewhere): an app that
    /// installs its own update on quit replaces itself without keeping the old version. A copy left from an earlier
    /// update is filed first; if it can't be, nothing goes on (it may be the only copy of its version).
    static func macCloneScript(app: String, bundleID: String, stage: String, saved: String) -> String {
        macHeader(app: app, bundleID: bundleID) + keepPreFunction + """
        ST="$HOME/"\(Shell.q(stage)); SV="$HOME/"\(Shell.q(saved)); AN=\(Shell.q((app as NSString).lastPathComponent))
        if ! up_keep_pre 0; then
          up_fail "A copy of \((app as NSString).lastPathComponent) kept from an earlier update couldn't be saved for rollback (it is at $ST/pre); move it somewhere safe or delete it, then press Retry"
        fi
        rm -rf "$ST/pre"; mkdir -p "$ST/pre"
        if ! cp -cR "$APP" "$ST/pre/$AN" 2>/dev/null; then rm -rf "$ST/pre/$AN"; ditto "$APP" "$ST/pre/$AN"; fi
        touch "$ST/pre/.complete"
        echo "CLONED	$(defaults read "$ST/pre/$AN/Contents/Info" CFBundleShortVersionString)"

        """
    }

    /// `up_keep_pre FORCE`: files a copy made before quitting ("$ST/pre/$AN") under its version in "$SV", unless it
    /// is only a duplicate (already saved, or, without FORCE, the version still installed). A copy that was cut
    /// off while it was being made is dropped. Fails, keeping the copy where it is, if it couldn't be filed.
    /// Every step is checked by hand: it runs in conditions, where `set -e` doesn't apply.
    static let keepPreFunction = """
        up_keep_pre() {
          PRE="$ST/pre/$AN"
          [ -e "$ST/pre" ] || return 0
          if [ ! -d "$PRE" ]; then rm -rf "$ST/pre"; return 0; fi
          # Made by an earlier release (no completion mark): kept only if it is a whole, valid app.
          if [ ! -f "$ST/pre/.complete" ] && ! codesign --verify --deep --strict "$PRE" >/dev/null 2>&1; then rm -rf "$ST/pre"; return 0; fi
          V=$(defaults read "$PRE/Contents/Info" CFBundleShortVersionString 2>/dev/null) || V=""
          [ -n "$V" ] || return 1
          if [ -L "$SV" ] || [ -L "$SV/$V" ] || [ -L "$SV/$V/$AN" ]; then return 1; fi
          if [ -d "$SV/$V/$AN" ]; then rm -rf "$ST/pre"; echo "BACKUP	$V"; return 0; fi
          if [ "$1" != 1 ] && [ "$(current)" = "$V" ]; then rm -rf "$ST/pre"; return 0; fi
          mkdir -p "$SV/$V" || return 1
          mv "$PRE" "$SV/$V/$AN" || return 1
          rm -rf "$ST/pre"
          up_unregister "$SV/$V/$AN"
          touch "$SV/$V" 2>/dev/null || true
          echo "BACKUP	$V"
          return 0
        }

        """

    /// Removes a staged update. A copy of the app made before quitting is kept for rollback first; with `force`,
    /// even when it is the version still installed (its own updater may still be about to replace it).
    static func macDiscardScript(app: String, bundleID: String, stage: String, saved: String, force: Bool) -> String {
        macHeader(app: app, bundleID: bundleID) + keepPreFunction + """
        ST="$HOME/"\(Shell.q(stage)); SV="$HOME/"\(Shell.q(saved)); AN=\(Shell.q((app as NSString).lastPathComponent))
        if up_keep_pre \(force ? 1 : 0); then
          rm -rf "$ST"
        else
          echo "Couldn't save the copy made before quitting; it is still at $ST/pre" >&2
          find "$ST" -mindepth 1 -maxdepth 1 ! -name pre -exec rm -rf {} + 2>/dev/null || true
        fi

        """
    }

    /// Only the download: for when the saved versions can't be locked, so a copy made before quitting stays put.
    static func macDiscardDownloadScript(stage: String) -> String {
        "ST=\"$HOME/\"\(Shell.q(stage))\nfind \"$ST\" -mindepth 1 -maxdepth 1 ! -name pre -exec rm -rf {} + 2>/dev/null || true\n"
    }

    /// Files the clone made before quitting under its version, once the app's own updater has replaced the app.
    static func macKeepCloneScript(app: String, bundleID: String, stage: String, saved: String, keep: Int) -> String {
        macHeader(app: app, bundleID: bundleID) + keepPreFunction + """
        ST="$HOME/"\(Shell.q(stage)); SV="$HOME/"\(Shell.q(saved)); AN=\(Shell.q((app as NSString).lastPathComponent))
        [ -d "$ST/pre/$AN" ] || up_fail "The copy made before quitting is gone"
        up_keep_pre 1 || up_fail "Couldn't save the copy made before quitting (it is still at $ST/pre)"
        NOW=$(current)
        if [ -n "$NOW" ] && [ "$NOW" != "$V" ] && [ ! -L "$SV/$NOW" ]; then rm -rf "$SV/$NOW/$AN"; rmdir "$SV/$NOW" 2>/dev/null || true; fi
        \(macPruneSnippet(keep: keep))

        """
    }

    static func macOpenScript(app: String, bundleID: String) -> String {
        macHeader(app: app, bundleID: bundleID) + """
        # An app's own updater can relaunch the copy that was just moved aside: close it and open the real one.
        for i in 1 2 3; do
          P=$(saved_copy_pids)
          [ -n "$P" ] || break
          echo "Closing $(basename "$APP" .app) opened from a saved copy"
          kill -TERM $P 2>/dev/null || true
          for _ in $(seq 1 40); do [ -z "$(saved_copy_pids)" ] && break; sleep 0.25; done
        done
        if ! app_running; then open -g "$APP"; fi

        """
    }

    /// `KEY<tab>value` lines from a script's output.
    static func fields(_ r: ShellResult) -> [String: String] {
        var f: [String: String] = [:]
        for line in r.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].allSatisfy({ $0.isUppercase || $0 == "_" }) { f[parts[0]] = parts[1] }
        }
        return f
    }

    /// Runs a script on the item's machine, streaming its output to the given handler.
    typealias ScriptRunner = @Sendable (String, TimeInterval, (@Sendable (String) -> Void)?) async -> ShellResult

    static func macRunner(_ item: Item) -> ScriptRunner {
        { script, timeout, onOutput in await Runner.run(item.machine, os: .mac, script: script, timeout: timeout, onOutput: onOutput) }
    }

    /// How many replaced versions of each app are kept for rollback (Settings).
    static var keepVersions: Int {
        let n = UserDefaults.standard.integer(forKey: "keepVersions")
        return n > 0 ? n : 3
    }

    /// Asks an open app to quit: through AppKit on this Mac, through AppleScript elsewhere.
    static func quitApp(_ item: Item, app: String, bundleID: String, _ r: Reporter, run: ScriptRunner, log: inout String) async -> String? {
        if item.machine.isLocal, let quit = await LocalApps.quit(app, name: item.name, r) {
            return quit ? nil : "\(item.name) didn't quit. It may be asking you something; quit it and press Retry."
        }
        let res = await run(macQuitScript(app: app, bundleID: bundleID, name: item.name), 120, r.sink)
        log += res.combined + "\n"
        return res.ok ? nil : failure(res)
    }

    /// Nil once it is open again, else why not.
    @discardableResult
    static func reopen(_ item: Item, app: String, bundleID: String, _ r: Reporter, run: ScriptRunner) async -> String? {
        r.phase("Reopening \(item.name)")
        let res = await run(macOpenScript(app: app, bundleID: bundleID), 60, r.sink)
        guard res.ok else {
            Log.error("reopen \(item.key): \(failure(res))")
            return "Couldn't reopen \(item.name): \(failure(res))"
        }
        return nil
    }

    enum AppSource { case download(LatestInfo), saved }

    /// Puts `version` of a Mac app in place:
    /// 1. download and check it while the app keeps running (or pick the saved copy),
    /// 2. quit the app and let its own updater finish if quitting set one off,
    /// 3. swap it in, keeping the replaced version, and 4. reopen the app if it was open.
    /// `exact` installs that version even if it is older; otherwise an app already on it or newer is left alone.
    static func installMacApp(_ item: Item, version target: String, from source: AppSource, exact: Bool, relaunch: Bool, _ r: Reporter,
                              dryRun: Bool = false, trust: Bool = true, keep: Int = keepVersions, run custom: ScriptRunner? = nil) async -> UpdateOutcome {
        guard case let .macDirect(app, bid) = item.method else { return .fail("Not a downloaded Mac app") }
        let run = custom ?? macRunner(item)
        let name = item.name, stage = stagingPath(item)
        let verb = exact ? "Switched to" : "Updated to"
        var log = ""
        func step(_ script: String, _ timeout: TimeInterval) async -> (ShellResult, [String: String]) {
            let res = await run(script, timeout, r.sink)
            log += res.combined + "\n"
            return (res, fields(res))
        }
        func failed(_ res: ShellResult) -> UpdateOutcome {
            if res.cancelled { return .cancelledOutcome(output: log) }
            var o = UpdateOutcome.fail(failure(res), output: log)
            o.timedOut = res.timedOut
            return o
        }
        func done(_ current: String?) -> Bool {
            guard let c = current, !c.isEmpty else { return false }
            return exact ? c == target : !Version.isNewer(target, than: c)
        }
        let saved = savedPath(item)
        /// Clean-up and reopening always run to the end, even for a cancelled job. A copy made before quitting is
        /// filed only while holding the backups lock; without it, only the download is removed.
        func discard(force: Bool = false) async {
            var script = macDiscardScript(app: app, bundleID: bid, stage: stage, saved: saved, force: force)
            var lock: ItemLock?
            if item.machine.isLocal {
                if case let .success(l) = await ItemLock.take(ItemLock.backupsKey, waitingUpTo: 120) { lock = l }
                else { script = macDiscardDownloadScript(stage: stage) }
            }
            let res = await Task.detached { await run(script, 120, nil) }.value
            lock?.release()
            if !res.ok { Log.error("\(item.key): couldn't clean up its staged update: \(failure(res))") }
            else if let b = fields(res)["BACKUP"] { Log.info("\(item.key): kept \(b) for rollback") }
        }
        /// Nil once the app is open again, else why not.
        func reopenApp() async -> String? {
            await Task.detached { await reopen(item, app: app, bundleID: bid, r, run: run) }.value
        }
        func withReopenNote(_ o: UpdateOutcome, _ note: String?) -> UpdateOutcome {
            guard let note else { return o }
            var o = o
            o.message += o.ok ? " (\(note))" : ". \(note)"
            o.note = note
            return o
        }
        /// A step that adds to or removes from this Mac's saved versions, so Settings can't clean them up meanwhile.
        func backupStep(_ script: String, _ timeout: TimeInterval) async -> (ShellResult, [String: String]) {
            var lock: ItemLock?
            if item.machine.isLocal {
                switch await ItemLock.take(ItemLock.backupsKey, waitingUpTo: 120) {
                case let .success(l): lock = l
                case .failure:
                    let why = "Couldn't get at the saved versions of \(name) (Settings may be cleaning them up); press Retry"
                    log += why + "\n"
                    return (ShellResult(status: 1, stdout: "", stderr: "UPFAIL " + why), [:])
                }
            }
            defer { lock?.release() }
            return await step(script, timeout)
        }

        r.phase("Checking \(name)")
        let (s0, f0) = await backupStep(macStateScript(app: app, bundleID: bid, marker: swapMarkerPath(item)), 60)
        if let a = f0["RECOVERED"] { Log.error("\(item.key): put \(a) back after an interrupted update") }
        if let a = f0["FILED"] { Log.info("\(item.key): saved \(a) for rollback, left over from an interrupted update") }
        guard s0.ok else { return failed(s0) }
        // A dry run always downloads and checks the build, to prove the update would work.
        if done(f0["CURRENT"]) && !dryRun {
            return UpdateOutcome(ok: true, message: "Already on \(f0["CURRENT"]!)", output: log, installed: f0["CURRENT"], changed: false)
        }
        if f0["WRITABLE"] == "0" && !dryRun {
            return .fail("Needs admin rights to replace apps in \((app as NSString).deletingLastPathComponent)", output: log)
        }

        var staged: String?
        /// The version that will be swapped in, as read from the bundle itself.
        var candidate = target
        var wasRunning = f0["RUNNING"] == "1"
        var installedNow = f0["CURRENT"] ?? ""
        if case let .download(info) = source {
            // The app's own updater may have this version ready already: no need to download it again.
            let ready = pending(s0)
            let local = ready.apps.first { Version.clean($0.version) == Version.clean(target) }?.path
                ?? info.sha512Base64.flatMap { h in ready.zips.first { $0.sha512 == h }?.path }
            guard let url = info.url ?? local else { return .fail("No download is published for \(target)", output: log) }
            if let local { Log.info("\(item.key): using the update \(name) already downloaded: \(local)") }
            var (s1, f1) = await step(macStageScript(app: app, bundleID: bid, name: name, url: url, info: info, stage: stage,
                                                     local: local, trust: trust), 3600)
            if s1.cancelled || Task.isCancelled { await discard(); return .cancelledOutcome(output: log) }
            // The app's copy may be mid-way through being patched, or not what it seemed: download it after all.
            if local != nil, let url = info.url,
               !s1.ok || f1["STAGED"] == nil || Version.clean(f1["STAGED_VERSION"] ?? "") != Version.clean(target) {
                Log.info("\(item.key): the update \(name) already downloaded didn't check out (\(s1.ok ? "version \(f1["STAGED_VERSION"] ?? "?")" : failure(s1))); downloading it")
                (s1, f1) = await step(macStageScript(app: app, bundleID: bid, name: name, url: url, info: info, stage: stage, trust: trust), 3600)
                if s1.cancelled || Task.isCancelled { await discard(); return .cancelledOutcome(output: log) }
            }
            guard s1.ok, let path = f1["STAGED"] else { return failed(s1) }
            // A feed can point at another build than it lists: never install an older one as an update.
            let got = f1["STAGED_VERSION"] ?? ""
            if Version.clean(got) != Version.clean(target) && (exact || !Version.isNewer(got, than: f1["CURRENT"] ?? "")) {
                await discard()
                return .fail("The download is \(name) \(got.isEmpty ? "of an unknown version" : got), not \(target); nothing was installed", output: log)
            }
            if dryRun {
                await discard()
                return UpdateOutcome(ok: true, message: "Downloaded and checked \(f1["STAGED_VERSION"] ?? target) (dry run, nothing installed)", output: log, changed: false)
            }
            // The app may have updated itself during the download.
            if !exact && done(f1["CURRENT"]) {
                await discard()
                return UpdateOutcome(ok: true, message: "\(name) updated itself to \(f1["CURRENT"]!)", output: log, installed: f1["CURRENT"], changed: false)
            }
            staged = path
            candidate = got.isEmpty ? target : got
            wasRunning = f1["RUNNING"] == "1"
            installedNow = f1["CURRENT"] ?? installedNow
        }

        if Task.isCancelled { await discard(); return .cancelledOutcome(output: log) }

        // Only the brief quit + atomic-swap + reopen section is serialized per machine, so downloads run in parallel.
        // Waiting for it can still be cancelled; owning it can't.
        if await SwapGate.shared.isBusy(item.machine.id) { r.phase("Waiting for another app to finish installing") }
        guard await SwapGate.shared.acquire(machineID: item.machine.id) else {
            await discard()
            return .cancelledOutcome(output: log)
        }
        defer { Task { await SwapGate.shared.release(machineID: item.machine.id) } }

        // From here on an app may be quit or replaced: the job is no longer cancellable, so whatever happens,
        // things are put back and the app is reopened.
        guard r.commit() else { await discard(); return .cancelledOutcome(output: log) }

        // Whatever goes wrong from here, an app that was open is opened again (the old version is still in place).
        func giveUp(_ o: UpdateOutcome, force: Bool = false, recover: Bool = false) async -> UpdateOutcome {
            if recover {
                // A swap that failed half way may have left the app moved aside: put it back before opening it.
                let (rr, rf) = await backupStep(macRecoverScript(marker: swapMarkerPath(item)), 120)
                if let a = rf["RECOVERED"] { Log.error("\(item.key): put \(a) back after a failed swap") }
                if !rr.ok || rf["RECOVER_FAILED"] != nil { Log.error("\(item.key): couldn't put the previous version back after a failed swap") }
            }
            await discard(force: force)
            if relaunch && wasRunning { return withReopenNote(o, await reopenApp()) }
            return o
        }
        if wasRunning {
            let (sc, fc) = await backupStep(macCloneScript(app: app, bundleID: bid, stage: stage, saved: saved), 300)
            // Without it, an app that installs its own update on quit would leave nothing to roll back to.
            guard sc.ok, let c = fc["CLONED"], !c.isEmpty else {
                await discard()
                return .fail("Couldn't keep a copy of \(name) for rollback, so it wasn't quit or updated: \(failure(sc))", output: log)
            }
            if let err = await quitApp(item, app: app, bundleID: bid, r, run: run, log: &log) {
                await discard()
                return .fail(err, output: log)
            }
            r.phase("Making sure \(name) isn't installing its own update")
            let (s2, f2) = await step(macWaitUpdaterScript(app: app, bundleID: bid, name: name), 400)
            // Its updater may still be working on the app: leave reopening it to that updater, and keep the copy
            // made before quitting, since that updater is about to replace the version it holds.
            guard s2.ok else {
                if f2["UPDATER_BUSY"] != nil { await discard(force: true); return failed(s2) }
                // Couldn't tell (the connection dropped, the check failed): the app is closed, so open it again.
                return await giveUp(failed(s2), force: true)
            }
            installedNow = f2["CURRENT"] ?? ""
            // Its own updater replaced it: keep the copy so it can still be rolled back.
            var kept: String?
            if !installedNow.isEmpty, installedNow != c {
                let (sk, fk) = await backupStep(macKeepCloneScript(app: app, bundleID: bid, stage: stage, saved: saved, keep: keep), 120)
                if sk.ok { kept = fk["BACKUP"] } else { Log.error("\(item.key): couldn't keep \(c) for rollback: \(failure(sk))") }
            }
            if !exact && done(installedNow) {
                await discard(force: kept == nil && installedNow != c)
                let note = relaunch && f2["RUNNING"] != "1" ? await reopenApp() : nil
                return withReopenNote(UpdateOutcome(ok: true, message: "\(name) installed its own update to \(installedNow)", output: log,
                                                    previous: kept, installed: installedNow), note)
            }
            // Its updater may have reopened it; quit it once more.
            if f2["RUNNING"] == "1", let err = await quitApp(item, app: app, bundleID: bid, r, run: run, log: &log) {
                return await giveUp(.fail(err, output: log))
            }
        }

        // An update only ever moves forward from what is installed right now, which the app's own updater may
        // have changed since the download was checked.
        if !exact && installedNow.isEmpty {
            return await giveUp(.fail("Couldn't read which version of \(name) is installed, so nothing was replaced", output: log))
        }
        if !exact, !Version.isNewer(candidate, than: installedNow) {
            return await giveUp(.fail("\(name) is on \(installedNow) now, and the download (\(candidate)) isn't newer; nothing was installed", output: log))
        }

        let (s3, f3) = await backupStep(macSwapScript(app: app, bundleID: bid, name: name, staged: staged, version: target, stage: stage,
                                                      saved: saved, keep: keep, marker: swapMarkerPath(item), key: item.key,
                                                      trust: trust, expect: installedNow.isEmpty ? nil : installedNow,
                                                      forward: !exact), 600)
        guard s3.ok else { return await giveUp(failed(s3), recover: true) }
        let note = relaunch && wasRunning ? await reopenApp() : nil
        let installed = f3["INSTALLED"].flatMap { $0.isEmpty ? nil : $0 }
        let previous = f3["BACKUP"].flatMap { $0.isEmpty ? nil : $0 }
        return withReopenNote(UpdateOutcome(ok: true, message: "\(verb) \(installed ?? target)", output: log, previous: previous, installed: installed), note)
    }

    /// Apps installed with Homebrew: same quit-and-wait as above, then `brew upgrade --cask`.
    static func updateCask(_ item: Item, relaunch: Bool, _ r: Reporter) async -> UpdateOutcome {
        guard case .cask = item.method, let cmd = item.command else { return .fail("Not a Homebrew app") }
        let run = macRunner(item)
        let bid = item.machine.isLocal ? Bundle(path: item.path)?.bundleIdentifier ?? "" : ""
        var log = ""
        let target = item.latest?.version ?? ""
        func reopenApp() async -> String? {
            await Task.detached { await reopen(item, app: item.path, bundleID: bid, r, run: run) }.value
        }
        r.phase("Checking \(item.name)")
        let s0 = await run(macStateScript(app: item.path, bundleID: bid), 60, r.sink)
        log += s0.combined + "\n"
        guard s0.ok else { return s0.cancelled ? .cancelledOutcome(output: log) : .fail(failure(s0), output: log) }
        // Quitting the app and Homebrew replacing it both run to the end once started.
        guard r.commit() else { return .cancelledOutcome(output: log) }
        let wasRunning = fields(s0)["RUNNING"] == "1"
        if wasRunning {
            if let err = await quitApp(item, app: item.path, bundleID: bid, r, run: run, log: &log) { return .fail(err, output: log) }
            let w = await run(macWaitUpdaterScript(app: item.path, bundleID: bid, name: item.name), 400, r.sink)
            log += w.combined + "\n"
            guard w.ok else {
                var o = UpdateOutcome.fail(failure(w), output: log)
                // Only an updater known to be at work is left to reopen the app itself.
                if fields(w)["UPDATER_BUSY"] == nil, relaunch, let note = await reopenApp() { o.message += ". \(note)" }
                return o
            }
            if let cur = fields(w)["CURRENT"], !cur.isEmpty, !target.isEmpty, !Version.isNewer(target, than: cur) {
                var o = UpdateOutcome(ok: true, message: "\(item.name) installed its own update to \(cur)", output: log, installed: cur)
                if relaunch && fields(w)["RUNNING"] != "1", let note = await reopenApp() { o.message += " (\(note))"; o.note = note }
                return o
            }
        }
        // Unload any lingering Squirrel ShipIt launchd job before Homebrew deletes and moves the app bundle.
        // The bundle ID is read on the machine itself, so this works on other Macs too.
        _ = await run(Self.stopShipItScript(app: item.path), 15, nil)
        r.showLines = true
        r.phase("Updating with Homebrew")
        if let f = r.runFile { Log.appendRun(f, "$ \(cmd)\n") }
        let prelude = Probe.unixPrelude(cachedPath: Engine.cachedPath(for: item.machine))
        let res = await Runner.run(item.machine, os: .mac, script: prelude + "set -e\n" + brewRefresh(item) + cmd + "\n", timeout: 1800, onOutput: r.sink)
        log += res.combined + "\n"
        r.showLines = false
        let note = relaunch && wasRunning ? await reopenApp() : nil
        if res.stdout.contains("BREW_REFRESHED\t") { noteBrewRefreshed(item) }
        guard res.ok else {
            var o = UpdateOutcome.fail(failure(res), output: log)
            o.timedOut = res.timedOut
            if let note { o.message += ". \(note)" }
            return o
        }
        var o = UpdateOutcome(ok: true, message: "Updated", output: log)
        if let note { o.message += " (\(note))"; o.note = note }
        return o
    }

    /// Unloads the app's Squirrel ShipIt launchd job, reading its bundle ID on the machine it runs on.
    static func stopShipItScript(app: String) -> String {
        """
        BID=$(defaults read \(Shell.q(app + "/Contents/Info")) CFBundleIdentifier 2>/dev/null || true)
        if [ -n "$BID" ]; then launchctl bootout "gui/$(id -u)/$BID.ShipIt" >/dev/null 2>&1 || true; fi

        """
    }

    // MARK: Reading failures

    /// The one line that says why a script failed: our own UPFAIL message (with the tool's error when it has one),
    /// else the most telling error line, else the last thing printed.
    static func failure(_ r: ShellResult) -> String {
        if r.cancelled { return "Cancelled" }
        if r.timedOut { return "Timed out" }
        func lines(_ s: String) -> [String] {
            ShellResult.collapse(s).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let err = lines(r.stderr), out = lines(r.stdout)
        func noise(_ l: String) -> Bool {
            l.hasPrefix("==> ") || isProgressBar(l) || l.contains("complete log of this run") || l.hasPrefix("npm notice")
        }
        var message: String
        if let i = err.lastIndex(where: { $0.hasPrefix("UPFAIL ") }) {
            message = String(err[i].dropFirst(7))
            if let detail = err[..<i].last(where: { !noise($0) && !$0.hasPrefix("UPFAIL") }), !message.contains(detail) {
                message += ": " + detail
            }
        } else if let e = err.first(where: { $0.contains("Error:") || $0.contains("error:") }) ?? err.first(where: { $0.lowercased().contains("error") }) {
            message = e
        } else if let last = err.last(where: { !noise($0) }) ?? out.last(where: { !noise($0) }) {
            message = last
        } else {
            message = "Exited with code \(r.status)"
        }
        if (r.stdout + r.stderr).contains("Could not detect the installation method") {
            // OpenCode's updater, on a binary copied over by Migration Assistant or by hand.
            message = "Its updater can't tell how it was installed (copied from another Mac?). Reinstall it once, then Update works."
        } else if message.contains("Operation not permitted") {
            message += " (allow Update pls in System Settings › Privacy & Security › App Management)"
        } else if message.lowercased().contains("unauthenticated") {
            // Cursor Agent's own updater refuses to run until you sign in on that machine.
            message = String(message.prefix(200)) + " (\(signInHint), then press Retry)"
        }
        return message.count > 360 ? String(message.prefix(360)) + "…" : message
    }

    static let signInHint = "sign in to it on that machine first"

    /// Whether a failure only means the tool wants someone to sign in to it first.
    static func needsSignIn(_ message: String) -> Bool { message.contains(signInHint) }

    static func isProgressBar(_ line: String) -> Bool {
        !line.isEmpty && line.range(of: #"^[#=O\- ]*(\d{1,3}(\.\d+)?%)?$"#, options: .regularExpression) != nil
    }
}
