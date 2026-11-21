@testable import EC25Toolbox
import XCTest

final class ModuleConfigModelsTests: XCTestCase {
    // MARK: - QCFG parsing

    func testParseUSBCfgFullNineFieldHexVector() {
        // Grounded in the Quectel QCFG manual + forum outputs: VID, PID,
        // diag, nmea, at_port, modem, rmnet, adb, uac.
        let lines = ["+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,0,0"]
        let composition = QCFGParser.parseUSBCfg(lines)
        XCTAssertNotNil(composition)
        XCTAssertEqual(composition?.vendorID, 0x2C7C)
        XCTAssertEqual(composition?.productID, 0x0125)
        XCTAssertTrue(composition?.isQuectelIdentity ?? false)
        XCTAssertEqual(composition?.interfaces.map(\.kind), USBInterfaceKind.allCases)
        XCTAssertEqual(composition?.isEnabled(.diag), true)
        XCTAssertEqual(composition?.isEnabled(.nmea), true)
        XCTAssertEqual(composition?.isEnabled(.atPort), true)
        XCTAssertEqual(composition?.isEnabled(.modem), true)
        XCTAssertEqual(composition?.isEnabled(.rmnet), true)
        XCTAssertEqual(composition?.isEnabled(.adb), false)
        XCTAssertEqual(composition?.isEnabled(.uac), false)
    }

    func testParseUSBCfgDecimalIdentityAndSevenFields() {
        // The manual's write example uses decimal 11388/293; older firmware
        // stops after rmnet (no adb/uac).
        let lines = ["+QCFG: \"usbcfg\",11388,293,1,1,1,1,1"]
        let composition = QCFGParser.parseUSBCfg(lines)
        XCTAssertEqual(composition?.vendorID, 0x2C7C)
        XCTAssertEqual(composition?.productID, 0x0125)
        XCTAssertNil(composition?.isEnabled(.adb))
        XCTAssertNil(composition?.isEnabled(.uac))
    }

    func testParseUSBCfgRejectsGarbage() {
        XCTAssertNil(QCFGParser.parseUSBCfg(["OK"]))
        XCTAssertNil(QCFGParser.parseUSBCfg([]))
        XCTAssertNil(QCFGParser.parseUSBCfg(["+QCFG: \"usbnet\",1"]))
        // Unparseable VID is a failed parse, not a foreign identity.
        XCTAssertNil(QCFGParser.parseUSBCfg(["+QCFG: \"usbcfg\",garbage,0x0125,1,1,1,1,1,0,0"]))
    }

    func testParseUSBNetIMSAndVoice() {
        XCTAssertEqual(QCFGParser.parseUSBNet(["+QCFG: \"usbnet\",1"]), 1)
        XCTAssertEqual(QCFGParser.parseIMS(["+QCFG: \"ims\",1,1"]), 1)
        XCTAssertEqual(QCFGParser.parseIMS(["+QCFG: \"ims\",2"]), 2)
        XCTAssertNil(QCFGParser.parseIMS(["+QCFG: \"usbnet\",0"]))
        XCTAssertEqual(QCFGParser.parseUSBVoice(["+QPCMV: 1"]), true)
        XCTAssertEqual(QCFGParser.parseUSBVoice(["+QPCMV: 1,2"]), true)
        XCTAssertEqual(QCFGParser.parseUSBVoice(["+QPCMV: 0,2"]), false)
        XCTAssertEqual(QCFGParser.parseUSBVoice(["+QPCMV: 0"]), false)
        XCTAssertNil(QCFGParser.parseUSBVoice(["OK"]))
    }

    // MARK: - Profile classification

    private func composition(
        vendorID: Int? = 0x2C7C,
        productID: Int? = nil,
        diag: Int = 1,
        nmea: Int = 1,
        atPort: Int = 1,
        modem: Int = 1,
        rmnet: Int = 1,
        adb: Int = 0,
        uac: Int? = nil
    ) -> USBComposition {
        var values = [diag, nmea, atPort, modem, rmnet, adb]
        if let uac { values.append(uac) }
        return USBComposition(
            vendorID: vendorID,
            productID: productID ?? (vendorID == 0x2CA3 ? 0x4006 : 0x0125),
            interfaces: zip(USBInterfaceKind.allCases, values).map { kind, value in
                USBComposition.Interface(kind: kind, enabled: value != 0)
            }
        )
    }

    func testProfileMatrix() {
        XCTAssertEqual(ModuleConfigDecision.profile(composition: nil), .unknown)
        XCTAssertEqual(ModuleConfigDecision.profile(composition: composition()), .standardEC25)
        // USB Audio on is part of the Mac full target (call audio needs the
        // module sound card).
        XCTAssertEqual(
            ModuleConfigDecision.profile(composition: composition(uac: 1)),
            .standardEC25
        )
        // USB Audio explicitly off while otherwise standard: the module
        // sound card is absent and call audio would be silent.
        XCTAssertEqual(
            ModuleConfigDecision.profile(composition: composition(uac: 0)),
            .legacyUAC
        )
        // Non-Quectel VID: the original DJI (or other) identity.
        XCTAssertEqual(
            ModuleConfigDecision.profile(composition: composition(vendorID: 0x2CA3)),
            .rawDJI
        )
        // Without an AT port the app cannot operate the module.
        XCTAssertEqual(ModuleConfigDecision.profile(composition: composition(atPort: 0)), .unknown)
        // ADB on keeps a Quectel identity but is not the standard set.
        XCTAssertEqual(ModuleConfigDecision.profile(composition: composition(adb: 1)), .unknown)
    }

    // MARK: - Restore-standard plan

    func testPlanAlreadyStandardIsEmpty() {
        // UAC reported on: persistent composition needs no change.
        let plan = ModuleConfigPlanner.restoreStandardPlan(
            composition: composition(uac: 1), usbVoiceOn: true
        )
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.commands.isEmpty)
        XCTAssertEqual(plan.targetKey, ModuleConfigProfile.standardEC25.localizationKey)
        // Firmware without a UAC field and an unreadable voice path is
        // also compliant — the app never flips unreported values.
        XCTAssertTrue(ModuleConfigPlanner.restoreStandardPlan(
            composition: composition(), usbVoiceOn: nil
        ).isEmpty)
    }

    func testPlanProposesADBOffAndUACOnWithCurrentIdentity() {
        let plan = ModuleConfigPlanner.restoreStandardPlan(composition: composition(adb: 1, uac: 0))
        let fields = plan.changes.map(\.fieldKey)
        XCTAssertEqual(fields, ["moduleconfig.interface.adb", "moduleconfig.interface.uac"])
        XCTAssertEqual(plan.changes[0].from, "1")
        XCTAssertEqual(plan.changes[0].to, "0")
        XCTAssertEqual(plan.changes[1].from, "0")
        XCTAssertEqual(plan.changes[1].to, "1")
        XCTAssertEqual(
            plan.commands,
            ["AT+QCFG=\"usbcfg\",0x2C7C,0x125,1,1,1,1,1,0,1"]
        )
    }

    func testPlanLeavesTransientUSBVoiceStateForPerCallPreparation() {
        // QPCMV is transient and option 2 is UAC-specific. The persistent
        // composition plan must not write the ambiguous one-argument form.
        let plan = ModuleConfigPlanner.restoreStandardPlan(
            composition: composition(uac: 1), usbVoiceOn: false
        )
        XCTAssertTrue(plan.changes.isEmpty)
        XCTAssertTrue(plan.commands.isEmpty)
        // A persistent interface repair remains independent of QPCMV state.
        let combined = ModuleConfigPlanner.restoreStandardPlan(
            composition: composition(adb: 1, uac: 0), usbVoiceOn: false
        )
        XCTAssertEqual(combined.commands, [
            "AT+QCFG=\"usbcfg\",0x2C7C,0x125,1,1,1,1,1,0,1"
        ])
    }

    func testPlanMirrorsReportedFieldCount() {
        // Firmware without the UAC field gets an 8-argument command and no
        // UAC change; the application cannot flip an absent bit.
        let plan = ModuleConfigPlanner.restoreStandardPlan(composition: composition(diag: 0))
        XCTAssertEqual(plan.changes.map(\.fieldKey), ["moduleconfig.interface.diag"])
        XCTAssertEqual(plan.commands, ["AT+QCFG=\"usbcfg\",0x2C7C,0x125,1,1,1,1,1,0"])
    }

    func testPlanNeverTouchesForeignIdentity() {
        let plan = ModuleConfigPlanner.restoreStandardPlan(composition: composition(vendorID: 0x2CA3, adb: 1))
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.commands.isEmpty)
    }

    func testSupportedUSBIdentityRecognitionAndReversiblePlans() {
        let original = composition(vendorID: 0x2CA3, adb: 0, uac: 0)
        XCTAssertEqual(original.identity, .djiOriginal)
        XCTAssertEqual(ModuleUSBIdentity.ec25.displayValue, "2C7C:0125")
        XCTAssertEqual(ModuleUSBIdentity.djiOriginal.displayValue, "2CA3:4006")

        let toEC25 = ModuleConfigPlanner.identityPlan(
            composition: original,
            target: .ec25
        )
        XCTAssertEqual(toEC25?.changes.map(\.fieldKey), [
            "moduleconfig.identity.vendor_id",
            "moduleconfig.identity.product_id",
        ])
        XCTAssertEqual(
            toEC25?.commands,
            ["AT+QCFG=\"usbcfg\",0x2C7C,0x125,1,1,1,1,1,0,0"]
        )
        XCTAssertEqual(toEC25?.verificationTarget, .identity(.ec25))

        let compatible = composition(adb: 0, uac: 1)
        let toDJI = ModuleConfigPlanner.identityPlan(
            composition: compatible,
            target: .djiOriginal
        )
        XCTAssertEqual(
            toDJI?.commands,
            ["AT+QCFG=\"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0,1"]
        )
        XCTAssertEqual(toDJI?.verificationTarget, .identity(.djiOriginal))
    }

    func testEC21IsRecognizedWithoutEnablingConfigurationWrites() throws {
        let ec21 = try XCTUnwrap(QCFGParser.parseUSBCfg([
            #"+QCFG: "usbcfg",0x2C7C,0x0121,1,1,1,1,1,0,0"#
        ]))
        XCTAssertEqual(ec21.identity, .ec21)
        XCTAssertEqual(ModuleUSBIdentity.ec21.displayValue, "2C7C:0121")
        XCTAssertTrue(ModuleUSBIdentity.connectionOrder.contains(.ec21))
        XCTAssertNil(ec21.identity?.switchTarget)

        for mode in ModuleConfigMode.allCases {
            XCTAssertEqual(ec21.identity?.supportsPreset(mode), false)
            XCTAssertTrue(ModuleConfigPlanner.plan(
                mode: mode, composition: ec21, imsLTE: 0, volteDisabled: 1
            ).commands.isEmpty)
            XCTAssertFalse(ModuleConfigPlanner.reachedTarget(ec21, mode: mode))
        }

        XCTAssertNil(ModuleConfigPlanner.identityPlan(composition: ec21, target: .ec25))
        XCTAssertNil(ModuleConfigPlanner.identityPlan(composition: composition(), target: .ec21))
        XCTAssertNil(ModuleConfigPlanner.interfacePlan(composition: ec21, kind: .uac, enabled: true))

        let qdc507 = ModuleConfigPlanner.qdc507VoicePlan(
            composition: composition(vendorID: 0x2CA3, adb: 0, uac: 0)
        )
        XCTAssertFalse(qdc507.isEmpty)
        XCTAssertTrue(qdc507.verificationTarget.canApply(to: .djiOriginal))
        XCTAssertFalse(qdc507.verificationTarget.canApply(to: .ec21))
    }

    func testIdentityVerificationRequiresExactVendorAndProductPair() {
        XCTAssertTrue(ModuleConfigPlanner.reachedTarget(
            composition: composition(vendorID: 0x2CA3, productID: 0x4006),
            usbVoiceOn: nil,
            target: .identity(.djiOriginal)
        ))
        XCTAssertFalse(ModuleConfigPlanner.reachedTarget(
            composition: composition(vendorID: 0x2CA3, productID: 0x0125),
            usbVoiceOn: nil,
            target: .identity(.djiOriginal)
        ))
    }

    func testIdentityPlanRejectsIncompleteInterfaceVector() {
        let incomplete = USBComposition(
            vendorID: 0x2CA3,
            productID: 0x4006,
            interfaces: [
                USBComposition.Interface(kind: .diag, enabled: true),
                USBComposition.Interface(kind: .nmea, enabled: true),
            ]
        )

        XCTAssertNil(ModuleConfigPlanner.identityPlan(
            composition: incomplete,
            target: .ec25
        ))
    }

    // MARK: - Restore command and verification criteria (P5-B)

    private func backup(usbcfgLine: String?, ok: Bool = true) -> ModuleConfigBackup {
        ModuleConfigBackup(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            imei: nil,
            model: nil,
            revision: nil,
            usbDescription: nil,
            profile: .unknown,
            queries: [
                ModuleConfigQuery(
                    command: "AT+QCFG=\"usbcfg\"",
                    responseLines: usbcfgLine.map { [$0] } ?? [],
                    ok: ok
                )
            ]
        )
    }

    func testRestoreCommandReplaysBackupValuesVerbatim() {
        // The rollback command re-applies exactly what the firmware itself
        // reported — identity, radix, and field count included.
        XCTAssertEqual(
            ModuleConfigPlanner.restoreCommand(
                from: backup(usbcfgLine: "+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,0,0")
            ),
            "AT+QCFG=\"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,0,0"
        )
        XCTAssertEqual(
            ModuleConfigPlanner.restoreCommand(
                from: backup(usbcfgLine: "+QCFG: \"usbcfg\",11388,293,1,1,1,1,1")
            ),
            "AT+QCFG=\"usbcfg\",11388,293,1,1,1,1,1"
        )
    }

    func testRestoreCommandTrimsRecordedWhitespace() {
        XCTAssertEqual(
            ModuleConfigPlanner.restoreCommand(
                from: backup(usbcfgLine: "+QCFG: \"usbcfg\", 0x2C7C, 0x0125, 1, 1, 1, 1, 1, 0, 0")
            ),
            "AT+QCFG=\"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,0,0"
        )
    }

    func testRestoreCommandNilWithoutUsableUsbcfgReply() {
        XCTAssertNil(ModuleConfigPlanner.restoreCommand(from: backup(usbcfgLine: nil)))
        XCTAssertNil(ModuleConfigPlanner.restoreCommand(from: backup(usbcfgLine: nil, ok: false)))
        // A line without any value fields carries nothing to replay.
        XCTAssertNil(ModuleConfigPlanner.restoreCommand(from: backup(usbcfgLine: "+QCFG: \"usbcfg\"")))
    }

    func testMatchesBackupComposition() {
        let recorded = backup(usbcfgLine: "+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,0,0")
        XCTAssertTrue(ModuleConfigPlanner.matchesBackupComposition(
            QCFGParser.parseUSBCfg(["+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,0,0"]),
            backup: recorded
        ))
        // One flipped interface flag (adb) is a mismatch.
        XCTAssertFalse(ModuleConfigPlanner.matchesBackupComposition(
            QCFGParser.parseUSBCfg(["+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,1,0"]),
            backup: recorded
        ))
        XCTAssertFalse(ModuleConfigPlanner.matchesBackupComposition(nil, backup: recorded))
    }

    func testSchemaV3RestoreIncludesRecordedVoiceConfiguration() {
        let recorded = ModuleConfigBackup(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            imei: "860000000000000",
            model: "EC25",
            revision: nil,
            usbDescription: nil,
            profile: .legacyUAC,
            queries: [
                ModuleConfigQuery(
                    command: "AT+QCFG=\"usbcfg\"",
                    responseLines: ["+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,0,1"],
                    ok: true
                ),
                ModuleConfigQuery(
                    command: "AT+QCFG=\"ims\"",
                    responseLines: ["+QCFG: \"ims\",1,2"],
                    ok: true
                ),
                ModuleConfigQuery(
                    command: "AT+QCFG=\"volte_disable\"",
                    responseLines: ["+QCFG: \"volte_disable\",0"],
                    ok: true
                ),
            ]
        )

        XCTAssertEqual(ModuleConfigPlanner.restoreCommands(from: recorded), [
            "AT+QCFG=\"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,0,1",
            "AT+QCFG=\"ims\",1",
            "AT+QCFG=\"volte_disable\",0",
        ])
        let current = QCFGParser.parseUSBCfg(recorded.queries[0].responseLines)
        XCTAssertTrue(ModuleConfigPlanner.matchesBackupConfiguration(
            composition: current,
            imsLTE: 1,
            volteDisabled: 0,
            backup: recorded
        ))
        XCTAssertFalse(ModuleConfigPlanner.matchesBackupConfiguration(
            composition: current,
            imsLTE: 0,
            volteDisabled: 0,
            backup: recorded
        ))
    }

    func testLegacyBackupWithoutSchemaDecodesAsUSBOnlyRestore() throws {
        let json = #"{"createdAt":"2027-01-15T08:00:00Z","imei":null,"model":"EC25","revision":null,"usbDescription":null,"profile":"legacyUAC","queries":[{"command":"AT+QCFG=\"usbcfg\"","responseLines":["+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,0,1"],"ok":true},{"command":"AT+QCFG=\"ims\"","responseLines":["+QCFG: \"ims\",2,1"],"ok":true}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let recorded = try decoder.decode(ModuleConfigBackup.self, from: Data(json.utf8))

        XCTAssertEqual(recorded.schemaVersion, 2)
        XCTAssertEqual(ModuleConfigPlanner.restoreCommands(from: recorded), [
            "AT+QCFG=\"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,0,1",
        ])
        XCTAssertTrue(ModuleConfigPlanner.matchesBackupConfiguration(
            composition: QCFGParser.parseUSBCfg(recorded.queries[0].responseLines),
            imsLTE: 0,
            volteDisabled: 1,
            backup: recorded
        ))
    }

    func testReachedStandardTarget() {
        // Standard ports with USB Audio on: the Mac full target.
        XCTAssertTrue(ModuleConfigPlanner.reachedStandardTarget(
            QCFGParser.parseUSBCfg(["+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,0,1"])
        ))
        // USB Audio explicitly off deviates: call audio would be silent.
        XCTAssertFalse(ModuleConfigPlanner.reachedStandardTarget(
            QCFGParser.parseUSBCfg(["+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,0,0"])
        ))
        // Firmware without a UAC field cannot flip it; still the target.
        XCTAssertTrue(ModuleConfigPlanner.reachedStandardTarget(
            QCFGParser.parseUSBCfg(["+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1"])
        ))
        XCTAssertFalse(ModuleConfigPlanner.reachedStandardTarget(
            QCFGParser.parseUSBCfg(["+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,1,1"])
        ))
        XCTAssertFalse(ModuleConfigPlanner.reachedStandardTarget(nil))
        // A foreign identity also yields an empty plan, but it is never the
        // standard target — a reboot that loses the Quectel identity must
        // not count as a verified apply.
        XCTAssertFalse(ModuleConfigPlanner.reachedStandardTarget(
            QCFGParser.parseUSBCfg(["+QCFG: \"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0,0"])
        ))
    }

    // MARK: - Mode plans and reconnect suggestion (P5-C)

    func testMobileModePlanOnlyDisablesUAC() {
        // Even with ADB on, the mobile profile only touches USB Audio and
        // keeps every other reported value verbatim.
        let plan = ModuleConfigPlanner.plan(mode: .mobile, composition: composition(adb: 1, uac: 1))
        XCTAssertEqual(plan.changes.map(\.fieldKey), ["moduleconfig.interface.uac"])
        XCTAssertEqual(plan.changes.first?.from, "1")
        XCTAssertEqual(plan.changes.first?.to, "0")
        XCTAssertEqual(
            plan.commands,
            ["AT+QCFG=\"usbcfg\",0x2C7C,0x125,1,1,1,1,1,1,0"]
        )
    }

    func testMobileModePlanEmptyWhenUACOffUnreportedOrForeign() {
        XCTAssertTrue(ModuleConfigPlanner.plan(mode: .mobile, composition: composition(uac: 0)).isEmpty)
        // Firmware without a UAC field has nothing the plan may flip.
        XCTAssertTrue(ModuleConfigPlanner.plan(mode: .mobile, composition: composition()).isEmpty)
        XCTAssertTrue(ModuleConfigPlanner.plan(mode: .mobile, composition: composition(vendorID: 0x2CA3, uac: 1)).isEmpty)
        XCTAssertTrue(ModuleConfigPlanner.plan(mode: .mobile, composition: nil).isEmpty)
    }

    func testMacFullModePlanMatchesRestoreStandardPlan() {
        let current = composition(adb: 1, uac: 1)
        XCTAssertEqual(
            ModuleConfigPlanner.plan(mode: .macFull, composition: current, usbVoiceOn: false),
            ModuleConfigPlanner.restoreStandardPlan(composition: current, usbVoiceOn: false)
        )
    }

    func testInterfacePlanPreservesEveryOtherReportedFlag() {
        let current = composition(diag: 1, nmea: 0, atPort: 1, modem: 1, rmnet: 0, adb: 1, uac: 0)
        let plan = ModuleConfigPlanner.interfacePlan(
            composition: current,
            kind: .nmea,
            enabled: true
        )
        XCTAssertEqual(plan?.changes.map(\.fieldKey), ["moduleconfig.interface.nmea"])
        XCTAssertEqual(
            plan?.commands,
            ["AT+QCFG=\"usbcfg\",0x2C7C,0x125,1,1,1,1,0,1,0"]
        )
        XCTAssertEqual(plan?.verificationTarget, .interface(.nmea, true))
    }

    func testInterfacePlanCannotDisableManagementPort() {
        XCTAssertNil(ModuleConfigPlanner.interfacePlan(
            composition: composition(),
            kind: .atPort,
            enabled: false
        ))
    }

    func testExactInterfaceVerificationIgnoresUnrelatedFlags() {
        let target = ModuleConfigVerificationTarget.interface(.nmea, true)
        XCTAssertTrue(ModuleConfigPlanner.reachedTarget(
            composition: composition(nmea: 1, adb: 1),
            usbVoiceOn: false,
            target: target
        ))
        XCTAssertFalse(ModuleConfigPlanner.reachedTarget(
            composition: composition(nmea: 0),
            usbVoiceOn: true,
            target: target
        ))
    }

    func testReachedTargetPerMode() {
        // Mac full covers persistent USB composition. Transient QPCMV state
        // is prepared and verified immediately before each call.
        XCTAssertTrue(ModuleConfigPlanner.reachedTarget(composition(uac: 1), mode: .macFull, usbVoiceOn: true))
        XCTAssertTrue(ModuleConfigPlanner.reachedTarget(composition(), mode: .macFull, usbVoiceOn: nil))
        XCTAssertFalse(ModuleConfigPlanner.reachedTarget(composition(uac: 0), mode: .macFull, usbVoiceOn: true))
        XCTAssertTrue(ModuleConfigPlanner.reachedTarget(composition(uac: 1), mode: .macFull, usbVoiceOn: false))
        // Mobile target: USB Audio off (or unreported) on a Quectel identity.
        XCTAssertTrue(ModuleConfigPlanner.reachedTarget(composition(uac: 0), mode: .mobile))
        XCTAssertTrue(ModuleConfigPlanner.reachedTarget(composition(), mode: .mobile))
        XCTAssertFalse(ModuleConfigPlanner.reachedTarget(composition(uac: 1), mode: .mobile))
        XCTAssertFalse(ModuleConfigPlanner.reachedTarget(composition(vendorID: 0x2CA3, uac: 0), mode: .mobile))
        XCTAssertFalse(ModuleConfigPlanner.reachedTarget(nil, mode: .mobile))
    }

    func testQDC507VoicePlanPreservesIdentityAndUnrelatedFunctions() {
        let current = composition(
            vendorID: 0x2CA3,
            diag: 0,
            nmea: 1,
            atPort: 1,
            modem: 0,
            rmnet: 1,
            adb: 0,
            uac: 0
        )
        let plan = ModuleConfigPlanner.qdc507VoicePlan(
            composition: current,
            imsLTE: 1,
            volteDisabled: 0
        )
        XCTAssertEqual(plan.changes.map(\.fieldKey), [
            USBInterfaceKind.adb.localizationKey,
            USBInterfaceKind.uac.localizationKey,
        ])
        XCTAssertEqual(
            plan.commands,
            ["AT+QCFG=\"usbcfg\",0x2CA3,0x4006,0,1,1,0,1,1,1"]
        )
        guard case let .qdc507Runtime(target, ims, volteDisabled) = plan.verificationTarget else {
            return XCTFail("expected exact QDC507 runtime verification")
        }
        XCTAssertEqual(ims, 1)
        XCTAssertEqual(volteDisabled, 0)
        XCTAssertEqual(target.vendorID, current.vendorID)
        XCTAssertEqual(target.productID, current.productID)
        XCTAssertEqual(target.isEnabled(.diag), false)
        XCTAssertEqual(target.isEnabled(.modem), false)
        XCTAssertEqual(target.isEnabled(.adb), true)
        XCTAssertEqual(target.isEnabled(.uac), true)
        XCTAssertTrue(ModuleConfigPlanner.reachedTarget(
            composition: target,
            usbVoiceOn: nil,
            imsLTE: 1,
            volteDisabled: 0,
            target: plan.verificationTarget
        ))
        XCTAssertFalse(ModuleConfigPlanner.reachedTarget(
            composition: composition(vendorID: 0x2CA3, adb: 1, uac: 1),
            usbVoiceOn: nil,
            imsLTE: 1,
            volteDisabled: 0,
            target: plan.verificationTarget
        ))
    }

    func testQDC507VoicePlanAlsoEnablesIMSAndVoLTE() {
        let current = composition(adb: 1, uac: 1)
        let plan = ModuleConfigPlanner.qdc507VoicePlan(
            composition: current,
            imsLTE: 0,
            volteDisabled: 1
        )
        XCTAssertEqual(plan.commands, [
            "AT+QCFG=\"ims\",1",
            "AT+QCFG=\"volte_disable\",0",
        ])
        XCTAssertTrue(ModuleConfigPlanner.reachedTarget(
            composition: current,
            usbVoiceOn: nil,
            imsLTE: 1,
            volteDisabled: 0,
            target: plan.verificationTarget
        ))
        XCTAssertFalse(ModuleConfigPlanner.reachedTarget(
            composition: current,
            usbVoiceOn: nil,
            imsLTE: 1,
            volteDisabled: 1,
            target: plan.verificationTarget
        ))
    }

    func testShouldSuggestRestore() {
        let deviating = composition(adb: 1, uac: 1)
        XCTAssertTrue(ModuleConfigDecision.shouldSuggestRestore(
            freshComposition: deviating, usbVoiceOn: nil, preferredMode: .macFull, suggestionEnabled: true
        ))
        XCTAssertFalse(ModuleConfigDecision.shouldSuggestRestore(
            freshComposition: deviating, usbVoiceOn: nil, preferredMode: .macFull, suggestionEnabled: false
        ))
        XCTAssertFalse(ModuleConfigDecision.shouldSuggestRestore(
            freshComposition: deviating, usbVoiceOn: nil, preferredMode: .mobile, suggestionEnabled: true
        ))
        // Compliant composition: transient QPCMV state is irrelevant here.
        XCTAssertFalse(ModuleConfigDecision.shouldSuggestRestore(
            freshComposition: composition(uac: 1), usbVoiceOn: true, preferredMode: .macFull, suggestionEnabled: true
        ))
        // Voice-off alone is transient call state, not persistent drift.
        XCTAssertFalse(ModuleConfigDecision.shouldSuggestRestore(
            freshComposition: composition(uac: 1), usbVoiceOn: false, preferredMode: .macFull, suggestionEnabled: true
        ))
        XCTAssertFalse(ModuleConfigDecision.shouldSuggestRestore(
            freshComposition: nil, usbVoiceOn: nil, preferredMode: .macFull, suggestionEnabled: true
        ))
        // Foreign identity is never a restore suggestion.
        XCTAssertFalse(ModuleConfigDecision.shouldSuggestRestore(
            freshComposition: composition(vendorID: 0x2CA3, adb: 1), usbVoiceOn: nil, preferredMode: .macFull, suggestionEnabled: true
        ))
    }

    // MARK: - Backup round trip and archive

    func testBackupCodableRoundTrip() throws {
        let backup = ModuleConfigBackup(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            imei: "860000000000000",
            model: "EC25",
            revision: "EC25AFAR08A03M4G",
            usbDescription: "USB 2c7c:0125",
            profile: .legacyUAC,
            queries: [
                ModuleConfigQuery(command: "AT+QCFG=\"usbcfg\"", responseLines: ["+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,0,1"], ok: true),
                ModuleConfigQuery(command: "AT+QCFG=\"ims\"", responseLines: [], ok: false)
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ModuleConfigBackup.self, from: encoder.encode(backup))
        XCTAssertEqual(decoded, backup)
    }

    func testBackupArchiveRecordsCapsAndSurvivesCorruption() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moduleconfig-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ModuleConfigBackupStore(fileURL: url)

        XCTAssertTrue(store.records().isEmpty)
        XCTAssertNil(store.lastBackup())

        func makeBackup(_ index: Int) -> ModuleConfigBackup {
            ModuleConfigBackup(
                createdAt: Date(timeIntervalSince1970: Double(1_800_000_000 + index)),
                imei: nil,
                model: nil,
                revision: nil,
                usbDescription: nil,
                profile: .unknown,
                queries: []
            )
        }

        for index in 0..<25 {
            try store.record(makeBackup(index))
        }
        XCTAssertEqual(store.records().count, 20)
        XCTAssertEqual(store.lastBackup()?.createdAt, makeBackup(24).createdAt)

        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(store.records().isEmpty)
        try store.record(makeBackup(1))
        XCTAssertEqual(store.records().count, 1)
    }
}
