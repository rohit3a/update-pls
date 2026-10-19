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
        XCTAssertEqual(Version.channel("0.1.1-nightly.2026"), "nightly")
        XCTAssertNil(Version.channel("2026.10.01-e373342".replacingOccurrences(of: "e", with: "1")))
    }

    func testProbeParse() {
        let out = "OS\tDarwin\tarm64\nBREW\t/opt/homebrew/bin/brew\nCASKS\tcursor zed \n" +
            "CLI\tcodex\tcodex\t/u/.local/bin/codex\t/u/.local/lib/node_modules/@openai/codex/bin/codex.js\tcodex-cli 0.163.0\t@openai/codex\t0.163.0\t/u/.local/bin/npm\t1\n" +
            "CLI\tclaude-code\tclaude\t/u/.local/bin/claude\t/u/.local/share/claude/versions/2.1.303\t2.1.303 (Claude Code)\t\t\t\t0\n" +
            "APP\tcursor\tCursor\t/Applications/Cursor.app\t3.22.12\tcom.todesktop.x\t1\n"
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

        // Both app scripts must at least parse.
        let app = item(.macDirect(appPath: "/Applications/T.app", bundleID: "com.t"))
        XCTAssertTrue(app.supportsRollback)
        for script in [
            Engine.macRollbackScript(app: app.path, bundleID: "com.t", backup: Engine.backupPath(app), relaunch: true),
            Engine.macInstallScript(app: app.path, bundleID: "com.t", url: "https://x/T.zip", info: LatestInfo(version: "3"),
                                    backup: Engine.backupPath(app), relaunch: true),
        ] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-n", "-c", script]
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, script)
        }
    }

    /// Rolls a stand-in app back from its saved copy inside a throwaway home folder.
    func testMacRollbackSwapsApp() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("up-rb-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let app = home.appendingPathComponent("Apps/T.app")
        let item = Item(machine: .local, os: .mac, defID: "t", name: "T", brand: "T", isApp: true, path: app.path,
                        installed: "2", method: .macDirect(appPath: app.path, bundleID: "com.example.t"))
        let backup = home.appendingPathComponent(Engine.backupPath(item))
        try fm.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A tiny ad-hoc signed app stands in for the real one and its saved copy.
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/T").path)
        try (["CFBundleIdentifier": "com.example.t", "CFBundleExecutable": "T", "CFBundleShortVersionString": "1"] as NSDictionary)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let sign = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["-s", "-", "-f", app.path])
        sign.waitUntilExit()
        try fm.copyItem(atPath: app.path, toPath: backup.path)
        fm.createFile(atPath: app.appendingPathComponent("NEWER").path, contents: nil)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "set -e\n" + Engine.macRollbackScript(app: app.path, bundleID: "com.example.t",
                                                                  backup: Engine.backupPath(item), relaunch: false)]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertFalse(fm.fileExists(atPath: app.appendingPathComponent("NEWER").path), "the saved version should be back")
        XCTAssertFalse(fm.fileExists(atPath: backup.path), "the saved copy is used up")

        // A second rollback has nothing to go back to and leaves the app alone.
        let again = Process()
        again.executableURL = p.executableURL; again.arguments = p.arguments; again.environment = p.environment
        try again.run(); again.waitUntilExit()
        XCTAssertNotEqual(again.terminationStatus, 0)
        XCTAssertTrue(fm.fileExists(atPath: app.path))
    }

    func testChangedPart() {
        XCTAssertEqual(ItemRow.changedPart(of: "0.1.1-nightly.20261019.3373", from: "0.1.1-nightly.20261019.3360"), "3373")
        XCTAssertEqual(ItemRow.changedPart(of: "0.1.1-nightly.20261020.3380", from: "0.1.1-nightly.20261019.3360"), "20261020.3380")
        XCTAssertEqual(ItemRow.changedPart(of: "2.1.304", from: "2.1.303"), "2.1.304")
    }
}
