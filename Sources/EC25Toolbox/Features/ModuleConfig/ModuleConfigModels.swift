import Foundation

/// USB identities recognized by the native transport. Only the EC25 and
/// first-generation DJI identities form a reversible configuration pair.
enum ModuleUSBIdentity: String, CaseIterable, Equatable, Sendable {
    case ec25
    case ec21
    case djiOriginal

    static let connectionOrder: [ModuleUSBIdentity] = [.ec25, .ec21, .djiOriginal]

    var vendorID: Int {
        switch self {
        case .ec25: 0x2C7C
        case .ec21: 0x2C7C
        case .djiOriginal: 0x2CA3
        }
    }

    var productID: Int {
        switch self {
        case .ec25: 0x0125
        case .ec21: 0x0121
        case .djiOriginal: 0x4006
        }
    }

    var switchTarget: Self? {
        switch self {
        case .ec25: .djiOriginal
        case .djiOriginal: .ec25
        case .ec21: nil
        }
    }

    func supportsPreset(_ mode: ModuleConfigMode) -> Bool {
        switch self {
        case .ec25: true
        case .djiOriginal: mode == .qdc507Voice
        case .ec21: false
        }
    }

    var localizationKey: String { "moduleconfig.identity.\(rawValue)" }

    var displayValue: String {
        String(format: "%04X:%04X", vendorID, productID)
    }

    init?(vendorID: Int?, productID: Int?) {
        guard let vendorID, let productID,
              let match = Self.allCases.first(where: {
                  $0.vendorID == vendorID && $0.productID == productID
              }) else { return nil }
        self = match
    }
}

/// USB interface roles reported by `AT+QCFG="usbcfg"` after the VID/PID
/// pair, in response order (per the Quectel QCFG AT commands manual).
enum USBInterfaceKind: String, CaseIterable, Equatable, Sendable, Identifiable {
    case diag
    case nmea
    case atPort = "at_port"
    case modem
    case rmnet
    case adb
    /// USB Audio Class interface; only newer firmware reports this field.
    case uac

    var id: String { rawValue }

    var localizationKey: String {
        "moduleconfig.interface.\(rawValue)"
    }
}

/// Parsed `+QCFG: "usbcfg"` composition.
struct USBComposition: Equatable, Sendable {
    struct Interface: Equatable, Sendable, Identifiable {
        let kind: USBInterfaceKind
        let enabled: Bool
        var id: String { kind.rawValue }
    }

    var vendorID: Int?
    var productID: Int?
    var interfaces: [Interface]

    var identity: ModuleUSBIdentity? {
        ModuleUSBIdentity(vendorID: vendorID, productID: productID)
    }

    /// The EC25-compatible identity this application normally uses.
    var isQuectelIdentity: Bool { identity == .ec25 }
    var isDJIOriginalIdentity: Bool { identity == .djiOriginal }

    func isEnabled(_ kind: USBInterfaceKind) -> Bool? {
        interfaces.first { $0.kind == kind }?.enabled
    }
}

/// Coarse classification of the module's current configuration.
enum ModuleConfigProfile: String, Equatable, Codable, Sendable {
    /// Quectel VID with all expected serial/data ports on, ADB off, and
    /// USB Audio on (or unreported by the firmware) — the Mac full target.
    case standardEC25
    /// The device still presents a non-Quectel (e.g. original DJI) USB
    /// identity; it must be reconfigured outside this application.
    case rawDJI
    /// Otherwise-standard composition with USB Audio explicitly reported
    /// off: the module sound card is absent and call audio is silent. The
    /// raw value is frozen as "legacyUAC" for decoding persisted backups.
    case legacyUAC
    case unknown

    var localizationKey: String {
        switch self {
        case .standardEC25: "moduleconfig.profile.standard_ec25"
        case .rawDJI: "moduleconfig.profile.raw_dji"
        case .legacyUAC: "moduleconfig.profile.legacy_uac"
        case .unknown: "moduleconfig.profile.unknown"
        }
    }
}

/// Target composition the user wants the module in (P5-C). Persisted as a
/// raw setting; the planner turns the fresh composition into the plan for
/// the selected mode.
enum ModuleConfigMode: String, Equatable, Codable, Sendable, CaseIterable {
    /// Mac baseline: all serial/data interfaces on, ADB off, USB Audio on.
    /// Call audio depends on the module sound card, so this mode must keep
    /// the UAC interface (and the QPCMV voice path) enabled.
    case macFull
    /// Opt-in first-generation QDC507 voice runtime. It preserves the current
    /// VID/PID and every reported function bit except ensuring ADB and UAC are
    /// enabled so the verified runtime can be copied to module tmpfs.
    case qdc507Voice
    /// iPhone/iPad companion profile: only USB Audio is turned off; AT,
    /// USB data, and every other reported interface stay untouched.
    case mobile

    var localizationKey: String {
        switch self {
        case .macFull: "moduleconfig.mode.mac_full"
        case .qdc507Voice: "moduleconfig.mode.qdc507_voice"
        case .mobile: "moduleconfig.mode.mobile"
        }
    }
}

/// One read-only configuration query and its raw modem reply, kept verbatim
/// for the backup record.
struct ModuleConfigQuery: Codable, Equatable, Sendable {
    var command: String
    var responseLines: [String]
    var ok: Bool
}

/// Persisted configuration snapshot. Deliberately contains only device
/// identity, raw QCFG/QPCMV replies, and timestamps — never SIM PINs,
/// message contents, or activation codes.
struct ModuleConfigBackup: Codable, Equatable {
    /// Missing on legacy records, decoded as schema 2 (USB-only restore).
    /// Schema 3 also restores IMS and volte_disable when both were readable.
    var schemaVersion: Int
    var createdAt: Date
    var imei: String?
    var model: String?
    var revision: String?
    var usbDescription: String?
    var profile: ModuleConfigProfile
    var queries: [ModuleConfigQuery]

    init(
        schemaVersion: Int = 3,
        createdAt: Date,
        imei: String?,
        model: String?,
        revision: String?,
        usbDescription: String?,
        profile: ModuleConfigProfile,
        queries: [ModuleConfigQuery]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.imei = imei
        self.model = model
        self.revision = revision
        self.usbDescription = usbDescription
        self.profile = profile
        self.queries = queries
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case createdAt
        case imei
        case model
        case revision
        case usbDescription
        case profile
        case queries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        imei = try container.decodeIfPresent(String.self, forKey: .imei)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        revision = try container.decodeIfPresent(String.self, forKey: .revision)
        usbDescription = try container.decodeIfPresent(String.self, forKey: .usbDescription)
        profile = try container.decode(ModuleConfigProfile.self, forKey: .profile)
        queries = try container.decode([ModuleConfigQuery].self, forKey: .queries)
    }
}

/// One field the plan would change, shown in the confirmation list.
struct ModuleConfigFieldChange: Equatable, Identifiable, Sendable {
    var fieldKey: String
    var from: String
    var to: String
    var id: String { fieldKey }
}

/// Exact post-reboot fact a plan must satisfy. Keeping the verification
/// target with the plan lets individual interface controls use the same
/// backup/apply/verify/rollback pipeline as the two preset modes.
enum ModuleConfigVerificationTarget: Equatable, Sendable {
    case mode(ModuleConfigMode)
    case interface(USBInterfaceKind, Bool)
    case identity(ModuleUSBIdentity)
    case composition(USBComposition)
    case qdc507Runtime(composition: USBComposition, imsLTE: Int, volteDisabled: Int)

    func canApply(to identity: ModuleUSBIdentity) -> Bool {
        switch self {
        case let .mode(mode):
            identity.supportsPreset(mode)
        case .interface:
            identity == .ec25
        case let .identity(target):
            identity.switchTarget == target
        case let .composition(target):
            identity == .ec25 && target.identity == identity
        case let .qdc507Runtime(target, _, _):
            identity.supportsPreset(.qdc507Voice) && target.identity == identity
        }
    }
}

/// A pending modification plan: the field-level diff shown in the UI and
/// the write commands the confirmed apply will run.
struct ModuleConfigPlan: Equatable, Sendable {
    var targetKey: String
    var changes: [ModuleConfigFieldChange]
    /// Write commands the confirmed plan will run.
    var commands: [String]
    var verificationTarget: ModuleConfigVerificationTarget

    var isEmpty: Bool { changes.isEmpty }
}

/// Parses the read-only QCFG/QPCMV query responses. Pure and tolerant:
/// firmwares differ in field count, VID/PID radix, and supported keys.
enum QCFGParser {
    /// `+QCFG: "usbcfg",0x2C7C,0x0125,1,1,1,1,1,0,0` — VID/PID accept
    /// `0x` hex or decimal; trailing fields map to `USBInterfaceKind` in
    /// order. Returns nil when no usbcfg line is present.
    static func parseUSBCfg(_ lines: [String]) -> USBComposition? {
        guard let line = lines.first(where: { $0.hasPrefix("+QCFG: \"usbcfg\"") }) else {
            return nil
        }
        let parts = line
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let numberParts = parts.dropFirst()
        guard let vidRaw = numberParts.first, let vendorID = parseNumber(vidRaw) else {
            return nil
        }
        let productID = numberParts.dropFirst().first.flatMap(parseNumber)
        let interfaceValues = numberParts.dropFirst(2).compactMap(parseNumber)
        let interfaces = zip(USBInterfaceKind.allCases, interfaceValues).compactMap { kind, value in
            USBComposition.Interface(kind: kind, enabled: value != 0)
        }
        return USBComposition(vendorID: vendorID, productID: productID, interfaces: interfaces)
    }

    /// `+QCFG: "usbnet",0` — USB data mode (0 RMNET/QMI, 1 ECM, 2 MBIM,
    /// 3 RNDIS). Returns nil when unsupported or unparseable.
    static func parseUSBNet(_ lines: [String]) -> Int? {
        parseQCFGInteger("usbnet", lines)
    }

    /// `+QCFG: "ims",1,1` — LTE IMS switch (0 MBN default, 1 forced on,
    /// 2 forced off) plus an optional roaming half. Returns the LTE half.
    static func parseIMS(_ lines: [String]) -> Int? {
        parseQCFGInteger("ims", lines)
    }

    /// `+QCFG: "volte_disable",0` — zero is required for module-side VoLTE
    /// routing. Kept separate from the IMS switch because firmware may expose
    /// one without the other.
    static func parseVoLTEDisabled(_ lines: [String]) -> Int? {
        parseQCFGInteger("volte_disable", lines)
    }

    /// `+QPCMV: 1[,2]` — transient PCM forwarding state. The optional
    /// second value selects the carrier: option 2 is the USB sound card.
    static func parseUSBVoice(_ lines: [String]) -> Bool? {
        guard let line = lines.first(where: { $0.hasPrefix("+QPCMV: ") }),
              let token = line
                .dropFirst("+QPCMV: ".count)
                .split(separator: ",", maxSplits: 1)
                .first,
              let value = Int(token.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return value != 0
    }

    // MARK: - Internals

    private static func parseQCFGInteger(_ key: String, _ lines: [String]) -> Int? {
        let prefix = "+QCFG: \"\(key)\""
        guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let tail = line.dropFirst(prefix.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        let first = tail.split(separator: ",").first ?? Substring()
        return Int(first)
    }

    private static func parseNumber(_ raw: String) -> Int? {
        let upper = raw.uppercased()
        if upper.hasPrefix("0X") {
            return Int(upper.dropFirst(2), radix: 16)
        }
        return Int(raw)
    }
}

/// Pure classification of the parsed composition into a user-facing profile.
enum ModuleConfigDecision {
    /// Ports the application needs for full functionality.
    private static let requiredPorts: [USBInterfaceKind] = [.diag, .nmea, .atPort, .modem, .rmnet]

    static func profile(composition: USBComposition?) -> ModuleConfigProfile {
        guard let composition else { return .unknown }
        if composition.isDJIOriginalIdentity { return .rawDJI }
        guard composition.isQuectelIdentity else { return .unknown }
        // Without an AT port the application cannot operate the module at
        // all; that is not a profile it can describe or repair.
        guard composition.isEnabled(.atPort) == true else { return .unknown }
        let adbOn = composition.isEnabled(.adb) ?? false
        let portsOn = requiredPorts.allSatisfy { composition.isEnabled($0) == true }
        // A firmware that does not report a UAC field cannot flip it; that
        // composition still satisfies the standard target.
        let uacSatisfied = composition.isEnabled(.uac) ?? true
        if portsOn && !adbOn && uacSatisfied { return .standardEC25 }
        // Otherwise-standard with USB Audio explicitly off: the module
        // sound card is absent, so call audio would be silent.
        if portsOn && !adbOn { return .legacyUAC }
        return .unknown
    }

    /// Whether a freshly re-read composition after a reconnect should be
    /// surfaced as a "restore full mode?" suggestion. Derived exclusively
    /// from the fresh read — never from cached state — and only for the
    /// Mac-full preferred mode; a foreign identity is never a suggestion.
    static func shouldSuggestRestore(
        freshComposition: USBComposition?,
        usbVoiceOn: Bool?,
        preferredMode: ModuleConfigMode,
        suggestionEnabled: Bool
    ) -> Bool {
        guard suggestionEnabled, preferredMode == .macFull,
              let freshComposition, freshComposition.isQuectelIdentity else {
            return false
        }
        return !ModuleConfigPlanner.plan(
            mode: .macFull,
            composition: freshComposition,
            usbVoiceOn: usbVoiceOn
        ).isEmpty
    }
}

/// Builds the pending diff towards a target configuration, the rollback
/// command from a backup, and the verification criteria for both. The
/// Identity changes preserve the modem-reported interface field count and
/// every interface flag; mode and individual-interface plans retain their
/// existing safety boundaries. `usbnet` and IMS stay out because they are
/// user-adjustable runtime choices, not part of the USB composition.
enum ModuleConfigPlanner {
    /// Switches only the supported USB VID/PID pair. Preserving every reported
    /// interface flag makes the operation reversible without silently changing
    /// ADB, USB Audio, AT, GNSS, modem, or network behavior.
    static func identityPlan(
        composition: USBComposition?,
        target: ModuleUSBIdentity
    ) -> ModuleConfigPlan? {
        guard let composition, composition.identity?.switchTarget == target,
              composition.interfaces.count >= 5,
              let vendorID = composition.vendorID,
              let productID = composition.productID else { return nil }

        let changes = [
            ModuleConfigFieldChange(
                fieldKey: "moduleconfig.identity.vendor_id",
                from: hexID(vendorID, fallback: vendorID),
                to: hexID(target.vendorID, fallback: target.vendorID)
            ),
            ModuleConfigFieldChange(
                fieldKey: "moduleconfig.identity.product_id",
                from: hexID(productID, fallback: productID),
                to: hexID(target.productID, fallback: target.productID)
            ),
        ].filter { $0.from != $0.to }

        var arguments = [
            hexID(target.vendorID, fallback: target.vendorID),
            hexID(target.productID, fallback: target.productID),
        ]
        arguments.append(contentsOf: composition.interfaces.map { $0.enabled ? "1" : "0" })

        return ModuleConfigPlan(
            targetKey: target.localizationKey,
            changes: changes,
            commands: changes.isEmpty
                ? []
                : ["AT+QCFG=\"usbcfg\"," + arguments.joined(separator: ",")],
            verificationTarget: .identity(target)
        )
    }

    /// The pending plan for the user's preferred mode.
    static func plan(
        mode: ModuleConfigMode,
        composition: USBComposition?,
        usbVoiceOn: Bool? = nil,
        imsLTE: Int? = nil,
        volteDisabled: Int? = nil
    ) -> ModuleConfigPlan {
        switch mode {
        case .macFull: restoreStandardPlan(composition: composition, usbVoiceOn: usbVoiceOn)
        case .qdc507Voice:
            qdc507VoicePlan(
                composition: composition,
                imsLTE: imsLTE,
                volteDisabled: volteDisabled
            )
        case .mobile: mobileCompanionPlan(composition: composition)
        }
    }

    /// Enables only the two interfaces needed by the volatile QDC507 runtime.
    /// The target captures the complete expected composition so post-reboot
    /// verification rejects changes to VID/PID or any unrelated function bit.
    static func qdc507VoicePlan(
        composition: USBComposition?,
        imsLTE: Int? = nil,
        volteDisabled: Int? = nil
    ) -> ModuleConfigPlan {
        let empty = ModuleConfigPlan(
            targetKey: ModuleConfigMode.qdc507Voice.localizationKey,
            changes: [],
            commands: [],
            verificationTarget: .mode(.qdc507Voice)
        )
        guard let composition,
              composition.identity?.supportsPreset(.qdc507Voice) == true,
              composition.isEnabled(.atPort) == true,
              composition.isEnabled(.adb) != nil,
              composition.isEnabled(.uac) != nil,
              let vendorID = composition.vendorID,
              let productID = composition.productID else { return empty }

        var target = composition
        target.interfaces = composition.interfaces.map { interface in
            USBComposition.Interface(
                kind: interface.kind,
                enabled: interface.kind == .adb || interface.kind == .uac
                    ? true
                    : interface.enabled
            )
        }
        var changes = target.interfaces.compactMap { targetInterface -> ModuleConfigFieldChange? in
            guard composition.isEnabled(targetInterface.kind) != targetInterface.enabled else { return nil }
            return ModuleConfigFieldChange(
                fieldKey: targetInterface.kind.localizationKey,
                from: "0",
                to: "1"
            )
        }
        if imsLTE != 1 {
            changes.append(ModuleConfigFieldChange(
                fieldKey: "moduleconfig.field.ims",
                from: imsLTE.map(String.init) ?? "?",
                to: "1"
            ))
        }
        if volteDisabled != 0 {
            changes.append(ModuleConfigFieldChange(
                fieldKey: "moduleconfig.volte_disabled.label",
                from: volteDisabled.map(String.init) ?? "?",
                to: "0"
            ))
        }
        var arguments = [hexID(vendorID, fallback: vendorID), hexID(productID, fallback: productID)]
        arguments.append(contentsOf: target.interfaces.map { $0.enabled ? "1" : "0" })
        var commands: [String] = []
        if target.interfaces != composition.interfaces {
            commands.append("AT+QCFG=\"usbcfg\"," + arguments.joined(separator: ","))
        }
        if imsLTE != 1 { commands.append("AT+QCFG=\"ims\",1") }
        if volteDisabled != 0 { commands.append("AT+QCFG=\"volte_disable\",0") }
        return ModuleConfigPlan(
            targetKey: ModuleConfigMode.qdc507Voice.localizationKey,
            changes: changes,
            commands: commands,
            verificationTarget: .qdc507Runtime(
                composition: target,
                imsLTE: 1,
                volteDisabled: 0
            )
        )
    }

    /// Restores the standard EC25 composition this application expects:
    /// all serial/data ports on, ADB off, and USB Audio **on** — call audio
    /// depends on the module sound card, so an audio-off composition is a
    /// deviation this plan repairs. `QPCMV` is deliberately not persisted by
    /// this plan: it resets on module restart and the UAC-specific option 2
    /// must be negotiated immediately before each dial/answer. The usbcfg
    /// command mirrors the field count the firmware reported so
    /// older 7-field firmwares are not handed a 9-field write.
    static func restoreStandardPlan(composition: USBComposition?, usbVoiceOn: Bool? = nil) -> ModuleConfigPlan {
        // Identity changes are out of scope for the application; without a
        // Quectel identity there is nothing this plan may touch.
        guard let composition, composition.isQuectelIdentity else {
            return ModuleConfigPlan(
                targetKey: ModuleConfigProfile.standardEC25.localizationKey,
                changes: [],
                commands: [],
                verificationTarget: .mode(.macFull)
            )
        }

        var changes: [ModuleConfigFieldChange] = []
        // Interface flags: 1 for serial/data ports and USB Audio, 0 for adb.
        for kind in USBInterfaceKind.allCases {
            let wanted = kind == .adb ? "0" : "1"
            let current: String?
            if let value = composition.isEnabled(kind) {
                current = value ? "1" : "0"
            } else {
                // Not reported by this firmware: cannot flip an absent bit,
                // so leave it out of the plan.
                current = wanted
            }
            if let current, current != wanted {
                changes.append(ModuleConfigFieldChange(
                    fieldKey: "moduleconfig.interface.\(kind.rawValue)",
                    from: current,
                    to: wanted
                ))
            }
        }

        let hasADBField = composition.isEnabled(.adb) != nil
        let hasUACField = composition.isEnabled(.uac) != nil
        var arguments = [hexID(composition.vendorID, fallback: 0x2C7C), hexID(composition.productID, fallback: 0x0125), "1", "1", "1", "1", "1"]
        if hasADBField { arguments.append("0") }
        if hasUACField { arguments.append("1") }
        var commands: [String] = []
        if !changes.isEmpty {
            commands.append("AT+QCFG=\"usbcfg\"," + arguments.joined(separator: ","))
        }
        return ModuleConfigPlan(
            targetKey: ModuleConfigProfile.standardEC25.localizationKey,
            changes: changes,
            commands: commands,
            verificationTarget: .mode(.macFull)
        )
    }

    // MARK: - Internals

    /// The iPhone/iPad companion profile: only USB Audio is turned off.
    /// AT, USB data, and every other reported interface keep their current
    /// values verbatim. Firmware that does not report a UAC field has
    /// nothing this plan may change.
    private static func mobileCompanionPlan(composition: USBComposition?) -> ModuleConfigPlan {
        let empty = ModuleConfigPlan(
            targetKey: ModuleConfigMode.mobile.localizationKey,
            changes: [],
            commands: [],
            verificationTarget: .mode(.mobile)
        )
        // Identity changes are out of scope for the application; without a
        // Quectel identity there is nothing this plan may touch.
        guard let composition, composition.isQuectelIdentity else { return empty }
        guard composition.isEnabled(.uac) == true else { return empty }

        var arguments = [hexID(composition.vendorID, fallback: 0x2C7C), hexID(composition.productID, fallback: 0x0125)]
        for kind in USBInterfaceKind.allCases {
            guard let enabled = composition.isEnabled(kind) else { continue }
            let target = kind == .uac ? false : enabled
            arguments.append(target ? "1" : "0")
        }
        let command = "AT+QCFG=\"usbcfg\"," + arguments.joined(separator: ",")
        return ModuleConfigPlan(
            targetKey: ModuleConfigMode.mobile.localizationKey,
            changes: [
                ModuleConfigFieldChange(
                    fieldKey: "moduleconfig.interface.uac",
                    from: "1",
                    to: "0"
                )
            ],
            commands: [command],
            verificationTarget: .mode(.mobile)
        )
    }

    /// Builds an exact one-interface composition change while preserving the
    /// module-reported VID/PID, field count, and every other flag verbatim.
    /// The AT port cannot be disabled from the app because doing so would
    /// remove the management channel required to verify or roll back.
    static func interfacePlan(
        composition: USBComposition?,
        kind: USBInterfaceKind,
        enabled: Bool
    ) -> ModuleConfigPlan? {
        guard let composition,
              composition.isQuectelIdentity,
              let current = composition.isEnabled(kind),
              current != enabled,
              kind != .atPort || enabled else { return nil }

        var arguments = [
            hexID(composition.vendorID, fallback: 0x2C7C),
            hexID(composition.productID, fallback: 0x0125),
        ]
        for interface in composition.interfaces {
            arguments.append(interface.kind == kind
                ? (enabled ? "1" : "0")
                : (interface.enabled ? "1" : "0"))
        }
        return ModuleConfigPlan(
            targetKey: kind.localizationKey,
            changes: [ModuleConfigFieldChange(
                fieldKey: kind.localizationKey,
                from: current ? "1" : "0",
                to: enabled ? "1" : "0"
            )],
            commands: ["AT+QCFG=\"usbcfg\"," + arguments.joined(separator: ",")],
            verificationTarget: .interface(kind, enabled)
        )
    }

    private static func hexID(_ value: Int?, fallback: Int) -> String {
        let number = value ?? fallback
        return "0x" + String(number, radix: 16, uppercase: true)
    }

    /// Rebuilds the write command that re-applies the composition a backup
    /// recorded, replaying the firmware's own response values verbatim
    /// (identity and field count included).
    static func restoreCommand(from backup: ModuleConfigBackup) -> String? {
        guard let query = backup.queries.first(where: {
            $0.command == "AT+QCFG=\"usbcfg\"" && $0.ok
        }), let line = query.responseLines.first(where: {
            $0.hasPrefix("+QCFG: \"usbcfg\"")
        }) else {
            return nil
        }
        let parts = line.split(separator: ",")
        guard parts.count >= 2 else { return nil }
        let values = parts.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        return "AT+QCFG=\"usbcfg\"," + values.joined(separator: ",")
    }

    /// Schema-v3 restore set. USB is always restored when available; voice
    /// values are restored only for a v3 backup that successfully recorded
    /// them. Older records therefore retain their historical USB-only scope.
    static func restoreCommands(from backup: ModuleConfigBackup) -> [String] {
        var commands: [String] = []
        if let usb = restoreCommand(from: backup) {
            commands.append(usb)
        }
        guard backup.schemaVersion >= 3 else { return commands }
        if let ims = recordedQCFGInteger("ims", backup: backup) {
            commands.append("AT+QCFG=\"ims\",\(ims)")
        }
        if let volteDisabled = recordedQCFGInteger("volte_disable", backup: backup) {
            commands.append("AT+QCFG=\"volte_disable\",\(volteDisabled)")
        }
        return commands
    }

    /// True when the freshly read composition matches what the backup
    /// recorded — the success criterion for an automatic restore.
    static func matchesBackupComposition(_ current: USBComposition?, backup: ModuleConfigBackup) -> Bool {
        guard let current,
              let query = backup.queries.first(where: { $0.command == "AT+QCFG=\"usbcfg\"" && $0.ok })
        else { return false }
        return current == QCFGParser.parseUSBCfg(query.responseLines)
    }

    static func matchesBackupConfiguration(
        composition current: USBComposition?,
        imsLTE: Int?,
        volteDisabled: Int?,
        backup: ModuleConfigBackup
    ) -> Bool {
        guard matchesBackupComposition(current, backup: backup) else { return false }
        guard backup.schemaVersion >= 3 else { return true }
        if let expectedIMS = recordedQCFGInteger("ims", backup: backup), imsLTE != expectedIMS {
            return false
        }
        if let expectedVoLTEDisabled = recordedQCFGInteger("volte_disable", backup: backup),
           volteDisabled != expectedVoLTEDisabled {
            return false
        }
        return true
    }

    private static func recordedQCFGInteger(
        _ key: String,
        backup: ModuleConfigBackup
    ) -> Int? {
        let command = "AT+QCFG=\"\(key)\""
        guard let query = backup.queries.first(where: { $0.command == command && $0.ok }) else {
            return nil
        }
        switch key {
        case "ims": return QCFGParser.parseIMS(query.responseLines)
        case "volte_disable": return QCFGParser.parseVoLTEDisabled(query.responseLines)
        default: return nil
        }
    }

    /// True when the freshly read composition already satisfies the
    /// restore-standard target — the success criterion for an apply. This is
    /// the profile classifier, not plan emptiness: a foreign identity also
    /// yields an empty plan but is never the standard target.
    static func reachedStandardTarget(_ current: USBComposition?) -> Bool {
        ModuleConfigDecision.profile(composition: current) == .standardEC25
    }

    /// True when the freshly read composition already satisfies the
    /// selected mode's target — the success criterion for any apply. The
    /// Mac-full covers persistent USB composition only; transient QPCMV
    /// forwarding is prepared per call. The mobile target is met whenever
    /// USB Audio is off (or not reported); a foreign identity never satisfies
    /// any target.
    static func reachedTarget(
        _ current: USBComposition?,
        mode: ModuleConfigMode,
        usbVoiceOn: Bool? = nil
    ) -> Bool {
        switch mode {
        case .macFull:
            return reachedStandardTarget(current)
        case .qdc507Voice:
            guard let current, current.identity?.supportsPreset(.qdc507Voice) == true else {
                return false
            }
            return current.isEnabled(.atPort) == true
                && current.isEnabled(.adb) == true
                && current.isEnabled(.uac) == true
        case .mobile:
            guard let current, current.isQuectelIdentity else { return false }
            return current.isEnabled(.uac) != true
        }
    }

    static func reachedTarget(
        composition: USBComposition?,
        usbVoiceOn: Bool?,
        imsLTE: Int? = nil,
        volteDisabled: Int? = nil,
        target: ModuleConfigVerificationTarget
    ) -> Bool {
        switch target {
        case let .mode(mode):
            reachedTarget(composition, mode: mode, usbVoiceOn: usbVoiceOn)
        case let .interface(kind, enabled):
            composition?.isEnabled(kind) == enabled
        case let .identity(identity):
            composition?.identity == identity
        case let .composition(expected):
            composition == expected
        case let .qdc507Runtime(expected, expectedIMS, expectedVoLTEDisabled):
            expected.identity?.supportsPreset(.qdc507Voice) == true
                && composition == expected
                && imsLTE == expectedIMS
                && volteDisabled == expectedVoLTEDisabled
        }
    }
}

/// Failures of the apply/restore pipeline that need their own user-facing
/// explanation beyond the raw transport error.
enum ModuleConfigApplyError: Error, Equatable {
    case unsupportedConfiguration
    /// The module never re-enumerated its AT port after CFUN=1,1.
    case moduleDidNotReturn
    /// The post-restore composition differs from the backup.
    case restoreMismatch
    /// The backup holds no parseable usbcfg reply to replay.
    case noRestoreCommand
}
