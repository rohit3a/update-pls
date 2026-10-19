import Foundation

struct CLIRecord {
    var id, binary, path, realPath, versionOutput, package, packageVersion, npmBin: String
    var writable: Bool
}

struct AppRecord {
    var id, appName, path, version, bundleID: String
    var running: Bool
}

struct DebRecord { var id, package, installed, candidate: String }

struct WingetRow { var name, id, version, available: String }

struct ProbeResult {
    var os: OSKind
    var arch = ""
    var clis: [CLIRecord] = []
    var apps: [AppRecord] = []
    var casks: Set<String> = []
    var hasBrew = false
    var debs: [DebRecord] = []
    var winget: [WingetRow] = []
}

enum Probe {
    /// Shell setup shared by every POSIX script: borrow the user's login PATH (nvm, bun, brew, ...).
    static let unixPrelude = #"""
    export LC_ALL=C
    up_login_path() {
      "${SHELL:-/bin/bash}" -lic 'printf "\n__UPP__%s\n" "$PATH"' </dev/null 2>/dev/null &
      up_pid=$!
      ( sleep 8; kill $up_pid ) >/dev/null 2>&1 &
      up_k=$!
      wait $up_pid 2>/dev/null
      kill $up_k 2>/dev/null
    }
    UP_P=$(up_login_path | sed -n 's/^__UPP__//p' | tail -1)
    export PATH="${UP_P:+$UP_P:}$HOME/.local/bin:$HOME/.bun/bin:$HOME/.npm-global/bin:$HOME/.opencode/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
    up_to() { t=$1; shift; if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"; else "$@"; fi; }

    """#

    static let unixFunctions = #"""
    up_real() { realpath "$1" 2>/dev/null || readlink -f "$1" 2>/dev/null || echo "$1"; }
    up_field() {
      n=$(command -v node 2>/dev/null)
      if [ -n "$n" ]; then "$n" -p "require(process.argv[1]).$2" "$1" 2>/dev/null
      else sed -n "s/^  \"$2\": *\"\([^\"]*\)\".*/\1/p" "$1" | head -1; fi
    }
    up_cli() {
      id=$1; shift
      for b in "$@"; do
        p=$(command -v "$b" 2>/dev/null) || continue
        case "$p" in /*) ;; *) continue ;; esac
        r=$(up_real "$p")
        v=$(up_to 20 "$p" --version </dev/null 2>&1 | head -3 | tr '\t\n\r' '   ')
        pkg=""; pv=""; nb=""; w=0
        case "$r" in */node_modules/*)
          d=$(dirname "$r")
          while [ "$d" != "/" ] && [ ! -f "$d/package.json" ]; do d=$(dirname "$d"); done
          if [ -f "$d/package.json" ]; then
            pkg=$(up_field "$d/package.json" name); pv=$(up_field "$d/package.json" version)
            if [ -x "$(dirname "$p")/npm" ]; then nb="$(dirname "$p")/npm"; else nb=$(command -v npm 2>/dev/null); fi
            [ -w "$(dirname "$d")" ] && w=1
          fi ;;
        esac
        printf 'CLI\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$b" "$p" "$r" "$v" "$pkg" "$pv" "$nb" "$w"
        return
      done
    }
    up_app() {
      for base in /Applications "$HOME/Applications"; do
        a="$base/$2.app"
        [ -d "$a" ] || continue
        v=$(defaults read "$a/Contents/Info" CFBundleShortVersionString 2>/dev/null)
        bid=$(defaults read "$a/Contents/Info" CFBundleIdentifier 2>/dev/null)
        run=0
        ps -axo command= | grep -F "$a/Contents/MacOS/" | grep -v grep >/dev/null && run=1
        printf 'APP\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$a" "$v" "$bid" "$run"
        return
      done
    }
    up_deb() {
      v=$(dpkg-query -W -f='${Version}' "$2" 2>/dev/null) || return
      [ -n "$v" ] || return
      c=$(apt-cache policy "$2" 2>/dev/null | sed -n 's/^ *Candidate: *//p')
      printf 'DEB\t%s\t%s\t%s\t%s\n' "$1" "$2" "$v" "$c"
    }
    printf 'OS\t%s\t%s\n' "$(uname -s)" "$(uname -m)"
    if command -v brew >/dev/null 2>&1; then
      printf 'BREW\t%s\n' "$(command -v brew)"
      printf 'CASKS\t%s\n' "$(brew list --cask 2>/dev/null | tr '\n' ' ')"
    fi

    """#

    static func unixScript(_ c: Catalog) -> String {
        var s = unixPrelude + unixFunctions
        for d in c.clis {
            s += "up_cli " + ([d.id] + d.binaries).map(Shell.q).joined(separator: " ") + "\n"
        }
        s += "if [ \"$(uname -s)\" = Darwin ]; then\n"
        for d in c.apps { for v in d.mac ?? [] { s += "  up_app \(Shell.q(d.id)) \(Shell.q(v.app))\n" } }
        s += "elif command -v dpkg-query >/dev/null 2>&1; then\n  :\n"
        for d in c.apps { for p in d.linuxDeb ?? [] { s += "  up_deb \(Shell.q(d.id)) \(Shell.q(p))\n" } }
        s += "fi\n"
        return s
    }

    static let windowsPrelude = #"""
    $ErrorActionPreference = 'SilentlyContinue'
    $ProgressPreference = 'SilentlyContinue'
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User') + ';' + $env:Path

    """#

    static func windowsScript(_ c: Catalog) -> String {
        var s = windowsPrelude + #"""
        $t = "`t"
        "OS${t}Windows${t}$env:PROCESSOR_ARCHITECTURE"
        $npmRoot = ''
        if (Get-Command npm -CommandType Application) { $npmRoot = (& npm root -g 2>$null | Select-Object -First 1) }
        function Up-Cli([string]$id, [string[]]$bins, [string[]]$pkgs) {
          foreach ($b in $bins) {
            $c = Get-Command $b -CommandType Application | Select-Object -First 1
            if (-not $c) { continue }
            $p = $c.Source
            $v = ((& $p --version 2>&1 | Select-Object -First 3) -join ' ') -replace "`t|`r|`n", ' '
            $pkg = ''; $pv = ''; $nb = ''; $r = $p
            if ($npmRoot -and ($p -like '*\npm\*' -or $p -like '*\nodejs\*')) {
              foreach ($k in $pkgs) {
                $j = Join-Path $npmRoot (Join-Path $k 'package.json')
                if (Test-Path $j) { $pj = Get-Content $j -Raw | ConvertFrom-Json; $pkg = $pj.name; $pv = $pj.version; $nb = 'npm'; $r = Join-Path $npmRoot $k; break }
              }
            }
            "CLI${t}$id${t}$b${t}$p${t}$r${t}$v${t}$pkg${t}$pv${t}$nb${t}1"
            return
          }
        }

        """#
        func arr(_ a: [String]) -> String { "@(" + a.map(Shell.psq).joined(separator: ",") + ")" }
        for d in c.clis { s += "Up-Cli \(Shell.psq(d.id)) \(arr(d.binaries)) \(arr(d.npm ?? []))\n" }
        s += #"if (Get-Command winget) { winget list --accept-source-agreements --disable-interactivity 2>$null | ForEach-Object { "WL${t}$_" } }"# + "\n"
        return s
    }

    static func parse(_ text: String) -> ProbeResult {
        var r = ProbeResult(os: .linux)
        var wl: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let f = line.components(separatedBy: "\t")
            switch f[0] {
            case "OS" where f.count >= 3:
                r.os = f[1] == "Darwin" ? .mac : f[1] == "Windows" ? .windows : .linux
                r.arch = f[2]
            case "BREW": r.hasBrew = true
            case "CASKS" where f.count >= 2: r.casks = Set(f[1].split(separator: " ").map(String.init))
            case "CLI" where f.count >= 10:
                r.clis.append(CLIRecord(id: f[1], binary: f[2], path: f[3], realPath: f[4], versionOutput: f[5],
                                        package: f[6], packageVersion: f[7], npmBin: f[8], writable: f[9] == "1"))
            case "APP" where f.count >= 7:
                r.apps.append(AppRecord(id: f[1], appName: f[2], path: f[3], version: f[4], bundleID: f[5], running: f[6] == "1"))
            case "DEB" where f.count >= 5:
                r.debs.append(DebRecord(id: f[1], package: f[2], installed: f[3], candidate: f[4]))
            case "WL" where f.count >= 2:
                wl.append(f.dropFirst().joined(separator: "\t"))
            default: break
            }
        }
        r.winget = parseWinget(wl)
        return r
    }

    /// Parses `winget list`'s fixed-width table using the header's column positions.
    static func parseWinget(_ lines: [String]) -> [WingetRow] {
        let clean = lines.map { l -> String in
            let s = l.components(separatedBy: "\r").last ?? l
            return s.trimmingCharacters(in: CharacterSet(charactersIn: " ").union(.controlCharacters)).isEmpty ? "" : s
        }
        guard let h = clean.firstIndex(where: { $0.contains("Name") && $0.contains(" Id ") && $0.contains("Version") }) else { return [] }
        let header = Array(clean[h].drop(while: { $0 != "N" }))
        func col(_ name: String) -> Int? {
            let hs = String(header)
            guard let r = hs.range(of: name) else { return nil }
            return hs.distance(from: hs.startIndex, to: r.lowerBound)
        }
        guard let idC = col("Id"), let verC = col("Version") else { return [] }
        let availC = col("Available"), srcC = col("Source")
        var rows: [WingetRow] = []
        for l in clean[(h + 1)...] {
            let chars = Array(l)
            if chars.isEmpty || chars.allSatisfy({ $0 == "-" || $0 == " " }) { continue }
            func cut(_ a: Int, _ b: Int?) -> String {
                guard a < chars.count else { return "" }
                let end = min(b ?? chars.count, chars.count)
                return a < end ? String(chars[a..<end]).trimmingCharacters(in: .whitespaces) : ""
            }
            let name = cut(0, idC)
            let id = cut(idC, verC)
            let ver = cut(verC, availC ?? srcC)
            let avail = availC.map { cut($0, srcC) } ?? ""
            if !name.isEmpty && !id.isEmpty { rows.append(WingetRow(name: name, id: id, version: ver, available: avail)) }
        }
        return rows
    }
}
