import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @State private var listHeight: CGFloat = 0
    @State private var panelHeight: CGFloat = 0
    @State private var filter: ListFilter = .all
    @State private var dontAskAgain = false

    enum ListFilter: Hashable { case all, updates }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.isBusy && model.batchTotal > 1 {
                batchBar
            }
            if let pending = model.pendingQuit {
                Divider()
                quitBanner(pending)
            }
            Divider()
            if model.selfUpdateAvailable || model.selfError != nil { selfUpdateRow; Divider() }
            if model.visibleToolCount > 0 && (model.updateCount > 0 || model.failedCount > 0 || model.isBusy) {
                filterBar
                Divider()
            }
            // A ScrollView has no height of its own in a menu bar window, so size it to its content.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.machines) { m in
                        MachineSection(machine: m, updatesOnly: filter == .updates)
                    }
                    if filter == .updates && model.updateCount == 0 && !model.isBusy && model.failedCount == 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Everything is up to date").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                    }
                }
                .padding(12)
                .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            }
            .frame(height: min(max(listHeight, 1), 580))
            .onPreferenceChange(HeightKey.self) { listHeight = $0 }
            Divider()
            footer
        }
        .frame(width: 400)
        .background(GeometryReader { g in Color.clear.preference(key: PanelHeightKey.self, value: g.size.height) })
        .onPreferenceChange(PanelHeightKey.self) { panelHeight = $0 }
        // The menu bar window keeps the height it first had and centres the panel in it, so a shorter panel
        // floated mid-screen with see-through gaps above and below. Keep the panel at the top, and the window
        // sized to the panel with its top edge under the menu bar.
        .frame(maxHeight: .infinity, alignment: .top)
        // The menu bar window is see-through glass. In Light mode over dark windows it turns mid-gray while the
        // text stays dark, which is hard to read; a solid window background reads the same over anything.
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowFitter(height: panelHeight))
        .onChange(of: model.updateCount) { _, count in
            if count == 0 && !model.isBusy && model.failedCount == 0 && filter == .updates {
                filter = .all
            }
        }
    }

    var header: some View {
        HStack(spacing: 8) {
            Text("Update pls").font(.headline)
            Spacer()
            if model.isChecking { ProgressView().controlSize(.small) }
            Button { Task { await model.checkAll(.manual) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help(model.isBusy ? "Wait for the updates to finish" : "Check now (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isChecking || model.isBusy)
            if model.isBusy {
                Button { model.cancelAll() } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Cancel queued and running updates")
            }
            // Pressing it again only adds what isn't already queued, so nothing is ever installed twice.
            if !model.isBusy || !model.updatable.isEmpty {
                Button("Update all (\(model.updatable.count))") { model.updateAll() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(model.updatable.isEmpty || model.selfUpdating)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isBusy)
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    var batchBar: some View {
        let done = min(model.batchCompleted, model.batchTotal)
        let frac = model.batchTotal > 0 ? Double(done) / Double(model.batchTotal) : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Updating \(done) of \(model.batchTotal)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if model.failedCount > 0 {
                    Text("· \(model.failedCount) failed").font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Text("\(model.activeCount) active").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            ProgressView(value: frac).progressViewStyle(.linear).controlSize(.mini)
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    func quitBanner(_ pending: AppModel.PendingQuit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending.openNames.count == 1 ? "\(pending.openNames[0]) is open" : "\(pending.openNames.count) apps are open")
                        .font(.subheadline.weight(.semibold))
                    Text(pending.openNames.joined(separator: ", ") + (pending.openNames.count == 1 ? " will quit, update and reopen." : " will each quit, update and reopen."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Toggle("Don't ask again", isOn: $dontAskAgain)
                    .toggleStyle(.checkbox).controlSize(.small).font(.caption)
                Spacer()
                Button("Cancel") {
                    dontAskAgain = false
                    model.cancelPendingQuit()
                }.controlSize(.small)
                Button("Update & Relaunch") {
                    let remember = dontAskAgain
                    dontAskAgain = false
                    model.confirmPendingQuit(dontAskAgain: remember)
                }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
    }

    var filterBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $filter) {
                Text("All (\(model.visibleToolCount))").tag(ListFilter.all)
                Text("Updates (\(model.updateCount))").tag(ListFilter.updates)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    var selfUpdateRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update pls \(model.selfLatest ?? "") is out")
                Text(model.selfError ?? "You have \(SelfUpdate.current)").font(.caption)
                    .foregroundStyle(model.selfError == nil ? Color.secondary : Color.red).lineLimit(2)
            }
            Spacer()
            if model.selfUpdating {
                ProgressView().controlSize(.small).help("Building the new version…")
            } else {
                Button(SelfUpdate.source == nil ? "Download" : "Update") { Task { await model.updateSelf() } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(model.isBusy).help(model.isBusy ? "Wait for the updates to finish" : "")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    var footer: some View {
        HStack(spacing: 10) {
            if let d = model.lastCheck {
                HStack(spacing: 3) {
                    Text("Checked")
                    Text(d, style: .relative)
                    Text("ago")
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("v\(SelfUpdate.current)").font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button("Log") { NSWorkspace.shared.open(Log.file) }.buttonStyle(.borderless).help(Log.file.path)
            Button("Settings…") { SettingsWindow.show(model) }.buttonStyle(.borderless).keyboardShortcut(",", modifiers: .command)
            Button("Quit") { model.quit() }.buttonStyle(.borderless).keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Sizes the menu bar window to the panel, keeping its top edge where it is (under the menu bar).
private struct WindowFitter: NSViewRepresentable {
    let height: CGFloat
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let h = height.rounded(.up)
        guard h > 40 else { return }
        DispatchQueue.main.async {
            guard let w = view.window, abs(w.frame.height - h) > 0.5 else { return }
            var f = w.frame
            f.origin.y = f.maxY - h
            f.size.height = h
            w.setFrame(f, display: true)
        }
    }
}

struct MachineSection: View {
    @EnvironmentObject var model: AppModel
    let machine: Machine
    var updatesOnly: Bool = false
    @State private var collapsed = false
    @State private var showUpToDate = false

    var status: MachineStatus? { model.statuses.first { $0.machine == machine } }
    var machineUpdatable: [Item] { model.updatable(for: machine) }

    var body: some View {
        let parts = model.partitionedGroups(for: machine)
        let allGroups = model.groups(for: machine)
        let hasActionable = !parts.actionable.isEmpty
        let upToDateCount = parts.upToDate.reduce(0) { $0 + $1.items.count }

        if updatesOnly && !hasActionable && status?.state == .online {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 10)
                            Image(systemName: icon).foregroundStyle(.secondary)
                            Text(machine.isLocal ? "\(machine.name) (this Mac)" : machine.name).font(.subheadline.bold())
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    statusLabel
                    if !machineUpdatable.isEmpty {
                        Button("Update (\(machineUpdatable.count))") { model.updateMachine(machine) }
                            .controlSize(.mini)
                            .buttonStyle(.bordered)
                            .disabled(model.selfUpdating)
                    }
                }
                if !collapsed {
                    if allGroups.isEmpty, case .online = status?.state {
                        Text("No coding tools found").font(.caption).foregroundStyle(.secondary).padding(.leading, 16)
                    } else if updatesOnly {
                        brandList(parts.actionable)
                    } else if hasActionable && upToDateCount > 0 {
                        brandList(parts.actionable)
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { showUpToDate.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showUpToDate ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                Text("Up to date (\(upToDateCount))")
                                    .font(.caption)
                                Spacer()
                            }
                            .foregroundStyle(.secondary)
                            .padding(.leading, 16)
                            .padding(.top, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if showUpToDate {
                            brandList(parts.upToDate)
                        }
                    } else {
                        brandList(allGroups)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func brandList(_ groups: [(brand: String, items: [Item])]) -> some View {
        ForEach(Array(groups.enumerated()), id: \.element.brand) { i, g in
            if i > 0 { Divider().padding(.leading, 26) }
            // A brand with a CLI and an app (Claude Code + Claude Desktop) gets a header; single tools don't.
            if g.items.count > 1 {
                Text(g.brand).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 26).padding(.top, 2)
            }
            ForEach(g.items) { ItemRow(item: $0) }
        }
    }

    var icon: String {
        switch status?.os {
        case .windows: "pc"
        case .linux: "server.rack"
        default: machine.isLocal ? "laptopcomputer" : "desktopcomputer"
        }
    }

    @ViewBuilder var statusLabel: some View {
        switch status?.state {
        case .checking?: Text("Checking…").font(.caption).foregroundStyle(.secondary)
        case let .offline(msg)?: Text("Offline").font(.caption).foregroundStyle(.orange).help(msg)
        default: EmptyView()
        }
    }
}

struct ItemRow: View {
    @EnvironmentObject var model: AppModel
    let item: Item
    @State private var hovering = false

    var skipped: Bool { model.excluded.contains(item.key) }
    var activity: AppModel.Activity? { model.activity[item.key] }
    var runFile: URL? { model.runFiles[item.key] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                icon.frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).lineLimit(1)
                    detail
                }
                .help("\(item.path)\nvia \(item.method.label)")
                Spacer(minLength: 4)
                if skipped && activity == nil {
                    Button { model.toggleExcluded(item) } label: { Image(systemName: "pause.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Skipped in Update all. Click to include it again.")
                }
                action
                Menu { menuItems } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .opacity(hovering ? 1 : 0.35).help("More")
                    .simultaneousGesture(TapGesture().onEnded { model.loadVersions(item) })
            }
            if case let .running(_, fraction) = activity {
                Group {
                    if let fraction { ProgressView(value: fraction) } else { ProgressView() }
                }
                .progressViewStyle(.linear).controlSize(.small).padding(.leading, 28)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            model.scheduleLoadVersions(item, hovering: h)
        }
        .contextMenu { menuItems }
        .animation(.easeInOut(duration: 0.2), value: activity)
    }

    /// The line under the name: the version, or what the update is doing right now, or how it ended.
    @ViewBuilder var detail: some View {
        switch activity {
        case .queued?:
            Text(model.queuedMessage(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        case let .running(phase, fraction)?:
            // The time stays visible however long the step is, so a slow download never looks frozen.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 0) {
                    Text(fraction.map { "\(phase) · \(Int($0 * 100))%" } ?? (phase.hasSuffix(".") ? phase : "\(phase)…"))
                        .lineLimit(1).truncationMode(.tail)
                        .contentTransition(.opacity)
                    if let t = Self.timing(model.runTimes(item, now: ctx.date)) {
                        Text(t).monospacedDigit().fixedSize()
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        case let .checking(msg)?:
            Text("\(msg) · checking…").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        case let .done(msg)?:
            Text(msg).font(.caption).foregroundStyle(.green).lineLimit(2)
        case let .failed(msg)?:
            Text(msg).font(.caption).foregroundStyle(.red).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled).help(msg)
        case nil:
            HStack(spacing: 4) {
                Text(versionText).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if case .bundledWithApp = item.method {
                    EmptyView()
                } else {
                    Text(item.method.shortLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .fixedSize()
                }
            }
        }
    }

    /// " · 1:05" once a job has run 10 seconds, and " · 2:40, quiet 1:50" when nothing has moved for 45 seconds
    /// (npm and Homebrew print nothing while they download).
    static func timing(_ t: (elapsed: TimeInterval, quiet: TimeInterval)?) -> String? {
        guard let t, t.elapsed >= 10 else { return nil }
        func clock(_ s: TimeInterval) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
        return " · " + clock(t.elapsed) + (t.quiet >= 45 ? ", quiet \(clock(t.quiet))" : "")
    }

    /// For long versions, only the part that changed: 0.1.1-nightly.20261019.3360 → 3373.
    static func changedPart(of latest: String, from installed: String) -> String {
        guard installed.count > 14 else { return latest }
        // A different release (0.1.2-… → 0.1.3-…) is shown in full; only a newer build of the same one is shortened.
        guard installed.split(separator: "-").first == latest.split(separator: "-").first else { return latest }
        let a = installed.split(separator: "."), b = latest.split(separator: ".")
        let same = zip(a, b).prefix { $0 == $1 }.count
        return same > 0 && same < b.count ? b[same...].joined(separator: ".") : latest
    }

    @ViewBuilder var menuItems: some View {
        Button(skipped ? "Include in Update all" : "Skip in Update all") { model.toggleExcluded(item) }
        Button("Hide from list") { model.hidden.insert(item.key) }
        if item.supportsRollback && !model.isActive(item) { versionMenu }
        if let notesURL = model.releaseNotesURL(for: item) {
            Button("Release notes…") { NSWorkspace.shared.open(notesURL) }
        }
        Divider()
        if let runFile { Button("Show last update output") { NSWorkspace.shared.open(runFile) } }
        if let cmd = item.command { Button("Copy update command") { copy(cmd) } }
        if case .failed? = activity { Button("Dismiss error") { model.dismiss(item) } }
    }

    /// Every version this tool can switch to: copies saved on its machine (instant, no download),
    /// then versions its publisher still offers.
    @ViewBuilder var versionMenu: some View {
        let saved = model.savedVersions(item)
        let published = model.publishedVersions(item)
        Menu("Switch version") {
            if !saved.isEmpty {
                Section(item.machine.isLocal ? "Saved on this Mac" : "Saved on \(item.machine.name)") {
                    ForEach(saved, id: \.self) { v in
                        Button(label(v)) { model.install(item, version: v, from: .saved) }
                    }
                }
            }
            Section("Download") {
                if let published {
                    if published.isEmpty {
                        Text(item.isApp ? "\(item.name) doesn't publish older builds" : "No other versions published").foregroundStyle(.secondary)
                    }
                    ForEach(published, id: \.self) { v in
                        Button(label(v)) { model.install(item, version: v, from: .published) }
                    }
                } else {
                    Text("Looking up versions…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func label(_ v: String) -> String {
        let older = Version.isNewer(item.installed ?? "", than: v)
        let note = model.previous[item.key] == v ? "  (before the last update)" : ""
        return (older ? "\(v)" : "\(v)  ↑") + note
    }

    /// Cached app icons (also reused across remote machines when the same app is installed on this Mac).
    @ViewBuilder var icon: some View {
        if let img = AppIconCache.icon(for: item) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: item.isApp ? "macwindow" : "terminal").foregroundStyle(.secondary)
        }
    }

    var versionText: String {
        let installed = item.installed ?? "?"
        if case let .bundledWithApp(_, appName) = item.method {
            return "\(installed) · bundled in \(appName)"
        }
        guard let latest = item.latest?.version else { return "\(installed) · latest unknown" }
        guard item.state == .available else { return "\(installed) · latest" }
        let text = "\(installed) → \(Self.changedPart(of: latest, from: installed))"
        return model.waitingForSignIn.contains(item.key) ? text + " · sign in to update" : text
    }

    @ViewBuilder var action: some View {
        switch activity {
        case .queued?:
            HStack(spacing: 4) {
                Image(systemName: "clock").foregroundStyle(.secondary).help("Queued")
                Button { model.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove from queue")
            }
        case let .running(_, fraction)?:
            HStack(spacing: 4) {
                if let fraction {
                    Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                if model.canCancel(item) {
                    Button { model.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel update")
                }
            }
        case .checking?:
            ProgressView().controlSize(.small).help("Checking the new version")
        case .failed?:
            HStack(spacing: 6) {
                if let runFile {
                    Button { NSWorkspace.shared.open(runFile) } label: { Image(systemName: "doc.text.magnifyingglass") }
                        .buttonStyle(.borderless).help("Show what happened")
                }
                if model.canRetry(item) { Button("Retry") { model.retry(item) }.controlSize(.small) }
            }
        case .done? where !(item.state == .available && item.canUpdate):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Updated")
        default:
            stateAction
        }
    }

    @ViewBuilder var stateAction: some View {
        switch item.state {
        case .upToDate:
            Image(systemName: "checkmark").foregroundStyle(.secondary).help("Up to date")
        case .available, .unknown:
            if case let .bundledWithApp(_, appName) = item.method {
                Text("With app").font(.caption).foregroundStyle(.secondary)
                    .help("This CLI runs from \(appName).app — update \(appName) to update it.")
            } else if item.needsSudo, let cmd = item.command {
                Button("Copy sudo command") { copy(cmd) }.controlSize(.small).help(cmd)
            } else if item.state == .available && item.canUpdate {
                Button(item.running ? "Update & Relaunch" : "Update") { model.update(item) }
                    .buttonStyle(.borderedProminent).controlSize(.small).disabled(model.selfUpdating)
            } else if item.state == .available {
                Text("Update manually").font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary).help("Couldn't find the latest version")
            }
        }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("keepVersions") private var keepVersions = 3

    var body: some View {
        Form {
            Section("Machines (from ~/.ssh/config)") {
                if model.hosts.isEmpty { Text("No SSH hosts found").foregroundStyle(.secondary) }
                ForEach(model.hosts, id: \.self) { h in
                    Toggle(isOn: Binding(
                        get: { !model.disabledHosts.contains(h) },
                        set: { on in if on { model.disabledHosts.remove(h) } else { model.disabledHosts.insert(h) } })) {
                        Text(h)
                        if let other = model.sameMachine(as: h) {
                            Text("Same machine as \(other)\(model.disabledHosts.contains(h) ? "" : ", used if \(other) can't connect")")
                        }
                    }
                }
            }
            if !model.excluded.isEmpty {
                Section("Skipped from Update all") {
                    ForEach(model.excluded.sorted(), id: \.self) { key in
                        HStack {
                            Text(model.label(forKey: key))
                            Spacer()
                            Button("Include") { model.toggleExcluded(key: key) }
                        }
                    }
                }
            }
            if !model.waitingForSignIn.isEmpty {
                Section("Waiting for sign-in") {
                    ForEach(model.waitingForSignIn.sorted(), id: \.self) { key in
                        HStack {
                            Text(model.label(forKey: key))
                            Spacer()
                            Button("Clear") { model.waitingForSignIn.remove(key) }
                        }
                    }
                }
            }
            if !model.hidden.isEmpty {
                Section("Hidden tools") {
                    ForEach(model.hidden.sorted(), id: \.self) { key in
                        HStack {
                            Text(model.label(forKey: key))
                            Spacer()
                            Button("Show") { model.hidden.remove(key) }
                        }
                    }
                }
            }
            Section("Updates & Apps") {
                Picker("Check every", selection: $model.intervalHours) {
                    ForEach([1.0, 3, 6, 12, 24], id: \.self) { Text("\(Int($0)) h").tag($0) }
                }
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Show notifications", isOn: $model.notificationsEnabled)
                Toggle("Ask before quitting open apps", isOn: $model.askBeforeQuitting)
                Toggle("Prefer direct downloads over Homebrew Cask", isOn: $model.preferDirectDownloads)
                    .help("Updates Mac apps directly with APFS rollback backups, signature verification and pending-update reuse instead of brew upgrade --cask")
            }
            Section("Rollback Backups") {
                Picker("Versions kept per app", selection: $keepVersions) {
                    ForEach([1, 2, 3, 5], id: \.self) { Text("\($0)").tag($0) }
                }
                .help("How many replaced versions of each app stay on disk so you can switch back without a download")
                HStack {
                    Text("Storage used")
                    Spacer()
                    Text(model.backupSummary).foregroundStyle(.secondary).font(.caption)
                }
                HStack {
                    Button("Keep latest 1 per app") { model.cleanBackups(keep: 1) }
                        .disabled(model.isCleaningBackups || model.isBusy || model.backupVersions <= model.backupApps)
                    Button("Clear all backups") { model.cleanBackups(keep: 0) }
                        .disabled(model.isCleaningBackups || model.isBusy || model.backupVersions == 0)
                }
                .help(model.isBusy ? "Available once the running updates finish" : "")
                if let note = model.backupCleanupNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Advanced") {
                Button("Add your own tools…") {
                    Catalog.writeUserTemplateIfMissing()
                    NSWorkspace.shared.open(Catalog.userFile)
                }
                Button("Show logs") { NSWorkspace.shared.activateFileViewerSelecting([Log.file]) }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 460)
        .onAppear { model.refreshBackupStats() }
    }
}
