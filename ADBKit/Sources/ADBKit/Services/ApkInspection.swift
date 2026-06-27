import Foundation

/// Identifying details parsed from a local APK, shown in the install prompt.
/// `label`/`packageName`/… are nil when aapt2 isn't available — the file name
/// and size are always present.
public struct ApkInfo: Sendable, Equatable {
    public var fileName: String
    public var fileSizeBytes: Int
    public var label: String?
    public var packageName: String?
    public var versionName: String?
    public var versionCode: String?
    public var minSdk: String?
    public var targetSdk: String?

    public init(
        fileName: String,
        fileSizeBytes: Int,
        label: String? = nil,
        packageName: String? = nil,
        versionName: String? = nil,
        versionCode: String? = nil,
        minSdk: String? = nil,
        targetSdk: String? = nil
    ) {
        self.fileName = fileName
        self.fileSizeBytes = fileSizeBytes
        self.label = label
        self.packageName = packageName
        self.versionName = versionName
        self.versionCode = versionCode
        self.minSdk = minSdk
        self.targetSdk = targetSdk
    }

    /// True when aapt2 resolved at least the app label, package, or version —
    /// i.e. there's more to show than the file name and size.
    public var hasDetails: Bool {
        label != nil || packageName != nil || versionName != nil
    }
}

/// Parses `aapt2 dump badging` output. Pure and isolated so it's unit-tested
/// without aapt2 installed.
public enum ApkBadging {
    public struct Fields: Sendable, Equatable {
        public var label: String?
        public var packageName: String?
        public var versionName: String?
        public var versionCode: String?
        public var minSdk: String?
        public var targetSdk: String?
    }

    /// Pull the identifying fields out of badging text. Each lives on its own
    /// line, e.g. `package: name='com.x' versionCode='1' versionName='1.0'` and
    /// `application-label:'My App'`.
    public static func parse(_ output: String) -> Fields {
        Fields(
            label: capture(output, #"application-label:'([^']*)'"#)
                ?? capture(output, #"application: label='([^']*)'"#),
            packageName: capture(output, #"package: name='([^']*)'"#),
            versionName: capture(output, #"versionName='([^']*)'"#),
            versionCode: capture(output, #"versionCode='([^']*)'"#),
            minSdk: capture(output, #"sdkVersion:'([^']*)'"#),
            targetSdk: capture(output, #"targetSdkVersion:'([^']*)'"#)
        )
    }

    /// First capture group of `pattern` in `text`, or nil (also nil for an empty
    /// capture, e.g. `versionName=''`).
    private static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: full), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let value = String(text[range])
        return value.isEmpty ? nil : value
    }
}
