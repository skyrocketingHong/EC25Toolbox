import AppKit
import Darwin
import Foundation
import ServiceManagement

/// Main-actor application store that coordinates modem transport, polling,
/// persistence, and all user-triggered modem actions.
@MainActor
final class ModemStore: ObservableObject {
    /// Live UI state rendered by the SwiftUI panel.
    @Published var state = ModemState()
    /// Persisted user settings.
    @Published var settings = ModemSettings.defaults
    /// Optional module-side QDC507 runtime state. This is separate from the
    /// Mac CoreAudio bridge because downloading/loading firmware artifacts is
    /// an explicit, hardware-scoped operation.
    @Published var moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus()

    /// Physical direct-mode module owned by this store. nil denotes the
    /// legacy/remote placeholder session used when no local module is selected.
    private(set) var moduleDescriptor: USBModemDescriptor?
    /// Only one session owns process-global services such as login-item and
    /// remote-listener configuration. Every module still owns independent AT,
    /// polling, SMS, and call pipelines.
    private(set) var ownsGlobalServices: Bool
    /// Coordinator hook for app-wide preference propagation.
    var settingsDidChange: ((ModemSettings) -> Void)?
    /// User-visible module name (saved note first, IMEI/USB fallback).
    var moduleDisplayNameProvider: (() -> String)?
    /// Resolves the provisional USB identity to the stable IMEI identity after
    /// `AT+CGSN`. The coordinator migrates selection, notes, and binding state.
    var moduleIMEIDidResolve: ((String) -> Void)?

    let localTransport: EC25Transport
    var transport: any ModemTransport
    var remoteServer: RemoteManagementServer?
    /// SMS archive owned by this store; tests inject a temporary-directory
    /// instance through the dedicated initializer.
    let smsArchive: SMSArchiveStore
    /// Cached conversation projection for `state.messages`; recomputed only
    /// when the message collection changes instead of in every view `body`.
    let smsConversations = SMSConversationProjectionModel()
    let callLogStore: CallLogStore
    /// SIM identity whose call history is currently loaded.
    var callLogScope = SIMMessageScope(eid: nil, iccid: nil)
    /// Injected by the app delegate so SMS banners can resolve contact names
    /// without ModemStore depending on ContactStore.
    var smsContactNameResolver: ((String) -> String?)?
    /// In-memory contact-name lookup for caller identity (R12). Must only
    /// read an already-loaded snapshot — never a synchronous CNContactStore
    /// access and never a permission prompt at call time.
    var callContactNameResolver: ((String) -> String?)?
    /// Async snapshot reload (never prompts) used when the in-memory contact
    /// snapshot may still be loading while a call rings.
    var callContactSnapshotReload: (@MainActor () async -> Void)?
    /// Bounded RING→CLIP identity merge window, 250–500 ms per spec (R12).
    /// Internal so tests can shorten it deterministically.
    var callerIdentityMergeWindow: TimeInterval = 0.4
    /// Caller-identity coordinator bound to the tracked call epoch (R12).
    var callIdentityCoordinator = IncomingCallIdentityCoordinator()
    /// Fires when the merge window expires without a CLIP number.
    var callerIdentityHoldTask: Task<Void, Never>?
    /// Injected by the app delegate (R6): true while the SMS list surface is
    /// on screen. New-message banners are suppressed only in that state;
    /// app activity alone no longer decides, so banners still fire while the
    /// user is on another tab and stay quiet behind a visible SMS list.
    var isSMSSurfaceVisible: () -> Bool = { false }
    /// Scope that already served as a notification baseline; the first refresh
    /// after a scope change never notifies (it would banner the whole archive).
    var smsNotificationBaselineScopeID: String?
    /// PDU-mode (`CMGF=0`) listing latch: nil = untried, true = use PDU,
    /// false = firmware rejected it and text mode is used for the session.
    /// Internal for the R0 diagnostics snapshot.
    var smsPDUModeUsable: Bool?
    private var started = false
    private var infoPollTask: Task<Void, Never>?
    private var smsPollTask: Task<Void, Never>?
    private var recoverTask: Task<Void, Never>?
    private var operationTail: Task<Void, Never>?
    /// Refreshes can produce hundreds of diagnostic-only mutations while AT
    /// responses arrive. Buffer those diagnostics until completion so visible
    /// scroll views are not invalidated for every log line or command record.
    private var deferredRefreshLogLines: [String]?
    private var deferredRefreshCommandRecords: [CommandRecord]?
    var modemEventTask: Task<Void, Never>?
    var callMaintenanceTask: Task<Void, Never>?
    var callMaintenanceRunning = false
    /// Deterministic voice-call state fed by transport events and user intents.
    var callMachine = CallStateMachine()
    /// Internal (not private) so the recovery extension can defer
    /// automation behind queued user operations.
    var foregroundOperationQueued = false
    var refreshOperationQueued = false
    /// Prevents repeated automatic PIN attempts against the same locked SIM session.
    var simAutoUnlockAttemptedICCID: String?
    /// Prevents every status poll from repeating the same PIN-required user notification.
    var simPINNoticeFingerprint: String?
    /// Modem APDU backend and open logical channels for the current connection.
    var estkAPDUBackend: ESTKAPDUBackend?
    var estkLogicalChannels: [UInt8: UInt8] = [:]
    var estkDetectionICCID: String?
    var vowifiTask: Task<Void, Never>?
    var vowifiDataPlane: VoWiFiDataPlane?
    var vowifiIMSClient: IMSClient?
    var vowifiSessionICCID: String?
    /// Deterministic GNSS engine state fed by `AT+QGPSLOC` polls.
    var gnssMachine = GNSSStateMachine()
    /// Internal (not private) so the GNSS extension can own the poll loop.
    var gnssPollTask: Task<Void, Never>?
    /// Fallback-chain runtime and the independent USB NMEA endpoint (R4).
    var gnssSourceRuntime = GNSSSourceRuntime()
    var gnssNMEAEndpoint: EC25NMEAEndpoint?
    var gnssRemoteNMEARelayActive = false
    var gnssNMEATask: Task<Void, Never>?
    var gnssNMEABuffer: [String] = []

    /// Deterministic escalation state for automatic recovery, driven by the
    /// recovery poll tick; actions live in `ModemStore+Recovery`.
    var recoveryMachine = RecoveryStateMachine()
    /// Consecutive recovery ticks that saw the module data path stalled;
    /// debounces boot-time registration before escalating.
    var recoveryStalledTicks = 0

    /// Client for the privileged system helper (network service mutations).
    let systemHelper = SystemHelperClient()

    /// Default-path watcher backing the exit diagnostics and policy automation.
    let exitPathMonitor = ExitPathMonitor()

    /// Traffic sampling loop state (Network tab chart).
    var trafficPollTask: Task<Void, Never>?
    var trafficLastSample: TrafficSample?
    var trafficSampledNIC: ModemNICInfo?
    lazy var trafficArchive = TrafficArchiveStore(
        fileURL: moduleSupportDirectory.appendingPathComponent("TrafficHistory/sessions.json")
    )

    /// Module-configuration backups (P5-A) written before planned changes.
    lazy var moduleConfigArchive = ModuleConfigBackupStore(
        fileURL: moduleSupportDirectory.appendingPathComponent("ModuleConfig/backups.json")
    )

    /// eUICC profile metadata (P7-A) keyed by EID + ICCID, Mac-local only.
    lazy var profileMetadataStore = ProfileMetadataStore()

    /// Bidirectional call audio, call recording, and ringtone (P6). Runs
    /// outside the AT command pipeline by design.
    let callAudioService = CallAudioService()
    let qdc507VoiceRuntime = QDC507VoiceRuntimeController()
    var qdc507VoiceRouteActive = false

    /// User-imported ringtones under Application Support/Ringtones.
    lazy var ringtoneStore = RingtoneStore()

    /// Call recordings index + files under Application Support/CallRecordings.
    lazy var callRecordingStore = RecordingStore()

    private var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return AppIdentity.applicationSupportDirectory(base: base)
    }

    /// Technical caches/configuration are hardware-scoped. SIM content uses
    /// the shared EID/ICCID stores instead and therefore follows the card.
    private var moduleSupportDirectory: URL {
        appSupportDirectory
            .appendingPathComponent("Modules", isDirectory: true)
            .appendingPathComponent(moduleIdentifier, isDirectory: true)
    }

    var sentLogURL: URL {
        moduleSupportDirectory.appendingPathComponent("sent.json")
    }

    convenience init(callLogStore: CallLogStore = CallLogStore()) {
        self.init(callLogStore: callLogStore, smsArchive: SMSArchiveStore())
    }

    /// Tests inject an archive rooted in a temporary directory so store-level
    /// refreshes never touch the real Application Support data.
    init(
        callLogStore: CallLogStore,
        smsArchive: SMSArchiveStore,
        moduleDescriptor: USBModemDescriptor? = nil,
        ownsGlobalServices: Bool = true
    ) {
        let localTransport = EC25Transport(targetDevice: moduleDescriptor)
        self.moduleDescriptor = moduleDescriptor
        self.ownsGlobalServices = ownsGlobalServices
        self.localTransport = localTransport
        self.transport = localTransport
        self.callLogStore = callLogStore
        self.smsArchive = smsArchive
        settings = loadSettings()
        setAppLocale(settings.preferredLanguage ?? "")
        state.sentMessages = loadSentLog()
        state.smsBackup = smsArchive.state
        configureTransportFromSettings()
        observeWakeNotifications()
        wireCallAudioService()
        smsConversations.attach(store: self)
    }

    deinit {
        infoPollTask?.cancel()
        smsPollTask?.cancel()
        recoverTask?.cancel()
        operationTail?.cancel()
        modemEventTask?.cancel()
        callMaintenanceTask?.cancel()
        gnssPollTask?.cancel()
        gnssNMEATask?.cancel()
        vowifiTask?.cancel()
        remoteServer?.stop()
    }

    /// SF Symbol name used for menu-bar fallback labels and accessibility.
    var menuBarSystemImage: String {
        if !state.connected { return "antenna.radiowaves.left.and.right.slash" }
        switch state.info.signal.bars {
        case 1...4: return "cellularbars"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    /// Stable module index written beside the independent SIM scope. Records
    /// remain readable when the same SIM moves to another module, while their
    /// source hardware stays auditable.
    var moduleIdentifier: String {
        moduleDescriptor?.moduleID ?? "default"
    }

    var moduleSerialNumber: String? {
        moduleDescriptor?.serialNumber
    }

    var moduleDisplayName: String {
        moduleDisplayNameProvider?()
            ?? moduleDescriptor?.displaySerial
            ?? localized("app.name")
    }

    /// Refreshes volatile USB topology (notably the location anchor used by
    /// the module audio interface) without changing the IMEI-derived module
    /// identity or rebuilding its long-lived AT session.
    func updateModuleDescriptor(_ descriptor: USBModemDescriptor) {
        guard moduleDescriptor?.id == descriptor.id else { return }
        moduleDescriptor = descriptor
        callAudioService.refreshDevices()
    }

    /// Spoken menu-bar status including connectivity and signal strength.
    var menuBarAccessibilityLabel: String {
        guard state.connected else { return localized("accessibility.app_offline") }
        let bars = min(max(state.info.signal.bars, 0), 4)
        let signalText = state.info.signal.text == "-" ? "" : localizedFormat("format.comma_value", localized(state.info.signal.text))
        return localizedFormat("accessibility.app_signal", bars, signalText)
    }

    /// Compact status text shown in the panel header.
    var statusText: String {
        let working = state.busy || state.refreshing
        return state.connected ? (working ? "status.working" : "status.online") : (working ? "status.connecting" : "status.offline")
    }

    /// Starts login-item synchronization, polling, and the initial modem connection.
    func start() {
        guard !started else { return }
        started = true
        if ownsGlobalServices {
            applyLoginItemSetting()
            startRemoteSharingIfNeeded()
        }
        startExitPathMonitoring()
        restartPollers()
        refreshModuleVoiceRuntimeStatus()
        connect()
    }

    /// Permanently ends this in-memory hardware session. Rebinding creates a
    /// fresh store; a stopped `NWPathMonitor` and transport are never reused.
    func stopSession() {
        let needsTransportCleanup = started || state.connected
        started = false
        infoPollTask?.cancel()
        infoPollTask = nil
        smsPollTask?.cancel()
        smsPollTask = nil
        recoverTask?.cancel()
        recoverTask = nil
        operationTail?.cancel()
        operationTail = nil
        modemEventTask?.cancel()
        modemEventTask = nil
        callMaintenanceTask?.cancel()
        callMaintenanceTask = nil
        gnssPollTask?.cancel()
        gnssPollTask = nil
        gnssNMEATask?.cancel()
        gnssNMEATask = nil
        vowifiTask?.cancel()
        vowifiTask = nil
        stopTrafficSampling(persist: true)
        exitPathMonitor.stop()
        callAudioService.shutdown()
        if ownsGlobalServices { stopRemoteSharing() }

        guard needsTransportCleanup else { return }
        Task { @MainActor [self] in
            await markDisconnected(logRemoval: false)
        }
    }

    /// Transfers the single process-global service owner when the current
    /// primary module is unbound while other module sessions keep running.
    func setGlobalServicesOwnership(_ owns: Bool) {
        guard ownsGlobalServices != owns else { return }
        ownsGlobalServices = owns
        if owns {
            applyLoginItemSetting()
            startRemoteSharingIfNeeded()
        } else {
            stopRemoteSharing()
        }
    }

    /// Feeds default-path updates into the network snapshot and re-applies
    /// the exit policy. Runs for the whole app lifetime.
    private func startExitPathMonitoring() {
        exitPathMonitor.start { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.network.defaultPath = snapshot
                self.refreshExitFacts()
            }
        }
    }

    /// Opens the USB AT transport and initializes modem state. An explicit
    /// connect supersedes any running automatic recovery episode.
    func connect() {
        cancelRecoveryEpisode()
        run {
            try await self.connectImpl(prefix: localized("log.connected"))
        }
    }

    /// Reopens the USB AT transport after a manual reconnect request.
    func reconnect() {
        cancelRecoveryEpisode()
        run {
            try await self.connectImpl(prefix: localized("log.reconnected"))
        }
    }

    /// Refreshes both modem information and SMS messages.
    func refreshAll() {
        runRefresh {
            try await self.refreshInfoImpl()
            if self.state.simSecurity.isReady {
                try await self.refreshMessagesImpl()
            } else {
                self.clearMessagesForLockedSIM()
            }
            await self.refreshNetworkStatusImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Performs a lightweight connectivity probe and refreshes modem information.
    func refreshInfoOnly() {
        runRefresh {
            do {
                _ = try await self.send("AT", timeout: 2_500)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await self.markDisconnected()
                return
            }
            try await self.refreshInfoImpl()
            await self.refreshNetworkStatusImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Executes an arbitrary AT command from the terminal page.
    func runTerminalCommand(_ command: String) {
        let clean = trimmed(command)
        guard !clean.isEmpty else { return }

        run {
            self.appendTerminal("> \(clean)")
            do {
                let lines = try await self.executeTerminalCommand(clean, timeout: 15_000)
                if lines.isEmpty {
                    self.appendTerminal("OK")
                } else {
                    lines.forEach { self.appendTerminal($0) }
                    self.appendTerminal("OK")
                }
            } catch {
                self.appendTerminal("ERROR: \(error.localizedDescription)")
                throw error
            }
        }
    }

    /// Sends a terminal command after ensuring that the selected transport is
    /// connected. A stale UI connection state is recovered once when the
    /// transport reports that its underlying session is no longer open.
    func executeTerminalCommand(_ command: String, timeout: Int32 = 15_000) async throws -> [String] {
        if !state.connected {
            try await connectImpl(prefix: localized("log.reconnected"))
        }

        do {
            return try await send(command, timeout: timeout)
        } catch EC25TransportError.notOpen {
            try await connectImpl(prefix: localized("log.reconnected"))
            return try await send(command, timeout: timeout)
        }
    }

    /// Updates the modem USB networking mode.
    ///
    /// - Parameter mode: Quectel `usbnet` mode integer, such as ECM or RNDIS.
    func setUSBMode(_ mode: Int) {
        run {
            _ = try await self.send("AT+QCFG=\"usbnet\",\(mode)", timeout: 8_000)
            _ = try await self.send("AT+QCFG=\"usbnet\"", timeout: 6_000)
            try await self.refreshInfoImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Writes the primary PDP context APN.
    func setAPN(_ apn: String) {
        let clean = trimmed(apn)
        guard !clean.isEmpty else {
            state.lastError = localized("error.apn_empty")
            return
        }

        run {
            _ = try await self.send("AT+CGDCONT=1,\"IPV4V6\",\"\(clean)\"", timeout: 8_000)
            try await self.refreshInfoImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Stores the device's own number in the SIM/phonebook entry when supported.
    func setOwnNumber(_ number: String) {
        let clean = sanitizedDialNumber(number)
        guard !clean.isEmpty else {
            state.lastError = localized("error.own_number_empty")
            return
        }

        run {
            let type = clean.hasPrefix("+") ? 145 : 129
            do {
                _ = try await self.send("AT+CSCS=\"IRA\"", timeout: 5_000)
                _ = try await self.send("AT+CPBS=\"ON\"", timeout: 5_000)
                let rangeLines = try await self.send("AT+CPBR=?", timeout: 5_000)
                let index = parsePhonebookIndexRange(rangeLines)?.lowerBound ?? 1
                _ = try await self.send(
                    "AT+CPBW=\(index),\"\(clean)\",\(type),\"EC25 Toolbox\"",
                    timeout: 10_000
                )
                _ = try? await self.send("AT+CSCS=\"UCS2\"", timeout: 5_000)
            } catch {
                _ = try? await self.send("AT+CSCS=\"UCS2\"", timeout: 5_000)
                throw error
            }
            try await self.refreshInfoImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Forces a fresh network search by temporarily deregistering and returning to auto mode.
    func researchNetwork() {
        run {
            self.log(localized("log.searching_network"))
            _ = try await self.send("AT+COPS=2", timeout: 20_000)
            _ = try await self.send("AT+COPS=0", timeout: 60_000)
            try await self.refreshInfoImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Requests a modem reboot and waits for automatic recovery to reconnect.
    func restartModule() {
        run {
            _ = try? await self.send("AT+CFUN=1,1", timeout: 4_000)
            await self.markDisconnected(logRemoval: false)
            self.log(localized("log.restarting_modem"))
        }
    }

    /// Mutates persisted settings and restarts dependent services.
    ///
    /// - Parameter mutate: Closure that edits a copy of current settings.
    func updateSettings(_ mutate: (inout ModemSettings) -> Void) {
        var next = settings
        mutate(&next)
        if next.visibleFields.isEmpty {
            next.visibleFields = ModemSettings.defaults.visibleFields
        }
        setAppLocale(next.preferredLanguage ?? "")
        settings = next
        saveSettings(next)
        if ownsGlobalServices { applyLoginItemSetting() }
        restartPollers()
        settingsDidChange?(next)
    }

    /// Applies an app-wide settings update received from another device
    /// session without writing it again or recursively notifying the
    /// coordinator.
    func applySharedSettings(_ shared: ModemSettings) {
        guard settings != shared else { return }
        let modeChanged = settings.effectiveManagementMode != shared.effectiveManagementMode
        setAppLocale(shared.preferredLanguage ?? "")
        settings = shared
        if moduleDescriptor == nil, modeChanged {
            configureTransportFromSettings()
        }
        if started { restartPollers() }
        callAudioService.refreshDevices()
    }

    /// Runs a user operation with shared busy/error handling.
    ///
    /// Feature extensions use this to participate in the same serialized action
    /// pipeline as the core status, SMS, and configuration commands.
    func run(_ operation: @escaping () async throws -> Void) {
        guard !state.busy, !foregroundOperationQueued else { return }
        // User operations outrank automatic recovery; the machine paces
        // itself from this moment instead of firing right behind them.
        recoveryMachine.reportUserActivity(now: Date())
        foregroundOperationQueued = true
        enqueueOperation(refreshing: false, operation)
    }

    /// Runs a refresh without putting every control in the disabled state.
    /// Foreground actions remain clickable and are serialized behind the poll.
    func runRefresh(_ operation: @escaping () async throws -> Void) {
        guard !state.busy, !foregroundOperationQueued, !refreshOperationQueued else { return }
        refreshOperationQueued = true
        enqueueOperation(refreshing: true, operation)
    }

    private func enqueueOperation(
        refreshing: Bool,
        _ operation: @escaping () async throws -> Void
    ) {
        let previous = operationTail
        operationTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }

            var startedState = self.state
            if refreshing {
                self.beginRefreshDiagnosticsBatch()
                startedState.refreshing = true
            } else {
                startedState.busy = true
            }
            startedState.lastError = nil
            self.state = startedState

            var operationError: String?
            do {
                try await operation()
            } catch is CancellationError {
                // App shutdown or a cancelled queued operation needs no UI error.
            } catch {
                operationError = error.localizedDescription
                self.log(localizedFormat("common.error_format", error.localizedDescription))
            }

            var completedState = self.state
            completedState.lastError = operationError
            if refreshing {
                self.finishRefreshDiagnosticsBatch(into: &completedState)
                completedState.refreshing = false
                self.refreshOperationQueued = false
            } else {
                completedState.busy = false
                self.foregroundOperationQueued = false
            }
            self.state = completedState
        }
    }

    func connectImpl(prefix: String) async throws {
        // The transport is not usable until the complete AT initialization has
        // succeeded. Keeping this false prevents eSTK views from launching lpac
        // against a session that may still be torn down on initialization error.
        state.connected = false
        estkAPDUBackend = nil
        estkLogicalChannels.removeAll()
        await transport.disconnect()
        do {
            let description = try await transport.connect()
            state.usbDescription = description.isEmpty ? state.usbDescription : description
            try await initialize()
            state.connected = true
            startModemEventTask()
            updateSIMPINBlockedServiceNotice()
            log("\(prefix) \(state.usbDescription)")
            scheduleModuleConfigSuggestionReadIfNeeded()
        } catch {
            await markDisconnected(logRemoval: false)
            throw error
        }
    }

    /// Reconnect follow-up: always read the fresh USB composition so an
    /// original DJI identity can surface the first-use guide. The optional
    /// restore suggestion is still derived from settings inside that read;
    /// applying any change always requires explicit confirmation.
    /// Skipped mid-apply because the pipeline re-reads and verifies itself.
    private func scheduleModuleConfigSuggestionReadIfNeeded() {
        guard state.moduleConfig.applyPhase.allowsNewApply else { return }
        enqueueBackground {
            try await self.refreshModuleConfigImpl()
        }
    }

    private func initialize() async throws {
        _ = try await send("AT", timeout: 5_000)
        _ = try await send("ATE0", timeout: 5_000)
        // A PIN-locked SIM may reject SMS configuration commands even though
        // the modem and its AT interface are healthy. Establish connectivity
        // from the basic AT probe first, then configure SMS only after CPIN is
        // READY so the UI can stay online and expose the PIN unlock controls.
        _ = try? await send("AT+CMEE=2")
        // R8: surface module auto-answer (`ATS0`). A non-zero value makes the
        // modem answer calls by itself, which the incoming-call gate must not
        // present as a user answer; read-only probe, never modified here.
        if let autoAnswerLines = try? await send("ATS0?", timeout: 3_000) {
            state.autoAnswerRings = parseAutoAnswerRings(autoAnswerLines)
        }
        try await refreshInfoImpl()
        state.capabilities = await ModemCapabilityProber.probe { command in
            try await self.send(command, timeout: 4_000)
        }
        if state.simSecurity.isReady {
            _ = try? await send("AT+CNMI=2,1,0,0,0")
            // Caller identification for the incoming-call state machine; a
            // locked SIM may reject it, which only costs the caller number.
            _ = try? await send("AT+CLIP=1", timeout: 3_000)
            do {
                try await refreshMessagesImpl()
            } catch {
                log(localizedFormat("common.error_format", error.localizedDescription))
            }
        } else {
            clearMessagesForLockedSIM()
        }
        state.lastUpdated = Date()
        ensureVoWiFiStarted()
    }

    func refreshInfoImpl() async throws {
        refreshNetworkHints()
        resetCommandRecords()
        await refreshSIMSecurityState(allowAutoUnlock: true)

        let manufacturer = await query(localized("parameter.manufacturer.label"), "AT+CGMI")
        let model = await query(localized("parameter.model.label"), "AT+CGMM")
        let revision = await query(localized("parameter.firmware.label"), "AT+CGMR")
        let imei = await query("IMEI", "AT+CGSN")
        let imsi = await query("IMSI", "AT+CIMI")
        let iccid = await query("ICCID", "AT+QCCID", privacy: .suppressResponse)
        let ownNumber = await query(
            localized("parameter.own_number.label"),
            "AT+CNUM",
            privacy: .suppressResponse
        )
        var resolvedOwnNumber = parseOwnNumber(ownNumber)
        if resolvedOwnNumber == "-", state.simSecurity.isReady {
            _ = await query(localized("query.own_number_phonebook"), "AT+CPBS=\"ON\"")
            let rangeLines = await query(localized("query.own_number_phonebook"), "AT+CPBR=?")
            if let range = parsePhonebookIndexRange(rangeLines) {
                let upper = min(range.upperBound, range.lowerBound + 9)
                let phonebook = await query(
                    localized("query.own_number_phonebook"),
                    "AT+CPBR=\(range.lowerBound),\(upper)"
                )
                resolvedOwnNumber = parseOwnNumberPhonebook(phonebook)
            }
        }
        let sim = await query(localized("parameter.sim_status.label"), "AT+CPIN?")
        let simInserted = await query(localized("parameter.sim_inserted.label"), "AT+QSIMSTAT?")
        let operatorName = await query(localized("parameter.operator.label"), "AT+COPS?")
        let signal = await query(localized("parameter.signal.label"), "AT+CSQ")
        let registration = await query(localized("parameter.cs_registration.label"), "AT+CREG?")
        let gprsRegistration = await query(localized("parameter.ps_registration.label"), "AT+CGREG?")
        let epsRegistration = await query(localized("parameter.eps_registration.label"), "AT+CEREG?")
        let packetAttached = await query(localized("parameter.packet_attach.label"), "AT+CGATT?")
        let activePdp = await query(localized("parameter.pdp_activation.label"), "AT+CGACT?")
        let pdpAddress = await query(localized("parameter.pdp_address.label"), "AT+CGPADDR")
        let networkInfo = await query(localized("parameter.data_network_type.label"), "AT+QNWINFO")
        let servingCell = await query(localized("overview.section.serving_cell"), "AT+QENG=\"servingcell\"", timeout: 8_000)
        let carrierAggregation = await query(localized("parameter.carrier_aggregation.label"), "AT+QCAINFO", timeout: 8_000)
        let usbMode = await query(localized("settings.section.usb_mode"), "AT+QCFG=\"usbnet\"")
        let apnProfiles = await query(localized("query.apn_pdp_configuration"), "AT+CGDCONT?", timeout: 8_000)
        let temperature = await query(localized("parameter.temperature.label"), "AT+QTEMP")

        var csq = parseSignal(signal)
        let network = parseNetworkType(networkInfo)
        let cell = parseServingCell(servingCell)
        let temperatures = parseTemperatures(temperature)
        let band = cell.band ?? Int(network.band.filter(\.isNumber))
        let earfcn = cell.earfcn ?? Int(network.channel)
        let frequency = earfcnToDlMHz(band: band, earfcn: earfcn)
        if let rsrpBars = barsFromRSRP(cell.rsrp) {
            csq.bars = rsrpBars
        }
        let profiles = parseAPNProfiles(apnProfiles)

        let resolvedIMEI = USBModemDescriptor.normalizedIMEI(firstNonCommandLine(imei))
        state.info = ModemInfo(
            manufacturer: firstNonCommandLine(manufacturer) ?? "-",
            model: firstNonCommandLine(model) ?? "-",
            revision: firstNonCommandLine(revision) ?? "-",
            imei: resolvedIMEI ?? "-",
            imsi: firstNonCommandLine(imsi) ?? "-",
            iccid: parseICCID(iccid),
            ownNumber: resolvedOwnNumber,
            simStatus: parsePrefixed(sim, prefix: "+CPIN:"),
            simInserted: parsePrefixed(simInserted, prefix: "+QSIMSTAT:"),
            operatorName: parseOperator(operatorName),
            tech: parseTech(operatorLines: operatorName, fallback: network.label),
            signal: csq,
            ber: parseBER(signal),
            registration: parseRegistration(registration, prefix: "+CREG:"),
            gprsRegistration: parseRegistration(gprsRegistration, prefix: "+CGREG:"),
            epsRegistration: parseRegistration(epsRegistration, prefix: "+CEREG:"),
            packetAttached: parsePrefixed(packetAttached, prefix: "+CGATT:"),
            activePdp: compactLines(activePdp, prefix: "+CGACT:"),
            pdpAddress: compactLines(pdpAddress, prefix: "+CGPADDR:"),
            dataNetworkType: network.full,
            plmn: cell.plmn ?? "-",
            networkLabel: network.label,
            servingCell: compactLines(servingCell, prefix: "+QENG:"),
            carrierAggregation: compactLines(carrierAggregation, prefix: "+QCAINFO:"),
            usbNetworkMode: parseUSBNetworkMode(usbMode),
            apnProfiles: profiles,
            currentApn: currentAPN(profiles),
            temperature: temperatures.all,
            temperatureAvg: temperatures.average,
            band: band.map { "Band \($0)" } ?? "-",
            duplexMode: cell.duplexMode ?? "-",
            channel: earfcn.map(String.init) ?? "-",
            rsrp: cell.rsrp.map { "\($0) dBm" } ?? "-",
            rsrq: cell.rsrq.map { "\($0) dB" } ?? "-",
            rssiDbm: cell.rssi.map { "\($0) dBm" } ?? csq.text,
            sinr: cell.sinr.map(String.init) ?? "-",
            cqi: cell.cqi.map(String.init) ?? "-",
            modulation: cqiToModulation(cell.cqi),
            dlBandwidth: cell.dlBandwidth ?? "-",
            ulBandwidth: cell.ulBandwidth ?? "-",
            pci: cell.pci.map(String.init) ?? "-",
            cellId: cell.cellId ?? "-",
            tac: cell.tac ?? "-",
            earfcn: earfcn.map(String.init) ?? "-",
            freqMhz: frequency.map { "\($0) MHz" } ?? "-"
        )
        if let resolvedIMEI, moduleDescriptor?.imei != resolvedIMEI {
            moduleIMEIDidResolve?(resolvedIMEI)
        }
        updateSIMPINBlockedServiceNotice()
        reloadCallLogForCurrentScope()
        await refreshESTKAvailabilityIfNeeded()
        ensureVoWiFiStarted()
    }

    /// Swaps the visible call history when the SIM identity (EID/ICCID)
    /// changes so records never mix across cards or eUICC profiles.
    @discardableResult
    private func query(
        _ title: String,
        _ command: String,
        timeout: Int32 = 5_000,
        privacy: ATLogPrivacy = .plain
    ) async -> [String] {
        do {
            let lines = try await send(command, timeout: timeout, privacy: privacy)
            let recorded = privacy == .suppressResponse
                ? [localizedFormat("log.redacted_lines", lines.count)]
                : lines
            appendCommandRecord(CommandRecord(
                title: title,
                command: command,
                lines: recorded,
                error: nil
            ))
            return lines
        } catch {
            appendCommandRecord(CommandRecord(
                title: title,
                command: command,
                lines: [],
                error: error.localizedDescription
            ))
            return []
        }
    }

    /// Sends one AT command through the transport and mirrors the response into the app log.
    ///
    /// - Parameters:
    ///   - command: AT command line without trailing carriage return.
    ///   - payload: Optional payload sent after the command prompt, used by SMS.
    ///   - timeout: Command timeout in milliseconds.
    ///   - privacy: Redaction level applied to the diagnostics mirror; the
    ///     transport still receives and returns the full command and response.
    /// - Returns: Response lines with transport framing removed.
    @discardableResult
    func send(
        _ command: String,
        payload: String? = nil,
        timeout: Int32 = 4_000,
        privacy: ATLogPrivacy = .plain
    ) async throws -> [String] {
        switch privacy {
        case .plain, .suppressResponse:
            log("> \(command)")
        case .maskArguments:
            log("> \(redactedCommandMirror(command))")
        }
        let lines = try await transport.transact(command: command, payload: payload, timeoutMs: timeout)
        if lines.isEmpty {
            log("< OK")
        } else if privacy == .suppressResponse {
            log("< \(localizedFormat("log.redacted_lines", lines.count))")
        } else {
            lines.forEach { log("< \($0)") }
        }
        return lines
    }

    /// Sends a sensitive command without mirroring APDU or activation-session data
    /// into the in-memory diagnostics log.
    @discardableResult
    func sendUnlogged(_ command: String, timeout: Int32 = 4_000) async throws -> [String] {
        try await transport.transact(command: command, payload: nil, timeoutMs: timeout)
    }

    /// Internal (not private) so the recovery extension can tear the
    /// session down after a module hard reset.
    func markDisconnected(logRemoval: Bool = true) async {
        if state.connected && logRemoval {
            log(localized("log.device_removed"))
        }
        let previousESTKAvailability = state.estk.availability
        state.connected = false
        state.info = .empty
        state.estk = ESTKState()
        // Keep the last confirmed card type while the modem is temporarily
        // offline. A new ICCID is probed again after reconnecting, so swapping
        // the SIM while disconnected still updates the tab correctly.
        state.estk.availability = previousESTKAvailability
        estkAPDUBackend = nil
        estkLogicalChannels.removeAll()
        state.simSecurity = SIMSecurityState()
        // Phonebook capability belongs to the card; a re-enumerated module may
        // present a different one and must be probed again.
        state.phonebook = PhonebookState()
        simAutoUnlockAttemptedICCID = nil
        simPINNoticeFingerprint = nil
        state.usbDescription = "USB modem"
        // The USB NIC disappears with the device; re-discovered on reconnect.
        // Default-path observation keeps running, so it survives the reset.
        stopTrafficSampling(persist: true)
        let defaultPath = state.network.defaultPath
        let lastSession = state.network.lastSession
        state.network = ModemNetworkStatus()
        state.network.defaultPath = defaultPath
        state.network.lastSession = lastSession
        // Module configuration belongs to the unplugged device; the backup
        // timestamp survives so the UI can still point at the last backup.
        let moduleBackupAt = state.moduleConfig.lastBackupAt
        state.moduleConfig = ModuleConfigState()
        state.moduleConfig.lastBackupAt = moduleBackupAt
        if callMachine.hasLiveCall {
            feedMachine(.transportLost)
        }
        state.activeCallNumber = nil
        state.autoAnswerRings = nil
        // The module sound card disappears with the device; stop call audio,
        // recording, and any ringtone instead of leaving handles open.
        callAudioService.shutdown()
        await shutdownQDC507VoiceRuntime()
        callAudioService.refreshDevices()
        if gnssMachine.isEngineRunning {
            feedGNSS(.transportLost)
        }
        gnssPollTask?.cancel()
        gnssPollTask = nil
        teardownGNSSNMEAEndpoint()
        modemEventTask?.cancel()
        modemEventTask = nil
        callMaintenanceTask?.cancel()
        callMaintenanceTask = nil
        callMaintenanceRunning = false
        await stopVoWiFiSession(resetPhase: settings.effectiveVoWiFiEnabled ? .waitingForSIM : .disabled)
        await transport.disconnect()
    }

    /// Explains the common “device connected but no signal” state caused by an unentered SIM PIN.
    func updateSIMPINBlockedServiceNotice() {
        guard state.connected, state.simSecurity.requiresPIN else {
            simPINNoticeFingerprint = nil
            return
        }

        let fingerprint = state.simSecurity.iccid.isEmpty
            ? state.usbDescription
            : state.simSecurity.iccid
        guard simPINNoticeFingerprint != fingerprint else { return }
        simPINNoticeFingerprint = fingerprint
        SIMPINNotification.postLockedSIMNotice()
    }

    /// Recovery tick: assesses health and escalates the deterministic
    /// recovery ladder in `ModemStore+Recovery`. Tier actions run through
    /// the same serialized pipeline as user operations, so a recovery cycle
    /// cannot race an lpac APDU session and controls stay responsive.
    private func attemptRecover() {
        driveRecovery()
    }

    private func handleWake() {
        run {
            self.log(localized("log.resuming"))
            var description: String?
            for attempt in 0..<3 where description == nil {
                do {
                    description = try await self.transport.connect()
                } catch {
                    if attempt < 2 {
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            }

            guard let description else {
                await self.markDisconnected()
                return
            }

            if self.settings.restartOnWake, self.settings.effectiveManagementMode == .direct {
                self.log(localized("log.wake_restarting"))
                _ = try? await self.send("AT+CFUN=1,1", timeout: 4_000)
                await self.markDisconnected(logRemoval: false)
                return
            }

            self.state.connected = true
            self.startModemEventTask()
            self.state.usbDescription = description.isEmpty ? self.state.usbDescription : description
            self.log(localizedFormat("log.wake_reconnected", self.state.usbDescription))
            do {
                try await self.initialize()
            } catch {
                await self.markDisconnected(logRemoval: false)
                throw error
            }
        }
    }

    private func restartPollers() {
        infoPollTask?.cancel()
        smsPollTask?.cancel()
        recoverTask?.cancel()

        let infoSeconds = max(2, settings.infoPollSeconds)
        infoPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(infoSeconds))
                if !Task.isCancelled, state.connected, !state.busy, !state.refreshing {
                    refreshInfoOnly()
                }
            }
        }

        recoverTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled {
                    attemptRecover()
                }
            }
        }

        if settings.smsPollSeconds > 0 {
            let smsSeconds = settings.smsPollSeconds
            smsPollTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(smsSeconds))
                    if !Task.isCancelled, state.connected, !state.busy, !state.refreshing, state.simSecurity.isReady {
                        refreshMessages()
                    }
                }
            }
        }
    }

    private func observeWakeNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
    }

    /// Chains a modem command behind user operations without claiming the
    /// busy or refreshing UI states and without surfacing errors to the user.
    /// Internal so feature extensions (GNSS polling) share the same chain.
    /// The chained task is returned so callers can await completion and keep
    /// single-flight semantics.
    @discardableResult
    func enqueueBackground(_ operation: @escaping () async throws -> Void) -> Task<Void, Never> {
        let previous = operationTail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            do {
                try await operation()
            } catch is CancellationError {
            } catch {
                self.log(localizedFormat("common.error_format", error.localizedDescription))
            }
        }
        operationTail = task
        return task
    }

    private func refreshNetworkHints() {
        var hints: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            state.networkHints = []
            return
        }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            var socketAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &socketAddress.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = buffer.prefix { $0 != 0 }.withUnsafeBufferPointer { pointer in
                String(decoding: pointer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            if ip.hasPrefix("192.168.225.") {
                hints.append("\(name) · \(ip)")
            }
        }

        state.networkHints = hints.sorted()
    }

    /// Adds a bounded phone call event for the Phone feature and persists it
    /// under the current SIM identity.
    /// Internal (not private) so feature extensions can append recovery
    /// and poll lines to the same diagnostics buffer.
    func log(_ line: String) {
        if deferredRefreshLogLines != nil {
            deferredRefreshLogLines?.append(line)
            return
        }
        state.logLines.append(line)
        if state.logLines.count > 600 {
            state.logLines.removeFirst(state.logLines.count - 600)
        }
    }

    private func beginRefreshDiagnosticsBatch() {
        deferredRefreshLogLines = []
        deferredRefreshCommandRecords = nil
    }

    private func finishRefreshDiagnosticsBatch(into completedState: inout ModemState) {
        if let bufferedLogs = deferredRefreshLogLines {
            completedState.logLines.append(contentsOf: bufferedLogs)
            if completedState.logLines.count > 600 {
                completedState.logLines.removeFirst(completedState.logLines.count - 600)
            }
        }
        if let bufferedRecords = deferredRefreshCommandRecords {
            completedState.commandRecords = bufferedRecords
        }
        deferredRefreshLogLines = nil
        deferredRefreshCommandRecords = nil
    }

    private func resetCommandRecords() {
        if deferredRefreshLogLines != nil {
            deferredRefreshCommandRecords = []
        } else {
            state.commandRecords = []
        }
    }

    private func appendCommandRecord(_ record: CommandRecord) {
        if deferredRefreshCommandRecords != nil {
            deferredRefreshCommandRecords?.append(record)
        } else {
            state.commandRecords.append(record)
        }
    }

    private func appendTerminal(_ line: String) {
        state.terminalLines.append(line)
        if state.terminalLines.count > 600 {
            state.terminalLines.removeFirst(state.terminalLines.count - 600)
        }
    }

    private func loadSettings() -> ModemSettings {
        let defaults = UserDefaults.standard
        if defaults.data(forKey: "settings") == nil {
            for legacyIdentifier in AppIdentity.legacyBundleIdentifiers {
                guard let legacyDefaults = UserDefaults(suiteName: legacyIdentifier),
                      let legacyData = legacyDefaults.data(forKey: "settings") else { continue }
                defaults.set(legacyData, forKey: "settings")
                break
            }
        }
        guard let data = defaults.data(forKey: "settings"),
              let decoded = try? JSONDecoder().decode(ModemSettings.self, from: data) else {
            return .defaults
        }
        return decoded.visibleFields.isEmpty ? .defaults : decoded
    }

    private func saveSettings(_ settings: ModemSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "settings")
        }
    }

    private func loadSentLog() -> [SentMessage] {
        guard let data = try? Data(contentsOf: sentLogURL),
              let decoded = try? JSONDecoder().decode([SentMessage].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveSentLog() {
        do {
            try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state.sentMessages)
            try data.write(to: sentLogURL, options: .atomic)
        } catch {
            // Sent-message persistence is best-effort.
        }
    }

    private func applyLoginItemSetting() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if settings.openAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log(localizedFormat("error.login_item", error.localizedDescription))
        }
    }
}
