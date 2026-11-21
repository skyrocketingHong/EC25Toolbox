import Foundation

/// QDC507 runtime actions and the call-lifecycle bridge. Runtime deployment
/// remains outside the serialized AT pipeline; only QADBKEY authorization and
/// USB-composition changes use the modem command queue.
extension ModemStore {
    var usesQDC507VoiceRuntime: Bool {
        settings.effectiveModuleConfigMode == .qdc507Voice
            && configurationIdentity?.supportsPreset(.qdc507Voice) == true
    }

    func refreshModuleVoiceRuntimeStatus() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let installed = await qdc507VoiceRuntime.isInstalled()
            guard moduleVoiceRuntimeStatus.phase != .downloading,
                  moduleVoiceRuntimeStatus.phase != .preparing,
                  moduleVoiceRuntimeStatus.phase != .routing,
                  moduleVoiceRuntimeStatus.phase != .active,
                  moduleVoiceRuntimeStatus.phase != .stopping else { return }
            moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(
                phase: installed ? .ready : .unavailable,
                localCacheAvailable: installed
            )
        }
    }

    /// Called only after the runtime download confirmation dialog is accepted.
    func installQDC507VoiceRuntime() {
        run {
            self.moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(phase: .downloading)
            do {
                _ = try await self.qdc507VoiceRuntime.install { artifact, completed, total in
                    await MainActor.run {
                        self.moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(
                            phase: .downloading,
                            currentArtifact: artifact,
                            completedBytes: completed,
                            totalBytes: total
                        )
                    }
                }
                self.moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(phase: .ready)
                self.log(localized("modulevoice.log.downloaded"))
            } catch {
                let installed = await self.qdc507VoiceRuntime.isInstalled()
                self.moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(
                    phase: .failed,
                    localCacheAvailable: installed,
                    detail: error.localizedDescription
                )
                throw error
            }
        }
    }

    func removeQDC507VoiceRuntime() {
        guard !qdc507VoiceRouteActive else {
            state.lastError = localized("modulevoice.error.remove_active")
            return
        }
        run {
            try await self.qdc507VoiceRuntime.removeInstalledRuntime()
            self.moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(phase: .unavailable)
            self.log(localized("modulevoice.log.removed"))
        }
    }

    /// Accepts only the old eight-digit QADBKEY challenge. The derived
    /// response is sent without logging and is never persisted or returned to
    /// the UI. Unknown challenge formats fail closed.
    func authorizeQDC507ADB() {
        guard state.connected, transport is EC25Transport else {
            state.lastError = localized("modulevoice.error.direct_only")
            return
        }
        run {
            guard self.usesQDC507VoiceRuntime else {
                throw ModuleConfigApplyError.unsupportedConfiguration
            }
            let lines = try await self.sendUnlogged("AT+QADBKEY?", timeout: 4_000)
            guard let challenge = QDC507ADBKey.parseChallenge(lines) else {
                throw ModuleVoiceRuntimeError.commandFailed(
                    localized("modulevoice.error.qadbkey_challenge")
                )
            }
            let response = try QDC507ADBKey.deriveResponse(challenge: challenge)
            _ = try await self.sendUnlogged("AT+QADBKEY=\"\(response)\"", timeout: 8_000)
            self.log(localized("modulevoice.log.adb_authorized"))
        }
    }

    /// Explicit no-call self-test: verifies the local artifacts, opens the
    /// ADB interface for this physical module, checks root/kernel identity,
    /// pushes to tmpfs, loads the two modules, and runs the helper's check.
    func prepareQDC507VoiceRuntime() {
        guard usesQDC507VoiceRuntime else {
            state.lastError = localized("moduleconfig.plan.unavailable")
            return
        }
        guard let descriptor = moduleDescriptor, transport is EC25Transport else {
            state.lastError = localized("modulevoice.error.direct_only")
            return
        }
        moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(phase: .preparing)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await qdc507VoiceRuntime.prepare(for: descriptor)
                moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(phase: .prepared)
                log(localized("modulevoice.log.prepared"))
            } catch {
                let installed = await qdc507VoiceRuntime.isInstalled()
                moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(
                    phase: .failed,
                    localCacheAvailable: installed,
                    detail: error.localizedDescription
                )
                state.lastError = error.localizedDescription
            }
        }
    }

    /// Selects the configured module voice backend before dial/answer. QDC507
    /// preparation never claims audio readiness until the active-call route is
    /// independently observed as RUNNING.
    func prepareModuleVoiceForCall() async throws {
        guard usesQDC507VoiceRuntime else {
            do {
                _ = try await send("AT+QPCMV=1,2", timeout: 4_000)
                state.moduleConfig.usbVoiceOn = true
                callAudioService.noteModuleVoicePreparation(succeeded: true)
            } catch {
                state.moduleConfig.usbVoiceOn = false
                callAudioService.noteModuleVoicePreparation(succeeded: false)
                throw error
            }
            return
        }

        guard let descriptor = moduleDescriptor, transport is EC25Transport else {
            throw ModuleVoiceRuntimeError.directModuleRequired
        }
        guard await qdc507VoiceRuntime.isInstalled() else {
            throw ModuleVoiceRuntimeError.notInstalled
        }
        moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(phase: .preparing)
        do {
            try await qdc507VoiceRuntime.prepare(for: descriptor)
            qdc507VoiceRouteActive = false
            state.moduleConfig.usbVoiceOn = false
            moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(phase: .prepared)
        } catch {
            moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(
                phase: .failed,
                localCacheAvailable: true,
                detail: error.localizedDescription
            )
            throw error
        }
    }

    /// Delays only the Mac audio bridge while the QDC507 route is entering
    /// RUNNING. Call state and AT processing continue normally.
    func syncCallAudioWithSelectedVoiceBackend(
        transition: CallTransition,
        remoteNumber: String?
    ) {
        guard usesQDC507VoiceRuntime else {
            callAudioService.syncWithCall(phase: callMachine.phase, remoteNumber: remoteNumber)
            return
        }

        if transition.to == .active, transition.from != .active {
            callAudioService.syncWithCall(phase: .dialing, remoteNumber: remoteNumber)
            startQDC507RouteForActiveCall()
            return
        }

        if transition.to == .active || transition.to == .held {
            if qdc507VoiceRouteActive {
                callAudioService.syncWithCall(phase: callMachine.phase, remoteNumber: remoteNumber)
            }
            return
        }

        callAudioService.syncWithCall(phase: callMachine.phase, remoteNumber: remoteNumber)
        if !callMachine.hasLiveCall || transition.to == .ending {
            stopQDC507RouteAfterCall()
        }
    }

    func shutdownQDC507VoiceRuntime() async {
        if qdc507VoiceRouteActive {
            moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(phase: .stopping)
            do {
                try await qdc507VoiceRuntime.stopRoute()
            } catch {
                let installed = await qdc507VoiceRuntime.isInstalled()
                moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(
                    phase: .failed,
                    localCacheAvailable: installed,
                    detail: error.localizedDescription
                )
            }
        }
        qdc507VoiceRouteActive = false
        state.moduleConfig.usbVoiceOn = false
        await qdc507VoiceRuntime.resetAfterDisconnect()
        if moduleVoiceRuntimeStatus.phase != .failed {
            let installed = await qdc507VoiceRuntime.isInstalled()
            moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(
                phase: installed ? .ready : .unavailable,
                localCacheAvailable: installed
            )
        }
    }

    private func startQDC507RouteForActiveCall() {
        guard let descriptor = moduleDescriptor, transport is EC25Transport else {
            state.lastError = localized("modulevoice.error.direct_only")
            callAudioService.noteModuleVoicePreparation(succeeded: false)
            return
        }
        moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(phase: .routing)
        let epoch = callMachine.callEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await qdc507VoiceRuntime.startRoute(for: descriptor)
                guard callMachine.callEpoch == epoch,
                      callMachine.phase == .active || callMachine.phase == .held else {
                    try? await qdc507VoiceRuntime.stopRoute()
                    return
                }
                qdc507VoiceRouteActive = true
                state.moduleConfig.usbVoiceOn = true
                moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(phase: .active)
                callAudioService.noteModuleVoicePreparation(succeeded: true)
                callAudioService.refreshDevices()
                callAudioService.syncWithCall(
                    phase: callMachine.phase,
                    remoteNumber: callMachine.number
                )
                startAutomaticCallRecordingIfNeeded()
            } catch {
                qdc507VoiceRouteActive = false
                state.moduleConfig.usbVoiceOn = false
                moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(
                    phase: .failed,
                    localCacheAvailable: true,
                    detail: error.localizedDescription
                )
                callAudioService.noteModuleVoicePreparation(succeeded: false)
                state.lastError = error.localizedDescription
            }
        }
    }

    private func stopQDC507RouteAfterCall() {
        guard qdc507VoiceRouteActive else { return }
        qdc507VoiceRouteActive = false
        state.moduleConfig.usbVoiceOn = false
        moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(phase: .stopping)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await qdc507VoiceRuntime.stopRoute()
                let installed = await qdc507VoiceRuntime.isInstalled()
                moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(
                    phase: installed ? .prepared : .unavailable,
                    localCacheAvailable: installed
                )
            } catch {
                let installed = await qdc507VoiceRuntime.isInstalled()
                moduleVoiceRuntimeStatus = ModuleVoiceRuntimeStatus(
                    phase: .failed,
                    localCacheAvailable: installed,
                    detail: error.localizedDescription
                )
                state.lastError = error.localizedDescription
            }
        }
    }
}
