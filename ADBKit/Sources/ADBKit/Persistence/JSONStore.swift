import Foundation

public enum AppPaths {
    /// ~/Library/Application Support/Droidective
    public static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Droidective", isDirectory: true)
    }
}

/// One JSON file holding one Codable value, cached in memory and written
/// atomically. The durable-data analog of the reference's `DataStore<T>`.
public actor JSONStore<T: Codable & Sendable> {
    private let fileURL: URL
    private let defaultValue: T
    private var cached: T?

    public init(filename: String, default defaultValue: T, directory: URL = AppPaths.supportDir) {
        self.fileURL = directory.appendingPathComponent(filename)
        self.defaultValue = defaultValue
    }

    public func load() -> T {
        if let cached { return cached }
        let loaded: T
        if let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode(T.self, from: data) {
                loaded = decoded
            } else {
                // The file exists but doesn't decode — set it aside instead
                // of letting the next save() overwrite the user's data.
                let backup = fileURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: fileURL, to: backup)
                loaded = defaultValue
            }
        } else {
            loaded = defaultValue
        }
        cached = loaded
        return loaded
    }

    public func save(_ value: T) throws {
        cached = value
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tempURL)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
    }

    @discardableResult
    public func update(_ mutate: @Sendable (inout T) -> Void) throws -> T {
        var value = load()
        mutate(&value)
        try save(value)
        return value
    }
}
