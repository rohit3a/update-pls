import Foundation

struct LatestInfo: Hashable {
    var version: String
    /// Download for desktop apps, with the checksum the publisher lists for it.
    var url: String?
    var sha256: String?
    var sha512Base64: String?
}

/// Looks up the newest published versions. One instance per check, so each source is fetched once.
actor LatestResolver {
    private var cache: [String: LatestInfo?] = [:]
    private var npmTagCache: [String: [String: String]] = [:]

    func resolve(_ src: LatestSource, installed: String?, arch: String) async -> LatestInfo? {
        if let p = src.npm { return await npm(p, installed: installed) }
        if let p = src.pypi { return await cached("pypi:\(p)") { await self.pypi(p) } }
        if let r = src.github { return await cached("gh:\(r)") { await self.github(r) } }
        if let c = src.cask { return await cached("cask:\(c):\(arch)") { await self.cask(c, arch: arch) } }
        if let e = src.electronGithub { return await cached("eg:\(e.repo):\(e.channel):\(arch)") { await self.electron(e, arch: arch) } }
        if let s = src.scrape { return await cached("scrape:\(s.url)") { await self.scrape(s) } }
        if let q = src.squirrel { return await cached("squirrel:\(q):\(arch)") { await self.squirrel(q, arch: arch) } }
        return nil
    }

    func npm(_ pkg: String, installed: String?) async -> LatestInfo? {
        let tags: [String: String]
        if let hit = npmTagCache[pkg] { tags = hit } else {
            tags = await Self.json("https://registry.npmjs.org/\(pkg)", accept: "application/vnd.npm.install-v1+json")?["dist-tags"] as? [String: String] ?? [:]
            npmTagCache[pkg] = tags
        }
        // Follow the installed channel (nightly, preview, ...) when the package publishes one.
        if let ch = installed.flatMap(Version.channel), let v = tags[ch] { return LatestInfo(version: v) }
        return tags["latest"].map { LatestInfo(version: $0) }
    }

    func brewFormula(_ name: String) async -> LatestInfo? {
        await cached("formula:\(name)") {
            guard let j = await Self.json("https://formulae.brew.sh/api/formula/\(name).json"),
                  let v = (j["versions"] as? [String: Any])?["stable"] as? String else { return nil }
            return LatestInfo(version: v)
        }
    }

    private func cached(_ key: String, _ fetch: @escaping () async -> LatestInfo?) async -> LatestInfo? {
        if let hit = cache[key] { return hit }
        let v = await fetch()
        cache[key] = v
        return v
    }

    private func pypi(_ pkg: String) async -> LatestInfo? {
        guard let j = await Self.json("https://pypi.org/pypi/\(pkg)/json"),
              let v = (j["info"] as? [String: Any])?["version"] as? String else { return nil }
        return LatestInfo(version: v)
    }

    private func github(_ repo: String) async -> LatestInfo? {
        guard let j = await Self.json("https://api.github.com/repos/\(repo)/releases/latest"),
              let tag = j["tag_name"] as? String else { return nil }
        return LatestInfo(version: Version.clean(tag))
    }

    private func cask(_ token: String, arch: String) async -> LatestInfo? {
        guard var j = await Self.json("https://formulae.brew.sh/api/cask/\(token).json") else { return nil }
        // The top level describes Apple Silicon; Intel builds live under "variations".
        if arch == "x86_64", let vars = j["variations"] as? [String: [String: Any]],
           let intel = vars.first(where: { !$0.key.hasPrefix("arm64") })?.value {
            j.merge(intel) { _, new in new }
        }
        guard let v = j["version"] as? String else { return nil }
        let sha = j["sha256"] as? String
        return LatestInfo(version: Version.clean(v), url: j["url"] as? String, sha256: sha == "no_check" ? nil : sha)
    }

    /// electron-builder feeds published on GitHub releases (e.g. T3 Code nightly).
    private func electron(_ feed: LatestSource.ElectronFeed, arch: String) async -> LatestInfo? {
        guard let data = await Self.get("https://api.github.com/repos/\(feed.repo)/releases?per_page=30"),
              let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let ymlName = "\(feed.channel)-mac.yml"
        for rel in releases {
            guard let tag = rel["tag_name"] as? String, let assets = rel["assets"] as? [[String: Any]],
                  let yml = assets.first(where: { $0["name"] as? String == ymlName }),
                  let ymlURL = yml["browser_download_url"] as? String,
                  let text = await Self.get(ymlURL).map({ String(decoding: $0, as: UTF8.self) }) else { continue }
            let (version, files) = Self.parseElectronYml(text)
            let wantArm = arch == "arm64"
            guard let v = version,
                  let file = files.first(where: { $0.url.hasSuffix(".zip") && $0.url.contains("arm64") == wantArm })
                    ?? files.first(where: { $0.url.hasSuffix(".zip") }) else { return nil }
            let url = file.url.hasPrefix("http") ? file.url : "https://github.com/\(feed.repo)/releases/download/\(tag)/\(file.url)"
            return LatestInfo(version: v, url: url, sha512Base64: file.sha512)
        }
        return nil
    }

    static func parseElectronYml(_ text: String) -> (String?, [(url: String, sha512: String)]) {
        var version: String?
        var files: [(String, String)] = []
        var url: String?
        func value(_ line: Substring) -> String {
            let v = line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return v.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("version:") { version = value(line[...]) }
            else if t.hasPrefix("- url:") { url = value(Substring(t.dropFirst(2))) }
            else if t.hasPrefix("sha512:"), let u = url, line.hasPrefix(" ") { files.append((u, value(Substring(t)))); url = nil }
        }
        return (version, files)
    }

    private func squirrel(_ template: String, arch: String) async -> LatestInfo? {
        let url = template.replacingOccurrences(of: "{platform}", with: arch == "x86_64" ? "darwin-x64" : "darwin-arm64")
        guard let j = await Self.json(url), let v = j["name"] as? String, let dl = j["url"] as? String else { return nil }
        return LatestInfo(version: Version.clean(v), url: dl)
    }

    private func scrape(_ s: LatestSource.Scrape) async -> LatestInfo? {
        guard let data = await Self.get(s.url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let re = try? NSRegularExpression(pattern: s.regex),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return LatestInfo(version: String(text[r]))
    }

    static func get(_ url: String, accept: String? = nil) async -> Data? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue("update-pls", forHTTPHeaderField: "User-Agent")
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    static func json(_ url: String, accept: String? = nil) async -> [String: Any]? {
        guard let d = await get(url, accept: accept) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}
