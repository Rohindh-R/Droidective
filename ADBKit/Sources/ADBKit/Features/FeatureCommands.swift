import Foundation

/// One representative command a feature runs, with an optional note on what
/// that specific invocation does. Surfaced in the UI next to the ⓘ how-it-works
/// text, each with a one-click copy. Placeholders like `<package>` stand in for
/// values filled at run time; the device target (`-s <serial>`) is implied.
public struct FeatureCommand: Sendable, Equatable, Identifiable {
    public let command: String
    public let note: String?

    public var id: String { command }

    public init(_ command: String, note: String? = nil) {
        self.command = command
        self.note = note
    }
}

extension FeatureRegistry {
    /// The adb (or scrcpy/emulator/ffmpeg) command(s) a feature runs, for the
    /// in-app command reference. Every feature has at least one entry — a test
    /// enforces it, mirroring `howTo`.
    public static func commands(for featureID: String) -> [FeatureCommand] {
        commandReference[featureID] ?? []
    }

    private static let commandReference: [String: [FeatureCommand]] = [
        // ── Input & Clipboard ────────────────────────────────────────────
        "send-text": [
            FeatureCommand("adb shell input text <text>", note: "ASCII — spaces are encoded as %s"),
            FeatureCommand(
                "adb shell am broadcast -a ADB_INPUT_B64 --es msg <base64>",
                note: "Unicode / % — routed through the ADBKeyboard IME"
            ),
        ],
        "get-ip": [
            FeatureCommand("adb shell ip -f inet addr show wlan0", note: "Wi-Fi (wlan0) address"),
            FeatureCommand("adb shell ip route", note: "fallback when wlan0 has no inet line"),
        ],

        // ── Connection ───────────────────────────────────────────────────
        "connection": [
            FeatureCommand("adb shell ip -f inet addr show wlan0", note: "copy the device Wi-Fi IP"),
            FeatureCommand("adb reverse tcp:<port> tcp:<port>", note: "forward a port to your Mac"),
            FeatureCommand("adb disconnect <ip:port>", note: "drop a wireless connection"),
            FeatureCommand("adb pair <host>:<port> <code>", note: "Android 11+ pairing"),
            FeatureCommand("adb shell settings put global private_dns_mode hostname", note: "Private DNS"),
        ],
        "reverse-port": [
            FeatureCommand("adb reverse tcp:<port> tcp:<port>"),
        ],
        "wireless-adb": [
            FeatureCommand("adb tcpip 5555", note: "switch a USB device to TCP/IP"),
            FeatureCommand("adb connect <ip>:5555", note: "connect over Wi-Fi"),
            FeatureCommand("adb pair <host>:<port> <code>", note: "Android 11+ pairing"),
        ],
        "network-speed": [
            FeatureCommand("adb shell cat /proc/net/dev", note: "RX/TX byte counters — sampled as deltas for speed"),
        ],
        "system-restrictions": [
            FeatureCommand("adb shell settings put global verifier_verify_adb_installs 0", note: "skip ADB-install verification"),
            FeatureCommand("adb shell settings put global hidden_api_policy 1", note: "allow hidden-API access"),
            FeatureCommand("adb shell su -c 'setenforce 0'", note: "SELinux Permissive — root only"),
            FeatureCommand("adb shell su -c 'mount -o rw,remount /'", note: "remount system read-write — root only"),
        ],
        "private-dns": [
            FeatureCommand("adb shell settings get global private_dns_mode", note: "off / opportunistic / hostname"),
            FeatureCommand("adb shell settings put global private_dns_specifier <hostname>", note: "e.g. dns.google"),
            FeatureCommand("adb shell settings put global private_dns_mode hostname", note: "off / opportunistic / hostname"),
        ],
        "wifi": [
            FeatureCommand("adb shell cmd wifi status", note: "SSID, link speed, frequency, RSSI"),
            FeatureCommand("adb shell svc wifi enable", note: "disable to turn the radio off"),
            FeatureCommand("adb shell cmd wifi list-networks", note: "saved networks (Android 11+)"),
            FeatureCommand("adb shell cmd wifi connect-network <ssid> <type> <password>", note: "connect / switch"),
            FeatureCommand("adb shell su -c 'cat /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml'", note: "saved passwords — root only"),
        ],
        "emulators": [
            FeatureCommand("emulator -list-avds", note: "list available AVDs"),
            FeatureCommand(
                "emulator -avd <name>",
                note: "launch — add -no-snapshot-load to cold boot, -wipe-data to wipe"
            ),
            FeatureCommand("adb emu kill", note: "stop a running emulator"),
        ],
        "install-app": [
            FeatureCommand("adb install -r <path.apk>", note: "install or reinstall (keeps data)"),
        ],
        "apk-inspector": [
            FeatureCommand("aapt2 dump badging <path.apk>", note: "package, version, SDK, permissions, features"),
            FeatureCommand("apksigner verify -v --print-certs <path.apk>", note: "signing schemes and certificate digests"),
        ],
        "apk-sign": [
            FeatureCommand("zipalign -f -p 4 <in.apk> <out.apk>", note: "page-align before signing"),
            FeatureCommand("apksigner sign --ks <keystore> <out.apk>", note: "sign with a debug or release keystore"),
            FeatureCommand("apksigner verify -v --print-certs <out.apk>", note: "confirm the signature"),
        ],

        // ── React Native ─────────────────────────────────────────────────
        "react-native": [
            FeatureCommand("adb shell input keyevent 82", note: "open the dev menu"),
            FeatureCommand("adb shell input keyevent 46 46", note: "reload the JS bundle"),
            FeatureCommand("adb shell am start -a android.intent.action.VIEW -d <url>", note: "launch a deep link"),
            FeatureCommand("adb reverse tcp:<port> tcp:<port>", note: "reach a Metro dev server"),
        ],
        "open-dev-menu": [
            FeatureCommand("adb shell input keyevent 82"),
        ],
        "reload-js": [
            FeatureCommand("adb shell input keyevent 46 46", note: "double-tap R"),
        ],
        "deep-link": [
            FeatureCommand("adb shell am start -a android.intent.action.VIEW -d <url>"),
        ],
        "process-death": [
            FeatureCommand("adb shell input keyevent 3", note: "HOME — send the app to the background"),
            FeatureCommand("adb shell am kill <package>", note: "kill the backgrounded process"),
        ],
        "rn-dev-host": [
            FeatureCommand("adb reverse tcp:<port> tcp:<port>", note: "tunnel the Metro port back to your Mac"),
        ],
        "reactotron": [
            FeatureCommand(
                "adb reverse tcp:9090 tcp:9090",
                note: "route the device's localhost:9090 to Droidective's Reactotron server"
            ),
        ],

        // ── Screen & Capture ─────────────────────────────────────────────
        "scrcpy": [
            FeatureCommand("scrcpy -s <serial>", note: "mirror with defaults"),
            FeatureCommand(
                "scrcpy -s <serial> --max-size 1024 --video-bit-rate 8M --max-fps 60",
                note: "common quality/perf caps"
            ),
            FeatureCommand(
                "scrcpy -s <serial> --turn-screen-off --stay-awake --record file.mp4",
                note: "record while the device screen stays off"
            ),
        ],
        "screenshot": [
            FeatureCommand("adb exec-out screencap -p > screenshot.png"),
        ],
        "screen-record": [
            FeatureCommand(
                "scrcpy -s <serial> --no-playback --record <file>.mp4",
                note: "records headless on the Mac — no time limit, audio by default"
            ),
            FeatureCommand(
                "scrcpy -s <serial> --no-playback --no-audio --max-size 1280 --max-fps 60 --record <file>.mp4",
                note: "options are set under Advanced; Stop sends SIGTERM so the MP4 finalizes"
            ),
        ],
        "video-editor": [
            FeatureCommand(
                "ffmpeg -ss <start> -t <dur> -i in.mp4 -c:v libx264 -crf 18 out.mp4",
                note: "trim + re-encode"
            ),
            FeatureCommand(
                "ffmpeg -i in.mp4 -vf transpose=1,crop=iw*<w>:ih*<h>:iw*<x>:ih*<y> out.mov",
                note: "rotate + crop, convert container"
            ),
            FeatureCommand(
                "ffmpeg -i in.mp4 -filter_complex \"fps=15,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse\" out.gif",
                note: "export as GIF"
            ),
        ],
        "demo-mode": [
            FeatureCommand("adb shell settings put global sysui_demo_allowed 1"),
            FeatureCommand(
                "adb shell am broadcast -a com.android.systemui.demo -e command enter",
                note: "+ clock / battery / network / notifications broadcasts"
            ),
            FeatureCommand(
                "adb shell am broadcast -a com.android.systemui.demo -e command exit",
                note: "turn off"
            ),
        ],

        // ── Device Info & State Simulation ───────────────────────────────
        "file-explorer": [
            FeatureCommand("adb shell ls -la <dir>/", note: "browse"),
            FeatureCommand("adb pull <path> <dest>", note: "save to your Mac"),
            FeatureCommand("adb push <local> <remote>", note: "send to the device"),
            FeatureCommand("adb shell mkdir -p <path>", note: "new folder"),
            FeatureCommand("adb shell cp -r <src> <dest>", note: "copy / paste"),
            FeatureCommand("adb shell mv <src> <dest>", note: "move / cut + paste"),
            FeatureCommand("adb shell rm -rf <path>", note: "delete"),
        ],
        "device-info": [
            FeatureCommand("adb shell getprop", note: "all system properties"),
            FeatureCommand("adb shell dumpsys battery", note: "battery level / health / cycles"),
            FeatureCommand("adb shell cat /proc/meminfo", note: "RAM"),
            FeatureCommand("adb shell df -k /data", note: "storage"),
            FeatureCommand("adb shell pm list packages -3", note: "app counts (-s for system)"),
        ],
        "root-status": [
            FeatureCommand("adb shell su -c id", note: "uid=0 proves a working root shell"),
            FeatureCommand("adb shell which su", note: "su binary on PATH"),
            FeatureCommand("adb shell getprop ro.build.tags", note: "test-keys hints at a custom/eng build"),
            FeatureCommand("adb shell getenforce", note: "SELinux mode (Permissive when relaxed)"),
        ],
        "simulate": [
            FeatureCommand("adb shell dumpsys battery set level <n>", note: "fake battery level"),
            FeatureCommand("adb shell cmd uimode night yes", note: "dark mode"),
            FeatureCommand("adb shell settings put global animator_duration_scale 0", note: "disable animations"),
            FeatureCommand("adb shell settings put system system_locales <bcp47>", note: "change locale"),
            FeatureCommand("adb shell settings put global http_proxy <host:port>", note: "set proxy"),
        ],
        "fake-battery": [
            FeatureCommand("adb shell dumpsys battery set level <level>"),
            FeatureCommand("adb shell dumpsys battery unplug", note: "simulate unplugged"),
            FeatureCommand("adb shell dumpsys battery reset", note: "restore the real battery"),
        ],
        "dark-mode": [
            FeatureCommand("adb shell cmd uimode night yes", note: "yes = dark, no = light"),
        ],
        "layout-overrides": [
            FeatureCommand("adb shell settings put system font_scale <scale>"),
            FeatureCommand("adb shell wm density <dpi>", note: "wm density reset to restore"),
        ],
        "animation-scale": [
            FeatureCommand("adb shell settings put global window_animation_scale <0|1>"),
            FeatureCommand("adb shell settings put global transition_animation_scale <0|1>"),
            FeatureCommand("adb shell settings put global animator_duration_scale <0|1>"),
        ],
        "locale": [
            FeatureCommand(
                "adb shell am broadcast -a android.intent.action.LOCALE_CHANGED --es locale <locale>",
                note: "best-effort — a full switch often needs root"
            ),
        ],
        "network-toggles": [
            FeatureCommand("adb shell svc wifi enable", note: "or disable"),
            FeatureCommand("adb shell svc data enable", note: "mobile data"),
            FeatureCommand("adb shell cmd connectivity airplane-mode enable", note: "airplane mode"),
        ],
        "http-proxy": [
            FeatureCommand("adb shell settings put global http_proxy <host:port>"),
            FeatureCommand("adb shell settings delete global http_proxy", note: "clear the proxy"),
        ],

        // ── App Management ───────────────────────────────────────────────
        "apps": [
            FeatureCommand("adb shell pm list packages", note: "all packages (-3 = user only)"),
            FeatureCommand("adb shell dumpsys package packages", note: "versions"),
            FeatureCommand(
                "adb shell monkey -p <package> -c android.intent.category.LAUNCHER 1",
                note: "open"
            ),
            FeatureCommand("adb shell am force-stop <package>", note: "force-stop"),
            FeatureCommand("adb shell pm clear --cache-only <package>", note: "clear cache (Android 14+)"),
            FeatureCommand("adb shell pm clear <package>", note: "clear data"),
            FeatureCommand("adb shell pm disable-user --user 0 <package>", note: "disable (pm enable to undo)"),
            FeatureCommand("adb shell pm uninstall --user 0 <package>", note: "uninstall for this user"),
            FeatureCommand("adb shell cmd package install-existing <package>", note: "restore a removed app"),
        ],
        "app-management": [
            FeatureCommand(
                "adb shell monkey -p <package> -c android.intent.category.LAUNCHER 1",
                note: "open"
            ),
            FeatureCommand("adb shell am force-stop <package>", note: "force-stop"),
            FeatureCommand("adb shell input keyevent 3", note: "send to background"),
            FeatureCommand("adb shell pm clear --cache-only <package>", note: "clear cache (Android 14+)"),
            FeatureCommand("adb shell pm clear <package>", note: "clear data"),
            FeatureCommand("adb uninstall <package>", note: "uninstall"),
        ],
        "permissions": [
            FeatureCommand("adb shell dumpsys package <package>", note: "list runtime permissions"),
            FeatureCommand("adb shell pm grant <package> <permission>"),
            FeatureCommand("adb shell pm revoke <package> <permission>"),
        ],
        "app-info": [
            FeatureCommand("adb shell dumpsys package <package>", note: "version, SDK, install dates"),
            FeatureCommand("adb shell pm path <package>", note: "APK path"),
            FeatureCommand("adb pull <apk-path> <dest>", note: "pull the APK"),
        ],
        "current-activity": [
            FeatureCommand("adb shell dumpsys activity activities", note: "the resumed activity"),
            FeatureCommand("adb shell dumpsys window windows", note: "fallback — the current focus"),
        ],
        "foreground-package": [
            FeatureCommand(
                "adb shell dumpsys activity activities",
                note: "package id of the resumed activity"
            ),
        ],
        "meminfo": [
            FeatureCommand("adb shell dumpsys meminfo <package>", note: "refreshed every 2s"),
        ],
        "sandbox-browser": [
            FeatureCommand("adb shell run-as <package> ls -la <dir>", note: "debug builds only"),
            FeatureCommand("adb exec-out run-as <package> cat <file>", note: "pull a file"),
        ],
        "monkey": [
            FeatureCommand("adb shell monkey -p <package> -v <count>"),
        ],

        // ── Logs & Diagnostics ───────────────────────────────────────────
        "logcat": [
            FeatureCommand("adb logcat -v threadtime -T 300", note: "live stream, last 300 lines"),
            FeatureCommand("adb logcat … -b crash --pid <pid> *:E", note: "buffer / app / level filters"),
            FeatureCommand("adb shell pidof -s <package>", note: "resolve an app's PID to follow it"),
        ],
        "crash-catcher": [
            FeatureCommand("adb logcat -d -b crash -t 300", note: "the crash buffer"),
            FeatureCommand("adb logcat -d -b main -t 1000", note: "fallback — scan the main buffer"),
        ],
        "bug-report": [
            FeatureCommand("adb exec-out screencap -p", note: "screenshot"),
            FeatureCommand("adb logcat -d -t 2000", note: "recent logs"),
            FeatureCommand("adb shell getprop", note: "device info"),
            FeatureCommand("adb shell dumpsys package <package>", note: "app version (when a bundle is selected)"),
        ],
        "performance": [
            FeatureCommand("adb shell cat /proc/stat", note: "per-core CPU — sampled as deltas"),
            FeatureCommand("adb shell cat /proc/meminfo", note: "system RAM total / available"),
            FeatureCommand("adb shell dumpsys cpuinfo", note: "per-process CPU %"),
            FeatureCommand("adb shell dumpsys meminfo", note: "per-process PSS (RAM)"),
            FeatureCommand("adb shell cat /proc/net/dev", note: "RX/TX bytes → download / upload speed"),
            FeatureCommand("adb shell dumpsys gfxinfo <package>", note: "rendered frames → FPS & jank"),
        ],

        // ── Tool UX (system) ─────────────────────────────────────────────
        "custom-commands": [
            FeatureCommand(
                "adb <your command>",
                note: "{bundleId} and {serial} are substituted, then tokenized as argv — never run through a shell"
            ),
        ],
    ]
}
