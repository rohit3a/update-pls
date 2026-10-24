import AppKit
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    /// An update's progress and result, kept apart from the scanned items so a re-check never wipes it.
    enum Activity: Hashable {
        case queued
        case running(String, Double?)
        /// Finished, waiting for its machine to be read again to confirm it (the job's own message).
        case checking(String)
        case done(String)
        case failed(String)

        var isActive: Bool {
            switch self { case .queued, .running, .checking: true; default: false }
        }
    }

    enum Job: Hashable { case update, install(String, Engine.VersionSource) }

    enum CheckReason: String { case startup, manual, background }

    @Published var statuses: [MachineStatus] = []
    @Published var items: [Item] = []
    @Published var isChecking = false
    @Published var lastCheck: Date?
    @Published var selfLatest: String?
    @Published var selfUpdating = false
    @Published var selfError: String?
    @Published var hosts: [String] = SSHConfig.hosts()
    /// Update progress and results by item key.
    @Published var activity: [String: Activity] = [:]
    /// Each tool's last update output, by item key.
    @Published var runFiles: [String: URL] = [:]
    /// Published versions each tool can be switched to, by item key (looked up when its row is first hovered).
    @Published var versionLists: [String: [String]] = [:]
    private var loadingVersions: Set<String> = []
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
    @Published var askBeforeQuitting: Bool {
        didSet { UserDefaults.standard.set(!askBeforeQuitting, forKey: "dontAskBeforeQuitting") }
    }

    /// How a job runs and how a machine is re-checked afterwards; tests swap these out.
    var perform: (Item, Job, Reporter) async -> UpdateOutcome = { item, job, r in
        switch job {
        case .update: await Engine.update(item, relaunch: true, reporter: r)
        case let .install(v, source): await Engine.install(item, version: v, from: source, relaunch: true, reporter: r)
        }
    }
    var scan: @Sendable (Machine, Catalog, LatestResolver, [String: LatestInfo]) async -> (MachineStatus, [Item]) = { m, c, r, known in
        await Engine.check(m, catalog: c, resolver: r, known: known)
    }

    private var scheduler: NSBackgroundActivityScheduler?
    private var notified: Set<String>
    /// Jobs waiting, per machine. Each machine runs one job at a time (package managers lock); machines run in parallel.
    private var pending: [Machine: [(Item, Job)]] = [:]
    /// Machines with jobs running or being re-checked. The Mac stays awake while there are any.
    @Published private var workers: Set<Machine> = [] {
        didSet {
            if workers.isEmpty { KeepAwake.end(awake); awake = nil } else if awake == nil { awake = KeepAwake.begin("Updating tools") }
        }
    }
    private var awake: NSObjectProtocol?
    var keepsAwake: Bool { awake != nil }
    /// Machines being scanned by a check. Their queued jobs wait for it: a scan could catch an app mid-swap.
    private var scanning: Set<Machine> = []
    /// Each tool's last job, so Retry repeats a failed rollback rather than updating.
    private var lastJob: [String: Job] = [:]
    private var batch: [(name: String, ok: Bool, message: String)] = []
    /// Notifications only work from the app bundle (they crash a bare binary or the test runner).
    private let canNotify = Bundle.main.bundleURL.pathExtension == "app"

    init(autostart: Bool = true) {
        disabledHosts = Set(UserDefaults.standard.stringArray(forKey: "disabledHosts") ?? [])
        excluded = Set(UserDefaults.standard.stringArray(forKey: "excludedFromUpdateAll") ?? [])
        hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenTools") ?? [])
        previous = UserDefaults.standard.dictionary(forKey: "previousVersions") as? [String: String] ?? [:]
        notified = Set(UserDefaults.standard.stringArray(forKey: "notifiedUpdates") ?? [])
        askBeforeQuitting = !UserDefaults.standard.bool(forKey: "dontAskBeforeQuitting")
        let h = UserDefaults.standard.double(forKey: "intervalHours")
        intervalHours = h > 0 ? h : 3
        guard autostart else { return }
        Log.info("Update pls \(SelfUpdate.current) started on macOS \(ProcessInfo.processInfo.operatingSystemVersionString); "
                 + "hosts: \(machines.map(\.id).joined(separator: ", ")); log: \(Log.file.path)")
        if canNotify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in } }
        scheduleChecks()
        Task {
            let restored = await Engine.recoverInterruptedSwaps()
            if !restored.isEmpty {
                let content = UNMutableNotificationContent()
                content.title = "Put back after an interrupted update"
                content.body = restored.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                post(content)
            }
            await checkAll(.startup)
        }
    }

    var machines: [Machine] {
        [Machine.local] + hosts.filter { !disabledHosts.contains($0) }.map { Machine(id: $0, name: $0) }
    }

    /// Updates waiting: shown on the icon and in Update all.
    var pendingUpdates: [Item] {
        let on = Set(machines)
        return items.filter { on.contains($0.machine) && $0.state == .available && $0.canUpdate && !excluded.contains($0.key) && !hidden.contains($0.key) }
    }

    /// What Update all would start now (leaves out anything already queued or running).
    var updatable: [Item] { pendingUpdates.filter { !isActive($0) } }

    var isBusy: Bool { !workers.isEmpty || activity.values.contains(where: \.isActive) }
    var activeCount: Int { activity.values.filter(\.isActive).count }
    func isActive(_ item: Item) -> Bool { activity[item.key]?.isActive ?? false }

    /// "Cursor on rog-workstation" for a hidden tool's key, for Settings.
    func label(forKey key: String) -> String {
        guard let i = items.first(where: { $0.key == key }) else { return key }
        return i.machine.isLocal ? i.name : "\(i.name) on \(i.machine.name)"
    }

    func toggleExcluded(_ item: Item) {
        if excluded.contains(item.key) { excluded.remove(item.key) } else { excluded.insert(item.key) }
        History.clearHold(item.key)
    }

    var selfUpdateAvailable: Bool { selfLatest.map { Version.isNewer($0, than: SelfUpdate.current) } ?? false }

    /// Badge count in the menu bar: tool updates plus Update pls itself.
    var updateCount: Int { pendingUpdates.count + (selfUpdateAvailable ? 1 : 0) }

    /// A machine's items grouped by brand (Claude, OpenAI, Google, ...), brands in alphabetical order.
    func groups(for m: Machine) -> [(brand: String, items: [Item])] {
        Dictionary(grouping: items.filter { $0.machine == m && !hidden.contains($0.key) }, by: \.brand)
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { (brand: $0.key, items: $0.value.sorted { ($0.isApp ? 1 : 0, $0.name) < ($1.isApp ? 1 : 0, $1.name) }) }
    }

    // MARK: Checking

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
                guard let self else { return done(.finished) }
                // Never scan a machine while something is being installed on it.
                if self.isBusy { return done(.deferred) }
                await self.checkAll(.background)
                done(.finished)
            }
        }
        scheduler = s
    }

    func checkAll(_ reason: CheckReason = .manual) async {
        guard !isChecking, !(reason != .startup && isBusy) else { return }
        isChecking = true
        let start = Date()
        Log.info("checking all machines (\(reason.rawValue))")
        hosts = SSHConfig.hosts()
        // The command line may have recorded versions or skips since this app started.
        previous = History.previous
        excluded = History.excluded
        let catalog = Catalog.load()
        let resolver = LatestResolver()
        let machines = machines
        let scan = scan
        scanning = Set(machines)
        async let selfLatest = SelfUpdate.latest()
        statuses = machines.map { m in
            var s = statuses.first { $0.machine == m } ?? MachineStatus(machine: m)
            s.state = .checking
            return s
        }
        await withTaskGroup(of: (MachineStatus, [Item]).self) { group in
            for m in machines {
                group.addTask { await scan(m, catalog, resolver, [:]) }
            }
            for await (status, found) in group {
                apply(status, found)
                scanning.remove(status.machine)
            }
        }
        scanning = []
        items.removeAll { item in !machines.contains(item.machine) }
        if History.migrateVariantKeys(items) {
            previous = History.previous
            excluded = History.excluded
            hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenTools") ?? [])
        }
        self.selfLatest = await selfLatest ?? self.selfLatest
        // A failure stays until the tool is retried or turns out to be up to date; "Updated" until the next check you ask for.
        for (key, a) in activity {
            switch a {
            case .done where reason == .manual: activity[key] = nil
            case .failed where items.first(where: { $0.key == key })?.state == .upToDate: activity[key] = nil
            default: break
            }
        }
        lastCheck = Date()
        isChecking = false
        Log.info("check done in \(String(format: "%.1f", Date().timeIntervalSince(start)))s: \(pendingUpdates.count) updates waiting"
                 + (selfUpdateAvailable ? ", and Update pls \(self.selfLatest ?? "")" : ""))
        notifyNewUpdates()
    }

    /// Puts a machine's scan into the list. Offline machines keep their old list; a latest version
    /// that couldn't be looked up this time (GitHub rate limit, network blip) keeps the last known one.
    private func apply(_ status: MachineStatus, _ found: [Item]) {
        let m = status.machine
        if let i = statuses.firstIndex(where: { $0.machine == m }) { statuses[i] = status } else { statuses.append(status) }
        if case .offline = status.state { return }
        var found = found
        for i in found.indices where found[i].latest == nil {
            if let old = items.first(where: { $0.key == found[i].key })?.latest {
                found[i].latest = old
                found[i].state = Engine.state(found[i])
            }
        }
        items.removeAll { $0.machine == m }
        items.append(contentsOf: found)
    }

    // MARK: Updating

    func update(_ item: Item) {
        guard item.canUpdate, !isActive(item), confirmQuit([item]) else { return }
        enqueue([(item, .update)])
    }

    func updateAll() {
        let targets = updatable
        guard !targets.isEmpty, confirmQuit(targets) else { return }
        Log.info("Update all: \(targets.map(\.key).joined(separator: ", "))")
        enqueue(targets.map { ($0, .update) })
    }

    /// Saved copies this Mac app can switch to (other than the installed one), newest first.
    func savedVersions(_ item: Item) -> [String] { item.saved.filter { $0 != item.installed } }

    /// Published versions to offer next to the saved ones.
    func publishedVersions(_ item: Item) -> [String]? {
        versionLists[item.key].map { list in list.filter { !item.saved.contains($0) } }
    }

    /// Looks up the published versions once per tool, the first time its menu could be opened.
    func loadVersions(_ item: Item) {
        guard item.supportsRollback, versionLists[item.key] == nil, loadingVersions.insert(item.key).inserted else { return }
        Task {
            let list = await LatestResolver().versions(of: item, catalog: Catalog.load())
            versionLists[item.key] = list
            loadingVersions.remove(item.key)
        }
    }

    /// Switches a tool to another version: back to an older one, or forward to a newer saved one.
    func install(_ item: Item, version: String, from source: Engine.VersionSource) {
        guard !isActive(item), confirmInstall(item, version: version) else { return }
        enqueue([(item, .install(version, source))])
    }

    func dismiss(_ item: Item) { if !isActive(item) { activity[item.key] = nil } }

    /// Runs a failed job again: the same update, or the same switch to another version (already confirmed once).
    func retry(_ item: Item) {
        guard let job = lastJob[item.key], case .install = job else { return update(item) }
        enqueue([(item, job)])
    }

    func canRetry(_ item: Item) -> Bool {
        if case .install? = lastJob[item.key] { return true }
        return item.canUpdate
    }

    /// Queues jobs. Anything already queued or running is ignored, so pressing a button again does nothing.
    func enqueue(_ jobs: [(Item, Job)]) {
        // Update pls is about to quit and replace itself.
        guard !selfUpdating else { return }
        var seen = Set<String>()
        let fresh = jobs.filter { !isActive($0.0) && seen.insert($0.0.key).inserted }
        guard !fresh.isEmpty else { return }
        if !isBusy { batch = [] }
        for (item, job) in fresh {
            activity[item.key] = .queued
            pending[item.machine, default: []].append((item, job))
        }
        for m in Set(fresh.map(\.0.machine)) where !workers.contains(m) {
            workers.insert(m)
            Task { await drain(m) }
        }
    }

    private func drain(_ m: Machine) async {
        while scanning.contains(m) { try? await Task.sleep(for: .milliseconds(200)) }
        while let first = pending[m]?.first {
            var done: [(Item, Job, UpdateOutcome)] = []
            var next: (Item, Job)? = first
            while let (item, job) = next {
                pending[m]?.removeFirst()
                done.append((item, job, await run(item, job)))
                next = pending[m]?.first
            }
            await verify(m, done)
        }
        pending[m] = nil
        workers.remove(m)
        if workers.isEmpty { finishBatch() }
    }

    private func run(_ item: Item, _ job: Job) async -> UpdateOutcome {
        let key = item.key
        activity[key] = .running("Starting", nil)
        lastJob[key] = job
        let what = if case let .install(v, source) = job { "switch to \(v) (\(source == .saved ? "saved copy" : "published"))" } else { "update \(item.summary)" }
        let file = Log.newRun(key)
        runFiles[key] = file
        Log.appendRun(file, "\(Log.stamp()) \(item.name) on \(item.machine.name): \(what)\n")
        let reporter = Reporter(runFile: file) { [weak self] text, fraction in
            Task { @MainActor in
                guard let self, case .running = self.activity[key] else { return }
                self.activity[key] = .running(text, fraction)
            }
        }
        let outcome = await perform(item, job, reporter)
        Log.appendRun(file, "\n\(Log.stamp()) \(outcome.ok ? "Done" : "FAILED"): \(outcome.message)\n")
        activity[key] = outcome.ok ? .checking(outcome.message) : .failed(outcome.message)
        return outcome
    }

    /// Re-reads the machine once its queue is empty and confirms each job by its installed version. Only then
    /// is it shown as done and recorded (the version kept for rollback, a hold on Update all).
    private func verify(_ m: Machine, _ done: [(Item, Job, UpdateOutcome)]) async {
        let known = Dictionary(items.filter { $0.machine == m }.compactMap { i in i.latest.map { (i.key, $0) } }, uniquingKeysWith: { a, _ in a })
        let (status, found) = await scan(m, Catalog.load(), LatestResolver(), known)
        apply(status, found)
        let offline = if case .offline = status.state { true } else { false }
        for (item, job, o) in done {
            let key = item.key
            let version: String? = if case let .install(v, _) = job { v } else { nil }
            let (ok, message) = Engine.confirm(item, switchedTo: version, o, fresh: found.first { $0.key == key }, offline: offline)
            if ok, let hold = History.record(item, switchedTo: version, o) {
                Log.info("\(key): \(hold == .added ? "held back from Update all" : "back in Update all")")
            }
            if o.ok && !ok { Log.error("verify \(key): \(message)") }
            activity[key] = ok ? .done(message) : .failed(message)
            batch.append((item.name, ok, message))
        }
        previous = History.previous
        excluded = History.excluded
    }

    private func finishBatch() {
        guard !batch.isEmpty else { return }
        let failed = batch.filter { !$0.ok }, ok = batch.filter(\.ok)
        Log.info("batch done: \(ok.count) ok, \(failed.count) failed"
                 + (failed.isEmpty ? "" : "\n" + failed.map { "\($0.name): \($0.message)" }.joined(separator: "\n")))
        let content = UNMutableNotificationContent()
        if failed.isEmpty {
            content.title = ok.count == 1 ? "\(ok[0].name): \(ok[0].message)" : "Updated \(ok.count) tools"
            content.body = ok.count == 1 ? "" : ok.prefix(5).map { "\($0.name): \($0.message)" }.joined(separator: "\n")
        } else {
            content.title = failed.count == 1 ? "\(failed[0].name) couldn't update" : "\(failed.count) updates failed"
            content.body = (failed.prefix(4).map { "\($0.name): \($0.message)" } + (ok.isEmpty ? [] : ["\(ok.count) others updated"]))
                .joined(separator: "\n")
        }
        batch = []
        post(content)
    }

    func updateSelf() async {
        guard !isBusy else { return }
        selfUpdating = true
        selfError = await SelfUpdate.update()
        selfUpdating = false
    }

    // MARK: Asking

    /// One prompt listing the open apps an update will quit and reopen, with "Don't ask again".
    private func confirmQuit(_ targets: [Item]) -> Bool {
        // apt apps aren't quit (an open one stops with a message instead), so they aren't listed.
        let open = targets.filter { t in
            if case .deb = t.method { return false }
            return t.isApp && (t.machine.isLocal ? !LocalApps.instances(t.path).isEmpty : t.running)
        }
        guard !open.isEmpty, askBeforeQuitting else { return true }
        let alert = NSAlert()
        alert.messageText = open.count == 1 ? "\(open[0].name) is open" : "\(open.count) apps are open"
        alert.informativeText = open.map { $0.machine.isLocal ? $0.name : "\($0.name) on \($0.machine.name)" }.joined(separator: ", ")
            + (open.count == 1 ? " will quit, update and reopen." : " will each quit, update and reopen.")
        alert.addButton(withTitle: "Update & Relaunch")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        let ok = alert.runModal() == .alertFirstButtonReturn
        if ok && alert.suppressionButton?.state == .on { askBeforeQuitting = false }
        return ok
    }

    private func confirmInstall(_ item: Item, version v: String) -> Bool {
        let older = Version.isNewer(item.installed ?? "", than: v)
        let open = item.isApp && (item.machine.isLocal ? !LocalApps.instances(item.path).isEmpty : item.running)
        let alert = NSAlert()
        alert.messageText = older ? "Roll back \(item.name) to \(v)?" : "Switch \(item.name) to \(v)?"
        alert.informativeText = [
            open ? "\(item.name) will quit and reopen." : nil,
            older && item.isApp ? "Older versions may not open data saved by newer ones." : nil,
            (item.latest.map { Version.isNewer($0.version, than: v) } ?? false) ? "It will be skipped in Update all until you include it again." : nil,
        ].compactMap { $0 }.joined(separator: " ")
        alert.addButton(withTitle: older ? "Roll Back" : "Switch")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks before quitting in the middle of an update, which would leave it half done.
    func quit() {
        if isBusy {
            let alert = NSAlert()
            alert.messageText = "Updates are still running"
            alert.informativeText = "Quitting now can leave an app half updated."
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Quit Anyway")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { return }
        }
        Log.info("quit")
        NSApp.terminate(nil)
    }

    // MARK: Notifications

    private func notifyNewUpdates() {
        let fresh = pendingUpdates.filter { !notified.contains("\($0.key)@\($0.latest?.version ?? "")") }
        guard !fresh.isEmpty else { return }
        notified = Set(pendingUpdates.map { "\($0.key)@\($0.latest?.version ?? "")" })
        UserDefaults.standard.set(Array(notified), forKey: "notifiedUpdates")
        let content = UNMutableNotificationContent()
        content.title = fresh.count == 1 ? "\(fresh[0].name) can be updated" : "\(fresh.count) updates available"
        content.body = fresh.prefix(4).map { "\($0.name) \($0.installed ?? "") → \($0.latest?.version ?? "") (\($0.machine.name))" }.joined(separator: "\n")
        post(content)
    }

    private func post(_ content: UNMutableNotificationContent) {
        guard canNotify else { return }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { try newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch {
                Log.error("open at login: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }
}
