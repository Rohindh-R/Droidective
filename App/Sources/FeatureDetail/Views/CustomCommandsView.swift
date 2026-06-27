import ADBKit
import SwiftUI

/// Define and run adb macros with {bundleId} and {serial} placeholders.
struct CustomCommandsView: View {
    @Environment(AppState.self) private var state
    @State private var commands: [CustomCommand] = []
    @State private var editing: CustomCommand?
    @State private var showEditor = false
    @State private var showPresets = false
    @State private var draftName = ""
    @State private var draftCommand = ""
    @State private var draftNeedsBundle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom Commands").font(.headline)
                    Text("Define adb actions with {bundleId} and {serial} placeholders.")
                        .font(.footnote)
                        .foregroundStyle(.textMuted)
                }
                Spacer()
                Button { showPresets = true } label: {
                    Label("Presets", systemImage: "square.grid.2x2")
                }
                .controlSize(.small)
                Button {
                    editing = nil
                    draftName = ""
                    draftCommand = ""
                    draftNeedsBundle = false
                    showEditor = true
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if commands.isEmpty {
                ContentUnavailableView(
                    "No custom commands",
                    systemImage: "terminal",
                    description: Text("Example: shell am force-stop {bundleId}")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(commands) { command in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(command.name)
                            Text("adb \(command.command)")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.textMuted)
                        }
                        Spacer()
                        Button {
                            run(command)
                        } label: {
                            Image(systemName: "play.fill").foregroundStyle(.brandAccent)
                        }
                        .buttonStyle(.plain)
                        Button {
                            editing = command
                            draftName = command.name
                            draftCommand = command.command
                            draftNeedsBundle = command.needsBundle
                            showEditor = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.plain)
                        Button {
                            commands.removeAll { $0.id == command.id }
                            persist()
                        } label: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { commands = await state.env.stores.customCommands.load() }
        .sheet(isPresented: $showEditor) { editor }
        .sheet(isPresented: $showPresets) { presetLibrary }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing == nil ? "New Command" : "Edit Command").font(.headline)
            TextField("Name", text: $draftName)
                .brandField()
            TextField("Command (e.g. shell am force-stop {bundleId})", text: $draftCommand)
                .brandField()
                .font(.system(.body, design: .monospaced))
            SwitchRow("Requires a saved bundle", isOn: $draftNeedsBundle)
            HStack {
                Spacer()
                Button("Cancel") { showEditor = false }
                Button("Save") {
                    save()
                    showEditor = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty
                    || draftCommand.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func save() {
        if var command = editing, let index = commands.firstIndex(where: { $0.id == command.id }) {
            command.name = draftName
            command.command = draftCommand
            command.needsBundle = draftNeedsBundle
            commands[index] = command
        } else {
            commands.append(CustomCommand(
                name: draftName,
                command: draftCommand,
                needsBundle: draftNeedsBundle,
                createdAt: Date().timeIntervalSince1970 * 1000
            ))
        }
        persist()
    }

    private func persist() {
        let snapshot = commands
        Task {
            try? await state.env.stores.customCommands.save(snapshot)
        }
    }

    private func run(_ command: CustomCommand) {
        if command.needsBundle && state.selectedBundle == nil {
            state.showToast(Toast(message: "Pick a saved bundle first.", ok: false))
            return
        }
        let serial = state.targetSerials.first ?? ""
        let bundleId = state.selectedBundle?.packageId
        Task {
            await CommandLog.userInitiated(feature: "custom-commands") {
                let result = await state.env.engine.customCommands.run(
                    command: command, bundleId: bundleId, serial: serial
                )
                state.showToast(Toast(message: result.message, ok: result.ok))
            }
        }
    }

    // MARK: - Presets

    private var presetLibrary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preset Commands").font(.headline)
                Spacer()
                Button("Done") { showPresets = false }
            }
            Text("Common adb commands. Add one to your list, then run or edit it.")
                .font(.footnote)
                .foregroundStyle(.textMuted)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(CommandPreset.library) { preset in
                        presetRow(preset)
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 520, height: 460)
    }

    private func presetRow(_ preset: CommandPreset) -> some View {
        let added = commands.contains { $0.name == preset.name }
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.name)
                Text("adb \(preset.command)")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.textMuted)
                Text(preset.detail)
                    .font(.caption)
                    .foregroundStyle(.textMuted)
            }
            Spacer(minLength: 8)
            if added {
                Label("Added", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.textMuted)
            } else {
                Button("Add") { add(preset) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func add(_ preset: CommandPreset) {
        guard !commands.contains(where: { $0.name == preset.name }) else { return }
        commands.append(CustomCommand(
            name: preset.name,
            command: preset.command,
            needsBundle: preset.needsBundle,
            createdAt: Date().timeIntervalSince1970 * 1000
        ))
        persist()
    }
}
