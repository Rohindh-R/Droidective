import ADBKit
import SwiftUI

/// The live Reactotron session — server, adb-reverse tunnels, and the whole
/// timeline/state buffer. Owned by `AppState` (like `terminalSession`) so it
/// survives leaving the feature: the user can keep events streaming in the
/// background and return to an intact timeline. The view is a thin renderer over
/// this; nothing here imports UI beyond `Color` used by the helper value types.
@MainActor
@Observable
final class ReactotronSession {
    static let maxItems = 2000

    fileprivate var items: [RtItem] = []
    fileprivate var commands: [RegisteredCommand] = []
    fileprivate var connection: RtConnection = .idle
    fileprivate var connectedApp: String?
    fileprivate var clients: [ClientInfo] = []
    fileprivate var selectedClient: Int?
    fileprivate var subscriptionPaths: [String] = []
    fileprivate var subscriptionValues: [String: JSONValue] = [:]
    fileprivate var snapshots: [Snapshot] = []
    fileprivate var storeState: JSONValue?
    fileprivate var pendingSnapshot = false
    fileprivate var awaitingStateTree = false
    fileprivate var replNames: [String] = []
    fileprivate var replResultText: String?

    private let client: AdbClient
    /// Back-reference for toasts and save dialogs; set right after init.
    weak var app: AppState?
    private var service: ReactotronService?
    private var consumeTask: Task<Void, Never>?
    private var reversedSerials: [String] = []

    /// True once the server is up — stays true after leaving the view when the
    /// user chose to keep the connection alive.
    var isRunning: Bool { service != nil }

    /// True when at least one app is connected — what makes "keep it running"
    /// worth asking about on the way out.
    var hasLiveConnection: Bool { isRunning && !clients.isEmpty }

    init(client: AdbClient) {
        self.client = client
    }

    fileprivate var displayedItems: [RtItem] {
        guard let selectedClient else { return items }
        return items.filter { $0.connectionId == selectedClient }
    }

    // MARK: - Lifecycle

    /// Start the server, or — if it's already running because the connection was
    /// kept alive — just re-apply the reverse so a re-entered view reconnects.
    func start(serials: [String]) async {
        if isRunning {
            await applyReverse(serials: serials)
            return
        }
        reset()
        let reactotron = ReactotronService(client: client)
        service = reactotron
        guard let stream = try? await reactotron.start() else {
            connection = .failed("Couldn't start the Reactotron server.")
            service = nil
            return
        }
        connection = .listening
        await applyReverse(serials: serials)
        consumeTask = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { break }
                self?.handle(event)
            }
        }
    }

    func applyReverse(serials: [String]) async {
        guard let service else { return }
        reversedSerials = serials
        await service.reverse(serials: serials)
    }

    /// Tear down the server and tunnels and clear all buffered state.
    func stop() async {
        consumeTask?.cancel()
        consumeTask = nil
        let stopping = service
        let serials = reversedSerials
        service = nil
        await stopping?.stop(serials: serials)
        reset()
    }

    /// Stop on app termination, bounded so a hung adb can't freeze quit. The
    /// server socket is closed first inside `stop()`, so even if the reverse
    /// removal is cut short the port is already freed (and a stale tunnel is
    /// harmless — it clears on next launch / device disconnect).
    func stopForQuit() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.stop() }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }
    }

    private func reset() {
        items.removeAll()
        commands.removeAll()
        subscriptionPaths.removeAll()
        subscriptionValues.removeAll()
        snapshots.removeAll()
        storeState = nil
        pendingSnapshot = false
        awaitingStateTree = false
        replNames.removeAll()
        replResultText = nil
        clients.removeAll()
        selectedClient = nil
        connectedApp = nil
        connection = .idle
    }

    // MARK: - Outbound

    /// Deliver a server→client frame to the selected app, or to every connected
    /// app when "All apps" is chosen, so multi-connection targeting stays
    /// consistent across commands, state, and REPL.
    private func sendToTarget(type: String, payload: JSONValue) async {
        if let selectedClient {
            await service?.send(type: type, payload: payload, toConnection: selectedClient)
        } else {
            await service?.broadcast(type: type, payload: payload)
        }
    }

    fileprivate func send(_ command: RegisteredCommand, args: [String: String]) {
        let argObject = Dictionary(
            uniqueKeysWithValues: command.args.map { ($0.name, JSONValue.string(args[$0.name] ?? "")) }
        )
        let payload = JSONValue.object(["command": .string(command.command), "args": .object(argObject)])
        Task {
            await sendToTarget(type: "custom", payload: payload)
            app?.showToast(Toast(message: "Sent “\(command.command)”", ok: true))
        }
    }

    func addSubscription(_ rawPath: String) {
        let path = rawPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !subscriptionPaths.contains(path) else { return }
        subscriptionPaths.append(path)
        sendSubscriptions()
    }

    func removeSubscription(_ path: String) {
        subscriptionPaths.removeAll { $0 == path }
        subscriptionValues[path] = nil
        sendSubscriptions()
    }

    private func sendSubscriptions() {
        let payload = JSONValue.object(["paths": .array(subscriptionPaths.map(JSONValue.string))])
        Task { await sendToTarget(type: "state.values.subscribe", payload: payload) }
    }

    func dispatch(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let data = text.data(using: .utf8),
              let action = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            app?.showToast(Toast(message: "Invalid action JSON", ok: false))
            return
        }
        Task {
            await sendToTarget(type: "state.action.dispatch", payload: .object(["action": action]))
            app?.showToast(Toast(message: "Dispatched", ok: true))
        }
    }

    /// Pull the whole store. redux/mst reply to `state.backup.request` with
    /// `state.backup.response`, while a plain `state.values.request` (no path)
    /// returns the whole cleaned state inside a `state.keys.response` (redux) or
    /// `state.values.response` (mst). Ask for both and take whichever arrives; if
    /// neither does within a few seconds, the app has no store plugin wired.
    func loadStateTree() {
        awaitingStateTree = true
        Task {
            await sendToTarget(type: "state.values.request", payload: .object([:]))
            await sendToTarget(type: "state.backup.request", payload: .object([:]))
            try? await Task.sleep(for: .seconds(4))
            guard awaitingStateTree else { return }
            awaitingStateTree = false
            app?.showToast(Toast(
                message: "No state received — wire reactotron-redux or reactotron-mst into your store to browse it here.",
                ok: false
            ))
        }
    }

    func takeSnapshot() {
        pendingSnapshot = true
        Task { await sendToTarget(type: "state.backup.request", payload: .object([:])) }
    }

    fileprivate func restore(_ snapshot: Snapshot) {
        Task {
            await sendToTarget(type: "state.restore.request", payload: .object(["state": snapshot.state]))
            app?.showToast(Toast(message: "Restored snapshot", ok: true))
        }
    }

    func sendReplLs() {
        Task { await sendToTarget(type: "repl.ls", payload: .null) }
    }

    func evalRepl(_ code: String) {
        let code = code.trimmingCharacters(in: .whitespaces)
        Task { await sendToTarget(type: "repl.execute", payload: .string(code)) }
    }

    func reverseNow(serials: [String]) {
        guard !serials.isEmpty else {
            app?.showToast(Toast(message: "No device connected to reverse", ok: false))
            return
        }
        Task {
            let results = await service?.reverse(serials: serials) ?? []
            if let failure = results.first(where: { !$0.ok }) {
                app?.showToast(Toast(
                    message: "reverse failed: \(failure.detail.isEmpty ? "unknown error" : failure.detail)",
                    ok: false
                ))
            } else {
                app?.showToast(Toast(
                    message: "adb reverse tcp:9090 → \(results.count)/\(results.count) device(s) OK",
                    ok: true
                ))
            }
        }
    }

    func clearTimeline() { items.removeAll() }
    fileprivate func deleteSnapshot(_ snapshot: Snapshot) { snapshots.removeAll { $0.id == snapshot.id } }

    func export() {
        guard let file = app?.askSaveLocation(
            suggestedName: "reactotron_\(ScreenCaptureService.stamp()).json"
        ) else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(items.map(\.command)).write(to: file)
            app?.showToast(Toast(message: "Exported \(items.count) events", ok: true, revealPath: file.path))
        } catch {
            app?.showToast(Toast(message: "Export failed: \(error.localizedDescription)", ok: false))
        }
    }

    // MARK: - Inbound

    private func handle(_ event: ReactotronServer.Event) {
        switch event {
        case .listening:
            if clients.isEmpty { connection = .listening }
        case let .connected(connectionId, intro):
            let parsed = ReactotronEvent(command: intro)
            var name = "App"
            var platform: String?
            if case let .clientIntro(introName, _, introPlatform, _) = parsed {
                name = introName
                platform = introPlatform
            }
            clients.removeAll { $0.id == connectionId }
            clients.append(ClientInfo(id: connectionId, name: name, platform: platform))
            refreshConnectionState()
            if !subscriptionPaths.isEmpty { sendSubscriptions() }
            append(RtItem(event: parsed, command: intro, connectionId: connectionId, important: false))
        case let .command(connectionId, command):
            let parsed = ReactotronEvent(command: command)
            switch parsed {
            case .clear:
                items.removeAll()
                return
            case let .customCommandRegister(id, name, title, description, args):
                registerCommand(RegisteredCommand(id: id, command: name, title: title, description: description, args: args))
            case let .customCommandUnregister(id, _):
                commands.removeAll { $0.id == id }
            case let .stateValuesChange(changes):
                for change in changes where subscriptionPaths.contains(change.path) {
                    subscriptionValues[change.path] = change.value
                }
            case let .stateBackup(snapshotState):
                if let snapshotState {
                    storeState = snapshotState
                    awaitingStateTree = false
                    if pendingSnapshot {
                        snapshots.append(Snapshot(state: snapshotState))
                        pendingSnapshot = false
                    }
                }
                return
            case let .stateKeysResponse(path, keys):
                if isWholeStorePath(path), let keys {
                    storeState = keys
                    awaitingStateTree = false
                }
                return
            case let .stateValuesResponse(path, value):
                if isWholeStorePath(path), let value {
                    storeState = value
                    awaitingStateTree = false
                }
                return
            case let .replKeys(names):
                replNames = names
                return
            case let .replResult(value):
                replResultText = value?.jsonString ?? "undefined"
                return
            default:
                break
            }
            append(RtItem(event: parsed, command: command, connectionId: connectionId, important: command.isImportant))
        case let .disconnected(connectionId):
            clients.removeAll { $0.id == connectionId }
            if selectedClient == connectionId { selectedClient = nil }
            if clients.isEmpty { commands.removeAll() }
            refreshConnectionState()
        case let .failed(reason, portInUse):
            connection = portInUse ? .portInUse : .failed(reason)
        }
    }

    private func isWholeStorePath(_ path: String?) -> Bool {
        path == nil || path?.isEmpty == true
    }

    private func refreshConnectionState() {
        if clients.isEmpty {
            connection = .listening
            connectedApp = nil
        } else {
            connection = .connected
            connectedApp = clients.count == 1 ? clients[0].name : "\(clients.count) apps"
        }
    }

    private func registerCommand(_ command: RegisteredCommand) {
        if let index = commands.firstIndex(where: { $0.id == command.id }) {
            commands[index] = command
        } else {
            commands.append(command)
        }
    }

    private func append(_ item: RtItem) {
        items.append(item)
        if items.count > Self.maxItems {
            items.removeFirst(items.count - Self.maxItems)
        }
    }
}

/// Native Reactotron server + live timeline. Droidective listens on :9090 and
/// auto-reverses the device port; the app's `reactotron-react-native` client
/// connects and streams events here. Mirrors `LogcatView`'s shape: the whole
/// server lifecycle hangs off `.task(id:)`, with a capped buffer and
/// follow-to-bottom. A second tab drives the client's custom commands.
struct ReactotronView: View {
    @Environment(AppState.self) private var state

    // View-local UI only — drafts and the active tab/split. Everything that must
    // survive leaving the feature lives on `session`.
    @State private var split = false
    @State private var tab: RtTab = .timeline
    @State private var newPath = ""
    @State private var dispatchText = ""
    @State private var replCode = ""

    private var session: ReactotronSession { state.reactotronSession }

    /// Reverse on every ready device, not just the selected one — the server is
    /// host-wide, so any connected device should be able to reach it.
    private var readySerials: [String] { state.devices.filter(\.isReady).map(\.serial) }

    var body: some View {
        VStack(spacing: 0) {
            topTabs
            Divider()
            statusBar
            Divider()
            content
        }
        // The session is owned by AppState, so it persists across feature
        // switches. `start` is idempotent — if the connection was kept alive it
        // just re-applies the reverse and the existing timeline stays intact.
        .task { await session.start(serials: readySerials) }
        .onChange(of: readySerials) { _, serials in
            Task { await session.applyReverse(serials: serials) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .timeline:
            timelineControls
            Divider()
            timelineBody
        case .commands:
            commandsPane
        case .state:
            statePane
        case .repl:
            replPane
        }
    }

    // MARK: - Tabs

    private var topTabs: some View {
        HStack {
            Picker("View", selection: $tab) {
                Text("Timeline").tag(RtTab.timeline)
                Text(session.commands.isEmpty ? "Commands" : "Commands (\(session.commands.count))").tag(RtTab.commands)
                Text("State").tag(RtTab.state)
                Text("REPL").tag(RtTab.repl)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            Spacer()
            RestartAppMenu()
                .controlSize(.small)
                .help("Force-stop and relaunch an app so it reconnects")
            Button {
                session.reverseNow(serials: readySerials)
            } label: {
                Label("Reverse :9090", systemImage: "arrow.uturn.backward.circle")
            }
            .controlSize(.small)
            .help("Run adb reverse tcp:9090 tcp:9090 on connected devices")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Toolbar (timeline)

    /// Pane-independent controls: split toggle plus the global export/clear. Each
    /// pane carries its own filter/search/order so a split view can watch two
    /// slices at once (e.g. Network on the left, State on the right).
    private var timelineControls: some View {
        HStack(spacing: 12) {
            Spacer()

            Button {
                split.toggle()
            } label: {
                Image(systemName: split ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                    .foregroundStyle(split ? Color.brandAccent : Color.secondary)
            }
            .help(split ? "Back to a single pane" : "Split into two panes")

            Button {
                session.export()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Export timeline to JSON")
            .disabled(session.items.isEmpty)

            Button {
                session.clearTimeline()
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear the timeline")
            .disabled(session.items.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var timelineBody: some View {
        if split {
            HStack(spacing: 0) {
                pane(showOnboarding: true)
                Divider()
                pane(showOnboarding: false)
            }
        } else {
            pane(showOnboarding: true)
        }
    }

    private func pane(showOnboarding: Bool) -> some View {
        TimelinePane(
            items: session.displayedItems,
            targetEmpty: state.targetSerials.isEmpty,
            connection: session.connection,
            showOnboarding: showOnboarding
        )
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.connection.color)
                .frame(width: 7, height: 7)
            Text(session.connection.text(app: session.connectedApp))
                .font(.caption)
                .foregroundStyle(.textMuted)
            if session.clients.count > 1 {
                Picker("App", selection: Binding(
                    get: { session.selectedClient },
                    set: { session.selectedClient = $0 }
                )) {
                    Text("All apps").tag(Int?.none)
                    ForEach(session.clients) { client in
                        Text(client.label).tag(Int?.some(client.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            Spacer()
            if tab == .timeline {
                Text("\(session.displayedItems.count) events")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.bgSurface)
    }

    // MARK: - Custom commands

    @ViewBuilder
    private var commandsPane: some View {
        if session.commands.isEmpty {
            ContentUnavailableView(
                "No custom commands", systemImage: "terminal",
                description: Text("Register commands in your app with `Reactotron.onCustomCommand(...)` — they appear here as buttons you can trigger on the device.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(session.commands) { command in
                        CommandCard(command: command) { cmd, args in session.send(cmd, args: args) }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - State (subscriptions + dispatch)

    @ViewBuilder
    private var statePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                stateTreeSection
                subscriptionsSection
                dispatchSection
                snapshotsSection
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("Needs the `reactotron-redux` or `reactotron-mst` plugin wired into your store.")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var stateTreeSection: some View {
        StateCard(
            icon: "list.bullet.indent", tint: .rtKey,
            title: "State tree",
            subtitle: "Pull the whole store and drill into any branch."
        ) {
            if let count = session.storeState?.objectValue?.count { CountChip(count: count, suffix: "keys") }
            Button { session.loadStateTree() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .controlSize(.small)
        } content: {
            if let storeState = session.storeState {
                JSONTreeView(root: storeState)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardInset()
            } else if session.awaitingStateTree {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Requesting store state…").font(.system(size: 11)).foregroundStyle(.textMuted)
                    Spacer()
                }
                .cardInset()
            } else {
                EmptyHint(
                    icon: "tree", message: "Load the current store to browse it as a tree.",
                    actionTitle: "Load store state"
                ) { session.loadStateTree() }
            }
        }
    }

    private var subscriptionsSection: some View {
        StateCard(
            icon: "dot.radiowaves.up.forward", tint: .rtName,
            title: "Subscriptions",
            subtitle: "Watch specific paths and see them update live."
        ) {
            if !session.subscriptionPaths.isEmpty {
                CountChip(count: session.subscriptionPaths.count, suffix: "watching")
            }
        } content: {
            HStack(spacing: 8) {
                TextField("Path to watch, e.g. user.name", text: $newPath)
                    .brandField()
                    .onSubmit { addSubscription() }
                Button("Add") { addSubscription() }
                    .controlSize(.small)
                    .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if session.subscriptionPaths.isEmpty {
                EmptyHint(icon: "eye", message: "Add a dot-path above to watch it change in real time.")
            } else {
                VStack(spacing: 6) {
                    ForEach(session.subscriptionPaths, id: \.self) { path in subscriptionRow(path) }
                }
            }
        }
    }

    private func addSubscription() {
        session.addSubscription(newPath)
        newPath = ""
    }

    private func subscriptionRow(_ path: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(path)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.rtKey)
                Text(session.subscriptionValues[path]?.jsonString ?? "waiting for a change…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(session.subscriptionValues[path] == nil ? Color.secondary : Color.textMuted)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            Button { session.removeSubscription(path) } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Stop watching this path")
        }
        .cardInset()
    }

    private var dispatchSection: some View {
        StateCard(
            icon: "paperplane", tint: .rtBadge,
            title: "Dispatch action",
            subtitle: "Send a Redux action straight to the running app."
        ) {
            EmptyView()
        } content: {
            TextField(#"{ "type": "INCREMENT" }"#, text: $dispatchText, axis: .vertical)
                .brandField()
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(2...6)
            HStack {
                Spacer()
                Button { session.dispatch(dispatchText) } label: { Label("Dispatch", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(dispatchText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var snapshotsSection: some View {
        StateCard(
            icon: "camera", tint: .rtNumber,
            title: "Snapshots",
            subtitle: "Freeze the store now, restore it later to reproduce a bug."
        ) {
            if !session.snapshots.isEmpty { CountChip(count: session.snapshots.count, suffix: "saved") }
            Button { session.takeSnapshot() } label: { Label("Take Snapshot", systemImage: "camera.fill") }
                .controlSize(.small)
        } content: {
            if session.snapshots.isEmpty {
                EmptyHint(icon: "camera", message: "Take a snapshot to capture the store as it is right now.")
            } else {
                VStack(spacing: 6) {
                    ForEach(session.snapshots) { snapshot in snapshotRow(snapshot) }
                }
            }
        }
    }

    private func snapshotRow(_ snapshot: Snapshot) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.timeFormatter.string(from: snapshot.takenAt))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.rtNumber)
                Text(snapshot.state.jsonString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Restore") { session.restore(snapshot) }
                .controlSize(.small)
            Button { session.deleteSnapshot(snapshot) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Delete this snapshot")
        }
        .cardInset()
    }

    // MARK: - REPL

    @ViewBuilder
    private var replPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("REPL").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { session.sendReplLs() } label: { Image(systemName: "arrow.clockwise") }
                        .controlSize(.small)
                        .help("Refresh available values")
                }
                Text("Evaluate JS against values your app registered with `Reactotron.repl(name, value)`.")
                    .font(.caption).foregroundStyle(.textMuted)
                if !session.replNames.isEmpty {
                    Text("Available: \(session.replNames.joined(separator: ", "))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.textMuted)
                }
                TextField("e.g. store.getState()", text: $replCode, axis: .vertical)
                    .brandField()
                    .lineLimit(2...5)
                HStack {
                    Spacer()
                    Button("Evaluate") { session.evalRepl(replCode) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(replCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let replResultText = session.replResultText {
                    Text("Result").font(.system(size: 12, weight: .semibold))
                    Text(replResultText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { session.sendReplLs() }
    }
}

// MARK: - Connection state

private enum RtTab {
    case timeline
    case commands
    case state
    case repl
}

private enum RtConnection: Equatable {
    case idle
    case listening
    case connected
    case portInUse
    case failed(String)

    var color: Color {
        switch self {
        case .idle: .textMuted
        case .listening: .orange
        case .connected: .green
        case .portInUse, .failed: .red
        }
    }

    func text(app: String?) -> String {
        switch self {
        case .idle: "Starting the server on :9090…"
        case .listening: "Listening on :9090 — waiting for your app to connect"
        case .connected: "Connected" + (app.map { " — \($0)" } ?? "")
        case .portInUse: "Port 9090 is in use — close the Reactotron desktop app, then reopen this screen"
        case let .failed(reason): "Server error: \(reason)"
        }
    }
}

// MARK: - Timeline item

private struct RtItem: Identifiable {
    let id = UUID()
    let event: ReactotronEvent
    let command: ReactotronCommand
    let connectionId: Int
    let important: Bool
    let receivedAt = Date()

    var searchText: String {
        let presentation = event.presentation
        return "\(presentation.badge) \(presentation.primary)"
    }
}

private struct RegisteredCommand: Identifiable {
    let id: Int
    let command: String
    let title: String?
    let description: String?
    let args: [ReactotronCommandArg]
}

private struct Snapshot: Identifiable {
    let id = UUID()
    let state: JSONValue
    let takenAt = Date()
}

/// One connected Reactotron client, keyed by the server's connection id. Powers
/// the app picker so several devices/apps can stream at once and the user can
/// switch which one the timeline and control tabs target.
private struct ClientInfo: Identifiable {
    let id: Int
    let name: String
    let platform: String?

    var label: String {
        guard let platform, !platform.isEmpty else { return name }
        return "\(name) · \(platform)"
    }
}

private enum RtFilter: String, CaseIterable, Identifiable {
    case all, log, network, state, display, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .log: "Logs"
        case .network: "Network"
        case .state: "State"
        case .display: "Display"
        case .other: "Other"
        }
    }
}

// MARK: - Timeline pane

/// One scrollable timeline column with its own filter, search and sort order, fed
/// from the shared event buffer. Used once on its own or twice side-by-side (the
/// VSCode-style split), so each pane can watch a different slice at the same time.
private struct TimelinePane: View {
    let items: [RtItem]
    let targetEmpty: Bool
    let connection: RtConnection
    let showOnboarding: Bool

    @State private var search = ""
    @State private var filter: RtFilter = .all
    @State private var following = true
    @State private var newestFirst = true

    var body: some View {
        VStack(spacing: 0) {
            paneToolbar
            Divider()
            timeline
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var paneToolbar: some View {
        HStack(spacing: 10) {
            Picker("Filter", selection: $filter) {
                ForEach(RtFilter.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)

            TextField("Search…", text: $search)
                .brandField()
                .frame(maxWidth: 200)

            Spacer()

            if !search.isEmpty || filter != .all {
                Text("\(visibleItems.count)")
                    .font(.caption)
                    .foregroundStyle(.textMuted)
            }

            Button {
                newestFirst.toggle()
                following = true
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundStyle(newestFirst ? Color.brandAccent : Color.secondary)
            }
            .help(newestFirst ? "Newest first — click for oldest first" : "Oldest first — click for newest first")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var visibleItems: [RtItem] {
        items.filter { item in
            if filter != .all, item.event.category != filter { return false }
            if !search.isEmpty, !item.searchText.localizedCaseInsensitiveContains(search) { return false }
            return true
        }
    }

    private var orderedItems: [RtItem] {
        newestFirst ? Array(visibleItems.reversed()) : visibleItems
    }

    private var scrollAnchorID: String { newestFirst ? "rt-top" : "rt-bottom" }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 1).id("rt-top")
                    ForEach(orderedItems) { item in
                        RtRow(item: item)
                        Divider()
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("rt-bottom")
                        .onAppear { if !newestFirst { following = true } }
                        .onDisappear { if !newestFirst { following = false } }
                }
            }
            .background(.background)
            .overlay { emptyOverlay }
            .onChange(of: items.last?.id) {
                guard following else { return }
                proxy.scrollTo(scrollAnchorID, anchor: newestFirst ? .top : .bottom)
            }
            .onChange(of: newestFirst) {
                proxy.scrollTo(scrollAnchorID, anchor: newestFirst ? .top : .bottom)
            }
        }
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if targetEmpty {
            ContentUnavailableView(
                "No device connected", systemImage: "iphone.slash",
                description: Text("Connect a device or start an emulator to receive Reactotron events.")
            )
        } else if items.isEmpty, showOnboarding {
            ReactotronOnboarding(connection: connection)
        }
    }
}

// MARK: - Row

private struct RtRow: View {
    let item: RtItem
    @State private var expanded = false
    @State private var apiTab: ApiTab = .response

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var object: JSONValue? { item.command.payload }
    private var canExpand: Bool { object != nil }

    var body: some View {
        let presentation = item.event.presentation
        return VStack(alignment: .leading, spacing: 0) {
            header(presentation)
            if expanded {
                expandedBody()
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(item.important ? Color.orange.opacity(0.06) : Color.clear)
        .overlay(alignment: .leading) {
            if item.important { Rectangle().fill(.orange).frame(width: 3) }
        }
        .contextMenu {
            if let object {
                Button("Copy object") { copyToPasteboard(object.prettyJSON) }
            }
            Button("Copy line") { copyToPasteboard(presentation.copyText) }
        }
    }

    /// Generous tap target — the whole header toggles the row.
    private func header(_ presentation: RtPresentation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
                .opacity(canExpand ? 1 : 0)
            Text(Self.timeFormatter.string(from: item.receivedAt))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.textMuted)
            Text(presentation.badge)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(presentation.badgeColor)
                .fixedSize()
            if !presentation.primary.isEmpty {
                Text(presentation.primary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(presentation.primaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { if canExpand { expanded.toggle() } }
    }

    @ViewBuilder
    private func expandedBody() -> some View {
        switch item.event {
        case let .apiResponse(method, url, status, duration, request, response):
            apiBody(method: method, url: url, status: status, duration: duration, request: request, response: response)
        case let .stateAction(_, action, ms):
            actionBody(action: action, ms: ms)
        case let .log(_, _, stack):
            logBody(stack: stack)
        case let .image(uri, _, caption, width, height):
            imageBody(uri: uri, caption: caption, width: width, height: height)
        case let .display(_, value, _, image):
            displayBody(value: value, image: image)
        default:
            if let object { treeSection(title: nil, object: object) }
        }
    }

    private func imageBody(uri: String, caption: String?, width: Double?, height: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption, !caption.isEmpty {
                Text(caption).font(.system(size: 12)).foregroundStyle(.primary)
            }
            RtImageThumbnail(uri: uri)
            if let width, let height {
                metaRow("Size", "\(Int(width)) × \(Int(height))", color: .rtNumber)
            }
        }
    }

    private func displayBody(value: JSONValue?, image: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image, !image.isEmpty { RtImageThumbnail(uri: image) }
            if let value, !value.isNull { treeSection(title: nil, object: value) }
        }
    }

    // MARK: type-specific bodies

    private func actionBody(action: JSONValue?, ms: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let ms { metaRow("duration", "\(formatMs(ms)) ms", color: .rtNumber) }
            treeSection(title: "ACTION", object: action ?? object ?? .object([:]))
        }
    }

    private func apiBody(
        method: String, url: String, status: Int, duration: Double, request: JSONValue?, response: JSONValue?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.rtKey)
                .textSelection(.enabled)
                .lineLimit(3)
            VStack(alignment: .leading, spacing: 3) {
                metaRow("Status", "\(status)", color: statusColor(status))
                metaRow("Method", method.uppercased(), color: .rtNumber)
                metaRow("Duration", "\(formatMs(duration)) ms", color: .rtNumber)
            }
            HStack {
                Spacer()
                CopyButton(label: "Copy as cURL", icon: "terminal") {
                    curlCommand(method: method, url: url, request: request)
                }
            }
            Picker("", selection: $apiTab) {
                ForEach(ApiTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            treeSection(title: nil, object: apiObject(request: request, response: response))
        }
    }

    private func apiObject(request: JSONValue?, response: JSONValue?) -> JSONValue {
        switch apiTab {
        case .response: return parseBody(response?["body"]) ?? response?["body"] ?? response ?? .null
        case .request: return request ?? .null
        case .responseHeaders: return response?["headers"] ?? .object([:])
        case .requestHeaders: return request?["headers"] ?? .object([:])
        }
    }

    private func logBody(stack: [ReactotronStackFrame]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = object?["message"] {
                switch message {
                case .object, .array:
                    treeSection(title: nil, object: message)
                default:
                    Text(String((message.stringValue ?? message.jsonString).prefix(20_000)))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !stack.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(stack.enumerated()), id: \.offset) { _, frame in
                        Text("\(frame.functionName.isEmpty ? "?" : frame.functionName)  \(frame.fileName):\(frame.lineNumber.map(String.init) ?? "?")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.textMuted)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    // MARK: building blocks

    private func metaRow(_ label: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.textMuted)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }

    private func treeSection(title: String?, object: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let title {
                    Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
                Spacer()
                CopyButton { object.prettyJSON }
            }
            JSONTreeView(root: object)
        }
        .padding(8)
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 6))
    }

    private func parseBody(_ value: JSONValue?) -> JSONValue? {
        guard case let .string(text) = value,
              let data = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return parsed
    }

    /// Reproduce the request as a copy-pasteable curl command.
    private func curlCommand(method: String, url: String, request: JSONValue?) -> String {
        var parts: [String] = ["curl"]
        let verb = method.uppercased()
        if verb != "GET" { parts.append("-X \(verb)") }
        parts.append(shellQuote(url))
        if let headers = request?["headers"]?.objectValue {
            for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                let rendered = value.stringValue ?? rawJSON(value)
                parts.append("-H \(shellQuote("\(key): \(rendered)"))")
            }
        }
        if let data = request?["data"], !data.isNull {
            let body = data.stringValue ?? rawJSON(data)
            if !body.isEmpty { parts.append("--data \(shellQuote(body))") }
        }
        return parts.joined(separator: " \\\n  ")
    }

    /// Raw (non-marker-repaired) JSON — for curl bodies that must stay valid.
    private func rawJSON(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func formatMs(_ ms: Double) -> String {
        ms < 10 ? String(format: "%.2f", ms) : String(Int(ms.rounded()))
    }

    private func statusColor(_ status: Int) -> Color {
        switch status {
        case 200..<300: .green
        case 400..<500: .orange
        case 500...: .red
        default: .rtNumber
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private enum ApiTab: String, CaseIterable, Identifiable {
    case response, request, responseHeaders, requestHeaders
    var id: String { rawValue }
    var label: String {
        switch self {
        case .response: "Response"
        case .request: "Request"
        case .responseHeaders: "Resp Headers"
        case .requestHeaders: "Req Headers"
        }
    }
}

// MARK: - Image overlay

/// Inline thumbnail for `image`/`display` events. Handles base64 `data:` URIs
/// (e.g. `Reactotron.display({ image })`) and remote `http(s)` URLs
/// (`Reactotron.image({ uri })`); clicking opens a full-size lightbox.
private struct RtImageThumbnail: View {
    let uri: String
    @State private var showFull = false

    var body: some View {
        thumbnail
            .sheet(isPresented: $showFull) { RtImageOverlay(uri: uri) }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = rtDecodeImage(uri) {
            framed(Image(nsImage: image))
        } else if let url = rtRemoteURL(uri) {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image): framed(image)
                case .failure: fallback
                default: ProgressView().controlSize(.small).frame(width: 80, height: 60)
                }
            }
        } else {
            fallback
        }
    }

    private func framed(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 320, maxHeight: 240, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture { showFull = true }
            .help("Click to view full size")
    }

    private var fallback: some View {
        Text(uri.isEmpty ? "No image" : "Can't render image\n\(String(uri.prefix(140)))")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.textMuted)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Full-size image lightbox shown as a sheet over the timeline.
private struct RtImageOverlay: View {
    let uri: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 480, idealWidth: 760, minHeight: 360, idealHeight: 600)
    }

    @ViewBuilder
    private var content: some View {
        if let image = rtDecodeImage(uri) {
            Image(nsImage: image).resizable().scaledToFit()
        } else if let url = rtRemoteURL(uri) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else if phase.error != nil {
                    Text("Couldn't load image").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        } else {
            Text("Can't render this image").foregroundStyle(.secondary)
        }
    }
}

/// Decode a base64 `data:` URI into an image; nil for any other form.
private func rtDecodeImage(_ uri: String) -> NSImage? {
    guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
    let encoded = String(uri[uri.index(after: comma)...])
    guard let data = Data(base64Encoded: encoded) else { return nil }
    return NSImage(data: data)
}

private func rtRemoteURL(_ uri: String) -> URL? {
    guard uri.hasPrefix("http://") || uri.hasPrefix("https://") else { return nil }
    return URL(string: uri)
}

// MARK: - JSON tree (collapsible, searchable, lazy)

/// Renders a `JSONValue` as a collapsible tree. Everything starts collapsed and
/// only expanded/visible nodes are flattened into the `LazyVStack`, so even a
/// very large object is cheap to display until the user drills in.
private struct JSONTreeView: View {
    let root: JSONValue
    @State private var expanded: Set<String> = []
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                TextField("Search keys & values…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
            }
            LazyVStack(alignment: .leading, spacing: 1) {
                let nodes = rows
                ForEach(nodes) { node in
                    rowView(node)
                }
                if nodes.isEmpty {
                    Text(search.isEmpty ? "(empty)" : "No matches")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var rows: [JSONNode] {
        search.isEmpty ? collapsedRows() : matchRows(search.lowercased())
    }

    private func collapsedRows() -> [JSONNode] {
        var out: [JSONNode] = []
        func walk(_ node: JSONNode) {
            out.append(node)
            guard node.isContainer, expanded.contains(node.path) else { return }
            for child in node.children { walk(child) }
        }
        for child in JSONNode(path: "", key: "", value: root, depth: -1).children { walk(child) }
        return out
    }

    private func matchRows(_ query: String) -> [JSONNode] {
        var out: [JSONNode] = []
        var visited = 0
        func walk(_ node: JSONNode) {
            if out.count >= 800 || visited >= 40_000 { return }
            visited += 1
            if node.matches(query) { out.append(JSONNode(path: node.path, key: node.key, value: node.value, depth: 0)) }
            for child in node.children { walk(child) }
        }
        for child in JSONNode(path: "", key: "", value: root, depth: -1).children { walk(child) }
        return out
    }

    @ViewBuilder
    private func rowView(_ node: JSONNode) -> some View {
        HStack(alignment: .top, spacing: 4) {
            if search.isEmpty {
                Color.clear.frame(width: CGFloat(max(0, node.depth)) * 12, height: 1)
            }
            if node.isContainer, search.isEmpty {
                Image(systemName: expanded.contains(node.path) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            } else {
                Color.clear.frame(width: 10, height: 1)
            }
            if !node.key.isEmpty {
                Text(node.key)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.rtKey)
                Text(":")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text(node.valuePreview)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(node.valueColor)
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isContainer, search.isEmpty { toggle(node.path) }
        }
        .contextMenu {
            Button("Copy value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.value.prettyJSON, forType: .string)
            }
        }
    }

    private func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }
}

private struct JSONNode: Identifiable {
    let path: String
    let key: String
    let value: JSONValue
    let depth: Int
    var id: String { path }

    var isContainer: Bool {
        switch value {
        case .object, .array: return true
        default: return false
        }
    }

    var children: [JSONNode] {
        switch value {
        case let .object(dict):
            return dict.sorted { $0.key < $1.key }.map {
                JSONNode(path: path + "/" + $0.key, key: $0.key, value: $0.value, depth: depth + 1)
            }
        case let .array(items):
            return items.enumerated().map {
                JSONNode(path: path + "/\($0.offset)", key: "[\($0.offset)]", value: $0.element, depth: depth + 1)
            }
        default:
            return []
        }
    }

    func matches(_ query: String) -> Bool {
        if key.lowercased().contains(query) { return true }
        switch value {
        case let .string(text): return text.lowercased().contains(query)
        case let .number(number): return "\(number)".contains(query)
        case let .bool(flag): return "\(flag)".contains(query)
        default: return false
        }
    }

    var valuePreview: String {
        switch value {
        case let .object(dict): return "{ \(dict.count) }"
        case let .array(items): return "[ \(items.count) ]"
        case let .string(text):
            if let marker = text.wholeMatch(of: /~~~ (.+) ~~~/) { return String(marker.1) }
            return "\"\(text)\""
        case let .number(number):
            return number.truncatingRemainder(dividingBy: 1) == 0 && abs(number) < 9e15
                ? String(Int(number)) : String(number)
        case let .bool(flag): return flag ? "true" : "false"
        case .null: return "null"
        }
    }

    var valueColor: Color {
        switch value {
        case let .string(text): return text.hasPrefix("~~~ ") ? .rtSpecial : .primary
        case .number: return .rtNumber
        case .bool: return .rtNumber
        case .null: return .rtSpecial
        case .object, .array: return .secondary
        }
    }
}

// MARK: - Command card

private struct CommandCard: View {
    let command: RegisteredCommand
    let onSend: (RegisteredCommand, [String: String]) -> Void
    @State private var args: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title ?? command.command)
                        .font(.system(size: 13, weight: .semibold))
                    if command.title != nil {
                        Text(command.command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.textMuted)
                    }
                    if let description = command.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.textMuted)
                    }
                }
                Spacer()
                Button("Send") { onSend(command, args) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            ForEach(command.args, id: \.name) { arg in
                TextField(arg.name, text: Binding(
                    get: { args[arg.name] ?? "" },
                    set: { args[arg.name] = $0 }
                ))
                .brandField()
            }
        }
        .padding(12)
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

// MARK: - Onboarding

private struct ReactotronOnboarding: View {
    let connection: RtConnection

    private static let snippet = """
    // App entry (e.g. index.js)
    import Reactotron from 'reactotron-react-native'

    Reactotron.configure()
      .useReactNative()
      .connect()
    """

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundStyle(.textMuted)
            Text("Waiting for your app")
                .font(.title3.weight(.semibold))
            Text("Droidective is the Reactotron server — it listens on :9090 and already ran `adb reverse tcp:9090 tcp:9090`. Add the client to your app and reload:")
                .font(.callout)
                .foregroundStyle(.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Text(Self.snippet)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 6))
            Text("Needs `reactotron-react-native` installed in the app and a dev build.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            alreadyRunningHint
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// A connected client only registers when it (re)launches, so an app that was
    /// already open before the server came up won't appear until it restarts.
    private var alreadyRunningHint: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.rtName.opacity(0.16)).frame(width: 30, height: 30)
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.rtName)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Already running your app?")
                    .font(.system(size: 12, weight: .semibold))
                Text("Restart it so it reconnects.")
                    .font(.caption)
                    .foregroundStyle(.textMuted)
            }
            Spacer(minLength: 12)
            RestartAppMenu()
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 460)
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.borderSubtle))
    }
}

/// Picks an installed third-party app and restarts it (force-stop → relaunch) so
/// it reconnects to the Reactotron server. Opens a searchable dropdown — the
/// package list is fetched per device.
private struct RestartAppMenu: View {
    @Environment(AppState.self) private var state
    @State private var apps: [String] = []
    @State private var loading = false
    @State private var showPicker = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var serial: String? {
        state.selectedSerial ?? state.devices.first(where: \.isReady)?.serial
    }

    private var filtered: [String] {
        guard !search.isEmpty else { return apps }
        return apps.filter {
            $0.localizedCaseInsensitiveContains(search)
                || restartAppDisplayName($0).localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Button {
            showPicker = true
        } label: {
            Label("Restart app", systemImage: "arrow.clockwise.circle")
        }
        .disabled(serial == nil)
        .task(id: serial) { await load() }
        .onChange(of: showPicker) { _, open in
            if open {
                search = ""
                if apps.isEmpty { Task { await load() } }
                Task { @MainActor in searchFocused = true }
            }
        }
        .sheet(isPresented: $showPicker) { picker }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.brandAccent.opacity(0.16)).frame(width: 30, height: 30)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.brandAccent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Restart app")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Force-stop and relaunch so it reconnects")
                        .font(.system(size: 10))
                        .foregroundStyle(.textMuted)
                }
                Spacer()
                Button { showPicker = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Search apps…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.bgRoot, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.borderSubtle))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()
            content
        }
        .frame(width: 360, height: 440)
        .background(Color.bgSurface)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            hint("Loading apps…")
        } else if apps.isEmpty {
            hint("No third-party apps found")
        } else if filtered.isEmpty {
            hint("No matches")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.self) { package in
                        AppPickerRow(package: package, serial: serial ?? "") {
                            showPicker = false
                            restart(package)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.textMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard let serial else { apps = []; return }
        loading = true
        defer { loading = false }
        let service = AppControlService(client: state.env.client)
        apps = (try? await service.listInstalledPackages(serial: serial)) ?? []
    }

    private func restart(_ package: String) {
        guard let serial else { return }
        Task {
            let service = AppControlService(client: state.env.client)
            _ = try? await service.control(serial: serial, packageId: package, action: .stop)
            let result = try? await service.control(serial: serial, packageId: package, action: .open)
            if result?.ok == true {
                state.showToast(Toast(message: "Restarting \(package)…", ok: true))
            } else {
                state.showToast(Toast(message: result?.message ?? "Couldn't restart \(package)", ok: false))
            }
        }
    }
}

private struct AppPickerRow: View {
    let package: String
    let serial: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AppIconView(packageId: package, name: restartAppDisplayName(package), serial: serial)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(restartAppDisplayName(package))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(package)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.brandAccent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Friendly app name from a package id ("com.foo.bar" → "Bar"), mirroring the
/// Apps feature's `AppListing.displayName`.
private func restartAppDisplayName(_ packageId: String) -> String {
    packageId.split(separator: ".").last
        .map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? packageId
}

// MARK: - State tab building blocks

/// A labeled card: a type-colored icon + title + subtitle, an optional trailing
/// control cluster, and content below. The four State-tab sections share it so
/// each reads as one unit and the icon color identifies it at a glance (teal =
/// tree, gold = subscriptions, coral = dispatch, orange = snapshots), echoing the
/// timeline badge palette.
private struct StateCard<Trailing: View, Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(tint.opacity(0.16))
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.textMuted)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) { trailing() }
            }
            content()
        }
        .padding(14)
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.borderSubtle))
    }
}

/// Small pill showing a count (e.g. "3 keys") in a card header.
private struct CountChip: View {
    let count: Int
    let suffix: String

    var body: some View {
        Text("\(count) \(suffix)")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.textMuted)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.bgRoot, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.borderSubtle))
    }
}

/// An empty-state row that invites the next action instead of just stating
/// emptiness — optionally with an inline button.
private struct EmptyHint: View {
    let icon: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.bgRoot, in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension View {
    /// Inset surface for rows/trees inside a `StateCard` — one step deeper than
    /// the card so nested content reads as recessed.
    func cardInset() -> some View {
        padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bgRoot, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.borderSubtle.opacity(0.6)))
    }
}

// MARK: - Reactotron palette

private extension ShapeStyle where Self == Color {
    static var rtBadge: Color { Color(red: 0.91, green: 0.46, blue: 0.36) }   // coral — type badges
    static var rtName: Color { Color(red: 0.95, green: 0.78, blue: 0.42) }    // gold — action / primary name
    static var rtKey: Color { Color(red: 0.46, green: 0.76, blue: 0.86) }     // teal — JSON keys
    static var rtNumber: Color { Color(red: 0.93, green: 0.60, blue: 0.40) }  // orange — numbers
    static var rtSpecial: Color { Color(red: 0.90, green: 0.52, blue: 0.48) } // null / undefined / functions
}

// MARK: - Copy button with feedback

private struct CopyButton: View {
    var label = "Copy"
    var icon = "doc.on.doc"
    let provider: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(provider(), forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : icon)
                Text(copied ? "Copied" : label)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(copied ? Color.white : Color.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(copied ? Color.green : Color.secondary.opacity(0.18), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: copied)
    }
}

// MARK: - Event presentation

private struct RtPresentation {
    let badge: String
    let badgeColor: Color
    let primary: String
    let primaryColor: Color

    var copyText: String { "\(badge) \(primary)".trimmingCharacters(in: .whitespaces) }
}

/// Path (+ trimmed query) of an API URL for the compact list row; the full URL
/// is shown when the row is expanded.
private func rtShortPath(_ url: String) -> String {
    guard let components = URLComponents(string: url), components.host != nil else { return url }
    let path = components.path.isEmpty ? "/" : components.path
    if let query = components.query, !query.isEmpty {
        return path + "?" + String(query.prefix(60))
    }
    return path
}

private extension ReactotronEvent {
    var category: RtFilter {
        switch self {
        case .log: .log
        case .apiResponse: .network
        case .stateAction, .stateValuesChange: .state
        case .display, .image: .display
        default: .other
        }
    }

    var presentation: RtPresentation {
        switch self {
        case let .clientIntro(name, environment, _, _):
            return RtPresentation(
                badge: "CONNECT", badgeColor: .green,
                primary: [name, environment].compactMap { $0 }.joined(separator: " · "), primaryColor: .primary
            )
        case let .log(level, message, _):
            return RtPresentation(badge: level.badge, badgeColor: level.tint, primary: message, primaryColor: .primary)
        case let .display(name, _, preview, _):
            return RtPresentation(
                badge: "DISPLAY", badgeColor: .rtBadge,
                primary: [name, preview].compactMap { $0 }.joined(separator: " — "), primaryColor: .rtName
            )
        case let .image(_, _, caption, _, _):
            return RtPresentation(badge: "IMAGE", badgeColor: .rtBadge, primary: caption ?? "", primaryColor: .primary)
        case let .apiResponse(method, url, _, _, _, _):
            return RtPresentation(
                badge: "API", badgeColor: .rtBadge,
                primary: "\(method.uppercased()) \(rtShortPath(url))", primaryColor: .primary
            )
        case let .benchmark(title, _):
            return RtPresentation(badge: "BENCHMARK", badgeColor: .rtBadge, primary: title, primaryColor: .rtName)
        case .clear:
            return RtPresentation(badge: "CLEAR", badgeColor: .secondary, primary: "", primaryColor: .secondary)
        case let .asyncStorage(action, _):
            return RtPresentation(badge: "STORAGE", badgeColor: .rtBadge, primary: action, primaryColor: .rtName)
        case let .stateAction(name, _, _):
            return RtPresentation(badge: "ACTION", badgeColor: .rtBadge, primary: name, primaryColor: .rtName)
        case let .stateValuesChange(changes):
            return RtPresentation(
                badge: "STATE", badgeColor: .rtBadge,
                primary: changes.first?.path ?? "\(changes.count) changes", primaryColor: .rtName
            )
        case let .customCommandRegister(_, command, _, _, _):
            return RtPresentation(badge: "COMMAND", badgeColor: .rtBadge, primary: command, primaryColor: .rtName)
        case let .customCommandUnregister(_, command):
            return RtPresentation(badge: "COMMAND", badgeColor: .secondary, primary: "removed \(command)", primaryColor: .secondary)
        case let .stateValuesResponse(path, _):
            return RtPresentation(badge: "STATE", badgeColor: .rtBadge, primary: path ?? "store", primaryColor: .rtName)
        case let .stateKeysResponse(path, _):
            return RtPresentation(badge: "STATE", badgeColor: .rtBadge, primary: path ?? "store", primaryColor: .rtName)
        case .stateBackup:
            return RtPresentation(badge: "SNAPSHOT", badgeColor: .rtBadge, primary: "", primaryColor: .primary)
        case let .replKeys(names):
            return RtPresentation(badge: "REPL", badgeColor: .rtBadge, primary: names.joined(separator: ", "), primaryColor: .primary)
        case .replResult:
            return RtPresentation(badge: "REPL", badgeColor: .rtBadge, primary: "result", primaryColor: .primary)
        case let .unknown(type, payload):
            return RtPresentation(
                badge: type.uppercased(), badgeColor: .secondary,
                primary: payload?.stringValue.map { String($0.prefix(140)) } ?? "", primaryColor: .secondary
            )
        }
    }
}

private extension ReactotronLogLevel {
    var badge: String { rawValue.uppercased() }

    var tint: Color {
        switch self {
        case .debug: .secondary
        case .warn: .orange
        case .error: .red
        }
    }
}
