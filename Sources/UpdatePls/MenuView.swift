import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.machines) { m in MachineSection(machine: m) }
                }
                .padding(12)
            }
            .frame(maxHeight: 520)
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

    var footer: some View {
        HStack {
            if let d = model.lastCheck {
                Text("Checked \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink { Text("Settings…") }.buttonStyle(.borderless)
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
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
            let list = model.items(for: machine)
            if list.isEmpty, case .online = status?.state {
                Text("No coding agents found").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(list.filter { $0.state != .upToDate }) { ItemRow(item: $0) }
            let current = list.filter { $0.state == .upToDate }
            if !current.isEmpty {
                DisclosureGroup(isExpanded: $showCurrent) {
                    ForEach(current) { ItemRow(item: $0) }
                } label: {
                    Text("\(current.count) up to date").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @State private var showCurrent = false

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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isApp ? "macwindow" : "terminal").frame(width: 16).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text(versionText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .help("\(item.path)\nvia \(item.method.label)")
            Spacer()
            action
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let cmd = item.command { Button("Copy update command") { copy(cmd) } }
            if !item.log.isEmpty { Button("Copy last output") { copy(item.log) } }
        }
    }

    var versionText: String {
        let installed = item.installed ?? "?"
        guard let latest = item.latest?.version else { return installed }
        return item.state == .available || item.isFailed ? "\(installed) → \(latest)" : installed
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
