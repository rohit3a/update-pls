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
        HStack {
            Text("Update pls").font(.headline)
            Spacer()
            if model.isChecking { ProgressView().controlSize(.small) }
            Button { Task { await model.checkAll() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Check now").disabled(model.isChecking)
            Button("Update all (\(model.available.count))") { Task { await model.updateAll() } }
                .disabled(model.available.isEmpty)
        }
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
            Button("Settings…") { SettingsWindow.show(model) }.buttonStyle(.borderless)
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
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

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text(versionText).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .help("\(item.path)\nvia \(item.method.label)")
            Spacer()
            if skipped {
                Button { model.toggleExcluded(item) } label: { Image(systemName: "pause.circle") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Skipped in Update all. Click to include it again.")
            }
            action
            Menu { menuItems } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .opacity(hovering ? 1 : 0).help("More")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
    }

    /// For long versions, only the part that changed: 0.1.1-nightly.20261019.3360 → 3373.
    static func changedPart(of latest: String, from installed: String) -> String {
        guard installed.count > 14 else { return latest }
        let a = installed.split(separator: "."), b = latest.split(separator: ".")
        let same = zip(a, b).prefix { $0 == $1 }.count
        return same > 0 && same < b.count ? b[same...].joined(separator: ".") : latest
    }

    @ViewBuilder var menuItems: some View {
        Button(skipped ? "Include in Update all" : "Skip in Update all") { model.toggleExcluded(item) }
        if let v = model.rollbackVersion(item) {
            Button("Roll back to \(v)…") { Task { await model.rollback(item) } }
        }
        Divider()
        if let cmd = item.command { Button("Copy update command") { copy(cmd) } }
        if !item.log.isEmpty { Button("Copy last output") { copy(item.log) } }
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
        switch item.state {
        case .available, .failed, .updating: return "\(installed) → \(Self.changedPart(of: latest, from: installed))"
        default: return "\(installed) · latest"
        }
    }

    @ViewBuilder var action: some View {
        switch item.state {
        case .updating:
            ProgressView().controlSize(.small)
        case .updated:
            Label("Updated", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green)
        case .upToDate:
            Image(systemName: "checkmark").foregroundStyle(.secondary).help("Up to date")
        case let .failed(msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(msg)
                if item.canUpdate { Button("Retry") { Task { await model.update(item) } } }
            }
        case .available, .unknown:
            if item.needsSudo, let cmd = item.command {
                Button("Copy sudo command") { copy(cmd) }.help(cmd)
            } else if item.state == .available && item.canUpdate {
                Button(item.running ? "Update & Relaunch" : "Update") { Task { await model.update(item) } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
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
            Section("General") {
                Picker("Check every", selection: $model.intervalHours) {
                    ForEach([1.0, 3, 6, 12, 24], id: \.self) { Text("\(Int($0)) h").tag($0) }
                }
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Button("Add your own tools…") {
                    Catalog.writeUserTemplateIfMissing()
                    NSWorkspace.shared.open(Catalog.userFile)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 420)
    }
}
