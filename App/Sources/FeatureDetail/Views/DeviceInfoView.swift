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
                ProgressView("Reading device info…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: state.targetSerials.first ?? "") { await load() }
    }

    private func content(_ props: [String: String]) -> some View {
        VStack(spacing: 0) {
            TextField("Filter properties…", text: $search)
                .brandField()
                .padding(12)

            Divider()

            if search.isEmpty {
                curated(props)
            } else {
                filtered(props)
            }
        }
    }

    private func curated(_ props: [String: String]) -> some View {
        HubColumn {
            if let overview {
                HubSection("Memory") {
                    infoRows([
                        ("Total RAM", formatKb(overview.ramTotalKb)),
                        ("Used RAM", formatKb(overview.ramUsedKb)),
                        ("Available RAM", formatKb(overview.ramAvailableKb)),
                    ])
                }
                HubSection("Storage") {
                    infoRows([
                        ("Total", formatKb(overview.storageTotalKb)),
                        ("Used", formatKb(overview.storageUsedKb)),
                        ("Available", formatKb(overview.storageAvailableKb)),
                    ])
                }
                HubSection("Battery") { infoRows(batteryRows) }
                HubSection("Apps & CPU") {
                    infoRows([
                        ("CPU Architecture", overview.cpuAbi ?? "—"),
                        ("Installed Apps", overview.userAppCount.map(String.init) ?? "—"),
                        ("System Apps", overview.systemAppCount.map(String.init) ?? "—"),
                    ])
                }
            } else {
                HubSection("Overview") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading memory, storage, and battery…").foregroundStyle(.textMuted)
                    }
                }
            }

            ForEach(Self.groups, id: \.section) { group in
                let rows = group.items.compactMap { item -> (String, String)? in
                    guard let value = props[item.key], !value.isEmpty else { return nil }
                    return (item.label, value)
                }
                if !rows.isEmpty {
                    HubSection(group.section) { infoRows(rows) }
                }
            }

            HubSection("All properties (\(props.count))") {
                Text("Type in the filter box above to search every raw getprop value.")
                    .font(.footnote)
                    .foregroundStyle(.textMuted)
            }
        }
    }

    private var batteryRows: [(String, String)] {
        guard let overview else { return [] }
        var rows: [(String, String)] = [
            ("Level", overview.batteryLevel.map { "\($0)%" } ?? "—"),
            ("Health", overview.batteryHealth ?? "—"),
        ]
        if let cycles = overview.batteryCycleCount {
            rows.append(("Cycle Count", "\(cycles)"))
        }
        return rows
    }

    private func infoRows(_ pairs: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                if index > 0 { Divider() }
                HubRow(pair.0, pair.1).padding(.vertical, 7)
            }
        }
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
                            .foregroundStyle(.textMuted)
                            .textSelection(.enabled)
                    }
                }
                .scrollContentBackground(.hidden)
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
        let (fetchedProps, fetchedOverview) = await CommandLog.userInitiated(feature: "device-info") {
            async let propsResult = (try? DeviceProps.all(client: state.env.client, serial: serial)) ?? [:]
            async let overviewResult = DeviceOverview.fetch(client: state.env.client, serial: serial)
            return await (propsResult, overviewResult)
        }
        guard !Task.isCancelled else { return }
        props = fetchedProps
        overview = fetchedOverview
    }
}
