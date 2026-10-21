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
    @Published var selfLatest: String?
    @Published var selfUpdating = false
    @Published var selfError: String?
    @Published var hosts: [String] = SSHConfig.hosts()
    @Published var disabledHosts: Set<String> {
        didSet { UserDefaults.standard.set(Array(disabledHosts), forKey: "disabledHosts") }
    }
    /// Tools (`machine/tool`) that Update all leaves alone.
    @Published var excluded: Set<String> {
        didSet { UserDefaults.standard.set(Array(excluded), forKey: "excludedFromUpdateAll") }
    }
    /// Tools (`machine/tool`) left out of the list altogether.
    @Published var hidden: Set<String> {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "hiddenTools") }
    }
    /// The version each tool (`machine/tool`) was on before Update pls last updated it, for rollback.
    @Published var previous: [String: String] {
        didSet { UserDefaults.standard.set(previous, forKey: "previousVersions") }
    }
    @Published var intervalHours: Double {
        didSet { UserDefaults.standard.set(intervalHours, forKey: "intervalHours"); scheduleChecks() }
    }

    private var scheduler: NSBackgroundActivityScheduler?
    private var notified: Set<String> = []

    init() {
        disabledHosts = Set(UserDefaults.standard.stringArray(forKey: "disabledHosts") ?? [])
        excluded = Set(UserDefaults.standard.stringArray(forKey: "excludedFromUpdateAll") ?? [])
        hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenTools") ?? [])
        previous = UserDefaults.standard.dictionary(forKey: "previousVersions") as? [String: String] ?? [:]
        let h = UserDefaults.standard.double(forKey: "intervalHours")
        intervalHours = h > 0 ? h : 3
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
        scheduleChecks()
        Task { await checkAll() }
    }

    var machines: [Machine] {
        [Machine.local] + hosts.filter { !disabledHosts.contains($0) }.map { Machine(id: $0, name: $0) }
    }

    var available: [Item] {
        items.filter { $0.state == .available && $0.canUpdate && !excluded.contains($0.key) && !hidden.contains($0.key) }
    }

    /// "Cursor on rog-workstation" for a hidden tool's key, for Settings.
    func label(forKey key: String) -> String {
        guard let i = items.first(where: { $0.key == key }) else { return key }
        return i.machine.isLocal ? i.name : "\(i.name) on \(i.machine.name)"
    }

    func toggleExcluded(_ item: Item) {
        if excluded.contains(item.key) { excluded.remove(item.key) } else { excluded.insert(item.key) }
    }

    /// The version a rollback would go back to, if Update pls replaced one and can put it back.
    func rollbackVersion(_ item: Item) -> String? {
        guard item.supportsRollback, let v = previous[item.key], v != item.installed else { return nil }
        return v
    }

    func rollback(_ item: Item) async {
        guard let v = rollbackVersion(item), confirmRollback(item, to: v) else { return }
        set(item.id) { $0.state = .updating; $0.log = "" }
        let result = await Engine.rollback(item, to: v, relaunch: true)
        let log = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.ok else {
            let last = log.split(separator: "\n").last.map(String.init) ?? "Rollback failed"
            set(item.id) { $0.state = .failed(result.timedOut ? "Timed out" : last); $0.log = log }
            return
        }
        // Keep it on this version: Update all would otherwise take it straight back to the new one.
        excluded.insert(item.key)
        previous[item.key] = nil
        await check(item.machine)
        if let fresh = items.first(where: { $0.key == item.key }), fresh.installed != v {
            set(fresh.id) { $0.state = .failed("Still on \(fresh.installed ?? "?") after rolling back"); $0.log = log }
        }
    }

    var selfUpdateAvailable: Bool { selfLatest.map { Version.isNewer($0, than: SelfUpdate.current) } ?? false }

    /// Badge count in the menu bar: tool updates plus Update pls itself.
    var updateCount: Int { available.count + (selfUpdateAvailable ? 1 : 0) }

    /// A machine's items grouped by brand (Claude, OpenAI, Google, ...), brands in alphabetical order.
    func groups(for m: Machine) -> [(brand: String, items: [Item])] {
        Dictionary(grouping: items(for: m), by: \.brand)
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { (brand: $0.key, items: $0.value.sorted { ($0.isApp ? 1 : 0, $0.name) < ($1.isApp ? 1 : 0, $1.name) }) }
    }

    func items(for m: Machine) -> [Item] {
        items.filter { $0.machine == m && !hidden.contains($0.key) }.sorted { ($0.state.sortKey, $0.name) < ($1.state.sortKey, $1.name) }
    }

    /// Background checks through macOS's activity scheduler, which picks an energy-friendly moment
    /// within the tolerance (and catches up after sleep) instead of keeping a timer awake.
    func scheduleChecks() {
        scheduler?.invalidate()
        let s = NSBackgroundActivityScheduler(identifier: "com.rohit3a.updatepls.check")
        s.repeats = true
        s.interval = intervalHours * 3600
        s.tolerance = s.interval / 10
        s.qualityOfService = .utility
        s.schedule { [weak self] done in
            Task { @MainActor in
                await self?.checkAll()
                done(.finished)
            }
        }
        scheduler = s
    }

    func checkAll() async {
        guard !isChecking else { return }
        isChecking = true
        hosts = SSHConfig.hosts()
        let catalog = Catalog.load()
        let resolver = LatestResolver()
        let machines = machines
        async let selfLatest = SelfUpdate.latest()
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
        self.selfLatest = await selfLatest ?? self.selfLatest
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

    func updateSelf() async {
        selfUpdating = true
        selfError = await SelfUpdate.update()
        selfUpdating = false
    }

    private func runUpdate(_ item: Item) async {
        set(item.id) { $0.state = .updating; $0.log = "" }
        let result = await Engine.update(item, relaunch: true)
        let log = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.ok {
            // An app that had already updated itself leaves no saved copy to roll back to.
            if item.supportsRollback, let v = item.installed, !log.contains("Already on") { previous[item.key] = v }
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

    private func confirmRollback(_ item: Item, to v: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Roll back \(item.name) to \(v)?"
        alert.informativeText = (item.running ? "\(item.name) will quit and reopen. " : "")
            + "It will be skipped in Update all until you include it again."
        alert.addButton(withTitle: "Roll Back")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
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
