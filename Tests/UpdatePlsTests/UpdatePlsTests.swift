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
}
