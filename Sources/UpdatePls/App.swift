import SwiftUI

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if ["check", "update", "versions", "install"].contains(args.first) {
            exit(CLI.run(args))
        }
        // With no saved position, macOS puts a new menu bar icon at the far left, which on a full menu bar
        // with a notch means hidden. Default to a spot near the system icons; dragging it still overrides this.
        UserDefaults.standard.register(defaults: ["NSStatusItem Preferred Position Item-0": 400])
        UpdatePlsApp.main()
    }
}

struct UpdatePlsApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(nsImage: MenuIcon.image(count: model.updateCount, busy: model.isBusy))
        }
        .menuBarExtraStyle(.window)
    }
}

/// The settings window. SwiftUI's Settings scene doesn't open reliably from a menu bar app, so it is managed here.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(_ model: AppModel) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environmentObject(model)))
            w.title = "Update pls Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Menu bar icon: the down-arrow circle, with the update count punched into a badge when there are updates,
/// and a dotted circle while updates are running. A template image, so it follows the menu bar's light or dark look.
enum MenuIcon {
    static func image(count: Int, busy: Bool = false) -> NSImage {
        let name = busy ? "arrow.down.circle.dotted" : count > 0 ? "arrow.down.circle.fill" : "arrow.down.circle"
        let symbol = (NSImage(systemSymbolName: name, accessibilityDescription: busy ? "Update pls, updating" : "Update pls")
            ?? NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Update pls")!)
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))!
        guard count > 0, !busy else { symbol.isTemplate = true; return symbol }
        let label = count > 99 ? "99+" : "\(count)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.black])
        let badgeW = max(12, text.size().width + 6), badgeH: CGFloat = 12
        let size = NSSize(width: symbol.size.width + badgeW - 4, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(x: 0, y: (18 - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
            let badge = NSRect(x: size.width - badgeW, y: 18 - badgeH, width: badgeW, height: badgeH)
            let ctx = NSGraphicsContext.current!
            // Clear a ring around the badge, fill it, then cut the number out of it.
            ctx.compositingOperation = .destinationOut
            NSBezierPath(roundedRect: badge.insetBy(dx: -1.5, dy: -1.5), xRadius: 7.5, yRadius: 7.5).fill()
            ctx.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
            ctx.compositingOperation = .destinationOut
            let t = text.size()
            text.draw(at: NSPoint(x: badge.midX - t.width / 2, y: badge.midY - t.height / 2))
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Update pls, \(count) updates"
        return img
    }
}

/// The command line, for terminals and scripts:
/// `check [host…]`, `update <host>/<tool>|all [--dry-run]`, `versions <host>/<tool>`, `install <host>/<tool> <version> [--download]`.
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        var code: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            code = await main(args)
            done.signal()
        }
        done.wait()
        return code
    }

    static func machines(_ names: [String]) -> [Machine] {
        let disabled = Set(UserDefaults.standard.stringArray(forKey: "disabledHosts") ?? [])
        let all = [Machine.local] + SSHConfig.hosts().filter { !disabled.contains($0) }.map { Machine(id: $0, name: $0) }
        return names.isEmpty ? all : all.filter { names.contains($0.id) }
    }

    static func checkAll(_ machines: [Machine]) async -> [(MachineStatus, [Item])] {
        let catalog = Catalog.load(), resolver = LatestResolver()
        return await withTaskGroup(of: (MachineStatus, [Item]).self) { g in
            for m in machines { g.addTask { await Engine.check(m, catalog: catalog, resolver: resolver) } }
            var out: [(MachineStatus, [Item])] = []
            for await r in g { out.append(r) }
            return out.sorted { $0.0.machine.id < $1.0.machine.id }
        }
    }

    static func main(_ args: [String]) async -> Int32 {
        Log.info("command line: \(args.joined(separator: " "))")
        if args[0] == "check" {
            print("Update pls \(SelfUpdate.current) (latest \(await SelfUpdate.latest() ?? "?"))")
            for (status, items) in await checkAll(machines(Array(args.dropFirst()))) {
                switch status.state {
                case let .offline(msg): print("\(status.machine.id): offline (\(msg))"); continue
                default: print("\(status.machine.id) [\(status.os?.rawValue ?? "?")]")
                }
                for i in items {
                    let mark = switch i.state { case .available: "UPDATE"; case .upToDate: "ok"; default: "?" }
                    let cmd = i.command.map { "  $ \($0)" } ?? ""
                    print("  \(mark.padding(toLength: 7, withPad: " ", startingAt: 0)) \(i.key.padding(toLength: 22, withPad: " ", startingAt: 0)) \(i.installed ?? "?") -> \(i.latest?.version ?? "?")  [\(i.method.label)]\(cmd)")
                }
            }
            print("Log: \(Log.file.path)")
            return 0
        }
        if args[0] == "versions" || args[0] == "install" { return await versions(args) }
        let dryRun = args.contains("--dry-run")
        let rest = args.dropFirst().filter { $0 != "--dry-run" }
        guard let target = rest.first, target == "all" || target.split(separator: "/").count >= 2 else {
            print("usage: UpdatePls update <host>/<tool-id> | all [--dry-run]")
            return 2
        }
        let results = await checkAll(machines(target == "all" ? [] : [String(target.split(separator: "/")[0])]))
        let skipped = Set((UserDefaults.standard.stringArray(forKey: "excludedFromUpdateAll") ?? [])
            + (UserDefaults.standard.stringArray(forKey: "hiddenTools") ?? []))
        let items = results.flatMap(\.1).filter { i in
            target == "all" ? i.state == .available && i.canUpdate && !skipped.contains(i.key) : i.key == target
        }
        if items.isEmpty { print("Nothing to update"); return 0 }
        var code: Int32 = 0
        // One machine at a time here keeps the terminal output readable.
        for i in items {
            print("== \(i.machine.id)/\(i.defID): \(i.installed ?? "?") -> \(i.latest?.version ?? "latest")")
            let file = Log.newRun(i.key)
            Log.appendRun(file, "\(Log.stamp()) \(i.name) on \(i.machine.name): update \(i.summary)\(dryRun ? " (dry run)" : "")\n")
            let r = Reporter(runFile: file) { text, fraction in
                print("   \(text)\(fraction.map { " \(Int($0 * 100))%" } ?? "")")
            }
            let o = await Engine.update(i, relaunch: true, reporter: r, dryRun: dryRun)
            Log.appendRun(file, "\n\(Log.stamp()) \(o.ok ? "Done" : "FAILED"): \(o.message)\n")
            if !dryRun, History.record(i, o) == .lifted { print("   (back in Update all)") }
            print(o.ok ? "   OK: \(o.message)" : "   FAILED: \(o.message)")
            print("   output: \(file.path)")
            if !o.ok { code = 1 }
        }
        return code
    }

    /// `versions <host>/<tool>` lists what a tool can switch to; `install <host>/<tool> <version>` switches it,
    /// from a saved copy when there is one (or `--download` to fetch the published build).
    static func versions(_ args: [String]) async -> Int32 {
        let rest = args.dropFirst().filter { !$0.hasPrefix("--") }
        guard let target = rest.first, target.split(separator: "/").count >= 2, args[0] == "versions" || rest.count >= 2 else {
            print("usage: UpdatePls versions <host>/<tool>\n       UpdatePls install <host>/<tool> <version> [--download]")
            return 2
        }
        let results = await checkAll(machines([String(target.split(separator: "/")[0])]))
        guard let item = results.flatMap(\.1).first(where: { $0.key == target }) else { print("No \(target) found"); return 1 }
        guard item.supportsRollback else { print("\(item.name) can't switch versions (\(item.method.label))"); return 1 }
        if args[0] == "versions" {
            print("\(item.name) on \(item.machine.name): installed \(item.installed ?? "?"), latest \(item.latest?.version ?? "?")")
            if !item.saved.isEmpty { print("saved:     " + item.saved.joined(separator: "  ")) }
            print("published: " + (await LatestResolver().versions(of: item, catalog: Catalog.load())).joined(separator: "  "))
            return 0
        }
        let version = rest[rest.index(after: rest.startIndex)]
        let source: Engine.VersionSource = item.saved.contains(version) && !args.contains("--download") ? .saved : .published
        print("== \(target): \(item.installed ?? "?") -> \(version) (\(source == .saved ? "saved copy" : "download"))")
        let file = Log.newRun(item.key)
        Log.appendRun(file, "\(Log.stamp()) \(item.name) on \(item.machine.name): switch to \(version) (\(source == .saved ? "saved copy" : "published"))\n")
        let r = Reporter(runFile: file) { text, fraction in print("   \(text)\(fraction.map { " \(Int($0 * 100))%" } ?? "")") }
        let o = await Engine.install(item, version: version, from: source, relaunch: true, reporter: r)
        Log.appendRun(file, "\n\(Log.stamp()) \(o.ok ? "Done" : "FAILED"): \(o.message)\n")
        switch History.record(item, switchedTo: version, o) {
        case .added: print("   (skipped in Update all so it stays on \(version))")
        case .lifted: print("   (back in Update all)")
        case nil: break
        }
        print(o.ok ? "   OK: \(o.message)" : "   FAILED: \(o.message)")
        print("   output: \(file.path)")
        return o.ok ? 0 : 1
    }
}
