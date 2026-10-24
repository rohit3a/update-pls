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

    static func fail(_ message: String, output: String = "") -> UpdateOutcome { UpdateOutcome(ok: false, message: message, output: output) }
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

    init(runFile: URL? = nil, onPhase: @escaping @Sendable (String, Double?) -> Void = { _, _ in }) {
        self.runFile = runFile
        self.onPhase = onPhase
    }

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
        if let v = version, let latest = item.latest?.version, Version.isNewer(latest, than: v) {
            // Update all would otherwise take it straight back to the latest.
            guard !skip.contains(key) else { return nil }
            skip.insert(key)
            hold.insert(key)
            return .added
        }
        guard hold.remove(key) != nil else { return nil }
        skip.remove(key)
        return .lifted
    }

    /// Skipping or un-skipping a tool by hand makes it your choice, not a rollback's.
    static func clearHold(_ key: String) {
        d.set(Array(held.subtracting([key])), forKey: "heldBackByRollback")
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
        let start = Date()
        Log.info("update \(item.key): \(item.summary)\(dryRun ? " (dry run)" : "")\(r.runFile.map { "\nrun log: \($0.path)" } ?? "")")
        var outcome: UpdateOutcome
        switch item.method {
        case .macDirect:
            if !dryRun, let info = item.latest, let copy = item.saved.first(where: { Version.clean($0) == Version.clean(info.version) }) {
                // Back to the latest after a rollback: that version is saved here already (its signature is checked again).
                outcome = await installMacApp(item, version: copy, from: .saved, exact: false, relaunch: relaunch, r)
            } else if let info = item.latest, info.url != nil {
                outcome = await installMacApp(item, version: info.version, from: .download(info), exact: false, relaunch: relaunch, r, dryRun: dryRun)
            } else {
                outcome = .fail("No download is published for this app")
            }
        case .cask where item.os == .mac: outcome = await updateCask(item, relaunch: relaunch, r)
        default: outcome = await runCommand(item, r)
        }
        finish(item, "update", &outcome, start)
        return outcome
    }

    /// Installs one exact version: an older one to roll back, or a newer saved one to go forward again.
    /// Mac apps come from a saved copy (checked: same bundle id, valid signature) or the publisher's release;
    /// other tools reinstall that version with their package manager.
    static func install(_ item: Item, version: String, from source: VersionSource, relaunch: Bool, reporter r: Reporter) async -> UpdateOutcome {
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
            let res = await Runner.run(item.machine, os: item.os, script: Probe.unixPrelude + "set -e\n" + cmd + "\n", timeout: 900, onOutput: r.sink)
            outcome = res.ok ? UpdateOutcome(ok: true, message: "Installed \(version)", output: res.combined, previous: item.installed)
                             : .fail(failure(res), output: res.combined)
            outcome.timedOut = res.timedOut
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

    /// CLIs and everything that has a single command: npm, brew, pipx, uv, bun, built-in updaters, winget.
    static func runCommand(_ item: Item, _ r: Reporter) async -> UpdateOutcome {
        var item = item
        if case let .npm(bin, prefix, pkg, _, w) = item.method {
            // Install the exact version we found, so nightly users stay on nightly.
            item.method = .npm(bin: bin, prefix: prefix, package: pkg, tag: item.latest?.version ?? "latest", writable: w)
        }
        guard let cmd = item.command else { return .fail("No way to update this automatically") }
        guard !item.needsSudo else { return .fail("Needs your password; copy the sudo command instead") }
        r.showLines = true
        r.phase("Updating with \(item.method.label)")
        if let f = r.runFile { Log.appendRun(f, "$ \(cmd)\n") }
        let script = item.os == .windows
            ? Probe.windowsPrelude + cmd + "\nexit $LASTEXITCODE\n"
            : Probe.unixPrelude + "set -e\n" + cmd + "\n"
        let res = await Runner.run(item.machine, os: item.os, script: script, timeout: 900, onOutput: r.sink)
        guard res.ok else {
            var o = UpdateOutcome.fail(failure(res), output: res.combined)
            o.timedOut = res.timedOut
            return o
        }
        return UpdateOutcome(ok: true, message: "Updated", output: res.combined,
                             previous: item.supportsRollback ? item.installed : nil)
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

        """
    }

    /// Prints the installed version, whether the app is open and whether it can be replaced without admin rights.
    /// Only the folder matters: the swap moves the whole bundle, which macOS allows even when App Management
    /// protection blocks writing inside it (so `-w "$APP"` would wrongly say no).
    /// Also lists updates the app's own updater has already downloaded (see `pending(_:)`).
    static func macStateScript(app: String, bundleID: String) -> String {
        macHeader(app: app, bundleID: bundleID) + """
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
                               local: String? = nil, trust: Bool = true) -> String {
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
            cp -c "$SRC" "$ST/dl" 2>/dev/null || cp "$SRC" "$ST/dl"
            \(unpack)
            """
        } else {
            fetch = """
            up_step \(Shell.q("Downloading \(name) \(info.version)"))
            curl -fL --retry 2 --connect-timeout 20 --speed-limit 4096 --speed-time 60 -# -o "$ST/dl" "$URL" || up_fail "Download failed"
            \(unpack)
            """
        }
        return macHeader(app: app, bundleID: bundleID) + """
        URL=\(Shell.q(url)); ST="$HOME/"\(Shell.q(stage))
        unmount() { if [ -d "$ST/mnt" ]; then hdiutil detach "$ST/mnt" -quiet -force >/dev/null 2>&1 || true; rmdir "$ST/mnt" 2>/dev/null || true; fi; }
        trap unmount EXIT
        rm -rf "$ST"; mkdir -p "$ST/x"
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
    /// Waits until no such updater has been seen for 4 seconds (5 minutes at most), then reports the version.
    static func macWaitUpdaterScript(app: String, bundleID: String, name: String) -> String {
        macHeader(app: app, bundleID: bundleID) + """
        updater_running() { ps -axo command= | grep -E 'ShipIt|Autoupdate|Updater|Installer|[Ss]parkle' | grep -F -e "$BID" -e "$APP/" | grep -v grep >/dev/null; }
        idle=0; seen=0
        for i in $(seq 1 600); do
          if updater_running; then
            idle=0
            if [ $seen = 0 ]; then seen=1; up_step \(Shell.q("\(name) is installing its own update")); fi
          else
            idle=$((idle + 1))
            if [ $idle -ge 8 ]; then break; fi
          fi
          sleep 0.5
        done
        report

        """
    }

    /// Swaps another version in: a checked download (`staged`) or a saved copy of `version`.
    /// The version it replaces is saved for rollback, and only the newest `keep` saved versions are kept.
    static func macSwapScript(app: String, bundleID: String, name: String, staged: String?, version: String,
                              stage: String, saved: String, keep: Int, trust: Bool = true) -> String {
        let appName = (app as NSString).lastPathComponent
        let source = staged.map { """
            NEW=\(Shell.q($0))
            [ -d "$NEW" ] || up_fail "The checked download is gone; press Retry"
            """ } ?? """
            NEW=""
            for c in "$SV"/*/"$AN" "$SV/$AN"; do
              if [ -d "$c" ] && [ "$(defaults read "$c/Contents/Info" CFBundleShortVersionString 2>/dev/null)" = "$WANT" ]; then NEW="$c"; break; fi
            done
            [ -n "$NEW" ] || up_fail "No saved copy of \(name) $WANT on this machine"
            [ "$(defaults read "$NEW/Contents/Info" CFBundleIdentifier)" = "$BID" ] || up_fail "The saved copy is a different app"
            \(trust ? #"codesign --verify --deep --strict "$NEW" || up_fail "The saved copy's signature is broken""# : "")
            """
        return macHeader(app: app, bundleID: bundleID) + """
        SV="$HOME/"\(Shell.q(saved)); ST="$HOME/"\(Shell.q(stage)); AN=\(Shell.q(appName)); WANT=\(Shell.q(version))
        up_step \(Shell.q("Installing \(name) \(version)"))
        \(source)
        if app_running; then up_fail \(Shell.q("\(name) is open again; quit it and press Retry")); fi
        mkdir -p "$SV"
        # Copies saved by Update pls 0.3 sit directly in the folder; file them under their version.
        if [ -d "$SV/$AN" ] && [ "$NEW" != "$SV/$AN" ]; then
          old=$(defaults read "$SV/$AN/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)
          rm -rf "$SV/$old/$AN"; mkdir -p "$SV/$old"; mv "$SV/$AN" "$SV/$old/$AN"
        fi
        CUR=$(current)
        KEEP="$SV/${CUR:-unknown}"
        rm -rf "$KEEP/$AN"; mkdir -p "$KEEP"
        echo "BACKUP	$CUR"
        mv "$APP" "$KEEP/$AN" || up_fail "Couldn't move the current version aside"
        if ! mv "$NEW" "$APP"; then rm -rf "$APP"; mv "$KEEP/$AN" "$APP"; up_fail "Couldn't install \(name) $WANT; the previous version was put back"; fi
        touch "$KEEP"
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
        NOW=$(current)
        echo "INSTALLED	$NOW"
        rm -rf "$ST"
        # A saved copy of the version now installed is only a duplicate.
        if [ -n "$NOW" ] && [ "$NOW" != "$CUR" ]; then rm -rf "$SV/$NOW"; fi
        \(macPruneSnippet(keep: keep))

        """
    }

    /// Keeps only the newest `keep` saved versions in "$SV".
    static func macPruneSnippet(keep: Int) -> String {
        """
        for d in "$SV"/*; do if [ -d "$d" ] && [ -z "$(ls -A "$d")" ]; then rmdir "$d"; fi; done
        n=0
        for d in $(ls -1t "$SV"); do
          n=$((n + 1))
          if [ $n -gt \(max(keep, 1)) ]; then rm -rf "$SV/$d"; fi
        done
        """
    }

    /// Clones the installed app before it quits (instant and free on APFS, a full copy elsewhere): an app that
    /// installs its own update on quit replaces itself without keeping the old version.
    static func macCloneScript(app: String, bundleID: String, stage: String) -> String {
        macHeader(app: app, bundleID: bundleID) + """
        ST="$HOME/"\(Shell.q(stage)); AN=\(Shell.q((app as NSString).lastPathComponent))
        rm -rf "$ST/pre"; mkdir -p "$ST/pre"
        if ! cp -cR "$APP" "$ST/pre/$AN" 2>/dev/null; then rm -rf "$ST/pre/$AN"; ditto "$APP" "$ST/pre/$AN"; fi
        echo "CLONED	$(defaults read "$ST/pre/$AN/Contents/Info" CFBundleShortVersionString)"

        """
    }

    /// Files the clone made before quitting under its version, once the app's own updater has replaced the app.
    static func macKeepCloneScript(app: String, bundleID: String, stage: String, saved: String, keep: Int) -> String {
        macHeader(app: app, bundleID: bundleID) + """
        ST="$HOME/"\(Shell.q(stage)); SV="$HOME/"\(Shell.q(saved)); AN=\(Shell.q((app as NSString).lastPathComponent))
        PRE="$ST/pre/$AN"
        [ -d "$PRE" ] || up_fail "The copy made before quitting is gone"
        V=$(defaults read "$PRE/Contents/Info" CFBundleShortVersionString)
        rm -rf "$SV/$V/$AN"; mkdir -p "$SV/$V"
        mv "$PRE" "$SV/$V/$AN"
        touch "$SV/$V"
        echo "BACKUP	$V"
        NOW=$(current)
        if [ -n "$NOW" ] && [ "$NOW" != "$V" ]; then rm -rf "$SV/$NOW"; fi
        \(macPruneSnippet(keep: keep))

        """
    }

    static func macOpenScript(app: String, bundleID: String) -> String {
        macHeader(app: app, bundleID: bundleID) + "if ! app_running; then open -g \"$APP\"; fi\n"
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

    static func reopen(_ item: Item, app: String, bundleID: String, _ r: Reporter, run: ScriptRunner) async {
        r.phase("Reopening \(item.name)")
        let res = await run(macOpenScript(app: app, bundleID: bundleID), 60, r.sink)
        if !res.ok { Log.error("reopen \(item.key): \(failure(res))") }
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
            var o = UpdateOutcome.fail(failure(res), output: log)
            o.timedOut = res.timedOut
            return o
        }
        func done(_ current: String?) -> Bool {
            guard let c = current, !c.isEmpty else { return false }
            return exact ? c == target : !Version.isNewer(target, than: c)
        }
        func discard() async { _ = await run("rm -rf \"$HOME/\"\(Shell.q(stage))", 60, nil) }

        r.phase("Checking \(name)")
        let (s0, f0) = await step(macStateScript(app: app, bundleID: bid), 60)
        guard s0.ok else { return failed(s0) }
        // A dry run always downloads and checks the build, to prove the update would work.
        if done(f0["CURRENT"]) && !dryRun {
            return UpdateOutcome(ok: true, message: "Already on \(f0["CURRENT"]!)", output: log, installed: f0["CURRENT"], changed: false)
        }
        if f0["WRITABLE"] == "0" && !dryRun {
            return .fail("Needs admin rights to replace apps in \((app as NSString).deletingLastPathComponent)", output: log)
        }

        var staged: String?
        var wasRunning = f0["RUNNING"] == "1"
        if case let .download(info) = source {
            // The app's own updater may have this version ready already: no need to download it again.
            let ready = pending(s0)
            let local = ready.apps.first { Version.clean($0.version) == Version.clean(target) }?.path
                ?? info.sha512Base64.flatMap { h in ready.zips.first { $0.sha512 == h }?.path }
            guard let url = info.url ?? local else { return .fail("No download is published for \(target)", output: log) }
            if let local { Log.info("\(item.key): using the update \(name) already downloaded: \(local)") }
            var (s1, f1) = await step(macStageScript(app: app, bundleID: bid, name: name, url: url, info: info, stage: stage,
                                                     local: local, trust: trust), 3600)
            // The app's copy may be mid-way through being patched, or not what it seemed: download it after all.
            if local != nil, let url = info.url,
               !s1.ok || f1["STAGED"] == nil || Version.clean(f1["STAGED_VERSION"] ?? "") != Version.clean(target) {
                Log.info("\(item.key): the update \(name) already downloaded didn't check out (\(s1.ok ? "version \(f1["STAGED_VERSION"] ?? "?")" : failure(s1))); downloading it")
                (s1, f1) = await step(macStageScript(app: app, bundleID: bid, name: name, url: url, info: info, stage: stage, trust: trust), 3600)
            }
            guard s1.ok, let path = f1["STAGED"] else { return failed(s1) }
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
            wasRunning = f1["RUNNING"] == "1"
        }

        // Whatever goes wrong from here, an app that was open is opened again (the old version is still in place).
        func giveUp(_ o: UpdateOutcome) async -> UpdateOutcome {
            await discard()
            if relaunch && wasRunning { await reopen(item, app: app, bundleID: bid, r, run: run) }
            return o
        }
        if wasRunning {
            let (sc, fc) = await step(macCloneScript(app: app, bundleID: bid, stage: stage), 300)
            if !sc.ok { Log.error("\(item.key): couldn't copy \(name) before quitting: \(failure(sc))") }
            if let err = await quitApp(item, app: app, bundleID: bid, r, run: run, log: &log) {
                await discard()
                return .fail(err, output: log)
            }
            r.phase("Making sure \(name) isn't installing its own update")
            let (s2, f2) = await step(macWaitUpdaterScript(app: app, bundleID: bid, name: name), 400)
            guard s2.ok else { return await giveUp(failed(s2)) }
            // Its own updater replaced it: keep the copy so it can still be rolled back.
            var kept: String?
            if let c = fc["CLONED"], !c.isEmpty, let now = f2["CURRENT"], !now.isEmpty, now != c {
                let (sk, fk) = await step(macKeepCloneScript(app: app, bundleID: bid, stage: stage, saved: savedPath(item), keep: keep), 120)
                if sk.ok { kept = fk["BACKUP"] } else { Log.error("\(item.key): couldn't keep \(c) for rollback: \(failure(sk))") }
            }
            if !exact && done(f2["CURRENT"]) {
                await discard()
                if relaunch && f2["RUNNING"] != "1" { await reopen(item, app: app, bundleID: bid, r, run: run) }
                return UpdateOutcome(ok: true, message: "\(name) installed its own update to \(f2["CURRENT"]!)", output: log,
                                     previous: kept, installed: f2["CURRENT"])
            }
            // Its updater may have reopened it; quit it once more.
            if f2["RUNNING"] == "1", let err = await quitApp(item, app: app, bundleID: bid, r, run: run, log: &log) {
                return await giveUp(.fail(err, output: log))
            }
        }

        let (s3, f3) = await step(macSwapScript(app: app, bundleID: bid, name: name, staged: staged, version: target, stage: stage,
                                                saved: savedPath(item), keep: keep, trust: trust), 600)
        guard s3.ok else { return await giveUp(failed(s3)) }
        if relaunch && wasRunning { await reopen(item, app: app, bundleID: bid, r, run: run) }
        let installed = f3["INSTALLED"].flatMap { $0.isEmpty ? nil : $0 }
        let previous = f3["BACKUP"].flatMap { $0.isEmpty ? nil : $0 }
        return UpdateOutcome(ok: true, message: "\(verb) \(installed ?? target)", output: log, previous: previous, installed: installed)
    }

    /// Apps installed with Homebrew: same quit-and-wait as above, then `brew upgrade --cask`.
    static func updateCask(_ item: Item, relaunch: Bool, _ r: Reporter) async -> UpdateOutcome {
        guard case .cask = item.method, let cmd = item.command else { return .fail("Not a Homebrew app") }
        let run = macRunner(item)
        let bid = item.machine.isLocal ? Bundle(path: item.path)?.bundleIdentifier ?? "" : ""
        var log = ""
        let target = item.latest?.version ?? ""
        r.phase("Checking \(item.name)")
        let s0 = await run(macStateScript(app: item.path, bundleID: bid), 60, r.sink)
        log += s0.combined + "\n"
        guard s0.ok else { return .fail(failure(s0), output: log) }
        let wasRunning = fields(s0)["RUNNING"] == "1"
        if wasRunning {
            if let err = await quitApp(item, app: item.path, bundleID: bid, r, run: run, log: &log) { return .fail(err, output: log) }
            let w = await run(macWaitUpdaterScript(app: item.path, bundleID: bid, name: item.name), 400, r.sink)
            log += w.combined + "\n"
            if let cur = fields(w)["CURRENT"], !cur.isEmpty, !target.isEmpty, !Version.isNewer(target, than: cur) {
                if relaunch && fields(w)["RUNNING"] != "1" { await reopen(item, app: item.path, bundleID: bid, r, run: run) }
                return UpdateOutcome(ok: true, message: "\(item.name) installed its own update to \(cur)", output: log, installed: cur)
            }
        }
        r.showLines = true
        r.phase("Updating with Homebrew")
        if let f = r.runFile { Log.appendRun(f, "$ \(cmd)\n") }
        let res = await Runner.run(item.machine, os: .mac, script: Probe.unixPrelude + "set -e\n" + cmd + "\n", timeout: 1800, onOutput: r.sink)
        log += res.combined + "\n"
        r.showLines = false
        if relaunch && wasRunning { await reopen(item, app: item.path, bundleID: bid, r, run: run) }
        guard res.ok else { var o = UpdateOutcome.fail(failure(res), output: log); o.timedOut = res.timedOut; return o }
        return UpdateOutcome(ok: true, message: "Updated", output: log)
    }

    // MARK: Reading failures

    /// The one line that says why a script failed: our own UPFAIL message (with the tool's error when it has one),
    /// else the most telling error line, else the last thing printed.
    static func failure(_ r: ShellResult) -> String {
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
        if message.contains("Operation not permitted") {
            message += " (allow Update pls in System Settings › Privacy & Security › App Management)"
        }
        return message.count > 360 ? String(message.prefix(360)) + "…" : message
    }

    static func isProgressBar(_ line: String) -> Bool {
        !line.isEmpty && line.range(of: #"^[#=O\- ]*(\d{1,3}(\.\d+)?%)?$"#, options: .regularExpression) != nil
    }
}
