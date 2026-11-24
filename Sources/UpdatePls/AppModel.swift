import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// Caches `NSWorkspace.shared.icon(forFile:)` so SwiftUI row redraws never repeatedly hit LaunchServices/disk,
/// and shares local Mac app icons by `defID` so remote machines also show real app icons.
@MainActor
enum AppIconCache {
    private static var byPath: [String: NSImage] = [:]
    private static var byDefID: [String: NSImage] = [:]

    static func icon(for item: Item) -> NSImage? {
        guard item.isApp else { return nil }
        // Variants (T3 Code and T3 Code Nightly) have their own icons, and an update can bring a new one.
        let shared = "\(item.defID)|\(item.variant ?? (item.path as NSString).lastPathComponent)"
        if item.machine.isLocal {
            let key = "\(item.path)|\(item.installed ?? "")"
            if let hit = byPath[key] { return hit }
            let img = NSWorkspace.shared.icon(forFile: item.path)
            byPath[key] = img
            byDefID[shared] = img
            return img
        }
        return byDefID[shared]
    }
}

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

    /// Inline confirmation state when an update needs to quit one or more open apps.
    struct PendingQuit: Equatable {
        let targets: [Item]
        let openNames: [String]
    }

    @Published var statuses: [MachineStatus] = []
    @Published var items: [Item] = [] {
        didSet { rebuildGroupCache() }
    }
    @Published var isChecking = false
    @Published var lastCheck: Date?
    @Published var selfLatest: String?
    @Published var selfUpdating = false
    @Published var selfError: String?
    @Published var hosts: [String] = SSHConfig.hosts()
    /// Where each alias connects ("user@host:port"), so aliases for one machine show as one.
    @Published private(set) var hostTargets: [String: String] = [:]
    /// Update progress and results by item key.
    @Published var activity: [String: Activity] = [:]
    /// Each tool's last update output, by item key.
    @Published var runFiles: [String: URL] = [:]
    /// Published versions each tool can be switched to, by item key.
    @Published var versionLists: [String: [String]] = [:]
    private var loadingVersions: Set<String> = []
    private var hoverTasks: [String: Task<Void, Never>] = [:]
    @Published var disabledHosts: Set<String> {
        didSet { UserDefaults.standard.set(Array(disabledHosts), forKey: "disabledHosts") }
    }
    /// Tools (`machine/tool`) that Update all leaves alone.
    @Published var excluded: Set<String> {
        didSet { UserDefaults.standard.set(Array(excluded), forKey: "excludedFromUpdateAll") }
    }
    /// Tools (`machine/tool`) left out of the list altogether.
    @Published var hidden: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(hidden), forKey: "hiddenTools")
            rebuildGroupCache()
        }
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
    /// Prefer direct downloads over Homebrew Cask for Mac apps (enables APFS rollback, signature checks, ShipIt safety).
    @Published var preferDirectDownloads: Bool {
        didSet {
            UserDefaults.standard.set(!preferDirectDownloads, forKey: "useHomebrewForApps")
            if oldValue != preferDirectDownloads, !isBusy, !isChecking, lastCheck != nil {
                Task { await checkAll(.manual) }
            }
        }
    }
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(!notificationsEnabled, forKey: "disableNotifications") }
    }
    /// Inline quit confirmation shown inside the popover instead of a modal alert.
    @Published var pendingQuit: PendingQuit?
    /// Batch progress counters for the header while updates are running.
    @Published var batchTotal: Int = 0
    @Published var batchCompleted: Int = 0
    /// Local rollback backup usage shown in Settings.
    @Published var backupBytes: Int64 = 0
    @Published var backupVersions: Int = 0
    @Published var backupApps: Int = 0
    @Published var isCleaningBackups = false

    /// How a job runs and how a machine is re-checked afterwards; tests swap these out.
    var perform: (Item, Job, Reporter) async -> UpdateOutcome = { item, job, r in
        switch job {
        case .update: await Engine.update(item, relaunch: true, reporter: r)
        case let .install(v, source): await Engine.install(item, version: v, from: source, relaunch: true, reporter: r)
        }
    }
    private var customScan = false
    var scan: @Sendable (Machine, Catalog, LatestResolver, [String: LatestInfo]) async -> (MachineStatus, [Item]) = { m, c, r, known in
        await Engine.check(m, catalog: c, resolver: r, known: known)
    } {
        didSet { customScan = true }
    }

    private var scheduler: NSBackgroundActivityScheduler?
    private var notified: Set<String>
    /// Jobs waiting, per machine, in the order they were queued. Each machine works through them in lanes
    /// (see `lane(_:)`): one job at a time per lane, lanes and machines in parallel.
    private var pending: [Machine: [(Item, Job)]] = [:]
    /// Active tasks by item key so running jobs can be cancelled cleanly.
    private var runningTasks: [String: Task<UpdateOutcome, Never>] = [:]
    /// Each running job's reporter, which knows whether the job has passed its point of no return.
    private var reporters: [String: Reporter] = [:]
    struct Lane: Hashable { let machine: Machine; let name: String }
    /// When each running job started and last showed progress, by item key.
    private var runStarted: [String: Date] = [:]
    private var lastProgress: [String: Date] = [:]
    /// Cached brand-grouped items per machine id, rebuilt only when `items` or `hidden` change.
    private var groupCache: [String: [(brand: String, items: [Item])]] = [:]
    /// Tools whose updater refused to run until someone signs in to it (Cursor Agent). Update all leaves them
    /// out, so they don't fail every time, until they update.
    @Published var waitingForSignIn: Set<String> {
        didSet { UserDefaults.standard.set(Array(waitingForSignIn), forKey: "waitingForSignIn") }
    }
    /// Lanes with jobs running or being re-checked. The Mac stays awake while there are any.
    @Published private var workers: Set<Lane> = [] {
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
        waitingForSignIn = Set(UserDefaults.standard.stringArray(forKey: "waitingForSignIn") ?? [])
        notified = Set(UserDefaults.standard.stringArray(forKey: "notifiedUpdates") ?? [])
        askBeforeQuitting = !UserDefaults.standard.bool(forKey: "dontAskBeforeQuitting")
        preferDirectDownloads = !UserDefaults.standard.bool(forKey: "useHomebrewForApps")
        notificationsEnabled = !UserDefaults.standard.bool(forKey: "disableNotifications")
        let h = UserDefaults.standard.double(forKey: "intervalHours")
        intervalHours = h > 0 ? h : 3
        guard autostart else { return }
        if canNotify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in } }
        scheduleChecks()
        Task {
            hostTargets = await SSHConfig.targetsAsync(hosts)
            Log.info("Update pls \(SelfUpdate.current) started on macOS \(ProcessInfo.processInfo.operatingSystemVersionString); "
                     + "hosts: \(machines.map(\.id).joined(separator: ", ")); log: \(Log.file.path)")
            let restored = await Engine.recoverInterruptedSwaps()
            if !restored.isEmpty {
                let content = UNMutableNotificationContent()
                content.title = "Put back after an interrupted update"
                content.body = restored.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                post(content)
            }
            await checkAll(.startup)
            refreshBackupStats()
        }
    }

    var machines: [Machine] {
        [Machine.local] + SSHConfig.machines(hosts: hosts, disabled: disabledHosts, targets: hostTargets, preferred: SSHConfig.preferred)
    }

    /// Updates waiting: shown on the icon and in Update all.
    var pendingUpdates: [Item] {
        let on = Set(machines)
        return items.filter { on.contains($0.machine) && $0.state == .available && $0.canUpdate && !excluded.contains($0.key)
            && !hidden.contains($0.key) && !waitingForSignIn.contains($0.key) }
    }

    /// What Update all would start now (leaves out anything already queued or running).
    var updatable: [Item] { pendingUpdates.filter { !isActive($0) } }

    /// What "Update" for one machine would start now.
    func updatable(for m: Machine) -> [Item] { updatable.filter { $0.machine == m } }

    var isBusy: Bool { !workers.isEmpty || activity.values.contains(where: \.isActive) }
    var activeCount: Int { activity.values.filter(\.isActive).count }
    var failedCount: Int {
        activity.values.filter { if case .failed = $0 { true } else { false } }.count
    }
    func isActive(_ item: Item) -> Bool { activity[item.key]?.isActive ?? false }

    /// True if this item is queued, or running and not yet past its point of no return: the job itself says
    /// when it starts quitting or replacing an app (see `Reporter.commit`). Over SSH, only a Mac app download
    /// can be stopped, since a cancel can't reach an installer running there.
    func canCancel(_ item: Item) -> Bool {
        switch activity[item.key] {
        case .queued?: return true
        case .running?:
            guard let r = reporters[item.key], !r.isCommitted else { return false }
            let current = items.first { $0.key == item.key } ?? item
            if current.machine.isLocal { return true }
            if case .macDirect = current.method { return true }
            return false
        default: return false
        }
    }

    /// "Cursor on my-server" for a hidden/skipped tool's key, for Settings.
    func label(forKey key: String) -> String {
        guard let i = items.first(where: { $0.key == key }) else { return key }
        return i.machine.isLocal ? i.name : "\(i.name) on \(i.machine.name)"
    }

    /// For Settings: the machine this alias is shown under, when that's another alias for the same machine.
    func sameMachine(as alias: String) -> String? {
        guard let t = hostTargets[alias] else { return nil }
        return machines.first { $0.id != alias && !$0.isLocal && hostTargets[$0.id] == t }?.id
    }

    func toggleExcluded(_ item: Item) {
        if excluded.contains(item.key) { excluded.remove(item.key) } else { excluded.insert(item.key) }
        History.clearHold(item.key)
    }

    func toggleExcluded(key: String) {
        if excluded.contains(key) { excluded.remove(key) } else { excluded.insert(key) }
        History.clearHold(key)
    }

    var selfUpdateAvailable: Bool { selfLatest.map { Version.isNewer($0, than: SelfUpdate.current) } ?? false }

    /// Badge count in the menu bar: tool updates plus Update pls itself.
    var updateCount: Int { pendingUpdates.count + (selfUpdateAvailable ? 1 : 0) }

    /// Total visible tools across enabled machines.
    var visibleToolCount: Int {
        let on = Set(machines)
        return items.filter { on.contains($0.machine) && !hidden.contains($0.key) }.count
    }

    private func rebuildGroupCache() {
        var next: [String: [(brand: String, items: [Item])]] = [:]
        let byMachine = Dictionary(grouping: items.filter { !hidden.contains($0.key) }, by: { $0.machine.id })
        for (mid, list) in byMachine {
            next[mid] = Dictionary(grouping: list, by: \.brand)
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { (brand: $0.key, items: $0.value.sorted { ($0.isApp ? 1 : 0, $0.name) < ($1.isApp ? 1 : 0, $1.name) }) }
        }
        groupCache = next
    }

    /// A machine's items grouped by brand (Claude, OpenAI, Google, ...), brands in alphabetical order.
    func groups(for m: Machine) -> [(brand: String, items: [Item])] {
        groupCache[m.id] ?? []
    }

    /// True if an item should appear in the primary/actionable section (has an update, is active, or failed/just finished).
    func isActionable(_ item: Item) -> Bool {
        if let a = activity[item.key] {
            switch a {
            case .queued, .running, .checking, .failed, .done: return true
            }
        }
        return item.state == .available
    }

    /// Splits a machine's visible items into actionable (updates/active/errors) and up-to-date groups.
    func partitionedGroups(for m: Machine) -> (actionable: [(brand: String, items: [Item])], upToDate: [(brand: String, items: [Item])]) {
        let all = groups(for: m)
        var act: [(brand: String, items: [Item])] = []
        var ok: [(brand: String, items: [Item])] = []
        for g in all {
            let a = g.items.filter { isActionable($0) }
            let u = g.items.filter { !isActionable($0) }
            if !a.isEmpty { act.append((g.brand, a)) }
            if !u.isEmpty { ok.append((g.brand, u)) }
        }
        return (act, ok)
    }

    func releaseNotesURL(for item: Item) -> URL? {
        Engine.releaseNotesURL(for: item, catalog: Catalog.load())
    }

    // MARK: Backups

    func refreshBackupStats() {
        Task.detached(priority: .utility) {
            let stats = Engine.backupStats()
            await MainActor.run {
                self.backupBytes = stats.bytes
                self.backupVersions = stats.versions
                self.backupApps = stats.apps
            }
        }
    }

    /// Why the last cleanup didn't run, for Settings.
    @Published var backupCleanupNote: String?

    func cleanBackups(keep: Int) {
        guard !isCleaningBackups else { return }
        // An update may be filing a saved version or relying on one to put an app back.
        guard !isBusy else {
            backupCleanupNote = "Wait for the updates to finish"
            return
        }
        backupCleanupNote = nil
        isCleaningBackups = true
        Task.detached(priority: .utility) {
            let result = Engine.pruneBackups(keep: keep)
            let stats = Engine.backupStats()
            await MainActor.run {
                self.backupBytes = stats.bytes
                self.backupVersions = stats.versions
                self.backupApps = stats.apps
                self.isCleaningBackups = false
                switch result {
                case let .success(removed):
                    if removed > 0 { Log.info("pruned \(removed) old rollback backup(s)") }
                    self.refreshSavedVersions()
                case .failure:
                    self.backupCleanupNote = "An update is using the saved versions; try again when it's done"
                }
            }
        }
    }

    /// After a cleanup, rollback menus (and Update after a rollback) offer only copies that still exist.
    private func refreshSavedVersions() {
        for i in items.indices where items[i].machine.isLocal {
            if case .macDirect = items[i].method { items[i].saved = Engine.savedVersions(of: items[i]) }
        }
    }

    var backupSummary: String {
        guard backupVersions > 0 else { return "None stored" }
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return "\(fmt.string(fromByteCount: backupBytes)) (\(backupVersions) \(backupVersions == 1 ? "copy" : "copies") across \(backupApps) \(backupApps == 1 ? "app" : "apps"))"
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
        let start = Date(), asleep = SleepClock.asleep
        Log.info("checking all machines (\(reason.rawValue))")
        let latestHosts = SSHConfig.hosts()
        // A check you ask for also re-reads where each alias leads (an edited ~/.ssh/config).
        if latestHosts != hosts || hostTargets.isEmpty || reason == .manual {
            hosts = latestHosts
            if !customScan {
                hostTargets = await SSHConfig.targetsAsync(latestHosts)
            }
        }
        // The command line may have recorded versions or skips since this app started.
        previous = History.previous
        excluded = History.excluded
        let catalog = Catalog.load()
        let resolver = LatestResolver()
        let machines = machines
        let scan = scan
        let useCustomScan = customScan
        let preferDirect = preferDirectDownloads
        let refreshPath = (reason == .manual || reason == .startup)
        scanning = Set(machines)
        async let selfLatest = SelfUpdate.latest()
        statuses = machines.map { m in
            var s = statuses.first { $0.machine == m } ?? MachineStatus(machine: m)
            s.state = .checking
            return s
        }
        await withTaskGroup(of: (MachineStatus, [Item]).self) { group in
            for m in machines {
                group.addTask {
                    if useCustomScan {
                        return await scan(m, catalog, resolver, [:])
                    }
                    return await Engine.check(m, catalog: catalog, resolver: resolver, known: [:],
                                              preferDirectDownloads: preferDirect, forcePathRefresh: refreshPath)
                }
            }
            for await (status, found) in group {
                apply(status, found)
                scanning.remove(status.machine)
            }
        }
        scanning = []
        // A check that fell back to another alias for the same machine lists it under that alias from now on.
        let current = machines
        statuses.removeAll { !current.contains($0.machine) }
        items.removeAll { item in !current.contains(item.machine) }
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
            // Its tool (or the alias it was on) is gone: nothing is left to retry or dismiss.
            case .failed where !items.contains(where: { $0.key == key }): activity[key] = nil
            case .done where !items.contains(where: { $0.key == key }): activity[key] = nil
            default: break
            }
        }
        lastCheck = Date()
        isChecking = false
        Log.info("check done in \(SleepClock.took(since: start, asleep: asleep)): \(pendingUpdates.count) updates waiting"
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
        // Jobs in other lanes may still be running on this machine: their rows keep what they showed before,
        // since a read taken mid-update (an app moved aside for its swap) isn't the tool's real state.
        let running = items.filter { i in
            if i.machine == m, case .running? = activity[i.key] { true } else { false }
        }
        found.removeAll { f in running.contains { $0.key == f.key } }
        items.removeAll { $0.machine == m }
        items.append(contentsOf: found + running)
        // Signed in and updated some other way: back in Update all.
        let current = Set(found.filter { $0.state != .available }.map(\.key))
        if !waitingForSignIn.isDisjoint(with: current) { waitingForSignIn.subtract(current) }
    }

    /// Merges one targeted single-item verification result into `items`.
    private func applySingle(_ status: MachineStatus, _ fresh: Item?) {
        let m = status.machine
        if let i = statuses.firstIndex(where: { $0.machine == m }) { statuses[i] = status }
        guard case .online = status.state, var fresh else { return }
        if fresh.latest == nil, let old = items.first(where: { $0.key == fresh.key })?.latest {
            fresh.latest = old
            fresh.state = Engine.state(fresh)
        }
        if let idx = items.firstIndex(where: { $0.key == fresh.key }) {
            items[idx] = fresh
        } else {
            items.append(fresh)
        }
        if fresh.state != .available { waitingForSignIn.remove(fresh.key) }
    }

    // MARK: Updating

    func update(_ item: Item) {
        // Jobs finish one by one now, so a press can arrive with a row's old copy just after its update ended:
        // only what the latest check says is still waiting gets queued.
        let item = items.first { $0.key == item.key } ?? item
        guard item.canUpdate, item.state == .available, !isActive(item) else { return }
        requestStart([item])
    }

    func updateAll() {
        let targets = updatable
        guard !targets.isEmpty else { return }
        requestStart(targets, logAll: true)
    }

    func updateMachine(_ m: Machine) {
        let targets = updatable(for: m)
        guard !targets.isEmpty else { return }
        requestStart(targets)
    }

    private func requestStart(_ targets: [Item], logAll: Bool = false) {
        let open = targets.filter { t in t.isApp && (t.machine.isLocal ? !LocalApps.instances(t.path).isEmpty : t.running) }
        if !open.isEmpty && askBeforeQuitting {
            let names = open.map { $0.machine.isLocal ? $0.name : "\($0.name) on \($0.machine.name)" }
            pendingQuit = PendingQuit(targets: targets, openNames: names)
            return
        }
        if logAll { Log.info("Update all: \(targets.map(\.key).joined(separator: ", "))") }
        enqueue(targets.map { ($0, .update) })
    }

    func confirmPendingQuit(dontAskAgain: Bool) {
        guard let pending = pendingQuit else { return }
        pendingQuit = nil
        if dontAskAgain { askBeforeQuitting = false }
        Log.info("Update confirmed (\(pending.targets.count)): \(pending.targets.map(\.key).joined(separator: ", "))")
        enqueue(pending.targets.map { ($0, .update) })
    }

    func cancelPendingQuit() {
        pendingQuit = nil
    }

    /// Saved copies this Mac app can switch to (other than the installed one), newest first.
    func savedVersions(_ item: Item) -> [String] { item.saved.filter { $0 != item.installed } }

    /// Published versions to offer next to the saved ones.
    func publishedVersions(_ item: Item) -> [String]? {
        versionLists[item.key].map { list in list.filter { !item.saved.contains($0) } }
    }

    /// Debounced version lookup on hover so gliding across rows doesn't burst npm/GitHub requests.
    func scheduleLoadVersions(_ item: Item, hovering: Bool) {
        hoverTasks[item.key]?.cancel()
        hoverTasks[item.key] = nil
        guard hovering, item.supportsRollback, versionLists[item.key] == nil, !loadingVersions.contains(item.key) else { return }
        hoverTasks[item.key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.loadVersions(item)
        }
    }

    /// Looks up the published versions once per tool.
    func loadVersions(_ item: Item) {
        guard item.supportsRollback, versionLists[item.key] == nil, loadingVersions.insert(item.key).inserted else { return }
        let catalog = Catalog.load()
        Task {
            let list = await LatestResolver().versions(of: item, catalog: catalog)
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

    /// Cancels a queued or running update cleanly.
    func cancel(_ item: Item) {
        let key = item.key
        switch activity[key] {
        case .queued?:
            if var list = pending[item.machine] {
                list.removeAll { $0.0.key == key }
                pending[item.machine] = list.isEmpty ? nil : list
            }
            activity[key] = nil
            batchTotal = max(0, batchTotal - 1)
            Log.info("cancelled queued \(key)")
        case .running?:
            // Checked and recorded in one step, so the job can't commit in between.
            guard canCancel(item), reporters[key]?.requestCancel() == true else { return }
            runningTasks[key]?.cancel()
            Log.info("cancelling running \(key)")
        default:
            break
        }
    }

    /// Cancels all queued jobs and all cancellable running jobs.
    func cancelAll() {
        pendingQuit = nil
        for (_, jobs) in pending {
            for (item, _) in jobs {
                activity[item.key] = nil
                batchTotal = max(0, batchTotal - 1)
            }
        }
        pending = [:]
        for (key, task) in runningTasks {
            if let item = items.first(where: { $0.key == key }), canCancel(item), reporters[key]?.requestCancel() == true {
                task.cancel()
            }
        }
        Log.info("cancelled remaining updates")
    }

    /// What a queued job is waiting for: a check of its machine, or the job running in its lane there.
    func queuedMessage(_ item: Item) -> String {
        if scanning.contains(item.machine) { return "Waiting for the check to finish…" }
        let lane = Self.lane(item)
        let others = items.filter { $0.machine == item.machine && $0.key != item.key && Self.lane($0) == lane }
        // Name the job actually running first; a finished one being confirmed only takes a few seconds.
        if let busy = others.first(where: { if case .running? = activity[$0.key] { true } else { false } }) {
            return "Waiting for \(busy.name) to finish…"
        }
        if others.contains(where: { if case .checking? = activity[$0.key] { true } else { false } }) {
            return "Waiting for the version check…"
        }
        return "Waiting to update…"
    }

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
        if !isBusy {
            batch = []
            batchTotal = 0
            batchCompleted = 0
        }
        batchTotal += fresh.count
        for (item, job) in fresh {
            activity[item.key] = .queued
            pending[item.machine, default: []].append((item, job))
        }
        for m in Set(fresh.map(\.0.machine)) { startLanes(m) }
    }

    /// Which jobs may run side by side on one machine. Jobs in the same lane run one at a time: one package
    /// manager (npm, Homebrew, apt, ...) never runs twice at once. Direct Mac app downloads each get their own
    /// lane so downloads and signature checks run in parallel (while `SwapGate` serializes only the brief swap).
    /// A tool's own updater only touches that tool, so each gets its own lane.
    nonisolated static func lane(_ item: Item) -> String {
        switch item.method {
        case .npm: "npm"
        case .bun: "bun"
        case .brewFormula, .cask: "brew"
        case .pipx: "pipx"
        case .uv: "uv"
        case .selfUpdate: "self:\(item.defID)"
        case .macDirect: "app:\(item.key)"
        case .winget: "winget"
        case .deb: "apt"
        case .bundledWithApp, .none: "manual"
        }
    }

    /// At most this many jobs at once on one machine (also keeps SSH connections to a server few).
    nonisolated static let maxLanes = 4

    /// Starts a worker for each lane that has queued jobs on this machine, in queue order, up to `maxLanes`.
    private func startLanes(_ m: Machine) {
        var lanes: [String] = []
        for (item, _) in pending[m] ?? [] where !lanes.contains(Self.lane(item)) { lanes.append(Self.lane(item)) }
        for name in lanes {
            let lane = Lane(machine: m, name: name)
            guard !workers.contains(lane) else { continue }
            guard workers.filter({ $0.machine == m }).count < Self.maxLanes else { return }
            workers.insert(lane)
            Task { await drain(lane) }
        }
    }

    private func drain(_ lane: Lane) async {
        let m = lane.machine
        while scanning.contains(m) { try? await Task.sleep(for: .milliseconds(200)) }
        // Each job is confirmed as soon as it ends, so one slow update never leaves the others at "checking…".
        while let i = pending[m]?.firstIndex(where: { Self.lane($0.0) == lane.name }) {
            let (queuedItem, job) = pending[m]!.remove(at: i)
            // Run what the latest check says, never what it said when the job was queued (e.g. after apt refresh).
            guard let item = items.first(where: { $0.key == queuedItem.key }) else {
                activity[queuedItem.key] = .failed("\(queuedItem.name) isn't there anymore")
                batchCompleted += 1
                continue
            }
            // A check since then may have switched its installer (Homebrew ↔ direct download): it belongs in that
            // installer's lane, so one package manager still never runs twice at once.
            if Self.lane(item) != lane.name {
                pending[m, default: []].insert((item, job), at: min(i, pending[m]?.count ?? 0))
                startLanes(m)
                continue
            }
            if case .update = job, item.state == .upToDate {
                activity[item.key] = .done("Already on \(item.installed ?? "the latest")")
                batchCompleted += 1
                continue
            }
            let outcome = await run(item, job)
            if outcome.cancelled {
                activity[item.key] = nil
                batchTotal = max(0, batchTotal - 1)
                continue
            }
            await verify(m, [(item, job, outcome)])
            batchCompleted += 1
        }
        if pending[m]?.isEmpty == true { pending[m] = nil }
        workers.remove(lane)
        // A lane that was waiting for a free slot can start now.
        startLanes(m)
        if workers.isEmpty { finishBatch() }
    }

    private func run(_ item: Item, _ job: Job) async -> UpdateOutcome {
        let key = item.key
        activity[key] = .running("Starting", nil)
        runStarted[key] = Date()
        lastProgress[key] = Date()
        lastJob[key] = job
        let what = if case let .install(v, source) = job { "switch to \(v) (\(source == .saved ? "saved copy" : "published"))" } else { "update \(item.summary)" }
        let file = Log.newRun(key)
        runFiles[key] = file
        let headerLine = "\(Log.stamp()) \(item.name) on \(item.machine.name): \(what)\n"
        let reporter = Reporter(runFile: file) { [weak self] text, fraction in
            Task { @MainActor in
                guard let self, case .running = self.activity[key] else { return }
                self.activity[key] = .running(text, fraction)
                self.lastProgress[key] = Date()
            }
        }
        reporters[key] = reporter
        let performFn = perform
        let task = Task<UpdateOutcome, Never> {
            Log.appendRun(file, headerLine)
            let outcome = await performFn(item, job, reporter)
            Log.appendRun(file, "\n\(Log.stamp()) \(outcome.cancelled ? "Cancelled" : outcome.ok ? "Done" : "FAILED"): \(outcome.message)\n")
            return outcome
        }
        runningTasks[key] = task
        let outcome = await task.value
        runningTasks[key] = nil
        reporters[key] = nil
        runStarted[key] = nil
        lastProgress[key] = nil
        if outcome.cancelled {
            return outcome
        }
        activity[key] = outcome.ok ? .checking(outcome.message) : .failed(outcome.message)
        if !outcome.ok && Engine.needsSignIn(outcome.message) {
            // Update all skips it until it's signed in; its own Update/Retry button still runs it.
            if waitingForSignIn.insert(key).inserted { Log.info("\(key): needs a sign-in, left out of Update all until it updates") }
        } else if outcome.ok {
            waitingForSignIn.remove(key)
        }
        return outcome
    }

    /// How long a running job has taken, and how long since it last showed any progress (for the menu row).
    func runTimes(_ item: Item, now: Date = Date()) -> (elapsed: TimeInterval, quiet: TimeInterval)? {
        guard let start = runStarted[item.key] else { return nil }
        return (now.timeIntervalSince(start), now.timeIntervalSince(lastProgress[item.key] ?? start))
    }

    /// Confirms finished jobs by reading their new installed version: uses fast targeted single-item verification
    /// in production (and falls back to `scan` when overridden in tests).
    private func verify(_ m: Machine, _ done: [(Item, Job, UpdateOutcome)]) async {
        let catalog = Catalog.load()
        if !customScan, done.count == 1 {
            let (item, job, o) = done[0]
            var (status, fresh) = await Engine.verifySingle(item, catalog: catalog, resolver: LatestResolver(),
                                                            preferDirectDownloads: preferDirectDownloads)
            if fresh == nil, case .online = status.state {
                // The quick read didn't find it (a new PATH, a moved command): read the whole machine afresh.
                let known = Dictionary(items.filter { $0.machine == m }.compactMap { i in i.latest.map { (i.key, $0) } }, uniquingKeysWith: { a, _ in a })
                let (st, all) = await Engine.check(m, catalog: catalog, resolver: LatestResolver(), known: known,
                                                   preferDirectDownloads: preferDirectDownloads, forcePathRefresh: true)
                apply(st, all)
                status = st
                fresh = all.first { $0.key == item.key }
            } else {
                applySingle(status, fresh)
            }
            let offline = if case .offline = status.state { true } else { false }
            let key = item.key
            let version: String? = if case let .install(v, _) = job { v } else { nil }
            let (ok, message) = Engine.confirm(item, switchedTo: version, o, fresh: fresh, offline: offline)
            if ok, let hold = History.record(item, switchedTo: version, o) {
                Log.info("\(key): \(hold == .added ? "held back from Update all" : "back in Update all")")
            }
            if o.ok && !ok { Log.error("verify \(key): \(message)") }
            activity[key] = ok ? .done(message) : .failed(message)
            batch.append((item.name, ok, message))
            previous = History.previous
            excluded = History.excluded
            return
        }
        let known = Dictionary(items.filter { $0.machine == m }.compactMap { i in i.latest.map { (i.key, $0) } }, uniquingKeysWith: { a, _ in a })
        let (status, found) = await scan(m, catalog, LatestResolver(), known)
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
        defer {
            batchTotal = 0
            batchCompleted = 0
        }
        refreshBackupStats()
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
        guard canNotify, notificationsEnabled else { return }
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
