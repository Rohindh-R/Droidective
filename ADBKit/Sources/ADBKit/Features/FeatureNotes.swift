import Foundation

extension FeatureRegistry {
    /// Short "what it does and how" notes, surfaced as ⓘ help in the UI.
    public static func howTo(for featureID: String) -> String? {
        notes[featureID]
    }

    private static let notes: [String: String] = [
        "send-text": "Types text into whatever field is focused on the device, via `adb shell input text`. Unicode and % need the ADBKeyboard app — you'll be offered a one-click install.",
        "get-ip": "Reads the device's Wi-Fi IP (wlan0) and copies it — handy for wireless ADB or pointing the device at your local services.",
        "reverse-port": "Maps a device port back to your Mac (`adb reverse`), so the device reaching localhost:8081 hits YOUR machine — essential for Metro/dev servers over USB.",
        "wireless-adb": "Frees you from the cable. Over USB: one click switches the device to tcpip and connects. Android 11+: use the pairing code flow from Developer options → Wireless debugging.",
        "disconnect": "Drops a wireless adb connection (or all of them when the field is left blank).",
        "open-dev-menu": "Sends keycode 82 — opens the React Native developer menu, same as shaking the device.",
        "reload-js": "Sends R twice (keycode 46 46) to reload the JS bundle. Only works in React Native dev builds.",
        "deep-link": "Saves your app's deep links and launches them via the system VIEW intent — test routing without typing URLs on the device.",
        "process-death": "Backgrounds the app (HOME) then kills its process — reopen it on the device to verify state restoration survives a real process death.",
        "rn-dev-host": "Reverse-tunnels the Metro port so the app can reach a dev server. For a remote host also set it in the RN dev menu.",
        "scrcpy": "Launches scrcpy to mirror and control the device screen in a window. Needs `brew install scrcpy`.",
        "screenshot": "Captures the screen (`screencap`), saves a PNG to ~/Downloads/Droidective, and previews it here. Drag the preview anywhere or copy the image.",
        "screen-record": "Records on-device (`screenrecord`), pulls the MP4 when you stop, optionally converts to GIF with ffmpeg. Caps at ~3 min, no audio, stops on rotation.",
        "demo-mode": "Forces a clean status bar (9:41, full battery/Wi-Fi, no notifications) for store screenshots. Toggle off to restore.",
        "device-info": "Browse the device's hardware/software overview and search every raw getprop value.",
        "fake-battery": "Overrides the reported battery level (`dumpsys battery set`) so you can test low-battery UI. Reset from the overrides pill.",
        "dark-mode": "Flips the system-wide dark mode (`cmd uimode night`).",
        "layout-overrides": "Overrides font scale and display density to test responsive layouts. Reset from the overrides pill.",
        "animation-scale": "Sets all three animation scales to 0× (great for UI tests) or back to 1×.",
        "locale": "Broadcasts a locale change for i18n testing. Best-effort — many ROMs need root for a full switch; apps usually need a restart.",
        "network-toggles": "Flips Wi-Fi, mobile data, and airplane mode via `svc`/`cmd connectivity` — test offline states without touching the device.",
        "http-proxy": "Points the device's global HTTP proxy at Charles/Proxyman/mitmproxy on your Mac. Leave blank and run to clear it.",
        "app-management": "Lifecycle controls for the selected bundle: open, force-stop, background, clear cache (Android 14+), clear data, uninstall.",
        "permissions": "Lists the app's runtime permissions and lets you grant/revoke each — test permission-denied flows instantly.",
        "app-info": "Version, SDK targets, install dates, APK size — and pulls the APK to your Mac.",
        "current-activity": "Shows which Activity is on screen right now (from dumpsys) — useful for navigation debugging and writing deep links.",
        "foreground-package": "Copies the package id of whatever app is currently on screen.",
        "meminfo": "Live PSS memory for the app, refreshed every 2 seconds while it runs.",
        "sandbox-browser": "Browses the app's private /data/data files via run-as — debug builds only. Pull databases and prefs to your Mac.",
        "monkey": "Fires N random taps/swipes/keys at the app to shake out crashes. Start small (500).",
        "logcat": "Live log stream. Filter by level or by a saved bundle (waits for the app and follows it across restarts), right-click a line to filter by tag, export the buffer to a file.",
        "crash-catcher": "Pulls the most recent crash from the crash buffer (with a main-buffer fallback) formatted for Slack/Jira/plain paste.",
        "bug-report": "Bundles a screenshot, recent logcat, device info, and the selected app's version into one zip in ~/Downloads/Droidective.",
        "custom-commands": "Your own adb one-liners with {bundleId} and {serial} placeholders. Tokenized safely — never run through a shell.",
        "file-explorer": "Browse the device's shared storage. Copy/cut/paste, delete, create folders, and pull files to your Mac.",
        "apps": "Every installed app (user + system) with search. Select one for its info, permission count, and live permission toggles.",
        "emulators": "Your Android Studio AVDs: launch normally, cold boot (skip the snapshot), or wipe data first; running ones show their adb serial and can be stopped. Needs the SDK emulator.",
    ]
}
