import Foundation

/// Concrete persistent stores + their data shapes. All durable user data
/// lives here. Shapes mirror the reference app's JSON files byte-for-byte so
/// existing data could be migrated by copying the files over.

public struct AppBundle: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var nickname: String
    public var packageId: String
    public var createdAt: Double

    public init(id: String = UUID().uuidString, nickname: String, packageId: String, createdAt: Double) {
        self.id = id
        self.nickname = nickname
        self.packageId = packageId
        self.createdAt = createdAt
    }
}

public struct DeepLink: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var url: String
    public var createdAt: Double

    public init(id: String = UUID().uuidString, label: String, url: String, createdAt: Double) {
        self.id = id
        self.label = label
        self.url = url
        self.createdAt = createdAt
    }
}

/// Deep links keyed by saved-bundle id.
public typealias DeepLinksMap = [String: [DeepLink]]

public struct CustomCommand: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// adb arguments template; supports {bundleId} and {serial} placeholders.
    public var command: String
    public var needsBundle: Bool
    public var createdAt: Double

    public init(id: String = UUID().uuidString, name: String, command: String, needsBundle: Bool, createdAt: Double) {
        self.id = id
        self.name = name
        self.command = command
        self.needsBundle = needsBundle
        self.createdAt = createdAt
    }
}

/// Feature customization. Hotkey bindings are persisted by the
/// KeyboardShortcuts library itself, so they don't live here.
public struct LayoutState: Codable, Sendable, Equatable {
    /// nil = use the registry's default-enabled set; otherwise the explicit set.
    public var enabledIds: [String]?
    public var favorites: [String]
    /// Registry ids this layout has seen — lets a brand-new default-enabled
    /// feature appear once for users with an explicit enabledIds set.
    public var knownIds: [String]?
    /// User's custom order for the ungrouped sidebar (feature ids). Ids not
    /// listed fall back to registry order after the listed ones. Optional so
    /// files written before the field existed still decode.
    public var sidebarOrder: [String]?
    /// Feature ids the user chose to show in the menu-bar menu. nil/empty falls
    /// back to pinned features (then enabled instant actions). Optional so files
    /// written before the field existed still decode.
    public var menuBarItems: [String]?

    public init(
        enabledIds: [String]? = nil,
        favorites: [String] = [],
        knownIds: [String]? = nil,
        sidebarOrder: [String]? = nil,
        menuBarItems: [String]? = nil
    ) {
        self.enabledIds = enabledIds
        self.favorites = favorites
        self.knownIds = knownIds
        self.sidebarOrder = sidebarOrder
        self.menuBarItems = menuBarItems
    }

    /// The effective enabled set: explicit user choice or registry defaults,
    /// with system features always present.
    public var effectiveEnabledIDs: Set<String> {
        Set(enabledIds ?? FeatureRegistry.defaultEnabledIDs)
            .union(FeatureRegistry.systemFeatureIDs)
    }

    /// Enable default-on features added to the registry since this layout
    /// last saw it. Returns true when something changed (caller persists).
    public mutating func adoptNewDefaults() -> Bool {
        let known = Set(knownIds ?? [])
        let allIds = FeatureRegistry.all.map(\.id)
        let newDefaults = FeatureRegistry.all
            .filter { $0.defaultEnabled && !known.contains($0.id) }
            .map(\.id)
        var changed = false
        if var explicit = enabledIds {
            let missing = newDefaults.filter { !explicit.contains($0) }
            if !missing.isEmpty {
                explicit.append(contentsOf: missing)
                changed = true
            }
            // A newly adopted hub gathers its members — drop them from the
            // sidebar (they stay searchable + hotkey-able via the registry).
            for (hub, members) in FeatureRegistry.absorbedByHub where !known.contains(hub) {
                let trimmed = explicit.filter { !members.contains($0) }
                if trimmed.count != explicit.count {
                    explicit = trimmed
                    changed = true
                }
            }
            enabledIds = explicit
        }
        if knownIds != allIds {
            knownIds = allIds
            changed = true
        }
        return changed
    }
}

public struct Presets: Codable, Sendable, Equatable {
    public var reversePorts: [Int]
    public var proxies: [String]

    public init(reversePorts: [Int] = [8081, 8097], proxies: [String] = []) {
        self.reversePorts = reversePorts
        self.proxies = proxies
    }
}

public struct OverrideEntry: Codable, Sendable, Equatable {
    /// Human-readable applied value, e.g. "10.0.0.5:8888" or "420".
    public var value: String
    public var setAt: Double

    public init(value: String, setAt: Double) {
        self.value = value
        self.setAt = setAt
    }
}

/// overrides[serial][overrideKind.rawValue] = entry.
public typealias OverridesMap = [String: [String: OverrideEntry]]

public struct Prefs: Codable, Sendable, Equatable {
    public var selectedSerial: String?
    public var runOnAll: Bool
    /// The active saved bundle id (used by every app-scoped feature).
    public var selectedBundleId: String?
    /// Feature id selected when the app was last used (restored at launch).
    /// Optional so files written before the field existed still decode.
    public var lastFeatureId: String?

    public init(
        selectedSerial: String? = nil,
        runOnAll: Bool = false,
        selectedBundleId: String? = nil,
        lastFeatureId: String? = nil
    ) {
        self.selectedSerial = selectedSerial
        self.runOnAll = runOnAll
        self.selectedBundleId = selectedBundleId
        self.lastFeatureId = lastFeatureId
    }
}

/// All seven durable stores, built once at app startup.
public struct AppStores: Sendable {
    public let bundles: JSONStore<[AppBundle]>
    public let deepLinks: JSONStore<DeepLinksMap>
    public let customCommands: JSONStore<[CustomCommand]>
    public let layout: JSONStore<LayoutState>
    public let presets: JSONStore<Presets>
    public let overrides: JSONStore<OverridesMap>
    public let prefs: JSONStore<Prefs>

    public init(directory: URL = AppPaths.supportDir) {
        bundles = JSONStore(filename: "bundles.json", default: [], directory: directory)
        deepLinks = JSONStore(filename: "deep-links.json", default: [:], directory: directory)
        customCommands = JSONStore(filename: "custom-commands.json", default: [], directory: directory)
        layout = JSONStore(filename: "layout.json", default: LayoutState(), directory: directory)
        presets = JSONStore(filename: "presets.json", default: Presets(), directory: directory)
        overrides = JSONStore(filename: "overrides.json", default: [:], directory: directory)
        prefs = JSONStore(filename: "prefs.json", default: Prefs(), directory: directory)
    }
}
