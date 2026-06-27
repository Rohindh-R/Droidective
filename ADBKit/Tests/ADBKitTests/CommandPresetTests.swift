import Testing
@testable import ADBKit

@Suite struct CommandPresetTests {
    @Test func libraryIsNonEmptyWithUniqueNames() {
        #expect(!CommandPreset.library.isEmpty)
        let names = Set(CommandPreset.library.map(\.name))
        #expect(names.count == CommandPreset.library.count)
    }

    @Test func everyPresetIsValidArgv() throws {
        for preset in CommandPreset.library {
            let args = try CustomCommandService.buildArgs(
                template: preset.command, bundleId: "com.example.app", serial: "SER123"
            )
            #expect(!args.isEmpty, "preset \(preset.name) produced no args")
        }
    }

    @Test func bundlePresetsUseTheBundlePlaceholder() {
        for preset in CommandPreset.library where preset.needsBundle {
            #expect(preset.command.contains("{bundleId}"), "\(preset.name) needs a bundle but has no {bundleId}")
        }
    }
}
