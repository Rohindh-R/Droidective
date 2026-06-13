import Foundation

public struct Device: Sendable, Equatable, Identifiable, Codable {
    public let serial: String
    /// adb state string: "device", "offline", "unauthorized", …
    public let state: String
    public let model: String?
    public let product: String?
    public let transportId: String?
    /// Friendly display label, e.g. "Pixel 7 (3f2a)".
    public let label: String
    public let isWireless: Bool

    public var id: String { serial }
    public var isReady: Bool { state == "device" }
}
