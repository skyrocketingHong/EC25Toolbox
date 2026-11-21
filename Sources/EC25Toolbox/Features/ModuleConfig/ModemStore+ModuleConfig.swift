import Foundation

/// Live module-configuration view state (P5-A/P5-B/P5-C). Reads, backups,
/// the mode-aware pending plan, the apply/restore pipeline phase, and the
/// reconnect-derived restore suggestion.
struct ModuleConfigState: Equatable {
    var queries: [ModuleConfigQuery] = []
    var composition: USBComposition?
    var usbnet: Int?
    var imsLTE: Int?
    var volteDisabled: Int?
    var usbVoiceOn: Bool?
    var profile: ModuleConfigProfile = .unknown
    var plan: ModuleConfigPlan?
    var lastReadAt: Date?
    var lastBackupAt: Date?
    var applyPhase: ModuleConfigApplyPhase = .idle
    /// Copyable manual recovery steps, populated only when the automatic
    /// restore itself failed.
    var manualRecoverySteps: [String] = []
    /// Derived from the freshest read only (never cache): the composition
    /// deviates from the preferred mode and the user asked for suggestions.
    var reconnectSuggestion = false
}

/// Progress of the apply-verify-restore pipeline. Everything except
/// `idle`/`succeeded`/`restored` is transient or requires user attention.
enum ModuleConfigApplyPhase: Equatable, Sendable {
    case idle
    /// Writing the planned QCFG commands.
    case applying
    /// CFUN=1,1 sent; waiting for the module to re-enumerate.
    case rebooting
    /// Re-reading the configuration after the reboot.
    case verifying
    /// Target composition confirmed.
    case succeeded
    /// Verification failed; replaying the backup composition.
    case restoring
    /// Backup composition confirmed after rollback.
    case restored
    /// Automatic restore failed; manual steps are shown.
    case restoreFailed

    /// Phases from which the user may start another apply. Anything
    /// mid-pipeline blocks the button; idle and terminal results do not.
    var allowsNewApply: Bool {
        switch self {
        case .idle, .succeeded, .restored, .restoreFailed: true
        case .applying, .rebooting, .verifying, .restoring: false
        }
    }
}

/// JSON archive of module-configuration backups. Backups are written for
/// later verification and rollback (P5-B) and never leave the Mac.
struct ModuleConfigBackupStore {
    let fileURL: URL
    private let maxRecords = 20

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func records() -> [ModuleConfigBackup] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? Self.makeDecoder().decode([ModuleConfigBackup].self, from: data) else {
            return []
        }
        return decoded
    }

    func lastBackup() -> ModuleConfigBackup? {
        records().max { $0.createdAt < $1.createdAt }
    }

    func record(_ backup: ModuleConfigBackup) throws {
        var all = records()
        all.append(backup)
        // Oldest first out; newest backups survive the cap.
        if all.count > maxRecords {
            all = Array(all.sorted { $0.createdAt < $1.createdAt }.suffix(maxRecords))
        }
        let data = try Self.makeEncoder().encode(all)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

extension ModemStore {
    var configurationIdentity: ModuleUSBIdentity? {
        let attached = ModuleUSBIdentity(
            vendorID: moduleDescriptor?.vendorID,
            productID: moduleDescriptor?.productID
        )
        if attached == .ec21 { return attached }
        return state.moduleConfig.composition?.identity ?? attached
    }

    /// Re-reads the module's USB/IMS/VoLTE configuration. Every query is
    /// optional: unsupported keys are recorded as failed instead of
    /// aborting the round.
    func refreshModuleConfig() {
        run {
            try await self.refreshModuleConfigImpl()
        }
    }

    func refreshModuleConfigImpl() async throws {
        let probes = [
            "AT+QCFG=\"usbcfg\"",
            "AT+QCFG=\"usbnet\"",
            "AT+QCFG=\"ims\"",
            "AT+QCFG=\"volte_disable\"",
            "AT+QPCMV?"
        ]
        var queries: [ModuleConfigQuery] = []
        for command in probes {
            do {
                let lines = try await send(command, timeout: 4_000)
                queries.append(ModuleConfigQuery(command: command, responseLines: lines, ok: true))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                queries.append(ModuleConfigQuery(command: command, responseLines: [], ok: false))
            }
        }

        func lines(_ command: String) -> [String] {
            queries.first { $0.command == command }?.responseLines ?? []
        }

        var next = ModuleConfigState()
        next.queries = queries
        next.composition = QCFGParser.parseUSBCfg(lines("AT+QCFG=\"usbcfg\""))
        next.usbnet = QCFGParser.parseUSBNet(lines("AT+QCFG=\"usbnet\""))
        next.imsLTE = QCFGParser.parseIMS(lines("AT+QCFG=\"ims\""))
        next.volteDisabled = QCFGParser.parseVoLTEDisabled(
            lines("AT+QCFG=\"volte_disable\"")
        )
        next.usbVoiceOn = QCFGParser.parseUSBVoice(lines("AT+QPCMV?"))
        next.profile = ModuleConfigDecision.profile(composition: next.composition)
        next.plan = ModuleConfigPlanner.plan(
            mode: settings.effectiveModuleConfigMode,
            composition: next.composition,
            usbVoiceOn: next.usbVoiceOn,
            imsLTE: next.imsLTE,
            volteDisabled: next.volteDisabled
        )
        // The suggestion is derived from this fresh read only; a reconnect
        // clears the snapshot, so no stale cache can keep a suggestion alive.
        next.reconnectSuggestion = ModuleConfigDecision.shouldSuggestRestore(
            freshComposition: next.composition,
            usbVoiceOn: next.usbVoiceOn,
            preferredMode: settings.effectiveModuleConfigMode,
            suggestionEnabled: settings.effectiveModuleConfigSuggestRestore
        )
        next.lastReadAt = Date()
        next.lastBackupAt = state.moduleConfig.lastBackupAt
        // A re-read refreshes facts but must not clear pipeline progress
        // or pending manual recovery steps.
        next.applyPhase = state.moduleConfig.applyPhase
        next.manualRecoverySteps = state.moduleConfig.manualRecoverySteps
        state.moduleConfig = next
        state.lastUpdated = Date()
    }

    /// Persists the current configuration snapshot as a backup record.
    /// The backup holds device identity and raw QCFG/QPCMV replies only —
    /// never SIM PINs, messages, or activation codes.
    func backupModuleConfig() {
        run {
            _ = try self.makeModuleConfigBackup()
            self.log(localized("moduleconfig.log.backed_up"))
        }
    }

    /// Applies the pending restore-standard plan after the UI confirmed it:
    /// writes the QCFG commands, reboots the module, re-reads and verifies
    /// the composition, and rolls back from the backup on mismatch.
    func applyModuleConfigPlan() {
        guard state.connected else {
            state.lastError = localized("moduleconfig.apply.error.not_connected")
            return
        }
        guard let plan = state.moduleConfig.plan, !plan.isEmpty else {
            state.lastError = localized("moduleconfig.apply.error.no_plan")
            return
        }
        applyModuleConfigPlan(plan)
    }

    /// Applies a user-confirmed direct interface plan through the same
    /// backup, reboot, verification, and rollback path as preset modes.
    func applyModuleConfigPlan(_ plan: ModuleConfigPlan) {
        guard state.connected else {
            state.lastError = localized("moduleconfig.apply.error.not_connected")
            return
        }
        guard !plan.isEmpty else {
            state.lastError = localized("moduleconfig.apply.error.no_plan")
            return
        }
        // The apply owns the reconnect cycle itself; automatic recovery
        // must not interleave its own ladder behind the same serial chain.
        cancelRecoveryEpisode()
        run {
            try await self.applyModuleConfigPlanImpl(plan)
        }
    }

    // MARK: - Apply pipeline

    private func applyModuleConfigPlanImpl(_ plan: ModuleConfigPlan) async throws {
        guard state.connected,
              configurationIdentity != .ec21,
              let identity = state.moduleConfig.composition?.identity,
              plan.verificationTarget.canApply(to: identity) else {
            throw ModuleConfigApplyError.unsupportedConfiguration
        }
        state.moduleConfig.manualRecoverySteps = []
        // Nothing is written before a fresh backup of the current state.
        let backup = try makeModuleConfigBackup()

        do {
            state.moduleConfig.applyPhase = .applying
            log(localized("moduleconfig.log.applying"))
            for command in plan.commands {
                _ = try await send(command, timeout: 10_000)
            }

            try await rebootModuleForConfigChange()

            state.moduleConfig.applyPhase = .verifying
            try await refreshModuleConfigImpl()
            if ModuleConfigPlanner.reachedTarget(
                composition: state.moduleConfig.composition,
                usbVoiceOn: state.moduleConfig.usbVoiceOn,
                imsLTE: state.moduleConfig.imsLTE,
                volteDisabled: state.moduleConfig.volteDisabled,
                target: plan.verificationTarget
            ) {
                state.moduleConfig.applyPhase = .succeeded
                log(localized("moduleconfig.log.succeeded"))
                return
            }
        } catch is CancellationError {
            state.moduleConfig.applyPhase = .idle
            throw CancellationError()
        } catch {
            // Fall through to the restore path; the original error is
            // reported if the restore also fails.
            log(localizedFormat("common.error_format", error.localizedDescription))
        }

        state.moduleConfig.applyPhase = .restoring
        log(localized("moduleconfig.log.restoring"))
        do {
            let restoreCommands = ModuleConfigPlanner.restoreCommands(from: backup)
            guard !restoreCommands.isEmpty else {
                throw ModuleConfigApplyError.noRestoreCommand
            }
            if !state.connected {
                try await reconnectModuleAfterReboot()
            }
            for command in restoreCommands {
                _ = try await send(command, timeout: 10_000)
            }

            try await rebootModuleForConfigChange()

            try await refreshModuleConfigImpl()
            if ModuleConfigPlanner.matchesBackupConfiguration(
                composition: state.moduleConfig.composition,
                imsLTE: state.moduleConfig.imsLTE,
                volteDisabled: state.moduleConfig.volteDisabled,
                backup: backup
            ) {
                state.moduleConfig.applyPhase = .restored
                log(localized("moduleconfig.log.restored"))
                return
            }
            throw ModuleConfigApplyError.restoreMismatch
        } catch is CancellationError {
            state.moduleConfig.applyPhase = .idle
            throw CancellationError()
        } catch {
            state.moduleConfig.applyPhase = .restoreFailed
            state.moduleConfig.manualRecoverySteps = manualRecoverySteps(for: backup)
            log(localized("moduleconfig.log.restore_failed"))
            throw error
        }
    }

    /// CFUN=1,1 then wait for the module to re-enumerate and come back
    /// through the full connect/initialize chain.
    private func rebootModuleForConfigChange() async throws {
        state.moduleConfig.applyPhase = .rebooting
        log(localized("moduleconfig.log.rebooting"))
        _ = try? await send("AT+CFUN=1,1", timeout: 8_000)
        await markDisconnected(logRemoval: false)
        try await reconnectModuleAfterReboot()
    }

    private func reconnectModuleAfterReboot() async throws {
        // A full module reboot takes tens of seconds to re-enumerate; keep
        // retrying the standard connect chain for roughly half a minute.
        for _ in 0..<10 {
            do {
                try await connectImpl(prefix: localized("moduleconfig.log.reconnected"))
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? await Task.sleep(for: .seconds(3))
            }
        }
        throw ModuleConfigApplyError.moduleDidNotReturn
    }

    /// Copyable fallback for a failed automatic restore.
    private func manualRecoverySteps(for backup: ModuleConfigBackup) -> [String] {
        let restoreCommands = ModuleConfigPlanner.restoreCommands(from: backup)
        guard !restoreCommands.isEmpty else {
            return [
                localized("moduleconfig.manual.no_command"),
                localized("moduleconfig.manual.step_final")
            ]
        }
        return [
            localized("moduleconfig.manual.step1"),
            restoreCommands.joined(separator: "\n"),
            "AT+CFUN=1,1",
            localized("moduleconfig.manual.step_final")
        ]
    }

    /// Builds and persists a backup of the currently read configuration.
    private func makeModuleConfigBackup() throws -> ModuleConfigBackup {
        let backup = ModuleConfigBackup(
            createdAt: Date(),
            imei: state.info.imei == "-" ? nil : state.info.imei,
            model: state.info.model == "-" ? nil : state.info.model,
            revision: state.info.revision == "-" ? nil : state.info.revision,
            usbDescription: state.usbDescription,
            profile: state.moduleConfig.profile,
            queries: state.moduleConfig.queries
        )
        try moduleConfigArchive.record(backup)
        state.moduleConfig.lastBackupAt = backup.createdAt
        return backup
    }
}

extension ModuleConfigApplyError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedConfiguration: return localized("moduleconfig.plan.unavailable")
        case .moduleDidNotReturn: return localized("moduleconfig.error.module_did_not_return")
        case .restoreMismatch: return localized("moduleconfig.error.restore_mismatch")
        case .noRestoreCommand: return localized("moduleconfig.error.no_restore_command")
        }
    }
}
