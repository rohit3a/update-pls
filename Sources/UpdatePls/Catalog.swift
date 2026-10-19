import Foundation

/// Where the newest version of something is published.
struct LatestSource: Codable, Hashable {
    struct ElectronFeed: Codable, Hashable { var repo: String; var channel: String }
    struct Scrape: Codable, Hashable { var url: String; var regex: String }
    var npm: String?
    var pypi: String?
    var github: String?
    var cask: String?
    var electronGithub: ElectronFeed?
    var scrape: Scrape?
}

struct CLIDef: Codable, Identifiable {
    var id: String
    var name: String
    var binaries: [String]
    var npm: [String]?
    var pypi: String?
    /// Arguments that make the tool update itself, e.g. "update".
    var selfUpdate: String?
    var latest: LatestSource?
}

struct MacVariant: Codable {
    var app: String
    var latest: LatestSource
}

struct AppDef: Codable, Identifiable {
    var id: String
    var name: String
    var mac: [MacVariant]?
    var windows: [String]?
    var linuxDeb: [String]?
}

struct Catalog: Codable {
    var clis: [CLIDef]
    var apps: [AppDef]

    static var userFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/update-pls/harnesses.json")
    }

    static func bundled() -> Catalog {
        let candidates = [
            Bundle.main.url(forResource: "catalog", withExtension: "json"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/catalog.json"),
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Catalog.self, from: data) { return c }
        }
        return Catalog(clis: [], apps: [])
    }

    /// Built-in catalog plus the user's own file; user entries replace built-ins with the same id.
    static func load() -> Catalog {
        var c = bundled()
        guard let data = try? Data(contentsOf: userFile) else { return c }
        struct Partial: Codable { var clis: [CLIDef]?; var apps: [AppDef]? }
        guard let user = try? JSONDecoder().decode(Partial.self, from: data) else { return c }
        for d in user.clis ?? [] { c.clis.removeAll { $0.id == d.id }; c.clis.append(d) }
        for d in user.apps ?? [] { c.apps.removeAll { $0.id == d.id }; c.apps.append(d) }
        return c
    }

    static func writeUserTemplateIfMissing() {
        guard !FileManager.default.fileExists(atPath: userFile.path) else { return }
        try? FileManager.default.createDirectory(at: userFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let template = """
        {
          "clis": [
            { "id": "my-tool", "name": "My Tool", "binaries": ["mytool"], "npm": ["my-tool"], "selfUpdate": "update", "latest": { "npm": "my-tool" } }
          ],
          "apps": []
        }
        """
        try? template.write(to: userFile, atomically: true, encoding: .utf8)
    }
}

enum Version {
    /// Pulls the first version-looking token out of `--version` output.
    static func extract(_ text: String) -> String? {
        let pattern = #"\d+(\.\d+)+(-[0-9A-Za-z][0-9A-Za-z.-]*)?"#
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[r])
    }

    /// Cask versions look like "3.25.9,5d4df96…"; keep the human part.
    static func clean(_ v: String) -> String {
        var s = v.split(separator: ",").first.map(String.init) ?? v
        if s.hasPrefix("v") { s.removeFirst() }
        if s.hasPrefix("rust-v") { s.removeFirst(6) }
        return s
    }

    /// The prerelease channel of a version, e.g. "nightly" for 0.1.1-nightly.2026.
    static func channel(_ v: String) -> String? {
        guard let dash = v.firstIndex(of: "-") else { return nil }
        let word = v[v.index(after: dash)...].prefix { $0.isLetter }
        return word.isEmpty ? nil : String(word)
    }

    /// True when `latest` is newer than `installed`.
    static func isNewer(_ latest: String, than installed: String) -> Bool {
        compare(clean(latest), clean(installed)) == .orderedDescending
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func split(_ v: String) -> ([Int], [String]) {
            let parts = v.split(separator: "-", maxSplits: 1).map(String.init)
            let core = parts[0].split(separator: ".").map { Int($0) ?? 0 }
            let pre = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
            return (core, pre)
        }
        let (ca, pa) = split(a), (cb, pb) = split(b)
        for i in 0..<max(ca.count, cb.count) {
            let x = i < ca.count ? ca[i] : 0, y = i < cb.count ? cb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        if pa == pb { return .orderedSame }
        if pa.isEmpty { return .orderedDescending }
        if pb.isEmpty { return .orderedAscending }
        for i in 0..<max(pa.count, pb.count) {
            guard i < pa.count else { return .orderedAscending }
            guard i < pb.count else { return .orderedDescending }
            if pa[i] == pb[i] { continue }
            if let x = Int(pa[i]), let y = Int(pb[i]) { return x < y ? .orderedAscending : .orderedDescending }
            return pa[i] < pb[i] ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
}
