import CryptoKit
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
            // A release without a usable zip (still uploading, or broken) is skipped, not the end of the search.
            guard let v = version,
                  let file = files.first(where: { $0.url.hasSuffix(".zip") && $0.url.contains("arm64") == wantArm })
                    ?? files.first(where: { $0.url.hasSuffix(".zip") }) else { continue }
            let url = file.url.hasPrefix("http") ? file.url : "https://github.com/\(feed.repo)/releases/download/\(tag)/\(file.url)"
            return LatestInfo(version: v, url: url, sha512Base64: file.sha512)
        }
        return nil
    }

    // MARK: Other versions

    /// Published versions this tool can be switched to, newest first: every version on npm or PyPI for CLIs,
    /// every GitHub release for Mac apps published there. Stays on the installed channel (stable, nightly, ...).
    func versions(of item: Item, catalog: Catalog) async -> [String] {
        var all: [String] = []
        let (npm, pypi) = Engine.registryPackage(item, catalog: catalog)
        if let npm {
            let doc = await Self.json("https://registry.npmjs.org/\(npm)", accept: "application/vnd.npm.install-v1+json")
            all = ((doc?["versions"] as? [String: Any]) ?? [:]).keys.map { $0 }
        } else if let pypi {
            let doc = await Self.json("https://pypi.org/pypi/\(pypi)/json")
            let releases = (doc?["releases"] as? [String: [[String: Any]]]) ?? [:]
            all = releases.filter { !$0.value.isEmpty && !$0.value.allSatisfy { ($0["yanked"] as? Bool) == true } }.map(\.key)
        } else if item.isApp, let repo = Self.githubRepo(item, catalog: catalog) {
            let data = await Self.get("https://api.github.com/repos/\(repo)/releases?per_page=50")
            let releases = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            all = releases.filter { ($0["draft"] as? Bool) != true }.compactMap { ($0["tag_name"] as? String).map(Version.clean) }
        }
        let channel = item.installed.flatMap(Version.channel)
        return all
            .filter { Version.channel($0) == channel && $0 != item.installed }
            .sorted { Version.isNewer($0, than: $1) }
            .prefix(25).map { $0 }
    }

    /// The download for one exact version of a Mac app published on GitHub, with its checksum when the release lists one.
    func release(of item: Item, version: String) async -> LatestInfo? {
        let catalog = Catalog.load()
        guard let repo = Self.githubRepo(item, catalog: catalog),
              let data = await Self.get("https://api.github.com/repos/\(repo)/releases?per_page=50"),
              let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let rel = releases.first(where: { ($0["tag_name"] as? String).map(Version.clean) == version }),
              let tag = rel["tag_name"] as? String else { return nil }
        let assets = rel["assets"] as? [[String: Any]] ?? []
        // electron-builder releases list every file with its SHA-512.
        if let yml = assets.first(where: { ($0["name"] as? String)?.hasSuffix("-mac.yml") == true }),
           let ymlURL = yml["browser_download_url"] as? String,
           let text = await Self.get(ymlURL).map({ String(decoding: $0, as: UTF8.self) }) {
            let (_, files) = Self.parseElectronYml(text)
            let wantArm = item.arch != "x86_64"
            if let file = files.first(where: { $0.url.hasSuffix(".zip") && $0.url.contains("arm64") == wantArm })
                ?? files.first(where: { $0.url.hasSuffix(".zip") }) {
                let url = file.url.hasPrefix("http") ? file.url : "https://github.com/\(repo)/releases/download/\(tag)/\(file.url)"
                return LatestInfo(version: version, url: url, sha512Base64: file.sha512)
            }
        }
        // Otherwise the same file as the latest release, with the version swapped in the URL; the download is
        // still checked by signature, notarization and signing team before it is installed.
        guard let latest = item.latest, let url = latest.url, url.contains(latest.version) else { return nil }
        let name = (url.replacingOccurrences(of: latest.version, with: version) as NSString).lastPathComponent
        guard let asset = assets.first(where: { $0["name"] as? String == name }),
              let dl = asset["browser_download_url"] as? String else { return nil }
        return LatestInfo(version: version, url: dl)
    }

    /// The GitHub repo a Mac app's releases come from: its electron feed, or its download URL.
    static func githubRepo(_ item: Item, catalog: Catalog) -> String? {
        let variant = catalog.apps.first { $0.id == item.defID }?.mac?.first { item.path.hasSuffix("/\($0.app).app") }
        if let feed = variant?.latest.electronGithub { return feed.repo }
        if let gh = variant?.latest.github { return gh }
        guard let url = item.latest?.url, let r = url.range(of: "https://github.com/") else { return nil }
        let parts = url[r.upperBound...].split(separator: "/")
        return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
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

    /// No local cache: a cached answer would hide new versions (it once kept reporting an old VERSION for hours).
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// GitHub answers are revalidated with their ETag every time (so a new release shows up at once), and the
    /// last answer stands in when GitHub refuses (rate limit) or can't be reached.
    static func get(_ url: String, accept: String? = nil) async -> Data? {
        guard let u = URL(string: url) else { return nil }
        let github = u.host == "api.github.com"
        let cached = github ? GitHubCache.load(url, accept) : nil
        var signed = false
        func request() -> URLRequest {
            var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            req.setValue("update-pls", forHTTPHeaderField: "User-Agent")
            if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
            if github {
                if let etag = cached?.etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                signed = false
                if let t = GitHubToken.value { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization"); signed = true }
            }
            return req
        }
        do {
            var (data, resp) = try await session.data(for: request())
            if (resp as? HTTPURLResponse)?.statusCode == 401, signed {
                Log.error("latest: GitHub turned down the token; asking without it")
                GitHubToken.invalidate()
                (data, resp) = try await session.data(for: request())
            }
            let http = resp as? HTTPURLResponse
            if http?.statusCode == 304, let cached { return cached.body }
            guard http?.statusCode == 200 else {
                var note = ""
                if http?.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" { note = " (GitHub rate limit reached; it resets within an hour)" }
                Log.error("latest: GET \(url) -> HTTP \(http?.statusCode ?? 0)\(note)\(cached != nil ? "; using the last answer" : "")")
                return cached?.body
            }
            if github, let etag = http?.value(forHTTPHeaderField: "ETag") { GitHubCache.save(url, accept, etag: etag, body: data) }
            return data
        } catch {
            Log.error("latest: GET \(url) -> \(error.localizedDescription)\(cached != nil ? "; using the last answer" : "")")
            return cached?.body
        }
    }

    static func json(_ url: String, accept: String? = nil) async -> [String: Any]? {
        guard let d = await get(url, accept: accept) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

/// GitHub answers with their ETags, in ~/Library/Caches/Update pls/github.
enum GitHubCache {
    static var dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Update pls/github")

    private static func name(_ url: String, _ accept: String?) -> String {
        SHA256.hash(data: Data((url + "|" + (accept ?? "")).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// One file per answer, its ETag on the first line: written in one go, so the two always match.
    static func load(_ url: String, _ accept: String?) -> (etag: String, body: Data)? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name(url, accept) + ".cache")),
              let nl = data.firstIndex(of: 0x0A) else { return nil }
        return (String(decoding: data[..<nl], as: UTF8.self), Data(data[(nl + 1)...]))
    }

    static func save(_ url: String, _ accept: String?, etag: String, body: Data) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (Data((etag + "\n").utf8) + body).write(to: dir.appendingPathComponent(name(url, accept) + ".cache"), options: .atomic)
    }
}

/// A GitHub token, for 5,000 lookups an hour instead of 60: GH_TOKEN or GITHUB_TOKEN, else the GitHub CLI's
/// own (`gh auth token`). It is only ever sent to api.github.com and never logged.
enum GitHubToken {
    private static let lock = NSLock()
    private static var found: String??

    static var value: String? {
        lock.withLock {
            if found == nil { found = .some(find()) }
            return found!
        }
    }

    static func invalidate() { lock.withLock { found = .some(nil) } }

    private static func find() -> String? {
        let env = ProcessInfo.processInfo.environment
        for k in ["GH_TOKEN", "GITHUB_TOKEN"] {
            if let t = env[k]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { Log.info("GitHub: signed in with \(k)"); return t }
        }
        for gh in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where FileManager.default.isExecutableFile(atPath: gh) {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: gh)
            p.arguments = ["auth", "token", "--hostname", "github.com"]
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            let done = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in done.signal() }
            guard (try? p.run()) != nil else { continue }
            if done.wait(timeout: .now() + 5) == .timedOut { p.terminate(); continue }
            let t = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0, !t.isEmpty, !t.contains(" ") { Log.info("GitHub: signed in with the GitHub CLI"); return t }
        }
        Log.info("GitHub: not signed in (60 lookups an hour)")
        return nil
    }
}
