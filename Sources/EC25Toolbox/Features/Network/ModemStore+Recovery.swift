import Foundation

extension ModemStore {
    /// Tiers whose preconditions currently hold, recomputed on every tick.
    /// USB reconnect works for any transport (local or remote session);
    /// the data-path tiers only make sense while owning the local device.
    var applicableRecoveryTiers: Set<RecoveryTier> {
        var tiers = Set<RecoveryTier>()
        if !state.connected {
            tiers.insert(.usbReconnect)
        }
        guard settings.effectiveManagementMode == .direct else { return tiers }
        if state.connected {
            tiers.formUnion([.networkReattach, .moduleReset, .hardReset])
        }
        if let nic = state.network.nic,
           let service = state.network.service,
           service.enabled,
           service.usesDHCP,
           nic.bsdName == service.bsdName {
            tiers.insert(.dhcpRenew)
        }
        return tiers
    }

    /// True when the app-managed module service is enabled but the module
    /// NIC has no usable link — the "AT answers, data broken" symptom.
    var isModuleDataStalled: Bool {
        guard state.connected, settings.effectiveManagementMode == .direct else { return false }
        return applicableRecoveryTiers.contains(.dhcpRenew) && !state.network.moduleLink.isReady
    }

    /// Assessed on every recovery tick: starts or escalates an episode and
    /// authorizes at most one tier action, always behind user operations.
    func driveRecovery() {
        let now = Date()

        if state.connected && !isModuleDataStalled {
            recoveryStalledTicks = 0
            recoveryMachine.reportHealthy()
            return
        }

        let symptom: RecoverySymptom
        if state.connected {
            // Debounce boot-time registration: a fresh modem needs a few
            // polls before the link is judged as genuinely stalled.
            recoveryStalledTicks += 1
            guard recoveryStalledTicks >= 2 else { return }
            symptom = .dataStalled
        } else {
            recoveryStalledTicks = 0
            symptom = .transportLost
        }

        recoveryMachine.reportSymptom(symptom, now: now)
        guard !state.busy,
              !state.refreshing,
              !foregroundOperationQueued,
              !refreshOperationQueued else { return }
        guard let begin = recoveryMachine.beginAttempt(now: now, applicable: applicableRecoveryTiers) else { return }
        if begin.restartedEpisode {
            log(localized("recovery.log.restart"))
        }
        performRecoveryTier(begin.tier)
    }

    /// Ends any active episode because a user action owns the modem now.
    func cancelRecoveryEpisode() {
        if recoveryMachine.isActive {
            log(localized("recovery.log.cancelled"))
        }
        recoveryMachine.cancel()
        recoveryStalledTicks = 0
    }

    // MARK: - Tier dispatch

    private func performRecoveryTier(_ tier: RecoveryTier) {
        log(localizedFormat("recovery.log.attempt", localized(tier.localizationKey)))
        switch tier {
        case .usbReconnect:
            // Same serialized pipeline as user actions: a reconnect cycle
            // must not race an lpac APDU session, and normal controls stay
            // responsive while it runs.
            runRefresh { [weak self] in
                guard let self else { return }
                do {
                    try await self.connectImpl(prefix: localized("log.connected"))
                    self.finishRecovery(.usbReconnect, recovered: true)
                } catch {
                    self.finishRecovery(.usbReconnect, recovered: false, error: error)
                }
            }
        case .dhcpRenew:
            enqueueBackground { [weak self] in
                await self?.performDHCPRenewTier()
            }
        case .networkReattach:
            enqueueBackground { [weak self] in
                await self?.performReattachTier()
            }
        case .moduleReset:
            enqueueBackground { [weak self] in
                await self?.performModuleResetTier()
            }
        case .hardReset:
            enqueueBackground { [weak self] in
                await self?.performHardResetTier()
            }
        }
    }

    private func finishRecovery(_ tier: RecoveryTier, recovered: Bool, error: (any Error)? = nil) {
        if let error {
            log(localizedFormat("common.error_format", error.localizedDescription))
        }
        let report = recoveryMachine.reportOutcome(
            tier,
            succeeded: recovered,
            now: Date(),
            applicable: applicableRecoveryTiers
        )
        if report.recovered {
            log(localizedFormat("recovery.log.success", localized(tier.localizationKey)))
            recoveryStalledTicks = 0
        } else if report.exhausted {
            log(localizedFormat("recovery.log.exhausted", Int(recoveryMachine.config.episodeRetryDelay)))
        } else {
            log(localizedFormat("recovery.log.failed", localized(tier.localizationKey), report.attemptsAtTier))
        }
    }

    // MARK: - Tier actions

    /// Renews the module service DHCP lease through the privileged helper.
    /// Never creates or reconfigures services: recovery only repairs the
    /// existing app-managed service, so re-enumeration cannot duplicate it.
    private func performDHCPRenewTier() async {
        let current = await currentModuleNetworkStatus()
        guard let service = current.service,
              service.serviceID == state.network.service?.serviceID,
              let nic = current.nic,
              service.enabled,
              service.usesDHCP,
              nic.bsdName == service.bsdName else {
            finishRecovery(.dhcpRenew, recovered: false)
            return
        }
        do {
            try await systemHelper.networkRenewDHCP(serviceID: service.serviceID)
            guard await currentModuleNetworkStatus().nic == nic else {
                throw ModemNetworkError.noInterface
            }
            try await systemHelper.networkForceInterfaceRefresh(bsdName: nic.bsdName)
            // A fresh lease can take a few seconds; re-sample the link
            // before judging the tier.
            for _ in 0..<4 {
                try? await Task.sleep(for: .seconds(2))
                await refreshNetworkStatusImpl()
                if state.network.moduleLink.isReady {
                    break
                }
            }
            finishRecovery(.dhcpRenew, recovered: state.network.moduleLink.isReady)
        } catch {
            finishRecovery(.dhcpRenew, recovered: false, error: error)
        }
    }

    /// Re-attaches the packet domain and re-registers automatically.
    private func performReattachTier() async {
        guard state.connected else {
            finishRecovery(.networkReattach, recovered: false)
            return
        }
        do {
            if try await packetDomainAttached(), state.network.moduleLink.isReady {
                finishRecovery(.networkReattach, recovered: true)
                return
            }
            _ = try await send("AT+CGATT=1", timeout: 10_000)
            _ = try await send("AT+COPS=0", timeout: 10_000)
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(3))
                await refreshNetworkStatusImpl()
                if state.network.moduleLink.isReady, try await packetDomainAttached() {
                    finishRecovery(.networkReattach, recovered: true)
                    return
                }
            }
            finishRecovery(.networkReattach, recovered: false)
        } catch {
            finishRecovery(.networkReattach, recovered: false, error: error)
        }
    }

    /// Cycles module RF (CFUN 0/1); the AT stack stays on the same USB
    /// interfaces, so the session survives without re-enumeration.
    private func performModuleResetTier() async {
        guard state.connected else {
            finishRecovery(.moduleReset, recovered: false)
            return
        }
        do {
            _ = try await send("AT+CFUN=0", timeout: 10_000)
            try? await Task.sleep(for: .seconds(2))
            _ = try await send("AT+CFUN=1", timeout: 15_000)
            for _ in 0..<5 {
                if (try? await send("AT", timeout: 2_000)) != nil {
                    finishRecovery(.moduleReset, recovered: true)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
            finishRecovery(.moduleReset, recovered: false)
        } catch {
            finishRecovery(.moduleReset, recovered: false, error: error)
        }
    }

    /// Full module reboot. The command is strictly rate-limited by the
    /// machine (one attempt per episode, ten-minute cooldown); afterwards
    /// the session is dropped so the reconnect tier re-discovers the
    /// re-enumerated device.
    private func performHardResetTier() async {
        guard state.connected else {
            finishRecovery(.hardReset, recovered: false)
            return
        }
        do {
            _ = try await send("AT+CFUN=1,1", timeout: 8_000)
            await markDisconnected(logRemoval: false)
            finishRecovery(.hardReset, recovered: true)
        } catch {
            finishRecovery(.hardReset, recovered: false, error: error)
        }
    }

    private func packetDomainAttached() async throws -> Bool {
        let lines = try await send("AT+CGATT?", timeout: 4_000)
        return lines.contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("+CGATT: 1")
        }
    }
}
