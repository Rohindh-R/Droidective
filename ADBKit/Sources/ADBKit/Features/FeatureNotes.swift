import Foundation

extension FeatureRegistry {
    /// Short "what it does and how" notes, surfaced as ⓘ help in the UI.
    public static func howTo(for featureID: String) -> String? {
        notes[featureID]
    }

    private static let notes: [String: String] = [
        "send-text": "Types text into whatever field is focused on the device, via `adb shell input text`. Unicode and % need the ADBKeyboard app — you'll be offered a one-click install.",
        "get-ip": "Reads the device's Wi-Fi IP (wlan0) and copies it — handy for wireless ADB or pointing the device at your local services.",
        "connection": "All the connection plumbing in one place — copy the device's Wi-Fi IP, reverse a port back to your Mac (Metro), drop a wireless connection, set Private DNS, and run the Android 11+ wireless ADB pairing flow. Wi-Fi, Network Speed, and Emulators stay on their own screens.",
        "reverse-port": "Maps a device port back to your Mac (`adb reverse`), so the device reaching localhost:8081 hits YOUR machine — essential for Metro/dev servers over USB.",
        "wireless-adb": "Frees you from the cable. Over USB: one click switches the device to tcpip and connects. Android 11+: use the pairing code flow from Developer options → Wireless debugging.",
        "network-speed": "Watches live download/upload throughput, sampled from `/proc/net/dev` byte counters once a second — device-wide total, a per-interface breakdown (wlan0, cellular…), and a rolling chart. It streams as soon as you open it; hit Record whenever you want to capture a session with totals and export it as JSON + CSV. Device-wide only — per-app traffic needs root on modern Android.",
        "wifi": "Shows the current Wi-Fi connection (SSID, IP, link speed, frequency, signal) from `cmd wifi status`, toggles the radio with `svc wifi`, lists saved networks (`cmd wifi list-networks`), and connects to one (`cmd wifi connect-network`, Android 11+). On a rooted device it also reads saved passwords from WifiConfigStore.xml — connect/password features depend on the ROM allowing it over adb.",
        "private-dns": "Sets the device-wide Private DNS (DNS-over-TLS) mode via `settings put global private_dns_mode` — Off, Automatic (opportunistic), or a specific provider hostname like `dns.google` or `1dot1dot1dot1.cloudflare-dns.com`. Android 9+, no root needed.",
        "system-restrictions": "Dev-time toggles for common Android restrictions. No root: skip ADB-install verification, disable the package verifier, allow hidden-API access (`hidden_api_policy`), keep the screen awake while charging. Root only: SELinux Enforcing↔Permissive (`setenforce`) and remounting the system partition read-write — these only appear when a root shell is available.",
        "react-native": "Everything for React Native debugging in one place — reload the JS bundle, open the dev menu, simulate process death, point the app at a Metro dev server, and launch saved deep links. Reload and Dev Menu need a dev build; deep links and process death need a saved bundle.",
        "open-dev-menu": "Sends keycode 82 — opens the React Native developer menu, same as shaking the device.",
        "reload-js": "Sends R twice (keycode 46 46) to reload the JS bundle. Only works in React Native dev builds.",
        "deep-link": "Saves your app's deep links and launches them via the system VIEW intent — test routing without typing URLs on the device.",
        "process-death": "Backgrounds the app (HOME) then kills its process — reopen it on the device to verify state restoration survives a real process death.",
        "rn-dev-host": "Reverse-tunnels the Metro port so the app can reach a dev server. For a remote host also set it in the RN dev menu.",
        "scrcpy": "Launches scrcpy to mirror and control the device screen. Tune common options — max size, bit-rate, FPS, crop, record to file, stay awake, turn screen off, view-only, always-on-top, fullscreen — then Launch. Needs `brew install scrcpy`.",
        "screenshot": "Captures the screen (`screencap`), saves a PNG to ~/Downloads/Droidective, and previews it here. Optional capture delay (to arrange the screen) and auto-copy to the clipboard. Drag the preview anywhere or copy the image.",
        "screen-record": "Records on-device (`screenrecord`), pulls the MP4 when you stop, optionally converts to GIF with ffmpeg. Set resolution, bit-rate, time limit, rotation, and a timestamp overlay. Caps at ~3 min, no audio, stops on rotation.",
        "demo-mode": "Forces a clean status bar (9:41, full battery/Wi-Fi, no notifications) for store screenshots. Toggle off to restore.",
        "device-info": "Browse the device's hardware/software overview and search every raw getprop value.",
        "root-status": "Probes several independent signals — whether `su -c id` returns uid 0, a `su` binary or Magisk files exist, the build's `ro.build.tags`/`ro.debuggable`/`ro.secure`, and SELinux mode — to judge if the device is rooted. A working root shell is the only definitive proof, and is what Wi-Fi password export and the root-only system tweaks rely on.",
        "simulate": "Simulate device conditions for testing in one place — fake the battery level, flip dark mode and animation scale, override font scale and density, change the locale, toggle Wi-Fi/data/airplane, and set an HTTP proxy. Reset any of them from the overrides pill or the Reset button here.",
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
        "performance": "Live sampling over adb: per-core CPU (`/proc/stat`), system + per-process RAM (`dumpsys meminfo`), per-process CPU (`dumpsys cpuinfo`), network download/upload speed (`/proc/net/dev`), and the selected app's rendered FPS and jank (`dumpsys gfxinfo`). Record a session and export it as JSON + CSV. Network is device-wide (per-app traffic needs root on modern Android). React Native: gfxinfo measures the native UI frame rate (covering RN's rendered output); the JS-thread FPS isn't exposed over adb — use the in-app Perf Monitor or Flipper for that.",
        "sandbox-browser": "Browses the app's private /data/data files via run-as — debug builds only. Pull databases and prefs to your Mac.",
        "monkey": "Fires N random taps/swipes/keys at the app to shake out crashes. Start small (500).",
        "logcat": "Live log stream. Filter by level or by a saved bundle (waits for the app and follows it across restarts), right-click a line to filter by tag, export the buffer to a file.",
        "crash-catcher": "Pulls the most recent crash from the crash buffer (with a main-buffer fallback) formatted for Slack/Jira/plain paste.",
        "bug-report": "Bundles a screenshot, recent logcat, device info, and the selected app's version into one zip in ~/Downloads/Droidective.",
        "custom-commands": "Your own adb one-liners with {bundleId} and {serial} placeholders. Tokenized safely — never run through a shell.",
        "file-explorer": "Browse the device's shared storage. Double-click a folder to open it, single-click to select, right-click for options. Copy/cut/paste, delete, create folders, and pull files to your Mac. On a rooted device, flip Root on to browse the whole filesystem from / via su (pulls stage through /data/local/tmp).",
        "apps": "Every installed app (user + system) with search. Select one for its info, live permission toggles, APK pull, and full management — open, force-stop, clear cache (Android 14+) or clear data, disable/enable, and uninstall-for-user/restore (`pm clear` / `pm disable-user` / `pm uninstall --user 0` / `cmd package install-existing`). The reversible per-user actions double as a debloater; removing core system apps can break the UI, so stick to ones you recognise.",
        "emulators": "Your Android Studio AVDs: launch normally, cold boot (skip the snapshot), or wipe data first; running ones show their adb serial and can be stopped. Needs the SDK emulator.",
    ]
}
