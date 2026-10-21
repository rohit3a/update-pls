import SwiftUI

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "check" || args.first == "update" {
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
            Image(nsImage: MenuIcon.image(count: model.updateCount))
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

/// Menu bar icon: the down-arrow circle, with the update count punched into a badge when there are updates.
/// A template image, so it follows the menu bar's light or dark look.
enum MenuIcon {
    static func image(count: Int) -> NSImage {
        let symbol = NSImage(systemSymbolName: count > 0 ? "arrow.down.circle.fill" : "arrow.down.circle", accessibilityDescription: "Update pls")!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))!
        guard count > 0 else { symbol.isTemplate = true; return symbol }
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

/// `UpdatePls check [host…]` and `UpdatePls update <host>/<tool-id>|all` for terminals and scripts.
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
                    print("  \(mark.padding(toLength: 7, withPad: " ", startingAt: 0)) \(i.defID.padding(toLength: 16, withPad: " ", startingAt: 0)) \(i.installed ?? "?") -> \(i.latest?.version ?? "?")  [\(i.method.label)]\(cmd)")
                }
            }
            return 0
        }
        guard args.count >= 2 else { print("usage: UpdatePls update <host>/<tool-id> | all"); return 2 }
        let target = args[1]
        let results = await checkAll(machines(target == "all" ? [] : [String(target.split(separator: "/")[0])]))
        let skipped = Set((UserDefaults.standard.stringArray(forKey: "excludedFromUpdateAll") ?? [])
            + (UserDefaults.standard.stringArray(forKey: "hiddenTools") ?? []))
        let items = results.flatMap(\.1).filter { i in
            target == "all" ? i.state == .available && i.canUpdate && !skipped.contains(i.key) : i.key == target
        }
        if items.isEmpty { print("Nothing to update"); return 0 }
        var code: Int32 = 0
        for i in items {
            print("== \(i.machine.id)/\(i.defID): \(i.installed ?? "?") -> \(i.latest?.version ?? "latest")")
            let r = await Engine.update(i, relaunch: true)
            print(r.combined)
            if !r.ok { code = 1; print("FAILED") }
        }
        return code
    }
}
