import Foundation

public enum FeatureKind: String, Sendable, Codable {
    case instantAction = "instant-action"
    case formAction = "form-action"
    case toggleAction = "toggle-action"
    case view
    case system
}

public enum FeatureCategory: String, Sendable, Codable, CaseIterable {
    case input = "Input"
    case connection = "Connection"
    case reactNative = "ReactNative"
    case screen = "Screen"
    case deviceState = "DeviceState"
    case appManagement = "AppManagement"
    case logs = "Logs"
    case toolUX = "ToolUX"

    /// Sidebar/catalog display order.
    public static let displayOrder: [FeatureCategory] = [
        .input, .connection, .reactNative, .screen, .deviceState, .appManagement, .logs, .toolUX,
    ]

    public var label: String {
        switch self {
        case .input: return "Input & Clipboard"
        case .connection: return "Connection"
        case .reactNative: return "React Native"
        case .screen: return "Screen & Capture"
        case .deviceState: return "Device State"
        case .appManagement: return "App Management"
        case .logs: return "Logs & Diagnostics"
        case .toolUX: return "Tool UX"
        }
    }

    /// SF Symbol name representing the category (UI is free to use it).
    public var icon: String {
        switch self {
        case .input: return "keyboard"
        case .connection: return "wifi"
        case .reactNative: return "atom"
        case .screen: return "rectangle.on.rectangle"
        case .deviceState: return "slider.horizontal.3"
        case .appManagement: return "square.stack.3d.up"
        case .logs: return "scroll"
        case .toolUX: return "wrench.and.screwdriver"
        }
    }
}

public enum OverrideKind: String, Sendable, Codable, CaseIterable {
    case proxy
    case layout
    case battery
    case demo
    case animation
    case locale
    case darkMode
}

public enum FieldControl: String, Sendable {
    case text
    case number
    case select
    case `switch`
    case slider
    case bundle
    case preset
}

public struct FieldOption: Sendable, Equatable {
    public let value: String
    public let label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

/// A loosely typed form value, the Swift stand-in for the reference's
/// `Record<string, unknown>` feature params.
public enum FeatureValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        case .bool: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

public struct FieldDef: Sendable {
    public let name: String
    public let label: String
    public let control: FieldControl
    public let options: [FieldOption]
    /// Key into the presets store for the `preset` control (e.g. "reversePorts").
    public let presetKey: String?
    public let placeholder: String?
    public let description: String?
    public let defaultValue: FeatureValue?
    public let optional: Bool
    public let min: Double?
    public let max: Double?
    public let step: Double?

    public init(
        name: String,
        label: String,
        control: FieldControl,
        options: [FieldOption] = [],
        presetKey: String? = nil,
        placeholder: String? = nil,
        description: String? = nil,
        defaultValue: FeatureValue? = nil,
        optional: Bool = false,
        min: Double? = nil,
        max: Double? = nil,
        step: Double? = nil
    ) {
        self.name = name
        self.label = label
        self.control = control
        self.options = options
        self.presetKey = presetKey
        self.placeholder = placeholder
        self.description = description
        self.defaultValue = defaultValue
        self.optional = optional
        self.min = min
        self.max = max
        self.step = step
    }
}

public struct FeatureDef: Sendable, Identifiable {
    public let id: String
    /// Spec feature number (1–37).
    public let num: Int
    public let title: String
    public let subtitle: String?
    public let keywords: [String]
    public let category: FeatureCategory
    /// SF Symbol name (keeps ADBKit free of UI frameworks).
    public let icon: String
    public let kind: FeatureKind
    public let defaultEnabled: Bool
    /// Shows the saved-bundle dropdown in the run context.
    public let needsBundle: Bool
    /// false for host-only / connection actions.
    public let needsDevice: Bool
    /// Disabled unless scrcpy is installed.
    public let needsScrcpy: Bool
    public let isStateOverride: Bool
    public let overrideKind: OverrideKind?
    public let isDestructive: Bool
    public let fields: [FieldDef]
    public let toggleOnLabel: String?
    public let toggleOffLabel: String?
    /// Confirmation copy for destructive actions.
    public let confirmLabel: String?

    public init(
        id: String,
        num: Int,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        category: FeatureCategory,
        icon: String,
        kind: FeatureKind,
        defaultEnabled: Bool,
        needsBundle: Bool = false,
        needsDevice: Bool = true,
        needsScrcpy: Bool = false,
        isStateOverride: Bool = false,
        overrideKind: OverrideKind? = nil,
        isDestructive: Bool = false,
        fields: [FieldDef] = [],
        toggleOnLabel: String? = nil,
        toggleOffLabel: String? = nil,
        confirmLabel: String? = nil
    ) {
        self.id = id
        self.num = num
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.category = category
        self.icon = icon
        self.kind = kind
        self.defaultEnabled = defaultEnabled
        self.needsBundle = needsBundle
        self.needsDevice = needsDevice
        self.needsScrcpy = needsScrcpy
        self.isStateOverride = isStateOverride
        self.overrideKind = overrideKind
        self.isDestructive = isDestructive
        self.fields = fields
        self.toggleOnLabel = toggleOnLabel
        self.toggleOffLabel = toggleOffLabel
        self.confirmLabel = confirmLabel
    }

    /// Search match against title, subtitle, and keywords.
    public func matches(_ query: String) -> Bool {
        relevance(for: query) > 0
    }

    /// How well `query` matches (0 = not at all). Title hits outrank keyword
    /// hits, which outrank subtitle-only hits — so "app" ranks Apps above Deep
    /// Links (whose subtitle merely mentions "app"). Used to order search
    /// results in the palette and sidebar.
    public func relevance(for query: String) -> Int {
        let q = query.lowercased()
        if q.isEmpty { return 1 }
        let titleLower = title.lowercased()
        if titleLower == q { return 100 }
        if titleLower.hasPrefix(q) { return 80 }
        if titleLower.contains(q) { return 60 }
        if keywords.contains(where: { $0.lowercased().hasPrefix(q) }) { return 40 }
        if keywords.contains(where: { $0.lowercased().contains(q) }) { return 30 }
        if let subtitle, subtitle.lowercased().contains(q) { return 10 }
        return 0
    }
}
