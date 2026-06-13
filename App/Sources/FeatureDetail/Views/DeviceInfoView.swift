import ADBKit
import SwiftUI

/// Device properties: curated, human-readable groups up top, full searchable
/// getprop dump below.
struct DeviceInfoView: View {
    @Environment(AppState.self) private var state
    @State private var props: [String: String]?
    @State private var overview: DeviceOverview?
    @State private var search = ""

    /// Curated groups: (section, [(label, getprop key)]).
    private static let groups: [(section: String, items: [(label: String, key: String)])] = [
        ("Device", [
            ("Brand", "ro.product.brand"),
            ("Model", "ro.product.model"),
            ("Device", "ro.product.device"),
            ("Manufacturer", "ro.product.manufacturer"),
            ("Serial Number", "ro.serialno"),
        ]),
        ("Android", [
            ("Android Version", "ro.build.version.release"),
            ("SDK Level", "ro.build.version.sdk"),
            ("Security Patch", "ro.build.version.security_patch"),
            ("Build", "ro.build.display.id"),
            ("Build Type", "ro.build.type"),
        ]),
        ("Hardware", [
            ("CPU ABI", "ro.product.cpu.abi"),
            ("Supported ABIs", "ro.product.cpu.abilist"),
            ("Hardware", "ro.hardware"),
            ("Display Density", "ro.sf.lcd_density"),
        ]),
        ("Locale & Time", [
            ("Locale", "persist.sys.locale"),
            ("Time Zone", "persist.sys.timezone"),
        ]),
    ]

    var body: some View {
        Group {
            if state.targetSerials.isEmpty {
                ContentUnavailableView(
                    "No device connected", systemImage: "iphone.slash",
                    description: Text("Connect a device to browse its properties.")
                )
            } else if let props {
                content(props)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: state.targetSerials.first ?? "") { await load() }
    }

    private func content(_ props: [String: String]) -> some View {
        VStack(spacing: 0) {
            TextField("Filter properties…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)

            Divider()

            if search.isEmpty {
                curated(props)
            } else {
                filtered(props)
            }
        }
    }

    private func curated(_ props: [String: String]) -> some View {
        Form {
            if let overview {
                Section("Memory") {
                    LabeledContent("Total RAM", value: formatKb(overview.ramTotalKb))
                    LabeledContent("Used RAM", value: formatKb(overview.ramUsedKb))
                    LabeledContent("Available RAM", value: formatKb(overview.ramAvailableKb))
                }
                Section("Storage") {
                    LabeledContent("Total", value: formatKb(overview.storageTotalKb))
                    LabeledContent("Used", value: formatKb(overview.storageUsedKb))
                    LabeledContent("Available", value: formatKb(overview.storageAvailableKb))
                }
                Section("Battery") {
                    LabeledContent("Level", value: overview.batteryLevel.map { "\($0)%" } ?? "—")
                    LabeledContent("Health", value: overview.batteryHealth ?? "—")
                    if let cycles = overview.batteryCycleCount {
                        LabeledContent("Cycle Count", value: "\(cycles)")
                    }
                }
                Section("Apps & CPU") {
                    LabeledContent("CPU Architecture", value: overview.cpuAbi ?? "—")
                    LabeledContent("Installed Apps", value: overview.userAppCount.map(String.init) ?? "—")
                    LabeledContent("System Apps", value: overview.systemAppCount.map(String.init) ?? "—")
                }
            } else {
                Section("Overview") {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Reading memory, storage, and battery…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(Self.groups, id: \.section) { group in
                let rows = group.items.compactMap { item -> (String, String)? in
                    guard let value = props[item.key], !value.isEmpty else { return nil }
                    return (item.label, value)
                }
                if !rows.isEmpty {
                    Section(group.section) {
                        ForEach(rows, id: \.0) { row in
                            LabeledContent(row.0) {
                                Text(row.1)
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("All properties (\(props.count))") {
                Text("Type in the filter box above to search every raw getprop value.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func filtered(_ props: [String: String]) -> some View {
        let matches = props
            .filter {
                $0.key.localizedCaseInsensitiveContains(search)
                    || $0.value.localizedCaseInsensitiveContains(search)
            }
            .sorted { $0.key < $1.key }

        return Group {
            if matches.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(matches, id: \.key) { prop in
                    HStack(alignment: .firstTextBaseline) {
                        Text(prop.key)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Text(prop.value)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func formatKb(_ kb: Int?) -> String {
        guard let kb else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .memory)
    }

    private func load() async {
        props = nil
        overview = nil
        guard let serial = state.targetSerials.first else { return }
        async let propsResult = (try? DeviceProps.all(client: state.env.client, serial: serial)) ?? [:]
        async let overviewResult = DeviceOverview.fetch(client: state.env.client, serial: serial)
        let (fetchedProps, fetchedOverview) = await (propsResult, overviewResult)
        guard !Task.isCancelled else { return }
        props = fetchedProps
        overview = fetchedOverview
    }
}
