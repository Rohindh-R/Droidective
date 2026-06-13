import Foundation
import Testing
@testable import ADBKit

@Suite struct JSONStoreTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adbkit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func roundTripsValue() async throws {
        let dir = try tempDir()
        let store = JSONStore(filename: "prefs.json", default: Prefs(), directory: dir)
        try await store.save(Prefs(selectedSerial: "S1", runOnAll: true, selectedBundleId: "b1"))

        let fresh = JSONStore(filename: "prefs.json", default: Prefs(), directory: dir)
        let loaded = await fresh.load()
        #expect(loaded.selectedSerial == "S1")
        #expect(loaded.runOnAll)
        #expect(loaded.selectedBundleId == "b1")
    }

    @Test func returnsDefaultWhenFileMissing() async throws {
        let store = JSONStore(filename: "missing.json", default: Presets(), directory: try tempDir())
        let value = await store.load()
        #expect(value.reversePorts == [8081, 8097])
    }

    @Test func returnsDefaultOnCorruptJSON() async throws {
        let dir = try tempDir()
        try Data("{not json!!".utf8).write(to: dir.appendingPathComponent("layout.json"))
        let store = JSONStore(filename: "layout.json", default: LayoutState(), directory: dir)
        let value = await store.load()
        #expect(value.enabledIds == nil)
        #expect(value.favorites.isEmpty)
        // The undecodable file must be set aside, not left to be overwritten.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("layout.json.corrupt").path))
    }

    @Test func updateMutatesAndPersists() async throws {
        let dir = try tempDir()
        let store = JSONStore(filename: "bundles.json", default: [AppBundle](), directory: dir)
        try await store.update { $0.append(AppBundle(nickname: "My App", packageId: "com.example", createdAt: 1)) }
        try await store.update { $0.append(AppBundle(nickname: "Other", packageId: "com.other", createdAt: 2)) }

        let fresh = JSONStore(filename: "bundles.json", default: [AppBundle](), directory: dir)
        let bundles = await fresh.load()
        #expect(bundles.map(\.packageId) == ["com.example", "com.other"])
    }

    @Test func decodesReferenceAppPrefsShape() async throws {
        let dir = try tempDir()
        let referenceShape = #"{"selectedSerial": "X", "runOnAll": false, "selectedBundleId": null}"#
        try Data(referenceShape.utf8).write(to: dir.appendingPathComponent("prefs.json"))
        let store = JSONStore(filename: "prefs.json", default: Prefs(), directory: dir)
        let prefs = await store.load()
        #expect(prefs.selectedSerial == "X")
        #expect(prefs.selectedBundleId == nil)
    }
}
