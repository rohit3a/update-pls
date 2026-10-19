import SwiftUI

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "check" || args.first == "update" {
            exit(CLI.run(args))
        }
        UpdatePlsApp.main()
    }
}

struct UpdatePlsApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            let n = model.available.count
            Image(systemName: n > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
            if n > 0 { Text("\(n)") }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model)
        }
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
        let items = results.flatMap(\.1).filter { i in
            target == "all" ? i.state == .available && i.canUpdate : "\(i.machine.id)/\(i.defID)" == target
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
