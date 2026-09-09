import AppKit
import SwiftUI

/// Module configuration card (P5-A/P5-B): current USB/IMS/VoLTE
/// configuration, backups, the pending restore-standard plan, and the
/// confirmed apply/verify/rollback pipeline with copyable manual recovery
/// steps as the last resort.
struct ModuleConfigSettingsCard: View {
    @EnvironmentObject private var store: ModemStore
    @State private var confirmingApply = false
    @State private var confirmingInterfaceChange = false
    @State private var pendingInterfacePlan: ModuleConfigPlan?
    @State private var confirmingIdentityChange = false
    @State private var pendingIdentityPlan: ModuleConfigPlan?
    @State private var confirmingRuntimeDownload = false
    @State private var confirmingADBAuthorization = false
    @State private var confirmingRuntimePrepare = false
    @State private var confirmingRuntimeRemoval = false

    private var config: ModuleConfigState {
        store.state.moduleConfig
    }

    private var canRead: Bool {
        store.state.connected && !store.state.busy
    }

    private var canApply: Bool {
        canRead
            && config.applyPhase.allowsNewApply
            && !(config.plan?.isEmpty ?? true)
            && (config.profile != .rawDJI || store.settings.effectiveModuleConfigMode == .qdc507Voice)
    }

    private var moduleVoiceModeSelected: Bool {
        store.settings.effectiveModuleConfigMode == .qdc507Voice
    }

    private var canOperateModuleVoiceRuntime: Bool {
        canRead
            && store.settings.effectiveManagementMode != .remote
            && moduleVoiceModeSelected
    }

    private var canPrepareModuleVoiceRuntime: Bool {
        canOperateModuleVoiceRuntime
            && store.moduleVoiceRuntimeStatus.isInstalled
            && config.lastReadAt != nil
            && (config.plan?.isEmpty ?? true)
    }

    var body: some View {
        MacSettingsGroup("settings.group.moduleconfig") {
            identityRow
            identityGuidance
            MacSettingsDivider()
            profileRow
            MacSettingsDivider()
            modeRow
            MacSettingsDivider()
            suggestToggleRow
            MacSettingsDivider()
            moduleVoiceRuntimeSection

            if let composition = config.composition {
                MacSettingsDivider()
                compositionRows(composition)
            } else if config.lastReadAt != nil {
                MacSettingsDivider()
                unsupportedNote
            } else {
                MacSettingsDivider()
                notReadNote
            }

            if config.lastReadAt != nil, config.composition != nil {
                MacSettingsDivider()
                valueRows
                MacSettingsDivider()
                backupRow
                MacSettingsDivider()
                planSection
            }

            if config.applyPhase != .idle {
                MacSettingsDivider()
                phaseRow
            }

            if !config.manualRecoverySteps.isEmpty {
                MacSettingsDivider()
                manualRecoverySection
            }
        }
        .confirmationDialog(
            localized("moduleconfig.interface.confirm.title"),
            isPresented: $confirmingInterfaceChange,
            titleVisibility: .visible
        ) {
            Button(localized("moduleconfig.interface.confirm.apply"), role: .destructive) {
                if let pendingInterfacePlan {
                    store.applyModuleConfigPlan(pendingInterfacePlan)
                }
                pendingInterfacePlan = nil
            }
            Button(localized("common.cancel"), role: .cancel) {
                pendingInterfacePlan = nil
            }
        } message: {
            Text(localized("moduleconfig.interface.confirm.message"))
        }
        .confirmationDialog(
            localized("moduleconfig.identity.confirm.title"),
            isPresented: $confirmingIdentityChange,
            titleVisibility: .visible
        ) {
            Button(localized(identityConfirmationButtonKey), role: identityButtonRole) {
                if let pendingIdentityPlan {
                    store.applyModuleConfigPlan(pendingIdentityPlan)
                }
                pendingIdentityPlan = nil
            }
            Button(localized("common.cancel"), role: .cancel) {
                pendingIdentityPlan = nil
            }
        } message: {
            Text(localized("moduleconfig.identity.confirm.message"))
        }
        .confirmationDialog(
            localized("modulevoice.download.confirm.title"),
            isPresented: $confirmingRuntimeDownload,
            titleVisibility: .visible
        ) {
            Button(localized("modulevoice.download.action")) {
                store.installQDC507VoiceRuntime()
            }
            Button(localized("common.cancel"), role: .cancel) {}
        } message: {
            Text(localized("modulevoice.download.confirm.message"))
        }
        .confirmationDialog(
            localized("modulevoice.adb.confirm.title"),
            isPresented: $confirmingADBAuthorization,
            titleVisibility: .visible
        ) {
            Button(localized("modulevoice.adb.action"), role: .destructive) {
                store.authorizeQDC507ADB()
            }
            Button(localized("common.cancel"), role: .cancel) {}
        } message: {
            Text(localized("modulevoice.adb.confirm.message"))
        }
        .confirmationDialog(
            localized("modulevoice.prepare.confirm.title"),
            isPresented: $confirmingRuntimePrepare,
            titleVisibility: .visible
        ) {
            Button(localized("modulevoice.prepare.action"), role: .destructive) {
                store.prepareQDC507VoiceRuntime()
            }
            Button(localized("common.cancel"), role: .cancel) {}
        } message: {
            Text(localized("modulevoice.prepare.confirm.message"))
        }
        .confirmationDialog(
            localized("modulevoice.remove.confirm.title"),
            isPresented: $confirmingRuntimeRemoval,
            titleVisibility: .visible
        ) {
            Button(localized("modulevoice.remove.action"), role: .destructive) {
                store.removeQDC507VoiceRuntime()
            }
            Button(localized("common.cancel"), role: .cancel) {}
        } message: {
            Text(localized("modulevoice.remove.confirm.message"))
        }
    }

    private var moduleVoiceRuntimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacSettingsRow(
                title: "modulevoice.title",
                help: "modulevoice.help"
            ) {
                Label(
                    localized("modulevoice.phase.\(store.moduleVoiceRuntimeStatus.phase.rawValue)"),
                    systemImage: moduleVoiceRuntimeSymbol
                )
                .foregroundStyle(moduleVoiceRuntimeStyle)
            }

            Text(localized("modulevoice.license_notice"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)

            if let artifact = store.moduleVoiceRuntimeStatus.currentArtifact {
                ProgressView(
                    value: Double(store.moduleVoiceRuntimeStatus.completedBytes),
                    total: Double(max(1, store.moduleVoiceRuntimeStatus.totalBytes))
                ) {
                    Text(artifact).font(.caption.monospaced())
                }
                .padding(.horizontal, 14)
            }

            if let detail = store.moduleVoiceRuntimeStatus.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }

            Label(localized(moduleVoiceRuntimeGuidanceKey), systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    moduleVoiceRuntimeActions
                }

                VStack(alignment: .leading, spacing: 8) {
                    moduleVoiceRuntimeActions
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var moduleVoiceRuntimeActions: some View {
        Link(localized("modulevoice.upstream"), destination: ModuleVoiceRuntimeManifest.upstreamRepository)

        if store.moduleVoiceRuntimeStatus.isInstalled {
            Button(localized("modulevoice.adb.action")) {
                confirmingADBAuthorization = true
            }
            .disabled(!canOperateModuleVoiceRuntime)
            .help(localized(moduleVoiceRuntimeGuidanceKey))

            Button(localized("modulevoice.prepare.action")) {
                confirmingRuntimePrepare = true
            }
            .disabled(!canPrepareModuleVoiceRuntime)
            .help(localized(moduleVoiceRuntimeGuidanceKey))

            Button(localized("modulevoice.remove.action")) {
                confirmingRuntimeRemoval = true
            }
            .disabled(
                store.state.busy
                    || store.qdc507VoiceRouteActive
                    || store.moduleVoiceRuntimeStatus.phase == .downloading
                    || store.moduleVoiceRuntimeStatus.phase == .preparing
            )
        } else {
            Button(localized("modulevoice.download.action")) {
                confirmingRuntimeDownload = true
            }
            .disabled(store.state.busy || store.moduleVoiceRuntimeStatus.phase == .downloading)
        }
    }

    private var moduleVoiceRuntimeGuidanceKey: String {
        switch store.moduleVoiceRuntimeStatus.phase {
        case .downloading, .preparing, .routing, .stopping:
            return "modulevoice.guidance.wait"
        case .active:
            return "modulevoice.guidance.active"
        default:
            break
        }
        guard moduleVoiceModeSelected else {
            return "modulevoice.guidance.select_mode"
        }
        guard store.settings.effectiveManagementMode != .remote else {
            return "modulevoice.guidance.direct_only"
        }
        guard store.state.connected else {
            return "modulevoice.guidance.connect"
        }
        guard store.moduleVoiceRuntimeStatus.isInstalled else {
            return "modulevoice.guidance.download"
        }
        guard config.lastReadAt != nil else {
            return "modulevoice.guidance.read_config"
        }
        if !(config.plan?.isEmpty ?? true) {
            return "modulevoice.guidance.apply_config"
        }
        if store.moduleVoiceRuntimeStatus.phase == .prepared {
            return "modulevoice.guidance.prepared"
        }
        return "modulevoice.guidance.self_test"
    }

    private var moduleVoiceRuntimeSymbol: String {
        switch store.moduleVoiceRuntimeStatus.phase {
        case .unavailable: "shippingbox"
        case .downloading, .preparing, .routing, .stopping: "arrow.triangle.2.circlepath"
        case .ready, .prepared: "checkmark.circle"
        case .active: "waveform"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var moduleVoiceRuntimeStyle: Color {
        switch store.moduleVoiceRuntimeStatus.phase {
        case .failed: .red
        case .active: .green
        default: .secondary
        }
    }

    private var identityRow: some View {
        MacSettingsRow(
            title: "moduleconfig.identity.label",
            help: "moduleconfig.identity.help"
        ) {
            HStack(spacing: 8) {
                Text(currentIdentityText)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let targetIdentity {
                    Button(localized(identityActionKey)) {
                        guard let plan = ModuleConfigPlanner.identityPlan(
                            composition: config.composition,
                            target: targetIdentity
                        ), !plan.isEmpty else { return }
                        pendingIdentityPlan = plan
                        confirmingIdentityChange = true
                    }
                    .disabled(
                        !canRead
                            || !config.applyPhase.allowsNewApply
                            || config.composition == nil
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var identityGuidance: some View {
        if config.composition?.identity == .djiOriginal {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(localized("moduleconfig.identity.onboarding.title"))
                        .font(.subheadline.weight(.semibold))
                    Text(localized("moduleconfig.identity.onboarding.message"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if config.composition?.identity == .ec25 {
            MacSettingsNoteRow(
                text: "moduleconfig.identity.ec25.note",
                systemImage: nil
            )
        }
    }

    private var targetIdentity: ModuleUSBIdentity? {
        switch config.composition?.identity {
        case .djiOriginal: .ec25
        case .ec25: .djiOriginal
        // No identity rewrite is offered for a real EC21: there is no defined
        // counterpart, and writing AT+QCFG="usbcfg" would change the module's
        // own USB composition. Deliberately nil.
        case .ec21: nil
        case nil: nil
        }
    }

    private var currentIdentityText: String {
        guard let composition = config.composition else { return "-" }
        let raw = String(
            format: "%04X:%04X",
            composition.vendorID ?? 0,
            composition.productID ?? 0
        )
        guard let identity = composition.identity else { return raw }
        return "\(localized(identity.localizationKey)) · \(raw)"
    }

    private var identityActionKey: String {
        targetIdentity == .ec25
            ? "moduleconfig.identity.action.switch_ec25"
            : "moduleconfig.identity.action.restore_dji"
    }

    private var identityConfirmationButtonKey: String {
        targetIdentityFromPendingPlan == .ec25
            ? "moduleconfig.identity.confirm.switch_ec25"
            : "moduleconfig.identity.confirm.restore_dji"
    }

    private var identityButtonRole: ButtonRole? {
        targetIdentityFromPendingPlan == .djiOriginal ? .destructive : nil
    }

    private var targetIdentityFromPendingPlan: ModuleUSBIdentity? {
        guard case let .identity(identity) = pendingIdentityPlan?.verificationTarget else {
            return nil
        }
        return identity
    }

    private var profileRow: some View {
        MacSettingsRow(
            title: "moduleconfig.profile.label",
            help: "moduleconfig.profile.help"
        ) {
            HStack(spacing: 8) {
                Text(localized(config.profile.localizationKey))
                    .foregroundStyle(.secondary)
                Button(localized("moduleconfig.action.read")) {
                    store.refreshModuleConfig()
                }
                .disabled(!canRead)
            }
        }
    }

    private var modeRow: some View {
        MacSettingsRow(
            title: "moduleconfig.mode.label",
            help: "moduleconfig.mode.help"
        ) {
            Picker("", selection: modeBinding) {
                ForEach(ModuleConfigMode.allCases, id: \.self) { mode in
                    Text(localized(mode.localizationKey)).tag(mode)
                        .disabled(!isModeAvailable(mode))
                }
            }
            .labelsHidden()
            .disabled(config.composition?.identity == nil)
        }
    }

    private func isModeAvailable(_ mode: ModuleConfigMode) -> Bool {
        guard let identity = config.composition?.identity else { return false }
        if identity == .ec25 { return true }
        return identity == .djiOriginal && mode == .qdc507Voice
    }

    private var modeBinding: Binding<ModuleConfigMode> {
        Binding(
            get: { store.settings.effectiveModuleConfigMode },
            set: { value in
                store.updateSettings { $0.moduleConfigPreferredMode = value.rawValue }
                // Re-derive the plan for the newly selected mode from the
                // module, not from a locally recomputed guess.
                if store.state.connected {
                    store.refreshModuleConfig()
                }
            }
        )
    }

    private var suggestToggleRow: some View {
        MacSettingsToggleRow(
            title: "moduleconfig.suggest.toggle",
            help: "moduleconfig.suggest.toggle.help",
            isOn: Binding(
                get: { store.settings.effectiveModuleConfigSuggestRestore },
                set: { value in
                    store.updateSettings { $0.moduleConfigSuggestRestoreOnReconnect = value }
                }
            )
        )
    }

    @ViewBuilder
    private func compositionRows(_ composition: USBComposition) -> some View {
        VStack(spacing: 0) {
            ForEach(composition.interfaces) { interface in
                if interface.id != composition.interfaces.first?.id {
                    MacSettingsDivider()
                }
                MacSettingsRow(
                    title: interface.kind.localizationKey,
                    help: "\(interface.kind.localizationKey).help"
                ) {
                    Toggle("", isOn: Binding(
                        get: { interface.enabled },
                        set: { enabled in
                            guard let plan = ModuleConfigPlanner.interfacePlan(
                                composition: composition,
                                kind: interface.kind,
                                enabled: enabled
                            ) else { return }
                            pendingInterfacePlan = plan
                            confirmingInterfaceChange = true
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(AppControlPalette.accent)
                    .disabled(
                        !canRead
                            || !config.applyPhase.allowsNewApply
                            || config.profile == .rawDJI
                            || interface.kind == .atPort
                    )
                    .help(localized(
                        interface.kind == .atPort
                            ? "moduleconfig.interface.at_port.locked_help"
                            : "\(interface.kind.localizationKey).help"
                    ))
                }
            }
        }
    }

    private var unsupportedNote: some View {
        Text(localized("moduleconfig.note.unsupported"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }

    private var notReadNote: some View {
        Text(localized("moduleconfig.note.not_read"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }

    @ViewBuilder
    private var valueRows: some View {
        MacSettingsRow(title: "moduleconfig.field.usbnet") {
            Text(usbnetText).foregroundStyle(.secondary)
        }
        MacSettingsDivider()
        MacSettingsRow(title: "moduleconfig.field.ims") {
            Text(imsText).foregroundStyle(.secondary)
        }
        MacSettingsDivider()
        MacSettingsRow(title: "moduleconfig.volte_disabled.label") {
            Text(volteDisabledText).foregroundStyle(.secondary)
        }
        MacSettingsDivider()
        MacSettingsRow(title: "moduleconfig.field.usb_voice") {
            Text(usbVoiceText).foregroundStyle(.secondary)
        }
    }

    private var backupRow: some View {
        MacSettingsRow(
            title: "moduleconfig.action.backup",
            help: "moduleconfig.action.backup.help"
        ) {
            HStack(spacing: 8) {
                if let lastBackupAt = config.lastBackupAt {
                    Text(AppDateTimeFormatter.shared.string(from: lastBackupAt, role: .compact))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(AppDateTimeFormatter.shared.string(from: lastBackupAt, role: .full))
                }
                Button(localized("moduleconfig.action.backup")) {
                    store.backupModuleConfig()
                }
                .disabled(!canRead)
            }
        }
    }

    @ViewBuilder
    private var planSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacSettingsRow(title: planTitleKey, help: "moduleconfig.plan.apply_hint") {
                if let plan = config.plan, !plan.isEmpty {
                    Button(localized("moduleconfig.apply.action")) {
                        confirmingApply = true
                    }
                    .controlSize(.regular)
                    .disabled(!canApply)
                } else {
                    Text(localized(alreadyTargetKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if config.reconnectSuggestion, config.profile != .rawDJI {
                Label(localized("moduleconfig.suggestion.note"), systemImage: "exclamationmark.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }

            if config.profile == .rawDJI {
                Text(localized("moduleconfig.note.raw_dji"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            } else if let plan = config.plan, !plan.isEmpty {
                ForEach(plan.changes) { change in
                    HStack(spacing: 6) {
                        Text(localized(change.fieldKey))
                        Spacer(minLength: 8)
                        Text("\(change.from) → \(change.to)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                    .padding(.horizontal, 14)
                }

                if let command = plan.commands.first {
                    Text(command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            Color.secondary.opacity(0.075),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .padding(.horizontal, 14)
                }

            }
        }
        .padding(.bottom, 12)
        .confirmationDialog(
            localized("moduleconfig.apply.confirm.title"),
            isPresented: $confirmingApply,
            titleVisibility: .visible
        ) {
            Button(localized("moduleconfig.apply.confirm.button"), role: .destructive) {
                store.applyModuleConfigPlan()
            }
            Button(localized("common.cancel"), role: .cancel) {}
        } message: {
            Text(localized("moduleconfig.apply.confirm.message"))
        }
    }

    private var planTitleKey: String {
        switch store.settings.effectiveModuleConfigMode {
        case .macFull: "moduleconfig.plan.title.mac_full"
        case .qdc507Voice: "moduleconfig.plan.title.qdc507_voice"
        case .mobile: "moduleconfig.plan.title.mobile"
        }
    }

    private var alreadyTargetKey: String {
        switch store.settings.effectiveModuleConfigMode {
        case .macFull: "moduleconfig.plan.already_standard"
        case .qdc507Voice: "moduleconfig.plan.already_qdc507_voice"
        case .mobile: "moduleconfig.plan.already_mobile"
        }
    }

    private var phaseRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            MacSettingsRow(title: "moduleconfig.apply.phase.label") {
                Label(localized(phaseLocalizationKey), systemImage: phaseSymbol)
                    .foregroundStyle(phaseStyle)
                    .symbolRenderingMode(.hierarchical)
            }

            if config.applyPhase == .restored {
                Text(localized("moduleconfig.apply.result.restored_note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
        }
    }

    private var manualRecoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localized("moduleconfig.manual.title"))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Button(localized("moduleconfig.manual.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        config.manualRecoverySteps.joined(separator: "\n"),
                        forType: .string
                    )
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(config.manualRecoverySteps, id: \.self) { step in
                    Text(step)
                        .font(step.hasPrefix("AT+") ? .callout.monospaced() : .callout)
                        .foregroundStyle(step.hasPrefix("AT+") ? .primary : .secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Value formatting

    private var usbnetText: String {
        guard let usbnet = config.usbnet else { return "-" }
        guard (0...3).contains(usbnet) else { return String(usbnet) }
        return localizedFormat("moduleconfig.usbnet.value", usbnet, localized("moduleconfig.usbnet.\(usbnet)"))
    }

    private var imsText: String {
        guard let ims = config.imsLTE else { return "-" }
        guard (0...2).contains(ims) else { return String(ims) }
        return localizedFormat("moduleconfig.ims.value", ims, localized("moduleconfig.ims.\(ims)"))
    }

    private var usbVoiceText: String {
        guard let usbVoice = config.usbVoiceOn else { return "-" }
        return localized(usbVoice ? "moduleconfig.value.on" : "moduleconfig.value.off")
    }

    private var volteDisabledText: String {
        guard let value = config.volteDisabled else { return "-" }
        return localized(value == 0 ? "moduleconfig.value.off" : "moduleconfig.value.on")
    }

    // MARK: - Apply phase presentation

    private var phaseLocalizationKey: String {
        switch config.applyPhase {
        case .idle, .applying: "moduleconfig.phase.applying"
        case .rebooting: "moduleconfig.phase.rebooting"
        case .verifying: "moduleconfig.phase.verifying"
        case .succeeded: "moduleconfig.phase.succeeded"
        case .restoring: "moduleconfig.phase.restoring"
        case .restored: "moduleconfig.phase.restored"
        case .restoreFailed: "moduleconfig.phase.restore_failed"
        }
    }

    private var phaseSymbol: String {
        switch config.applyPhase {
        case .idle, .applying: "arrow.forward.circle"
        case .rebooting: "arrow.triangle.2.circlepath.circle"
        case .verifying: "questionmark.circle"
        case .succeeded: "checkmark.circle.fill"
        case .restoring: "arrow.uturn.backward.circle"
        case .restored: "arrow.uturn.backward.circle.fill"
        case .restoreFailed: "exclamationmark.triangle.fill"
        }
    }

    private var phaseStyle: Color {
        switch config.applyPhase {
        case .succeeded: .green
        case .restoreFailed: .orange
        default: .secondary
        }
    }
}
