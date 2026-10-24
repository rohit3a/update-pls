import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.selfUpdateAvailable || model.selfError != nil { selfUpdateRow; Divider() }
            // A ScrollView has no height of its own in a menu bar window, so size it to its content.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.machines) { m in MachineSection(machine: m) }
                }
                .padding(12)
                .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            }
            .frame(height: min(max(listHeight, 1), 560))
            .onPreferenceChange(HeightKey.self) { listHeight = $0 }
            Divider()
            footer
        }
        .frame(width: 380)
    }

    var header: some View {
        HStack(spacing: 8) {
            Text("Update pls").font(.headline)
            Spacer()
            if model.isChecking { ProgressView().controlSize(.small) }
            Button { Task { await model.checkAll(.manual) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help(model.isBusy ? "Wait for the updates to finish" : "Check now")
                .disabled(model.isChecking || model.isBusy)
            if model.isBusy {
                Text(model.activeCount > 0 ? "Updating \(model.activeCount)…" : "Confirming versions…").font(.caption).foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            // Pressing it again only adds what isn't already queued, so nothing is ever installed twice.
            if !model.isBusy || !model.updatable.isEmpty {
                Button("Update all (\(model.updatable.count))") { model.updateAll() }
                    .disabled(model.updatable.isEmpty || model.selfUpdating)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isBusy)
        .padding(12)
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
        HStack {
            if let d = model.lastCheck {
                Text("Checked \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
            }
            Text("v\(SelfUpdate.current)").font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button("Log") { NSWorkspace.shared.open(Log.file) }.buttonStyle(.borderless).help(Log.file.path)
            Button("Settings…") { SettingsWindow.show(model) }.buttonStyle(.borderless)
            Button("Quit") { model.quit() }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MachineSection: View {
    @EnvironmentObject var model: AppModel
    let machine: Machine

    var status: MachineStatus? { model.statuses.first { $0.machine == machine } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(machine.isLocal ? "\(machine.name) (this Mac)" : machine.name).font(.subheadline.bold())
                Spacer()
                statusLabel
            }
            let groups = model.groups(for: machine)
            if groups.isEmpty, case .online = status?.state {
                Text("No coding tools found").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(groups.enumerated()), id: \.element.brand) { i, g in
                if i > 0 { Divider().padding(.leading, 24) }
                // A brand with a CLI and an app (Claude Code + Claude Desktop) gets a header; single tools don't.
                if g.items.count > 1 {
                    Text(g.brand).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 24).padding(.top, 2)
                }
                ForEach(g.items) { ItemRow(item: $0) }
            }
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
                icon.frame(width: 16, height: 16)
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
                    .opacity(hovering ? 1 : 0).help("More")
            }
            if case let .running(_, fraction) = activity {
                Group {
                    if let fraction { ProgressView(value: fraction) } else { ProgressView() }
                }
                .progressViewStyle(.linear).controlSize(.small).padding(.leading, 24)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            if h { model.loadVersions(item) }
        }
        .contextMenu { menuItems }
        .animation(.easeInOut(duration: 0.25), value: activity)
    }

    /// The line under the name: the version, or what the update is doing right now, or how it ended.
    @ViewBuilder var detail: some View {
        switch activity {
        case .queued?:
            Text("Waiting to update…").font(.caption).foregroundStyle(.secondary)
        case let .running(phase, fraction)?:
            Text(fraction.map { "\(phase) · \(Int($0 * 100))%" } ?? (phase.hasSuffix(".") ? phase : "\(phase)…"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .contentTransition(.opacity)
        case let .checking(msg)?:
            Text("\(msg) · checking…").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        case let .done(msg)?:
            Text(msg).font(.caption).foregroundStyle(.green).lineLimit(2)
        case let .failed(msg)?:
            Text(msg).font(.caption).foregroundStyle(.red).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled).help(msg)
        case nil:
            Text(versionText).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
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

    /// Apps on this Mac show their real icon; everything else a symbol.
    @ViewBuilder var icon: some View {
        if item.isApp && item.machine.isLocal {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable()
        } else {
            Image(systemName: item.isApp ? "macwindow" : "terminal").foregroundStyle(.secondary)
        }
    }

    var versionText: String {
        let installed = item.installed ?? "?"
        guard let latest = item.latest?.version else { return "\(installed) · latest unknown" }
        return item.state == .available ? "\(installed) → \(Self.changedPart(of: latest, from: installed))" : "\(installed) · latest"
    }

    @ViewBuilder var action: some View {
        switch activity {
        case .queued?:
            Image(systemName: "clock").foregroundStyle(.secondary).help("Queued")
        case let .running(_, fraction)?:
            if let fraction {
                Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
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
            if item.needsSudo, let cmd = item.command {
                Button("Copy sudo command") { copy(cmd) }.help(cmd)
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
                    Toggle(h, isOn: Binding(
                        get: { !model.disabledHosts.contains(h) },
                        set: { on in if on { model.disabledHosts.remove(h) } else { model.disabledHosts.insert(h) } }))
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
            Section("General") {
                Picker("Check every", selection: $model.intervalHours) {
                    ForEach([1.0, 3, 6, 12, 24], id: \.self) { Text("\(Int($0)) h").tag($0) }
                }
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Ask before quitting open apps", isOn: $model.askBeforeQuitting)
                Picker("Versions kept for rollback", selection: $keepVersions) {
                    ForEach([1, 2, 3, 5], id: \.self) { Text("\($0)").tag($0) }
                }
                .help("How many replaced versions of each app stay on disk so you can switch back without a download")
                Button("Add your own tools…") {
                    Catalog.writeUserTemplateIfMissing()
                    NSWorkspace.shared.open(Catalog.userFile)
                }
                Button("Show logs") { NSWorkspace.shared.activateFileViewerSelecting([Log.file]) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 420)
    }
}
