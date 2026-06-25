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
    /// User's custom feature order (feature ids), applied in both the grouped
    /// and ungrouped sidebar and the catalog. Ids not listed fall back to
    /// registry order after the listed ones. Optional so files written before
    /// the field existed still decode.
    public var sidebarOrder: [String]?
    /// User's custom category order (`FeatureCategory` raw values). Categories
    /// not listed fall back to `displayOrder` after the listed ones. Optional
    /// so older files decode.
    public var categoryOrder: [String]?
    /// Categories the user collapsed in the sidebar (`FeatureCategory` raw
    /// values) — only their header shows. Optional so older files decode.
    public var collapsedCategories: [String]?
    /// Feature ids the user chose to show in the menu-bar menu. nil/empty falls
    /// back to pinned features (then enabled instant actions). Optional so files
    /// written before the field existed still decode.
    public var menuBarItems: [String]?
    /// One-time marker that the "every feature on by default" migration ran.
    /// nil on layouts written before the switch, so they catch up once. Optional
    /// so older files decode.
    public var didEnableAll: Bool?
    /// The role the user picked on first launch (`UserRole` raw value), or nil
    /// for "show everything". Drives the curated enabled set + sidebar order.
    /// Optional so older files decode.
    public var selectedRole: String?
    /// True once the user has been through the role picker (picked a role or
    /// chose "everything"). Gates the one-time picker; set together with
    /// `didEnableAll`/`knownIds` so the legacy migrations can't re-expand a
    /// curated role back to all-on. Optional so older files decode.
    public var roleChosen: Bool?

    public init(
        enabledIds: [String]? = nil,
        favorites: [String] = [],
        knownIds: [String]? = nil,
        sidebarOrder: [String]? = nil,
        categoryOrder: [String]? = nil,
        collapsedCategories: [String]? = nil,
        menuBarItems: [String]? = nil,
        didEnableAll: Bool? = nil,
        selectedRole: String? = nil,
        roleChosen: Bool? = nil
    ) {
        self.enabledIds = enabledIds
        self.favorites = favorites
        self.knownIds = knownIds
        self.sidebarOrder = sidebarOrder
        self.categoryOrder = categoryOrder
        self.collapsedCategories = collapsedCategories
        self.menuBarItems = menuBarItems
        self.didEnableAll = didEnableAll
        self.selectedRole = selectedRole
        self.roleChosen = roleChosen
    }

    /// The effective enabled set: explicit user choice or registry defaults,
    /// with system features always present.
    public var effectiveEnabledIDs: Set<String> {
        Set(enabledIds ?? FeatureRegistry.defaultEnabledIDs)
            .union(FeatureRegistry.systemFeatureIDs)
    }

    /// Enable default-on features added to the registry since this layout last
    /// saw it. Returns true when something changed (caller persists). Hub
    /// members never reach the sidebar regardless of what's stored here — the
    /// display layer filters `isAbsorbedByHub` out — so no trimming is needed.
    public mutating func adoptNewDefaults() -> Bool {
        let known = Set(knownIds ?? [])
        let allIds = FeatureRegistry.all.map(\.id)
        let newDefaults = FeatureRegistry.defaultEnabledIDs.filter { !known.contains($0) }
        var changed = false
        if var explicit = enabledIds {
            let missing = newDefaults.filter { !explicit.contains($0) }
            if !missing.isEmpty {
                explicit.append(contentsOf: missing)
                enabledIds = explicit
                changed = true
            }
        }
        if knownIds != allIds {
            knownIds = allIds
            changed = true
        }
        return changed
    }

    /// One-time switch to "every feature enabled by default": for a layout that
    /// predates it, turn on every catalog feature (existing choices on newly-on
    /// features are reset just this once). Runs once, then deliberate disables
    /// stick. Returns true when something changed (caller persists).
    public mutating func adoptAllEnabled() -> Bool {
        guard didEnableAll != true else { return false }
        didEnableAll = true
        if var explicit = enabledIds {
            let missing = FeatureRegistry.defaultEnabledIDs.filter { !explicit.contains($0) }
            explicit.append(contentsOf: missing)
            enabledIds = explicit
        }
        return true
    }

    /// Curate the layout to a role: enable exactly the role's features (system
    /// features stay on regardless via `effectiveEnabledIDs`) and match the
    /// sidebar order to the curated order. Marks `knownIds`/`didEnableAll` so
    /// `adoptNewDefaults`/`adoptAllEnabled` can't re-expand the set back to
    /// all-on. Used at first-run pick and when changing role later.
    public mutating func seedRole(_ role: UserRole) {
        let ids = FeatureRegistry.featureIDs(for: role)
        selectedRole = role.rawValue
        roleChosen = true
        enabledIds = ids
        sidebarOrder = ids
        knownIds = FeatureRegistry.all.map(\.id)
        didEnableAll = true
    }

    /// The "show me everything" choice: leave every feature on, just record that
    /// the user has been through the picker. Clears any prior role curation.
    public mutating func seedEverything() {
        selectedRole = nil
        roleChosen = true
        enabledIds = nil
        knownIds = FeatureRegistry.all.map(\.id)
        didEnableAll = true
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

    public init(
        selectedSerial: String? = nil,
        runOnAll: Bool = false,
        selectedBundleId: String? = nil
    ) {
        self.selectedSerial = selectedSerial
        self.runOnAll = runOnAll
        self.selectedBundleId = selectedBundleId
    }
}

/// All eight durable stores, built once at app startup.
public struct AppStores: Sendable {
    public let bundles: JSONStore<[AppBundle]>
    public let deepLinks: JSONStore<DeepLinksMap>
    public let customCommands: JSONStore<[CustomCommand]>
    public let layout: JSONStore<LayoutState>
    public let presets: JSONStore<Presets>
    public let overrides: JSONStore<OverridesMap>
    public let prefs: JSONStore<Prefs>
    public let usage: JSONStore<UsageStats>

    public init(directory: URL = AppPaths.supportDir) {
        bundles = JSONStore(filename: "bundles.json", default: [], directory: directory)
        deepLinks = JSONStore(filename: "deep-links.json", default: [:], directory: directory)
        customCommands = JSONStore(filename: "custom-commands.json", default: [], directory: directory)
        layout = JSONStore(filename: "layout.json", default: LayoutState(), directory: directory)
        presets = JSONStore(filename: "presets.json", default: Presets(), directory: directory)
        overrides = JSONStore(filename: "overrides.json", default: [:], directory: directory)
        prefs = JSONStore(filename: "prefs.json", default: Prefs(), directory: directory)
        usage = JSONStore(filename: "usage.json", default: UsageStats(), directory: directory)
    }
}
