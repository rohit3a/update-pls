import AppKit
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var statuses: [MachineStatus] = []
    @Published var items: [Item] = []
    @Published var isChecking = false
    @Published var lastCheck: Date?
    @Published var hosts: [String] = SSHConfig.hosts()
    @Published var disabledHosts: Set<String> {
        didSet { UserDefaults.standard.set(Array(disabledHosts), forKey: "disabledHosts") }
    }
    @Published var intervalHours: Double {
        didSet { UserDefaults.standard.set(intervalHours, forKey: "intervalHours"); scheduleChecks() }
    }

    private var timer: Task<Void, Never>?
    private var notified: Set<String> = []

    init() {
        disabledHosts = Set(UserDefaults.standard.stringArray(forKey: "disabledHosts") ?? [])
        let h = UserDefaults.standard.double(forKey: "intervalHours")
        intervalHours = h > 0 ? h : 6
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
        scheduleChecks()
    }

    var machines: [Machine] {
        [Machine.local] + hosts.filter { !disabledHosts.contains($0) }.map { Machine(id: $0, name: $0) }
    }

    var available: [Item] { items.filter { $0.state == .available && $0.canUpdate } }

    func items(for m: Machine) -> [Item] {
        items.filter { $0.machine == m }.sorted { ($0.state.sortKey, $0.name) < ($1.state.sortKey, $1.name) }
    }

    func scheduleChecks() {
        timer?.cancel()
        let seconds = intervalHours * 3600
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkAll()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func checkAll() async {
        guard !isChecking else { return }
        isChecking = true
        hosts = SSHConfig.hosts()
        let catalog = Catalog.load()
        let resolver = LatestResolver()
        let machines = machines
        statuses = machines.map { m in
            var s = statuses.first { $0.machine == m } ?? MachineStatus(machine: m)
            s.state = .checking
            return s
        }
        await withTaskGroup(of: Void.self) { group in
            for m in machines {
                group.addTask { await self.check(m, catalog: catalog, resolver: resolver) }
            }
        }
        items.removeAll { item in !machines.contains(item.machine) }
        lastCheck = Date()
        isChecking = false
        notifyNewUpdates()
    }

    func check(_ m: Machine, catalog: Catalog = Catalog.load(), resolver: LatestResolver = LatestResolver()) async {
        let (status, found) = await Engine.check(m, catalog: catalog, resolver: resolver)
        if let i = statuses.firstIndex(where: { $0.machine == m }) { statuses[i] = status } else { statuses.append(status) }
        // Keep the old list for machines that are offline right now.
        if case .offline = status.state { return }
        items.removeAll { $0.machine == m }
        items.append(contentsOf: found)
    }

    func update(_ item: Item) async {
        guard item.canUpdate else { return }
        if item.running && !confirmRelaunch([item]) { return }
        await runUpdate(item)
    }

    func updateAll() async {
        let targets = available
        let open = targets.filter(\.running)
        if !open.isEmpty && !confirmRelaunch(open) { return }
        // One at a time per machine (package managers lock), machines in parallel.
        let byMachine = Dictionary(grouping: targets, by: \.machine)
        await withTaskGroup(of: Void.self) { group in
            for (_, list) in byMachine {
                group.addTask { for item in list { await self.runUpdate(item) } }
            }
        }
    }

    private func runUpdate(_ item: Item) async {
        set(item.id) { $0.state = .updating; $0.log = "" }
        let result = await Engine.update(item, relaunch: true)
        let log = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.ok {
            // Confirm by reading the version again.
            await check(item.machine)
            if let fresh = items.first(where: { $0.id == item.id }) {
                set(fresh.id) { $0.state = fresh.state == .available ? .failed("Still on \(fresh.installed ?? "?") after updating") : .updated; $0.log = log }
            }
        } else {
            let last = log.split(separator: "\n").last.map(String.init) ?? "Update failed"
            set(item.id) { $0.state = .failed(result.timedOut ? "Timed out" : last); $0.log = log }
        }
    }

    private func set(_ id: String, _ change: (inout Item) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { change(&items[i]) }
    }

    private func confirmRelaunch(_ items: [Item]) -> Bool {
        let names = items.map { "\($0.name) on \($0.machine.name)" }.joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = items.count == 1 ? "\(items[0].name) is open" : "Some apps are open"
        alert.informativeText = "\(names) will quit, update and reopen."
        alert.addButton(withTitle: "Update & Relaunch")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func notifyNewUpdates() {
        let fresh = available.filter { !notified.contains("\($0.id)@\($0.latest?.version ?? "")") }
        guard !fresh.isEmpty else { return }
        for i in fresh { notified.insert("\(i.id)@\(i.latest?.version ?? "")") }
        let content = UNMutableNotificationContent()
        content.title = fresh.count == 1 ? "\(fresh[0].name) can be updated" : "\(fresh.count) updates available"
        content.body = fresh.prefix(4).map { "\($0.name) \($0.installed ?? "") → \($0.latest?.version ?? "") (\($0.machine.name))" }.joined(separator: "\n")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            objectWillChange.send()
        }
    }
}

extension ItemState {
    var sortKey: Int {
        switch self {
        case .failed: 0
        case .available, .updating: 1
        case .updated: 2
        case .unknown: 3
        case .upToDate: 4
        }
    }
}
