#if os(macOS) && !targetEnvironment(macCatalyst)
import Observation
import SwiftUI
import ManifoldMCP

/// Connection-only MCP UI for Manifold Mac. Connected sources remain local to
/// this coordinator until the separate chat tool-execution work is complete.
struct MCPConnectionsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator = MCPConnectionCoordinator()
    @State private var consentStore = MCPDataDisclosureConsentStore()
    @State private var pendingConsent: MCPServerDescriptor?
    @State private var isAddingService = false
    @State private var isVisible = false
    @State private var isConfirmingConfigurationReset = false
    @State private var draftName = ""
    @State private var draftExecutablePath = ""
    @State private var draftArguments = ""
    @State private var configurationError: String?

    var body: some View {
        lifecycleContent
        .toolbar {
            Button("Add Local Server", systemImage: "plus") {
                isAddingService = true
            }
            .disabled(coordinator.configurationLoadError != nil)
        }
        .confirmationDialog(
            "Review data use",
            isPresented: Binding(
                get: { pendingConsent != nil },
                set: { if !$0 { pendingConsent = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let descriptor = pendingConsent {
                Button("Connect") {
                    consentStore.accept(serverID: descriptor.id)
                    coordinator.connect(descriptor)
                    pendingConsent = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingConsent = nil }
        } message: {
            if let descriptor = pendingConsent {
                Text("\(descriptor.dataDisclosure)\n\nYou will only see this disclosure the first time you connect this service.")
            }
        }
        .confirmationDialog(
            "Reset saved MCP servers?",
            isPresented: $isConfirmingConfigurationReset,
            titleVisibility: .visible
        ) {
            Button("Reset Saved Servers", role: .destructive) {
                coordinator.resetSavedLocalServers()
            }
            .accessibilityIdentifier("mcp-confirm-reset-saved-servers")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The unreadable saved server data will be deleted. You can then add local servers again.")
        }
        .sheet(isPresented: $isAddingService) {
            localServerConfiguration
        }
    }

    private var lifecycleContent: some View {
        connectionContent
        .navigationTitle("MCP")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mcp-connections-root")
        .onAppear {
            isVisible = true
            coordinator.startListeningIfNeeded()
        }
        .onDisappear {
            isVisible = false
            coordinator.shutdown()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                coordinator.shutdown()
            } else if phase == .active && isVisible {
                coordinator.startListeningIfNeeded()
            }
        }
    }

    @ViewBuilder
    private var connectionContent: some View {
        Group {
            if let error = coordinator.configurationLoadError {
                ContentUnavailableView {
                    Label("Saved servers unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Reset Saved Servers") {
                        isConfirmingConfigurationReset = true
                    }
                    .accessibilityIdentifier("mcp-reset-saved-servers")
                }
            } else if coordinator.catalog.isEmpty {
                ContentUnavailableView {
                    Label("No local servers configured", systemImage: "server.rack")
                } description: {
                    Text("Add a trusted local MCP server executable to connect it over stdio.")
                }
            } else {
                List {
                    Section {
                        ForEach(coordinator.catalog, id: \.id) { descriptor in
                            serviceRow(for: descriptor)
                        }
                    } header: {
                        Text("Connected Services")
                    } footer: {
                        Text("Local servers run on your Mac after you review and approve their access.")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func serviceRow(for descriptor: MCPServerDescriptor) -> some View {
        let snapshot = coordinator.snapshot(for: descriptor.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(descriptor.displayName).font(.headline)
                    Text(snapshot.statusText)
                        .font(.caption)
                        .foregroundStyle(snapshot.isFailed ? Color.red : Color.secondary)
                        .accessibilityIdentifier("mcp-service-status-\(descriptor.id.uuidString)")
                }
                Spacer()
                if snapshot.isBusy { ProgressView().controlSize(.small) }
                if snapshot.canDisconnect {
                    Button("Disconnect", role: .destructive) { coordinator.disconnect(descriptor.id) }
                        .buttonStyle(.bordered)
                        .disabled(snapshot.isBusy)
                        .accessibilityIdentifier("mcp-service-disconnect-\(descriptor.id.uuidString)")
                } else {
                    Button(snapshot.isFailed ? "Retry" : "Connect") {
                        if consentStore.hasAccepted(serverID: descriptor.id) {
                            coordinator.connect(descriptor)
                        } else {
                            pendingConsent = descriptor
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(snapshot.isBusy)
                    .accessibilityIdentifier("mcp-service-connect-\(descriptor.id.uuidString)")
                }
            }
            if let message = snapshot.errorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mcp-service-error-\(descriptor.id.uuidString)")
            }
            DisclosureGroup("Data use") {
                Text(descriptor.dataDisclosure).font(.caption)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mcp-service-row-\(descriptor.id.uuidString)")
    }

    private var localServerConfiguration: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $draftName)
                    .accessibilityLabel("Name")
                TextField("Executable path", text: $draftExecutablePath)
                    .accessibilityLabel("Executable path")
                TextField("Arguments, one per line", text: $draftArguments, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityLabel("Arguments, one per line")
                Text("Only an absolute executable path is accepted. Shells and command strings are rejected; each argument is passed as its own argv value.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let configurationError {
                    Text(configurationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Local MCP Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { resetConfigurationDraft() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        do {
                            try coordinator.addLocalServer(
                                name: draftName,
                                executablePath: draftExecutablePath,
                                arguments: draftArguments.split(separator: "\n").map(String.init)
                            )
                            resetConfigurationDraft()
                        } catch {
                            configurationError = error.localizedDescription
                        }
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 280)
    }

    private func resetConfigurationDraft() {
        draftName = ""
        draftExecutablePath = ""
        draftArguments = ""
        configurationError = nil
        isAddingService = false
    }
}

@MainActor
@Observable
final class MCPConnectionCoordinator {
    private var client: MCPClient?
    private let configurationStore: MCPLocalServerConfigurationStore
    private var sourcesByID: [UUID: MCPToolSource] = [:]
    private var connectionAttempts: [UUID: UUID] = [:]
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var disconnectingIDs: Set<UUID> = []
    private var failedDisconnectIDs: Set<UUID> = []
    private var snapshotsByID: [UUID: MCPConnectionSnapshot] = [:]
    private var eventsTask: Task<Void, Never>?

    private(set) var catalog: [MCPServerDescriptor]
    private(set) var configurationLoadError: String?

    init() {
        let configurationStore = MCPLocalServerConfigurationStore()
        self.configurationStore = configurationStore
        self.catalog = MCPConnectionCatalog.services(configured: configurationStore.services)
        self.configurationLoadError = configurationStore.loadError
        for descriptor in catalog { snapshotsByID[descriptor.id] = .disconnected }
    }

    func startListeningIfNeeded() {
        guard eventsTask == nil else { return }
        // Cancelling an AsyncStream iterator terminates this client's single
        // event stream. Every new foreground/feature activation needs a client
        // with a fresh stream, not an iterator on the old client.
        let client = MCPClient()
        self.client = client
        eventsTask = Task { [weak self, client] in
            for await event in client.connectionEvents {
                guard !Task.isCancelled else { return }
                self?.handle(event)
            }
        }
    }

    func snapshot(for serverID: UUID) -> MCPConnectionSnapshot {
        snapshotsByID[serverID] ?? .disconnected
    }

    func connect(_ descriptor: MCPServerDescriptor) {
        guard connectionAttempts[descriptor.id] == nil,
              sourcesByID[descriptor.id] == nil,
              !disconnectingIDs.contains(descriptor.id) else { return }
        startListeningIfNeeded()
        guard let client else { return }
        let attemptID = UUID()
        failedDisconnectIDs.remove(descriptor.id)
        connectionAttempts[descriptor.id] = attemptID
        updateSnapshot(descriptor.id) {
            $0.phase = .connecting
            $0.errorMessage = nil
            $0.toolCount = 0
        }
        connectionTasks[descriptor.id] = Task { [weak self, client] in
            do {
                let source = try await client.connect(descriptor)
                try Task.checkCancellation()
                try await source.refreshTools()
                let toolCount = await source.currentToolNames().count
                try Task.checkCancellation()
                guard let self, self.connectionAttempts[descriptor.id] == attemptID else {
                    await client.disconnect(serverID: descriptor.id)
                    return
                }
                self.connectionAttempts.removeValue(forKey: descriptor.id)
                self.connectionTasks.removeValue(forKey: descriptor.id)
                self.sourcesByID[descriptor.id] = source
                self.updateSnapshot(descriptor.id) {
                    $0.phase = .connected
                    $0.toolCount = toolCount
                    $0.errorMessage = nil
                }
            } catch is CancellationError {
                await client.disconnect(serverID: descriptor.id)
            } catch {
                guard let self, self.connectionAttempts[descriptor.id] == attemptID else { return }
                self.sourcesByID.removeValue(forKey: descriptor.id)
                // `connect` can have created a client-owned source before a
                // later setup operation fails. Finish that close before the
                // UI makes Retry available for this descriptor.
                self.failedDisconnectIDs.insert(descriptor.id)
                await client.disconnect(serverID: descriptor.id)
                guard self.connectionAttempts[descriptor.id] == attemptID else { return }
                self.failedDisconnectIDs.insert(descriptor.id)
                self.connectionAttempts.removeValue(forKey: descriptor.id)
                self.connectionTasks.removeValue(forKey: descriptor.id)
                self.updateSnapshot(descriptor.id) {
                    $0.phase = .failed
                    $0.toolCount = 0
                    $0.errorMessage = Self.message(for: error)
                }
            }
        }
    }

    func disconnect(_ serverID: UUID) {
        guard !disconnectingIDs.contains(serverID) else { return }
        guard let client else {
            updateSnapshot(serverID) { $0 = .disconnected }
            return
        }
        disconnectingIDs.insert(serverID)
        failedDisconnectIDs.remove(serverID)
        connectionAttempts.removeValue(forKey: serverID)
        connectionTasks.removeValue(forKey: serverID)?.cancel()
        sourcesByID.removeValue(forKey: serverID)
        updateSnapshot(serverID) {
            $0.phase = .disconnecting
            $0.errorMessage = nil
            $0.toolCount = 0
        }
        Task { [weak self, client] in
            await client.disconnect(serverID: serverID)
            guard let self, self.client === client else { return }
            self.disconnectingIDs.remove(serverID)
            self.updateSnapshot(serverID) { $0 = .disconnected }
        }
    }

    func shutdown() {
        eventsTask?.cancel()
        eventsTask = nil
        let oldClient = client
        client = nil
        let inFlightTasks = Array(connectionTasks.values)
        inFlightTasks.forEach { $0.cancel() }
        connectionTasks.removeAll()
        connectionAttempts.removeAll()
        sourcesByID.removeAll()
        disconnectingIDs.removeAll()
        failedDisconnectIDs.removeAll()
        for serverID in snapshotsByID.keys {
            snapshotsByID[serverID] = .disconnected
        }
        if let oldClient {
            Task {
                for task in inFlightTasks { await task.value }
                await oldClient.disconnectAll()
            }
        }
    }

    func resetSavedLocalServers() {
        configurationStore.resetSavedConfigurations()
        configurationLoadError = nil
        catalog = MCPConnectionCatalog.services(configured: configurationStore.services)
        snapshotsByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, .disconnected) })
    }

    func addLocalServer(name: String, executablePath: String, arguments: [String]) throws {
        let descriptor = try configurationStore.add(
            name: name,
            executablePath: executablePath,
            arguments: arguments
        )
        catalog = configurationStore.services
        snapshotsByID[descriptor.id] = .disconnected
    }

    private func handle(_ event: MCPConnectionEvent) {
        switch event {
        case .connecting, .connected:
            break
        case .toolsChanged(let serverID, _, _):
            refreshToolCount(for: serverID)
        case .authorizationRequired(let serverID, _):
            updateSnapshot(serverID) {
                $0.phase = .failed
                $0.errorMessage = "Authorization is required before this service can be used."
            }
        case .scopeDowngraded(let serverID, let requested, let granted):
            updateSnapshot(serverID) {
                $0.errorMessage = "Granted scopes: \(granted.joined(separator: ", ")) (requested: \(requested.joined(separator: ", ")))."
            }
        case .disconnected(let serverID, let reason):
            guard !disconnectingIDs.contains(serverID) else { return }
            // The in-flight task owns initialization failure and only exposes
            // Retry after it has closed the client-side session.
            guard connectionAttempts[serverID] == nil else { return }
            guard failedDisconnectIDs.remove(serverID) == nil else { return }
            sourcesByID.removeValue(forKey: serverID)
            connectionAttempts.removeValue(forKey: serverID)
            connectionTasks.removeValue(forKey: serverID)?.cancel()
            updateSnapshot(serverID) {
                if reason == .requested {
                    $0 = .disconnected
                } else {
                    $0.phase = .failed
                    $0.toolCount = 0
                    $0.errorMessage = "Connection ended: \(Self.disconnectMessage(for: reason))"
                }
            }
        case .error(let serverID, let error):
            guard !disconnectingIDs.contains(serverID) else { return }
            // `MCPClient.connect` emits this before throwing. Let the owning
            // task close the provisional connection before presenting failure.
            guard connectionAttempts[serverID] == nil else { return }
            sourcesByID.removeValue(forKey: serverID)
            connectionTasks.removeValue(forKey: serverID)?.cancel()
            updateSnapshot(serverID) {
                $0.phase = .disconnecting
                $0.toolCount = 0
                $0.errorMessage = nil
            }
            guard let client else { return }
            Task { [weak self, client] in
                await client.disconnect(serverID: serverID)
                guard let self, self.client === client else { return }
                self.failedDisconnectIDs.insert(serverID)
                self.updateSnapshot(serverID) {
                    $0.phase = .failed
                    $0.toolCount = 0
                    $0.errorMessage = Self.message(for: error)
                }
            }
        }
    }

    private func refreshToolCount(for serverID: UUID) {
        guard let source = sourcesByID[serverID] else { return }
        Task { [weak self, source] in
            let count = await source.currentToolNames().count
            guard let self, self.sourcesByID[serverID] != nil else { return }
            self.updateSnapshot(serverID) { $0.toolCount = count }
        }
    }

    private func updateSnapshot(_ serverID: UUID, _ transform: (inout MCPConnectionSnapshot) -> Void) {
        var snapshot = snapshotsByID[serverID] ?? .disconnected
        transform(&snapshot)
        snapshotsByID[serverID] = snapshot
    }

    private static func message(for error: Error) -> String {
        guard let error = error as? MCPError else { return error.localizedDescription }
        return switch error {
        case .requestTimeout:
            "Connection timed out. Confirm the local server is available, then retry."
        case .transportClosed:
            "The server closed its connection before setup completed. Check its output, then retry."
        case .networkUnavailable:
            "Network unavailable. Check your connection, then retry."
        case .authorizationRequired:
            "Authorization is required before this service can be used."
        case .authorizationFailed:
            "Authorization failed. Sign in again, then retry."
        case .ssrfBlocked:
            "The server address is not permitted by the MCP network safety policy."
        case .transportFailure(let message), .failed(let message):
            message
        default:
            String(describing: error)
        }
    }

    private static func disconnectMessage(for reason: MCPDisconnectReason) -> String {
        switch reason {
        case .transportClosed: "the server closed its transport"
        case .networkUnavailable: "the network became unavailable"
        case .memoryPressure: "the app released it under memory pressure"
        case .unauthorized: "authorization was no longer valid"
        case .failed(let message): message
        case .requested: "requested"
        }
    }
}

struct MCPConnectionSnapshot {
    enum Phase: Equatable { case disconnected, connecting, connected, disconnecting, failed }
    var phase: Phase = .disconnected
    var toolCount = 0
    var errorMessage: String?
    static let disconnected = MCPConnectionSnapshot()
    var isBusy: Bool { phase == .connecting || phase == .disconnecting }
    var isFailed: Bool { phase == .failed }
    var canDisconnect: Bool { phase == .connected || phase == .disconnecting }
    var statusText: String {
        switch phase {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected:
            "Connected · \(toolCount) \(toolCount == 1 ? "tool" : "tools") available"
        case .disconnecting: "Disconnecting"
        case .failed: "Failed"
        }
    }
}

private enum MCPConnectionCatalog {
    private static let testServerID = UUID(uuidString: "3A1A1C87-5D4D-4B19-8C7E-78B36A6EEA72")!

    static func services(configured: [MCPServerDescriptor]) -> [MCPServerDescriptor] {
        if let fixture = fixtureService() { return [fixture] }
        return configured
    }

    private static func fixtureService() -> MCPServerDescriptor? {
        guard LaunchArguments.runsMCPConnectionFixture,
              let scriptURL = LaunchArguments.mcpFixtureServerURL else { return nil }
        return MCPServerDescriptor(
            id: testServerID,
            displayName: "Controlled local MCP fixture",
            transport: .stdio(.init(
                executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [scriptURL.path],
                environment: fixtureEnvironment()
            )),
            authorization: .none,
            toolNamespace: "fixture",
            initializationTimeout: LaunchArguments.mcpFixtureMode == "cancel-stall" ? .seconds(30) : .seconds(3),
            requestTimeout: .seconds(3),
            dataDisclosure: "Runs the app's bundled test-only local MCP fixture over stdio. It does not use credentials or contact the network.",
            toolFilter: .allowAll,
            approvalPolicy: .perCall,
            allowsSTDIOTransport: true,
            isUnauthenticatedUnsafe: true
        )
    }

    private static func fixtureEnvironment() -> [String: String] {
        var environment = [
            "MANIFOLD_MCP_FIXTURE_MODE": LaunchArguments.mcpFixtureMode
        ]
        if let attemptLogURL = LaunchArguments.mcpFixtureAttemptLogURL {
            environment["MANIFOLD_MCP_FIXTURE_ATTEMPT_LOG"] = attemptLogURL.path
        }
        return environment
    }
}

@MainActor
private final class MCPDataDisclosureConsentStore {
    private let defaults = UserDefaults.standard
    private let keyPrefix = "com.manifoldkit.manifold.mcp.data-disclosure."
    func hasAccepted(serverID: UUID) -> Bool { defaults.bool(forKey: key(for: serverID)) }
    func accept(serverID: UUID) { defaults.set(true, forKey: key(for: serverID)) }
    private func key(for serverID: UUID) -> String { keyPrefix + serverID.uuidString.lowercased() }
}

@MainActor
private final class MCPLocalServerConfigurationStore {
    private static let storageKey = "com.manifoldkit.manifold.mcp.local-servers.v1"
    private static let shells: Set<String> = ["bash", "dash", "fish", "ksh", "sh", "zsh"]
    private let defaults: UserDefaults
    private(set) var services: [MCPServerDescriptor]
    private(set) var loadError: String?

    init(defaults: UserDefaults? = nil) {
        let selectedDefaults = defaults ?? Self.selectedDefaults()
        self.defaults = selectedDefaults
        if LaunchArguments.seedsMalformedMCPConfiguration,
           selectedDefaults.data(forKey: Self.storageKey) == nil {
            selectedDefaults.set(Data("{".utf8), forKey: Self.storageKey)
        }
        guard let data = selectedDefaults.data(forKey: Self.storageKey) else {
            services = []
            return
        }
        do {
            let descriptors = try JSONDecoder().decode([MCPServerDescriptor].self, from: data)
            guard descriptors.allSatisfy(Self.isSupportedLocalDescriptor) else {
                throw MCPConfigurationError.unsupportedSavedConfiguration
            }
            services = descriptors
        } catch {
            // Preserve the original bytes for explicit user recovery. Treating
            // a decode failure as an empty catalog would let Add overwrite it.
            services = []
            loadError = "Saved local server configurations could not be read. They were left unchanged. Reset saved servers to add new ones."
        }
    }

    func add(name: String, executablePath: String, arguments: [String]) throws -> MCPServerDescriptor {
        guard loadError == nil else { throw MCPConfigurationError.savedConfigurationUnavailable }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { throw MCPConfigurationError.missingName }
        guard executablePath.hasPrefix("/") else { throw MCPConfigurationError.executableMustBeAbsolute }
        let executableURL = URL(fileURLWithPath: executablePath)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw MCPConfigurationError.executableUnavailable
        }
        guard Self.shells.contains(executableURL.lastPathComponent.lowercased()) == false else {
            throw MCPConfigurationError.shellExecutable
        }
        guard arguments.allSatisfy({ $0.contains("\0") == false }) else {
            throw MCPConfigurationError.invalidArgument
        }

        let descriptor = MCPServerDescriptor(
            displayName: trimmedName,
            transport: .stdio(.init(executable: executableURL, arguments: arguments)),
            authorization: .none,
            toolNamespace: Self.namespace(for: trimmedName),
            dataDisclosure: "Runs the local executable you selected over stdio. This server has no network authentication, so tool arguments are disclosed to that local process.",
            toolFilter: .allowAll,
            approvalPolicy: .perCall,
            allowsSTDIOTransport: true,
            isUnauthenticatedUnsafe: true
        )
        do {
            let updatedServices = services + [descriptor]
            defaults.set(try JSONEncoder().encode(updatedServices), forKey: Self.storageKey)
            services = updatedServices
        } catch {
            throw MCPConfigurationError.persistenceFailed
        }
        return descriptor
    }

    func resetSavedConfigurations() {
        defaults.removeObject(forKey: Self.storageKey)
        services = []
        loadError = nil
    }

    private static func selectedDefaults() -> UserDefaults {
        guard let testID = LaunchArguments.mcpConfigurationTestStoreID else { return .standard }
        let suiteName = "com.manifoldkit.manifold.mcp.ui-tests.\(testID.uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create the isolated MCP UI-test preferences suite.")
        }
        return defaults
    }

    private static func isSupportedLocalDescriptor(_ descriptor: MCPServerDescriptor) -> Bool {
        guard case .stdio(let command) = descriptor.transport else { return false }
        return descriptor.authorization == .none
            && descriptor.allowsSTDIOTransport
            && descriptor.isUnauthenticatedUnsafe
            && command.executable.path.hasPrefix("/")
            && shells.contains(command.executable.lastPathComponent.lowercased()) == false
    }

    private static func namespace(for name: String) -> String {
        let normalized = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : Character("_") }
        return String(normalized).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}

private enum MCPConfigurationError: LocalizedError {
    case missingName
    case executableMustBeAbsolute
    case executableUnavailable
    case shellExecutable
    case invalidArgument
    case persistenceFailed
    case unsupportedSavedConfiguration
    case savedConfigurationUnavailable

    var errorDescription: String? {
        switch self {
        case .missingName: "Enter a server name."
        case .executableMustBeAbsolute: "Enter an absolute executable path."
        case .executableUnavailable: "The selected executable does not exist or cannot be executed."
        case .shellExecutable: "Shell executables are not allowed for MCP servers."
        case .invalidArgument: "Arguments cannot contain NUL bytes."
        case .persistenceFailed: "The local server configuration could not be saved."
        case .unsupportedSavedConfiguration, .savedConfigurationUnavailable:
            "Saved local server configurations are unavailable. Reset saved servers before adding a new one."
        }
    }
}
#endif
