import Foundation
import XCTest
@testable import EC25Toolbox

@MainActor
final class ModemSessionCoordinatorTests: XCTestCase {
    private func descriptor(
        serial: String,
        location: UInt32,
        imei: String? = nil
    ) -> USBModemDescriptor {
        USBModemDescriptor(
            vendorID: 0x2c7c,
            productID: 0x0125,
            serialNumber: serial,
            locationID: location,
            productName: "EC25",
            imei: imei
        )
    }

    private func makeHarness(initialSettings: ModemSettings = .defaults) throws -> (
        coordinator: ModemSessionCoordinator,
        defaults: UserDefaults,
        root: URL
    ) {
        let suite = "EC25Toolbox.ModemSessionCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let sms = SMSArchiveStore(
            applicationSupportDirectory: root,
            iCloudDriveRoot: root.appendingPathComponent("no-cloud", isDirectory: true)
        )
        let calls = CallLogStore(applicationSupportDirectory: root)
        let coordinator = ModemSessionCoordinator(
            defaults: defaults,
            smsArchive: sms,
            callLogStore: calls,
            initialSettings: initialSettings,
            startsDeviceSessions: false
        )
        return (coordinator, defaults, root)
    }

    func testWindowSelectionSwitchesTheSelectedStore() throws {
        let harness = try makeHarness()
        let first = descriptor(serial: "A", location: 1, imei: "860000000000001")
        let second = descriptor(serial: "B", location: 2, imei: "860000000000002")
        harness.coordinator.reconcile(discovered: [first, second])

        let secondStore = try XCTUnwrap(harness.coordinator.store(for: second.moduleID))
        harness.coordinator.selectDevice(second.moduleID)

        XCTAssertEqual(harness.coordinator.selectedDeviceID, second.moduleID)
        XCTAssertTrue(harness.coordinator.selectedStore === secondStore)
        XCTAssertEqual(harness.coordinator.selectedDescriptor?.imei, second.imei)
    }

    func testSharedVoicePresetDoesNotSelectQDC507RuntimeForEC21() throws {
        var settings = ModemSettings.defaults
        settings.moduleConfigPreferredMode = ModuleConfigMode.qdc507Voice.rawValue
        let harness = try makeHarness(initialSettings: settings)
        let ec21 = USBModemDescriptor(
            vendorID: 0x2c7c, productID: 0x0121, serialNumber: "EC21", locationID: 1
        )
        let ec25 = descriptor(serial: "EC25", location: 2)

        harness.coordinator.reconcile(discovered: [ec21, ec25])
        let ec21Store = try XCTUnwrap(harness.coordinator.store(for: ec21.id))
        let ec25Store = try XCTUnwrap(harness.coordinator.store(for: ec25.id))
        XCTAssertEqual(ec21Store.settings.effectiveModuleConfigMode, .qdc507Voice)
        XCTAssertFalse(ec21Store.usesQDC507VoiceRuntime)
        XCTAssertTrue(ec25Store.usesQDC507VoiceRuntime)
    }

    func testIMEIResolutionMigratesSelectionAndModuleNote() throws {
        let harness = try makeHarness()
        let provisional = descriptor(serial: "A", location: 1)
        harness.coordinator.reconcile(discovered: [provisional])
        harness.coordinator.setNote("车载模块", for: provisional.moduleID)
        harness.coordinator.selectDevice(provisional.moduleID)
        let store = try XCTUnwrap(harness.coordinator.store(for: provisional.moduleID))

        store.moduleIMEIDidResolve?("860000000000003")
        var resolved = provisional
        resolved.imei = "860000000000003"

        XCTAssertEqual(harness.coordinator.selectedDeviceID, resolved.moduleID)
        XCTAssertEqual(harness.coordinator.note(for: resolved.moduleID), "车载模块")
        XCTAssertNil(harness.coordinator.store(for: provisional.moduleID))
        XCTAssertTrue(harness.coordinator.store(for: resolved.moduleID) === store)
    }

    func testUnbindPersistsAcrossDiscoveryAndRequiresExplicitRebind() throws {
        let harness = try makeHarness()
        let resolved = descriptor(serial: "A", location: 1, imei: "860000000000004")
        let discovered = descriptor(serial: "A", location: 1)
        harness.coordinator.reconcile(discovered: [resolved])
        harness.coordinator.setNote("待删除", for: resolved.moduleID)

        harness.coordinator.unbindDevice(resolved.moduleID)
        harness.coordinator.reconcile(discovered: [discovered])

        XCTAssertTrue(harness.coordinator.sessions.isEmpty)
        XCTAssertTrue(harness.coordinator.knownDevices.isEmpty)
        XCTAssertEqual(harness.coordinator.unboundDevices.map(\.moduleID), [resolved.moduleID])
        XCTAssertEqual(harness.coordinator.note(for: resolved.moduleID), "")

        let sms = SMSArchiveStore(
            applicationSupportDirectory: harness.root,
            iCloudDriveRoot: harness.root.appendingPathComponent("no-cloud", isDirectory: true)
        )
        let restored = ModemSessionCoordinator(
            defaults: harness.defaults,
            smsArchive: sms,
            callLogStore: CallLogStore(applicationSupportDirectory: harness.root),
            initialSettings: .defaults,
            startsDeviceSessions: false
        )
        restored.reconcile(discovered: [discovered])
        XCTAssertTrue(restored.sessions.isEmpty, "USB discovery must not silently undo an unbind")

        restored.bindDevice(resolved.moduleID)
        XCTAssertEqual(restored.sessions.map(\.id), [resolved.moduleID])
        XCTAssertTrue(restored.unboundDevices.isEmpty)
    }

    func testForgetUnboundDeviceRemovesTombstoneAndAllowsFreshDiscovery() throws {
        let harness = try makeHarness()
        let resolved = descriptor(serial: "A", location: 1, imei: "860000000000005")
        let discovered = descriptor(serial: "A", location: 1)
        harness.coordinator.reconcile(discovered: [resolved])
        harness.coordinator.unbindDevice(resolved.moduleID)

        harness.coordinator.forgetUnboundDevice(resolved.moduleID)

        XCTAssertTrue(harness.coordinator.unboundDevices.isEmpty)
        XCTAssertTrue(harness.coordinator.knownDevices.isEmpty)
        XCTAssertTrue(harness.coordinator.sessions.isEmpty)

        harness.coordinator.reconcile(discovered: [discovered])
        XCTAssertTrue(
            harness.coordinator.sessions.isEmpty,
            "A still-attached forgotten module must not jump straight back into the UI"
        )

        harness.coordinator.reconcile(discovered: [])
        harness.coordinator.reconcile(discovered: [discovered])
        XCTAssertEqual(harness.coordinator.sessions.count, 1)

        let restored = ModemSessionCoordinator(
            defaults: harness.defaults,
            smsArchive: SMSArchiveStore(
                applicationSupportDirectory: harness.root,
                iCloudDriveRoot: harness.root.appendingPathComponent("no-cloud", isDirectory: true)
            ),
            callLogStore: CallLogStore(applicationSupportDirectory: harness.root),
            initialSettings: .defaults,
            startsDeviceSessions: false
        )
        restored.reconcile(discovered: [discovered])
        XCTAssertTrue(restored.unboundDevices.isEmpty)
        XCTAssertEqual(restored.sessions.count, 1)
    }

    // MARK: - Presentation snapshot broadcast

    /// Lets every already-enqueued main-queue block (the store-driven snapshot
    /// refresh hops through the main queue) run before asserting on emissions.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func testPresentationSnapshotTracksDeviceSelectionWithSingleEmission() throws {
        let harness = try makeHarness()
        let first = descriptor(serial: "A", location: 1, imei: "860000000000011")
        let second = descriptor(serial: "B", location: 2, imei: "860000000000012")
        harness.coordinator.reconcile(discovered: [first, second])

        var snapshots: [PresentationSnapshot] = []
        let cancellable = harness.coordinator.$presentationSnapshot
            .dropFirst()
            .sink { snapshots.append($0) }
        defer { cancellable.cancel() }

        harness.coordinator.selectDevice(second.moduleID)

        XCTAssertEqual(harness.coordinator.presentationSnapshot.statusModuleID, second.moduleID)
        XCTAssertEqual(snapshots.count, 1, "selection must re-broadcast exactly once")
        XCTAssertEqual(snapshots.last?.statusModuleID, second.moduleID)
    }

    func testPresentationSnapshotIgnoresUnrelatedStoreChurnAndReportsLiveCalls() throws {
        let harness = try makeHarness()
        let module = descriptor(serial: "A", location: 1, imei: "860000000000013")
        harness.coordinator.reconcile(discovered: [module])
        let store = try XCTUnwrap(harness.coordinator.store(for: module.moduleID))

        var snapshots: [PresentationSnapshot] = []
        let cancellable = harness.coordinator.$presentationSnapshot
            .dropFirst()
            .sink { snapshots.append($0) }
        defer { cancellable.cancel() }

        // Store churn that feeds none of the snapshot fields (refresh spinner
        // state) must not re-broadcast to the status item / call surfaces.
        store.state.refreshing = true
        drainMainQueue()
        XCTAssertEqual(snapshots.count, 0)

        store.state.call.phase = .incoming
        drainMainQueue()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(snapshots.last?.hasIncomingCall ?? false)
        XCTAssertEqual(snapshots.last?.liveSessionIDs, [module.moduleID])

        store.state.refreshing = false
        drainMainQueue()
        XCTAssertEqual(snapshots.count, 1, "churn during a live call still stays silent")
    }
}
