import Foundation

/// A ready-made adb command the user can add to their custom commands. Every
/// template is argv-safe (no shell pipes or redirection) so it runs through
/// `CustomCommandService` unchanged.
public struct CommandPreset: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let command: String
    public let needsBundle: Bool
    public let detail: String

    public init(name: String, command: String, needsBundle: Bool = false, detail: String) {
        self.name = name
        self.command = command
        self.needsBundle = needsBundle
        self.detail = detail
    }
}

public extension CommandPreset {
    /// A small curated library of common adb commands to seed custom commands.
    static let library: [CommandPreset] = [
        CommandPreset(name: "Force-stop app", command: "shell am force-stop {bundleId}",
                      needsBundle: true, detail: "Kill the selected app."),
        CommandPreset(name: "Clear app data", command: "shell pm clear {bundleId}",
                      needsBundle: true, detail: "Wipe the selected app's data and cache."),
        CommandPreset(name: "Launch app", command: "shell monkey -p {bundleId} -c android.intent.category.LAUNCHER 1",
                      needsBundle: true, detail: "Cold-launch the selected app."),
        CommandPreset(name: "List installed apps", command: "shell pm list packages -3",
                      detail: "List user-installed package names."),
        CommandPreset(name: "Open a URL", command: "shell am start -a android.intent.action.VIEW -d https://example.com",
                      detail: "Open a URL — edit the address first."),
        CommandPreset(name: "Press Back", command: "shell input keyevent KEYCODE_BACK",
                      detail: "Send the Back button."),
        CommandPreset(name: "Press Home", command: "shell input keyevent KEYCODE_HOME",
                      detail: "Send the Home button."),
        CommandPreset(name: "Type text", command: "shell input text hello",
                      detail: "Type into the focused field — edit the text first."),
        CommandPreset(name: "Disable animations", command: "shell settings put global window_animation_scale 0",
                      detail: "Turn the window animation scale off."),
        CommandPreset(name: "Enable animations", command: "shell settings put global window_animation_scale 1",
                      detail: "Restore the window animation scale."),
        CommandPreset(name: "Show touches", command: "shell settings put system show_touches 1",
                      detail: "Show on-screen touch feedback."),
        CommandPreset(name: "Battery status", command: "shell dumpsys battery",
                      detail: "Dump the device battery state."),
        CommandPreset(name: "Clear logcat", command: "logcat -c",
                      detail: "Clear the device log buffer."),
        CommandPreset(name: "Reboot device", command: "reboot",
                      detail: "Reboot the device."),
    ]
}
