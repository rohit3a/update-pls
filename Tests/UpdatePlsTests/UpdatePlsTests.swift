import XCTest
@testable import UpdatePls

final class UpdatePlsTests: XCTestCase {
    func testVersionExtract() {
        XCTAssertEqual(Version.extract("2.1.303 (Claude Code)"), "2.1.303")
        XCTAssertEqual(Version.extract("codex-cli 0.163.0"), "0.163.0")
        XCTAssertEqual(Version.extract("t3 v0.0.46-nightly.20261005.2676"), "0.0.46-nightly.20261005.2676")
        XCTAssertEqual(Version.extract("2026.10.01-e373342"), "2026.10.01-e373342")
    }

    func testVersionCompare() {
        XCTAssertTrue(Version.isNewer("3.25.9,5d4df96", than: "3.22.12"))
        XCTAssertFalse(Version.isNewer("2.42304.2,af65c0e", than: "2.42304.2"))
        XCTAssertTrue(Version.isNewer("0.1.1-nightly.20261019.3360", than: "0.1.1-nightly.20261018.3331"))
        XCTAssertTrue(Version.isNewer("2026.10.16-e3cb207", than: "2026.10.01-e373342"))
        XCTAssertTrue(Version.isNewer("1.0.0", than: "1.0.0-beta.2"))
        XCTAssertFalse(Version.isNewer("v0.163.0", than: "0.163.0"))
        // Versions read from an app mid-install must not crash the comparison.
        for odd in ["", "-", "v", "-beta", "1.0-"] {
            _ = Version.isNewer(odd, than: "1.0.0")
            _ = Version.isNewer("1.0.0", than: odd)
        }
        XCTAssertFalse(Version.isNewer("", than: ""))
        XCTAssertEqual(Version.channel("0.1.1-nightly.2026"), "nightly")
        XCTAssertNil(Version.channel("2026.10.01-e373342".replacingOccurrences(of: "e", with: "1")))
    }

    func testProbeParse() {
        let out = "OS\tDarwin\tarm64\nBREW\t/opt/homebrew/bin/brew\nCASKS\tcursor zed \n" +
            "CLI\tcodex\tcodex\t/u/.local/bin/codex\t/u/.local/lib/node_modules/@openai/codex/bin/codex.js\tcodex-cli 0.163.0\t@openai/codex\t0.163.0\t/u/.local/bin/npm\t1\n" +
            "CLI\tclaude-code\tclaude\t/u/.local/bin/claude\t/u/.local/share/claude/versions/2.1.303\t2.1.303 (Claude Code)\t\t\t\t0\n" +
            "APP\tcursor\tCursor\t/Applications/Cursor.app\t3.22.12\tcom.todesktop.x\t1\n" +
            "SAVED\tcursor\tCursor\t3.21.0\nSAVED\tcursor\tCursor\t3.22.1\nSAVED\tcursor\tOther\t9.9\n"
        let p = Probe.parse(out)
        XCTAssertEqual(p.os, .mac)
        XCTAssertTrue(p.casks.contains("cursor"))
        let items = Engine.buildItems(p, machine: .local, catalog: Catalog.bundled())
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].method, .npm(bin: "/u/.local/bin/npm", prefix: "/u/.local", package: "@openai/codex", tag: "latest", writable: true))
        XCTAssertEqual(items[1].method, .selfUpdate(path: "/u/.local/bin/claude", args: "update"))
        XCTAssertEqual(items[1].installed, "2.1.303")
        XCTAssertEqual(items[2].method, .cask("cursor"))
        XCTAssertTrue(items[2].running)
        XCTAssertEqual(items[2].saved, ["3.22.1", "3.21.0"], "saved versions, newest first, only this app's")
        XCTAssertEqual(items[2].arch, "arm64")
    }

    /// apt apps are found, and updated by Update pls only where sudo needs no password.
    func testLinuxDebApps() {
        let out = "OS\tLinux\tx86_64\nSUDO\t1\nDEB\tclaude-desktop\tclaude-desktop\t3.1623.0\t3.6556.1\n" +
            "DEB\tcodex-app\tchatgpt\t26.928.20755\t26.928.20755\t1\n"
        let items = Engine.buildItems(Probe.parse(out), machine: Machine(id: "rog", name: "rog"), catalog: Catalog.bundled())
        XCTAssertEqual(items.map(\.name), ["Claude Desktop", "Codex App (ChatGPT)"])
        XCTAssertEqual(items.map(\.running), [false, true])
        XCTAssertEqual(Engine.state(items[0]), .available)
        XCTAssertTrue(items[0].canUpdate)
        XCTAssertEqual(items[0].command, "sudo -n apt-get update -q && sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y 'claude-desktop'")
        let asks = Engine.buildItems(Probe.parse(out.replacingOccurrences(of: "SUDO\t1\n", with: "")), machine: Machine(id: "rog", name: "rog"),
                                     catalog: Catalog.bundled())
        XCTAssertTrue(asks[0].needsSudo)
        XCTAssertFalse(asks[0].canUpdate, "a password is never typed for you: shown as a command to copy")
    }

    func testWingetParse() {
        let lines = [
            "\r   - \r   \\ \r",
            "Name                 Id                       Version      Available    Source",
            "-------------------------------------------------------------------------------",
            "Claude               Anthropic.Claude         1.0.2        1.0.5        winget",
            "Cursor (User)        Anysphere.Cursor         3.22.12                   winget",
            "Some App             ARP\\Machine\\X64\\Foo     2.0",
        ]
        let rows = Probe.parseWinget(lines)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].id, "Anthropic.Claude")
        XCTAssertEqual(rows[0].available, "1.0.5")
        XCTAssertEqual(rows[1].available, "")
        let items = Engine.buildItems(ProbeResult(os: .windows, winget: rows), machine: .local, catalog: Catalog.bundled())
        let claude = items.first { $0.defID == "claude-desktop" }
        XCTAssertEqual(claude?.method, .winget("Anthropic.Claude"))
        XCTAssertEqual(Engine.state(claude!), .available)
        XCTAssertEqual(items.first { $0.defID == "cursor" }?.method, .winget("Anysphere.Cursor"))
    }

    func testElectronYml() {
        let yml = """
        version: '0.1.1-nightly.20261019.3360'
        files:
          - url: T3-Code-0.1.1-arm64.zip
            sha512: abc==
            size: 1
          - url: T3-Code-0.1.1-x64.zip
            sha512: def==
        path: T3-Code-0.1.1-arm64.zip
        sha512: abc==
        """
        let (v, files) = LatestResolver.parseElectronYml(yml)
        XCTAssertEqual(v, "0.1.1-nightly.20261019.3360")
        XCTAssertEqual(files.map(\.url), ["T3-Code-0.1.1-arm64.zip", "T3-Code-0.1.1-x64.zip"])
        XCTAssertEqual(files.first?.sha512, "abc==")
    }

    func testRollback() throws {
        func item(_ m: UpdatePls.Method, install: String? = nil) -> Item {
            Item(machine: .local, os: .mac, defID: "t", name: "T", brand: "T", isApp: false, path: "/Applications/T.app",
                 installed: "2.0.0", method: m, installVersion: install)
        }
        let npm = item(.npm(bin: "/u/bin/npm", prefix: "/u", package: "@openai/codex", tag: "latest", writable: true))
        XCTAssertEqual(npm.rollbackCommand(to: "0.162.0"),
                       "'/u/bin/npm' install -g --prefix '/u' --allow-scripts='@openai/codex' '@openai/codex@0.162.0'")
        let claude = item(.selfUpdate(path: "/u/bin/claude", args: "update"), install: "install {version} --force")
        XCTAssertEqual(claude.rollbackCommand(to: "2.1.300"), "'/u/bin/claude' install 2.1.300 --force")
        XCTAssertFalse(item(.selfUpdate(path: "/u/bin/t3", args: "update")).supportsRollback)
        XCTAssertFalse(item(.cask("cursor")).supportsRollback)
        XCTAssertFalse(item(.npm(bin: "npm", prefix: "/usr", package: "x", tag: "latest", writable: false)).supportsRollback)
        XCTAssertEqual(item(.cask("cursor")).command, "brew upgrade --cask --greedy 'cursor'")

        // Every Mac app script must parse.
        let app = item(.macDirect(appPath: "/Applications/T.app", bundleID: "com.t"))
        XCTAssertTrue(app.supportsRollback)
        let info = LatestInfo(version: "3", url: "https://x/T.zip", sha256: "abc")
        for script in [
            Engine.macStateScript(app: app.path, bundleID: "com.t"),
            Engine.macStageScript(app: app.path, bundleID: "com.t", name: "T", url: "https://x/T.zip", info: info, stage: Engine.stagingPath(app)),
            Engine.macQuitScript(app: app.path, bundleID: "com.t", name: "T"),
            Engine.macWaitUpdaterScript(app: app.path, bundleID: "com.t", name: "T"),
            Engine.macSwapScript(app: app.path, bundleID: "com.t", name: "T", staged: "/tmp/x.app", version: "3", stage: Engine.stagingPath(app),
                                 saved: Engine.savedPath(app), keep: 3),
            Engine.macSwapScript(app: app.path, bundleID: "com.t", name: "T", staged: nil, version: "1", stage: Engine.stagingPath(app),
                                 saved: Engine.savedPath(app), keep: 3),
            Engine.macOpenScript(app: app.path, bundleID: "com.t"),
            Engine.macStateScript(app: app.path, bundleID: "com.t", marker: Engine.swapMarkerPath(app)),
            Engine.macStageScript(app: app.path, bundleID: "com.t", name: "T", url: "x", info: info, stage: Engine.stagingPath(app), local: "/tmp/T.app"),
            Engine.macStageScript(app: app.path, bundleID: "com.t", name: "T", url: "x", info: info, stage: Engine.stagingPath(app), local: "/tmp/T.zip"),
            Engine.macCloneScript(app: app.path, bundleID: "com.t", stage: Engine.stagingPath(app)),
            Engine.macKeepCloneScript(app: app.path, bundleID: "com.t", stage: Engine.stagingPath(app), saved: Engine.savedPath(app), keep: 3),
            Engine.macRecoverScript(marker: Engine.swapMarkerPath(app)),
            Probe.debFunctions + "up_deb_running chatgpt || true\n",
        ] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-n", "-c", "{\n" + script + "\n} </dev/null"]
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, script)
        }
    }

    /// Switches a stand-in app between saved copies, back and forward, inside a throwaway home folder.
    func testSwitchBetweenSavedVersions() async throws {
        let sandbox = try Sandbox()
        let item = sandbox.item(installed: "2")
        let saved = sandbox.home.appendingPathComponent(Engine.savedPath(item))
        try sandbox.makeApp(at: sandbox.app, version: "2")
        // A copy saved by 0.3 sits directly in the folder; it is found and filed under its version.
        try sandbox.makeApp(at: saved.appendingPathComponent("T.app"), version: "1")

        var o = await Engine.installMacApp(item, version: "1", from: .saved, exact: true, relaunch: false, Reporter(), run: sandbox.runner)
        XCTAssertTrue(o.ok, o.message + o.output)
        XCTAssertEqual(o.message, "Switched to 1")
        XCTAssertEqual(o.previous, "2")
        XCTAssertEqual(sandbox.version(sandbox.app), "1")
        XCTAssertEqual(sandbox.version(saved.appendingPathComponent("2/T.app")), "2", "the replaced version is saved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.appendingPathComponent("1").path))

        // And forward again.
        o = await Engine.installMacApp(item, version: "2", from: .saved, exact: true, relaunch: false, Reporter(), run: sandbox.runner)
        XCTAssertTrue(o.ok, o.message + o.output)
        XCTAssertEqual(sandbox.version(sandbox.app), "2")
        XCTAssertEqual(sandbox.version(saved.appendingPathComponent("1/T.app")), "1")

        // A version that was never saved is refused and the app is left alone.
        o = await Engine.installMacApp(item, version: "0.9", from: .saved, exact: true, relaunch: false, Reporter(), run: sandbox.runner)
        XCTAssertFalse(o.ok)
        XCTAssertEqual(o.message, "No saved copy of T 0.9 on this machine")
        XCTAssertEqual(sandbox.version(sandbox.app), "2")
    }

    /// Only the newest `keep` replaced versions stay on disk.
    func testSavedVersionsArePruned() async throws {
        let sandbox = try Sandbox()
        try sandbox.makeApp(at: sandbox.app, version: "1")
        var item = sandbox.item(installed: "1")
        for v in ["2", "3", "4"] {
            let zip = try sandbox.zippedApp(version: v)
            item.latest = LatestInfo(version: v, url: zip.absoluteString)
            let o = await Engine.installMacApp(item, version: v, from: .download(item.latest!), exact: false, relaunch: false, Reporter(),
                                               trust: false, keep: 2, run: sandbox.runner)
            XCTAssertTrue(o.ok, o.message + o.output)
            try await Task.sleep(for: .milliseconds(1100))  // folder times have one-second resolution
        }
        let saved = sandbox.home.appendingPathComponent(Engine.savedPath(item))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: saved.path).sorted(), ["2", "3"])
        XCTAssertEqual(sandbox.version(sandbox.app), "4")
    }

    /// The whole download, check and swap with a stand-in app served from a file:// URL.
    func testMacAppUpdateInstallsAndKeepsBackup() async throws {
        let sandbox = try Sandbox()
        try sandbox.makeApp(at: sandbox.app, version: "1.0")
        let zip = try sandbox.zippedApp(version: "2.0")
        let sha = try sandbox.sha256(zip)
        var item = sandbox.item(installed: "1.0")
        item.latest = LatestInfo(version: "2.0", url: zip.absoluteString, sha256: sha)
        // An old saved copy of the version being installed only duplicates it once it's in place.
        let saved = sandbox.home.appendingPathComponent(Engine.savedPath(item))
        try sandbox.makeApp(at: saved.appendingPathComponent("2.0/T.app"), version: "2.0")

        let phases = Box<[String]>([])
        let r = Reporter { text, _ in phases.mutate { $0.append(text) } }
        let o = await Engine.installMacApp(item, version: "2.0", from: .download(item.latest!), exact: false, relaunch: false, r,
                                           trust: false, run: sandbox.runner)
        XCTAssertTrue(o.ok, o.message + "\n" + o.output)
        XCTAssertEqual(o.message, "Updated to 2.0")
        XCTAssertEqual(o.previous, "1.0")
        XCTAssertEqual(sandbox.version(sandbox.app), "2.0")
        XCTAssertEqual(sandbox.version(saved.appendingPathComponent("1.0/T.app")), "1.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.appendingPathComponent("2.0").path), "duplicate of the installed version")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.home.appendingPathComponent(Engine.stagingPath(item)).path),
                       "staging is cleaned up")
        let seen = phases.value
        for step in ["Downloading T 2.0", "Checking the download", "Unpacking", "Checking signature", "Installing T 2.0"] {
            XCTAssertTrue(seen.contains(step), "missing step \(step) in \(seen)")
        }
    }

    /// A version the app's own updater (ShipIt, Sparkle) already has ready is used instead of downloading it again.
    /// Its leftovers from older updates are ignored, and its own copy is left where it is.
    func testMacAppUpdateUsesUpdateTheAppAlreadyDownloaded() async throws {
        let sandbox = try Sandbox()
        try sandbox.makeApp(at: sandbox.app, version: "1.0")
        let caches = sandbox.home.appendingPathComponent("Library/Caches")
        let ready = caches.appendingPathComponent("com.example.t.ShipIt/update.abc/T.app")
        try sandbox.makeApp(at: ready, version: "2.0")
        try sandbox.makeApp(at: caches.appendingPathComponent("com.example.t/org.sparkle-project.Sparkle/Installation/x/y/T.app"), version: "1.5")
        var item = sandbox.item(installed: "1.0")
        // Nothing to download from: the update has to come from the ready copy.
        item.latest = LatestInfo(version: "2.0", url: "file:///nonexistent/T-2.0.zip")
        let phases = Box<[String]>([])
        let o = await Engine.installMacApp(item, version: "2.0", from: .download(item.latest!), exact: false, relaunch: false,
                                           Reporter { text, _ in phases.mutate { $0.append(text) } }, trust: false, run: sandbox.runner)
        XCTAssertTrue(o.ok, o.message + "\n" + o.output)
        XCTAssertEqual(o.message, "Updated to 2.0")
        XCTAssertEqual(sandbox.version(sandbox.app), "2.0")
        XCTAssertTrue(phases.value.contains("Using the update T already downloaded"), "\(phases.value)")
        XCTAssertFalse(phases.value.contains { $0.hasPrefix("Downloading") })
        XCTAssertEqual(sandbox.version(ready), "2.0", "the updater's own copy stays")
    }

    /// A ready copy that turns out not to be the right build (say, Sparkle is still patching it) is dropped for a download.
    func testMacAppUpdateDownloadsWhenTheAppsCopyDoesntCheckOut() async throws {
        let sandbox = try Sandbox()
        try sandbox.makeApp(at: sandbox.app, version: "1.0")
        let ready = sandbox.home.appendingPathComponent("Library/Caches/com.example.t/org.sparkle-project.Sparkle/Installation/x/y/T.app")
        try sandbox.makeApp(at: ready, version: "2.0")
        let zip = try sandbox.zippedApp(version: "2.0")
        var item = sandbox.item(installed: "1.0")
        item.latest = LatestInfo(version: "2.0", url: zip.absoluteString, sha256: try sandbox.sha256(zip))
        let run: Engine.ScriptRunner = { script, timeout, out in
            if script.contains("Using the update") { try? Sandbox.writeInfo(ready, version: "1.9") }
            return await sandbox.runner(script, timeout, out)
        }
        let phases = Box<[String]>([])
        let o = await Engine.installMacApp(item, version: "2.0", from: .download(item.latest!), exact: false, relaunch: false,
                                           Reporter { text, _ in phases.mutate { $0.append(text) } }, trust: false, run: run)
        XCTAssertTrue(o.ok, o.message + "\n" + o.output)
        XCTAssertEqual(sandbox.version(sandbox.app), "2.0")
        XCTAssertTrue(phases.value.contains("Using the update T already downloaded") && phases.value.contains("Downloading T 2.0"), "\(phases.value)")
    }

    /// electron-updater's downloaded zip is used when its hash is the published one, and ignored otherwise.
    func testMacAppUpdateUsesElectronUpdaterZip() async throws {
        let sandbox = try Sandbox()
        try sandbox.makeApp(at: sandbox.app, version: "1.0")
        let zip = try sandbox.zippedApp(version: "2.0")
        let pending = sandbox.home.appendingPathComponent("Library/Caches/t-updater/pending")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: zip, to: pending.appendingPathComponent("T-2.0.zip"))
        let hash = await Shell.run("/bin/bash", ["-c", "openssl dgst -sha512 -binary \(Shell.q(zip.path)) | base64"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try #"{"fileName":"T-2.0.zip","sha512":"\#(hash)","isAdminRightsRequired":false}"#
            .write(to: pending.appendingPathComponent("update-info.json"), atomically: true, encoding: .utf8)
        var item = sandbox.item(installed: "1.0")
        item.latest = LatestInfo(version: "2.0", url: "file:///nonexistent/T-2.0.zip", sha512Base64: hash)
        var o = await Engine.installMacApp(item, version: "2.0", from: .download(item.latest!), exact: false, relaunch: false, Reporter(),
                                           trust: false, run: sandbox.runner)
        XCTAssertTrue(o.ok, o.message + "\n" + o.output)
        XCTAssertEqual(sandbox.version(sandbox.app), "2.0")

        // A different published hash means it's not that build: download it instead (and fail here, as there's nothing to download).
        try Sandbox.writeInfo(sandbox.app, version: "1.0")
        item.latest = LatestInfo(version: "2.0", url: "file:///nonexistent/T-2.0.zip", sha512Base64: "other")
        o = await Engine.installMacApp(item, version: "2.0", from: .download(item.latest!), exact: false, relaunch: false, Reporter(),
                                       trust: false, run: sandbox.runner)
        XCTAssertFalse(o.ok)
        XCTAssertEqual(o.message.components(separatedBy: ":").first, "Download failed")
    }

    func testItemLockAllowsOneUpdateAtATime() throws {
        let saved = ItemLock.dir
        ItemLock.dir = FileManager.default.temporaryDirectory.appendingPathComponent("up-locks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ItemLock.dir); ItemLock.dir = saved }
        let a = try XCTUnwrap(ItemLock.take("local/cursor"))
        XCTAssertNil(ItemLock.take("local/cursor"), "a second update of the same tool must wait")
        XCTAssertNotNil(ItemLock.take("local/antigravity"), "other tools aren't blocked")
        a.release()
        XCTAssertNotNil(ItemLock.take("local/cursor"))
    }

    /// A swap cut off between its two moves leaves the app missing; it is put back before anything else.
    func testInterruptedSwapIsRecovered() async throws {
        let sandbox = try Sandbox()
        try sandbox.makeApp(at: sandbox.app, version: "1.0")
        var item = sandbox.item(installed: "1.0")
        let kept = sandbox.home.appendingPathComponent(Engine.savedPath(item)).appendingPathComponent("1.0/T.app")
        func interrupt() throws {
            try sandbox.makeApp(at: kept, version: "1.0")
            try? FileManager.default.removeItem(at: sandbox.app)
            let marker = sandbox.home.appendingPathComponent(Engine.swapMarkerPath(item))
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(sandbox.app.path)\n\(kept.path)\n\(item.key)\n".write(to: marker, atomically: true, encoding: .utf8)
        }

        // At launch, unless another Update pls holds that tool's lock (its swap may be in progress).
        let savedLocks = ItemLock.dir
        ItemLock.dir = sandbox.home.appendingPathComponent("Locks")
        defer { ItemLock.dir = savedLocks }
        try interrupt()
        let held = try XCTUnwrap(ItemLock.take(item.key))
        var restored = await Engine.recoverInterruptedSwaps(home: sandbox.home, run: sandbox.runner)
        XCTAssertEqual(restored, [])
        XCTAssertNil(sandbox.version(sandbox.app))
        held.release()
        restored = await Engine.recoverInterruptedSwaps(home: sandbox.home, run: sandbox.runner)
        XCTAssertEqual(restored, [sandbox.app.path])
        XCTAssertEqual(sandbox.version(sandbox.app), "1.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.home.appendingPathComponent(Engine.swapMarkerPath(item)).path))

        // Or by the next update of that app, which then goes ahead.
        try interrupt()
        let zip = try sandbox.zippedApp(version: "2.0")
        item.latest = LatestInfo(version: "2.0", url: zip.absoluteString, sha256: try sandbox.sha256(zip))
        let o = await Engine.installMacApp(item, version: "2.0", from: .download(item.latest!), exact: false, relaunch: false, Reporter(),
                                           trust: false, run: sandbox.runner)
        XCTAssertTrue(o.ok, o.message + "\n" + o.output)
        XCTAssertEqual(o.previous, "1.0")
        XCTAssertEqual(sandbox.version(sandbox.app), "2.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.home.appendingPathComponent(Engine.swapMarkerPath(item)).path))
    }

    func testStagingNeedsFreeSpace() async throws {
        let sandbox = try Sandbox()
        try sandbox.makeApp(at: sandbox.app, version: "1.0")
        let zip = try sandbox.zippedApp(version: "2.0")
        let item = sandbox.item(installed: "1.0")
        let info = LatestInfo(version: "2.0", url: zip.absoluteString)
        let r = await sandbox.runner(Engine.macStageScript(app: sandbox.app.path, bundleID: "com.example.t", name: "T", url: zip.absoluteString,
                                                           info: info, stage: Engine.stagingPath(item), trust: false, reserveMB: 1 << 40), 60, nil)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(Engine.failure(r).hasPrefix("Not enough disk space: needs about"), Engine.failure(r))
        XCTAssertFalse(r.combined.contains("Downloading"), "fails before downloading")
    }

    /// GitHub's last answer stands in when it can't answer (here: a repo that doesn't exist).
    func testGitHubLastAnswerIsUsedWhenGitHubRefuses() async throws {
        let saved = GitHubCache.dir
        GitHubCache.dir = FileManager.default.temporaryDirectory.appendingPathComponent("up-gh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: GitHubCache.dir); GitHubCache.dir = saved }
        let url = "https://api.github.com/repos/update-pls-test/does-not-exist-\(UUID().uuidString)/releases/latest"
        let body = Data(#"{"tag_name":"v1.2.3"}"#.utf8)
        GitHubCache.save(url, nil, etag: "W/\"x\"", body: body)
        XCTAssertEqual(GitHubCache.load(url, nil)?.etag, "W/\"x\"")
        let got = await LatestResolver.get(url)
        XCTAssertEqual(got, body)
    }

    /// An app that wasn't open is updated in place and stays closed, even with reopening on.
    func testMacAppUpdateLeavesClosedAppClosed() async throws {
        let sandbox = try Sandbox()
        try sandbox.makeApp(at: sandbox.app, version: "1.0")
        let zip = try sandbox.zippedApp(version: "2.0")
        var item = sandbox.item(installed: "1.0")
        item.latest = LatestInfo(version: "2.0", url: zip.absoluteString, sha256: try sandbox.sha256(zip))
        let opened = Box(false)
        let run: Engine.ScriptRunner = { script, timeout, out in
            if script.contains("open -g") { opened.mutate { $0 = true } }
            return await sandbox.runner(script, timeout, out)
        }
        let o = await Engine.installMacApp(item, version: "2.0", from: .download(item.latest!), exact: false, relaunch: true, Reporter(),
                                           trust: false, run: run)
        XCTAssertTrue(o.ok, o.message + "\n" + o.output)
        XCTAssertEqual(sandbox.version(sandbox.app), "2.0")
        XCTAssertFalse(opened.value, "a closed app must not be opened")
    }

    /// An app that already updated itself is left alone: no download, no quit.
    func testMacAppUpdateSkipsWhenAlreadyCurrent() async throws {
        let sandbox = try Sandbox()
        try sandbox.makeApp(at: sandbox.app, version: "3.0")
        var item = sandbox.item(installed: "2.0")
        item.latest = LatestInfo(version: "3.0", url: "file:///nonexistent/T.zip")
        let o = await Engine.installMacApp(item, version: "3.0", from: .download(item.latest!), exact: false, relaunch: false, Reporter(),
                                           trust: false, run: sandbox.runner)
        XCTAssertTrue(o.ok)
        XCTAssertEqual(o.message, "Already on 3.0")
        XCTAssertFalse(o.changed)
    }

    /// If the app updates itself while the download runs, the download is thrown away.
    func testMacAppUpdateNoticesSelfUpdateDuringDownload() async throws {
        let sandbox = try Sandbox()
        try sandbox.makeApp(at: sandbox.app, version: "1.0")
        let zip = try sandbox.zippedApp(version: "2.0")
        var item = sandbox.item(installed: "1.0")
        item.latest = LatestInfo(version: "2.0", url: zip.absoluteString)
        let app = sandbox.app
        let runner: Engine.ScriptRunner = { script, timeout, out in
            if script.contains("Downloading") { try? Sandbox.writeInfo(app, version: "2.0") }
            return await sandbox.runner(script, timeout, out)
        }
        let o = await Engine.installMacApp(item, version: "2.0", from: .download(item.latest!), exact: false, relaunch: false, Reporter(),
                                           trust: false, run: runner)
        XCTAssertTrue(o.ok, o.output)
        XCTAssertEqual(o.message, "T updated itself to 2.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.home.appendingPathComponent(Engine.savedPath(item)).path))
    }

    /// An open app whose own updater replaces it on quit: the version it was on is still kept for rollback.
    func testMacAppUpdateKeepsVersionReplacedByAppsOwnUpdater() async throws {
        let sandbox = try Sandbox()
        try sandbox.makeApp(at: sandbox.app, version: "1.0")
        let zip = try sandbox.zippedApp(version: "2.0")
        var item = sandbox.item(installed: "1.0")
        item.latest = LatestInfo(version: "2.0", url: zip.absoluteString)
        let app = sandbox.app
        let runner: Engine.ScriptRunner = { script, timeout, out in
            if script.contains("updater_running()") { try? Sandbox.writeInfo(app, version: "2.0") }
            var res = await sandbox.runner(script, timeout, out)
            // Pretend it's open until it is asked to quit.
            if script.contains("Downloading") { res.stdout = res.stdout.replacingOccurrences(of: "RUNNING\t0", with: "RUNNING\t1") }
            return res
        }
        let o = await Engine.installMacApp(item, version: "2.0", from: .download(item.latest!), exact: false, relaunch: false, Reporter(),
                                           trust: false, run: runner)
        XCTAssertTrue(o.ok, o.output)
        XCTAssertEqual(o.message, "T installed its own update to 2.0")
        XCTAssertEqual(o.previous, "1.0")
        XCTAssertEqual(sandbox.version(sandbox.app), "2.0")
        XCTAssertEqual(sandbox.version(sandbox.home.appendingPathComponent(Engine.savedPath(item)).appendingPathComponent("1.0/T.app")), "1.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.home.appendingPathComponent(Engine.stagingPath(item)).path))
    }

    func testMacAppUpdateFailuresSayWhy() async throws {
        let sandbox = try Sandbox()
        try sandbox.makeApp(at: sandbox.app, version: "1.0")
        var item = sandbox.item(installed: "1.0")

        item.latest = LatestInfo(version: "2.0", url: sandbox.home.appendingPathComponent("missing.zip").absoluteString)
        var o = await Engine.installMacApp(item, version: "2.0", from: .download(item.latest!), exact: false, relaunch: false, Reporter(),
                                           trust: false, run: sandbox.runner)
        XCTAssertFalse(o.ok)
        XCTAssertTrue(o.message.hasPrefix("Download failed: curl: (37)"), o.message)

        let zip = try sandbox.zippedApp(version: "2.0")
        item.latest = LatestInfo(version: "2.0", url: zip.absoluteString, sha256: String(repeating: "0", count: 64))
        o = await Engine.installMacApp(item, version: "2.0", from: .download(item.latest!), exact: false, relaunch: false, Reporter(),
                                       trust: false, run: sandbox.runner)
        XCTAssertFalse(o.ok)
        XCTAssertEqual(o.message, "Checksum mismatch: the download isn't what the publisher lists")
        XCTAssertEqual(sandbox.version(sandbox.app), "1.0", "a failed update leaves the app alone")
    }

    func testFailureMessages() {
        XCTAssertEqual(Engine.failure(ShellResult(status: 1, stdout: "==> Unpacking\n", stderr: "ditto: Couldn't read PKZip signature\nUPFAIL Couldn't unpack the download\n")),
                       "Couldn't unpack the download: ditto: Couldn't read PKZip signature")
        let npm = """
        npm error code EACCES
        npm error syscall mkdir
        npm error Error: EACCES: permission denied, mkdir '/usr/lib/node_modules/x'
        npm error A complete log of this run can be found in: /u/.npm/_logs/1.log
        """
        XCTAssertEqual(Engine.failure(ShellResult(status: 243, stdout: "", stderr: npm)),
                       "npm error Error: EACCES: permission denied, mkdir '/usr/lib/node_modules/x'")
        XCTAssertEqual(Engine.failure(ShellResult(status: 2, stdout: "", stderr: "")), "Exited with code 2")
        XCTAssertEqual(Engine.failure(ShellResult(status: 15, stdout: "", stderr: "", timedOut: true)), "Timed out")
    }

    func testReporterProgress() {
        let got = Box<[(String, Double?)]>([])
        let r = Reporter { t, f in got.mutate { $0.append((t, f)) } }
        r.output("==> Downloading Claude 3.6\n")
        r.output("#####          31.")
        r.output("4%\r########     52.0%\r")
        r.output("==> Unpacking\n")
        let seen = got.value
        XCTAssertEqual(seen.map(\.0), ["Downloading Claude 3.6", "Downloading Claude 3.6", "Downloading Claude 3.6", "Unpacking"])
        XCTAssertEqual(seen.map(\.1), [nil, 0.314, 0.52, nil], "a number split across chunks is read whole")
        XCTAssertEqual(Reporter.percent("##O#- 12.5%"), 0.125)
        XCTAssertNil(Reporter.percent("installed 100%"))
    }

    /// A timeout stops the script and everything it started, instead of leaving them running.
    func testShellTimeoutKillsChildren() async throws {
        let marker = "up-test-\(UUID().uuidString)"
        let start = Date()
        let r = await Shell.run("/bin/bash", ["-c", "sleep 300 & exec -a \(marker) sleep 300"], timeout: 1)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        try await Task.sleep(for: .seconds(4))
        let ps = await Shell.run("/bin/ps", ["-axo", "command="])
        XCTAssertFalse(ps.stdout.contains(marker))
    }

    func testShellStreamsOutput() async {
        let chunks = Box("")
        let r = await Shell.run("/bin/bash", ["-c", "echo one; sleep 0.2; echo two >&2"]) { c in chunks.mutate { $0 += c } }
        XCTAssertTrue(r.ok)
        let all = chunks.value
        XCTAssertTrue(all.contains("one") && all.contains("two"))
        XCTAssertEqual(r.stdout, "one\n")
        XCTAssertEqual(r.stderr, "two\n")
    }

    func testDetectOS() {
        XCTAssertEqual(Runner.classify(ShellResult(status: 0, stdout: "Darwin\n", stderr: "")), .os(.mac))
        XCTAssertEqual(Runner.classify(ShellResult(status: 0, stdout: "Linux\n", stderr: "")), .os(.linux))
        XCTAssertEqual(Runner.classify(ShellResult(status: 1, stdout: "", stderr: "'uname' is not recognized as an internal or external command")), .os(.windows))
        XCTAssertEqual(Runner.classify(ShellResult(status: 255, stdout: "", stderr: "ssh: connect to host x port 22: Connection refused")),
                       .offline("ssh: connect to host x port 22: Connection refused"))
        guard case .offline = Runner.classify(ShellResult(status: 127, stdout: "", stderr: "bash: uname: command not found")) else {
            return XCTFail("a broken shell must not be treated as Windows")
        }
    }

    func testLogWritesAndRuns() throws {
        let saved = Log.dir
        Log.dir = FileManager.default.temporaryDirectory.appendingPathComponent("up-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: Log.dir); Log.dir = saved }
        Log.info("hello\nsecond line")
        Log.error("boom")
        let lines = Log.tail(3)
        XCTAssertTrue(lines[0].hasSuffix("INFO  hello"))
        XCTAssertEqual(lines[1], "    | second line")
        XCTAssertTrue(lines[2].hasSuffix("ERROR boom"))
        let run = Log.newRun("local/cursor")
        Log.appendRun(run, "output\n")
        XCTAssertEqual(try String(contentsOf: run, encoding: .utf8), "output\n")
        XCTAssertTrue(run.lastPathComponent.hasSuffix(" local cursor.log"))
        let again = Log.newRun("local/cursor")
        XCTAssertNotEqual(again, run)
        XCTAssertEqual(try String(contentsOf: run, encoding: .utf8), "output\n", "a second run never empties the first one's file")
    }

    /// Downloads every desktop app in the catalog for this Mac through the real staging script and checks it
    /// the way an update would. Several GB, so only with UPDATEPLS_LIVE=1.
    func testLiveEveryMacAppDownloadsAndVerifies() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UPDATEPLS_LIVE"] == "1", "set UPDATEPLS_LIVE=1 to run")
        let sandbox = try Sandbox()
        let resolver = LatestResolver()
        var arch = "arm64"
        #if arch(x86_64)
        arch = "x86_64"
        #endif
        for def in Catalog.bundled().apps {
            for v in def.mac ?? [] {
                let label = "\(def.id)/\(v.app)"
                guard let info = await resolver.resolve(v.latest, installed: nil, arch: arch) else { XCTFail("\(label): no latest version"); continue }
                guard let url = info.url else { XCTFail("\(label): no download URL"); continue }
                let bid = (try? String(contentsOfFile: "/Applications/\(v.app).app/Contents/Info.plist", encoding: .utf8)) != nil
                    ? Bundle(path: "/Applications/\(v.app).app")?.bundleIdentifier ?? "" : ""
                let fake = sandbox.home.appendingPathComponent("Apps/\(v.app).app").path
                let stage = "Library/Caches/Update pls/Staging/live-\(def.id)"
                // Without a bundle id to match, take the first app in the download.
                let script = Engine.macStageScript(app: fake, bundleID: bid.isEmpty ? "*" : bid, name: v.app, url: url, info: info, stage: stage, trust: false)
                    .replacingOccurrences(of: #"if [ "$(defaults read "$a/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$BID" ]; then"#,
                                          with: #"if [ "$BID" = "*" ] || [ "$(defaults read "$a/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$BID" ]; then"#)
                let start = Date()
                let r = await sandbox.runner(script, 1800, nil)
                let f = Engine.fields(r)
                guard r.ok, let staged = f["STAGED"] else { XCTFail("\(label): \(Engine.failure(r))"); continue }
                let sign = await Shell.run("/bin/bash", ["-c", "codesign --verify --deep --strict \(Shell.q(staged)) && spctl --assess --type execute \(Shell.q(staged)) && codesign -dv \(Shell.q(staged)) 2>&1 | sed -n 's/^TeamIdentifier=//p'"], timeout: 600)
                XCTAssertTrue(sign.ok, "\(label): signature/Gatekeeper: \(sign.combined)")
                XCTAssertEqual(f["STAGED_VERSION"].map(Version.clean), Version.clean(info.version), "\(label): download's version differs from the published one")
                print("LIVE \(label): \(info.version) team \(sign.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) sha256:\(info.sha256 != nil) sha512:\(info.sha512Base64 != nil) \(Int(Date().timeIntervalSince(start)))s \(url)")
                _ = await sandbox.runner("rm -rf \"$HOME/\"\(Shell.q(stage))", 60, nil)
            }
        }
    }

    @MainActor
    func testQueueIgnoresRepeatClicksAndKeepsResults() async throws {
        let saved = Log.dir
        Log.dir = FileManager.default.temporaryDirectory.appendingPathComponent("up-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: Log.dir); Log.dir = saved }
        let model = AppModel(autostart: false)
        var a = Item(machine: .local, os: .mac, defID: "a", name: "A", brand: "A", isApp: false, path: "/a",
                     installed: "1.0", latest: LatestInfo(version: "2.0"), method: .bun(package: "a"))
        a.state = .available
        var b = a; b.defID = "b"; b.name = "B"; b.path = "/b"
        model.items = [a, b]
        var runs: [String] = []
        model.perform = { item, _, r in
            runs.append(item.key)
            r.phase("Working")
            try? await Task.sleep(for: .milliseconds(200))
            return UpdateOutcome(ok: true, message: "Updated", previous: "1.0")
        }
        // A updates for real; B claims success but is still on the old version afterwards.
        model.rescan = { m, _ in
            var a2 = a; a2.installed = "2.0"; a2.state = .upToDate
            return (MachineStatus(machine: m, os: .mac, state: .online), [a2, b])
        }
        model.enqueue([(a, .update), (b, .update)])
        model.enqueue([(a, .update)])
        model.updateAll()
        XCTAssertTrue(model.isActive(a) && model.isActive(b))
        XCTAssertTrue(model.updatable.isEmpty, "nothing queued can be started again")
        XCTAssertTrue(model.keepsAwake)
        for _ in 0..<50 where model.isBusy { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.keepsAwake)
        XCTAssertEqual(runs, ["local/a", "local/b"], "each tool runs exactly once")
        XCTAssertEqual(model.activity[a.key], .done("Updated to 2.0"))
        XCTAssertEqual(model.activity[b.key], .failed("Still on 1.0 after updating. Updated"))
        XCTAssertEqual(model.previous[a.key], "1.0")
        XCTAssertNotNil(model.runFiles[a.key])

        // Results survive the next background check; the failure only clears once the tool is current.
        await model.checkAll(.background)
        XCTAssertEqual(model.activity[b.key], .failed("Still on 1.0 after updating. Updated"))
    }

    /// Runs Update all through the menu's own model on this Mac's real apps, pressing the buttons again
    /// throughout, and prints every row change. It really updates them, so only with UPDATEPLS_LIVE_UPDATE=1.
    /// Anything from Claude is left alone.
    @MainActor
    func testLiveUpdateAllThroughTheMenuModel() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UPDATEPLS_LIVE_UPDATE"] == "1", "set UPDATEPLS_LIVE_UPDATE=1 to run")
        let model = AppModel(autostart: false)
        model.askBeforeQuitting = false
        model.disabledHosts = Set(SSHConfig.hosts())
        await model.checkAll()
        model.excluded = Set(model.items.filter { $0.defID.contains("claude") }.map(\.key))
        let targets = model.updatable
        try XCTSkipIf(targets.isEmpty, "nothing to update")
        let wasOpen = Set(targets.filter { $0.isApp && !LocalApps.instances($0.path).isEmpty }.map(\.key))
        print("LIVE targets: \(targets.map { "\($0.key) \($0.installed ?? "?") -> \($0.latest?.version ?? "?")" }), open: \(wasOpen.sorted())")
        var runs: [String: Int] = [:]
        let real = model.perform
        model.perform = { item, job, r in
            runs[item.key, default: 0] += 1
            return await real(item, job, r)
        }
        let start = Date()
        func t() -> String { String(format: "%6.1fs", Date().timeIntervalSince(start)) }
        model.updateAll()
        var shown: [String: String] = [:]
        while model.isBusy && Date().timeIntervalSince(start) < 1800 {
            model.updateAll()
            for item in targets { model.update(item) }
            for (key, a) in model.activity {
                let line: String = switch a {
                case .queued: "queued"
                case let .running(text, f): f.map { "\(text) \(Int($0 * 10) * 10)%" } ?? text
                case let .done(m): "DONE \(m)"
                case let .failed(m): "FAILED \(m)"
                }
                if shown[key] != line { print("LIVE \(t()) \(key): \(line)"); shown[key] = line }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("LIVE \(t()) finished")
        for item in targets {
            XCTAssertEqual(runs[item.key], 1, "\(item.key) ran \(runs[item.key] ?? 0) times")
            guard case let .done(message) = model.activity[item.key] else {
                XCTFail("\(item.key): \(String(describing: model.activity[item.key]))"); continue
            }
            let now = model.items.first { $0.key == item.key }
            XCTAssertEqual(now?.state, .upToDate, "\(item.key): \(message)")
            if wasOpen.contains(item.key) {
                XCTAssertFalse(LocalApps.instances(item.path).isEmpty, "\(item.key) wasn't reopened")
            } else if item.isApp {
                XCTAssertTrue(LocalApps.instances(item.path).isEmpty, "\(item.key) was closed but got opened")
            }
        }
    }

    func testRollbackHoldIsLiftedOnlyWhenItsOwn() {
        let d = UserDefaults.standard
        let keys = ["previousVersions", "excludedFromUpdateAll", "heldBackByRollback"]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { d.set(v, forKey: k) } }
        for k in keys { d.removeObject(forKey: k) }
        var a = Item(machine: .local, os: .mac, defID: "a", name: "A", brand: "A", isApp: false, path: "/a",
                     installed: "2.0", latest: LatestInfo(version: "2.0"), method: .bun(package: "a"))
        a.state = .upToDate
        var b = a; b.defID = "b"
        let ok = UpdateOutcome(ok: true, message: "Installed 1.0", previous: "2.0")

        // A rollback holds A back; switching or updating back to the latest lifts it.
        XCTAssertEqual(History.record(a, switchedTo: "1.0", ok), .added)
        XCTAssertEqual(History.excluded, ["local/a"])
        XCTAssertEqual(History.previous["local/a"], "2.0")
        XCTAssertEqual(History.record(a, UpdateOutcome(ok: true, message: "Updated", previous: "1.0")), .lifted)
        XCTAssertEqual(History.excluded, [])
        XCTAssertEqual(History.record(a, switchedTo: "1.0", ok), .added)
        XCTAssertEqual(History.record(a, switchedTo: "2.0", ok), .lifted)

        // B was skipped by hand: neither a rollback nor getting back to the latest touches that.
        d.set(["local/b"], forKey: "excludedFromUpdateAll")
        XCTAssertNil(History.record(b, switchedTo: "1.0", ok))
        XCTAssertNil(History.record(b, UpdateOutcome(ok: true, message: "Updated")))
        XCTAssertEqual(History.excluded, ["local/b"])

        // Taking over a rollback's skip by hand makes it stick.
        XCTAssertEqual(History.record(a, switchedTo: "1.0", ok), .added)
        History.clearHold("local/a")
        XCTAssertNil(History.record(a, UpdateOutcome(ok: true, message: "Updated")))
        XCTAssertEqual(History.excluded, ["local/a", "local/b"])
        XCTAssertNil(History.record(a, switchedTo: "1.0", .fail("nope")))
    }

    func testChangedPart() {
        XCTAssertEqual(ItemRow.changedPart(of: "0.1.1-nightly.20261019.3373", from: "0.1.1-nightly.20261019.3360"), "3373")
        XCTAssertEqual(ItemRow.changedPart(of: "0.1.1-nightly.20261020.3380", from: "0.1.1-nightly.20261019.3360"), "20261020.3380")
        XCTAssertEqual(ItemRow.changedPart(of: "2.1.304", from: "2.1.303"), "2.1.304")
    }

}

/// A throwaway home folder with stand-in apps, and a script runner that uses it as $HOME. Removed when the test ends.
final class Sandbox: @unchecked Sendable {
    let home: URL
    var app: URL { home.appendingPathComponent("Apps/T.app") }

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("up-sb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    func item(installed: String) -> Item {
        Item(machine: .local, os: .mac, defID: "t", name: "T", brand: "T", isApp: true, path: app.path,
             installed: installed, method: .macDirect(appPath: app.path, bundleID: "com.example.t"))
    }

    static func writeInfo(_ app: URL, version: String) throws {
        try (["CFBundleIdentifier": "com.example.t", "CFBundleExecutable": "T", "CFBundleShortVersionString": version] as NSDictionary)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
    }

    /// A tiny ad-hoc signed app.
    func makeApp(at url: URL, version: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: url.appendingPathComponent("Contents/MacOS/T").path)
        try Self.writeInfo(url, version: version)
        let sign = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["-s", "-", "-f", url.path])
        sign.waitUntilExit()
    }

    func zippedApp(version: String) throws -> URL {
        let src = home.appendingPathComponent("build-\(version)/T.app")
        try makeApp(at: src, version: version)
        let zip = home.appendingPathComponent("T-\(version).zip")
        let p = try Process.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-c", "-k", "--keepParent", src.path, zip.path])
        p.waitUntilExit()
        return zip
    }

    func sha256(_ url: URL) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256", url.path]
        p.standardOutput = out
        try p.run(); p.waitUntilExit()
        return String(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).prefix(64))
    }

    func version(_ app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    var runner: Engine.ScriptRunner {
        let home = home.path
        return { script, timeout, out in
            await Shell.run("/bin/bash", ["-s"], input: "export HOME=\(Shell.q(home))\n{\n" + script + "\n} </dev/null\n",
                            timeout: timeout, onOutput: out)
        }
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
    var value: T { lock.withLock { v } }
}
