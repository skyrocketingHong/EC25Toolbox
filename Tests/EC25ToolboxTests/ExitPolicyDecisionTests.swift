@testable import EC25Toolbox
import XCTest

final class ExitPolicyDecisionTests: XCTestCase {
    private func path(
        _ status: ExitPathStatus,
        interface: String?,
        kind: ExitInterfaceKind = .wiredEthernet
    ) -> ExitPathSnapshot {
        ExitPathSnapshot(status: status, interfaceBSD: interface, interfaceKind: kind)
    }

    // MARK: - Policy decision

    func testManualPolicyNeverActs() {
        XCTAssertNil(ExitPolicyDecision.moduleServiceShouldBeEnabled(
            policy: .manual, moduleBSD: "en7", defaultPath: path(.satisfied, interface: "en0")
        ))
        XCTAssertNil(ExitPolicyDecision.moduleServiceShouldBeEnabled(
            policy: .manual, moduleBSD: nil, defaultPath: path(.unsatisfied, interface: nil)
        ))
    }

    func testAllow4GAlwaysEnables() {
        XCTAssertEqual(ExitPolicyDecision.moduleServiceShouldBeEnabled(
            policy: .allow4G, moduleBSD: "en7", defaultPath: path(.satisfied, interface: "en0")
        ), true)
        XCTAssertEqual(ExitPolicyDecision.moduleServiceShouldBeEnabled(
            policy: .allow4G, moduleBSD: nil, defaultPath: path(.unsatisfied, interface: nil)
        ), true)
    }

    func testWifiPreferredParksModuleBehindOtherExit() {
        XCTAssertEqual(ExitPolicyDecision.moduleServiceShouldBeEnabled(
            policy: .wifiPreferred, moduleBSD: "en7", defaultPath: path(.satisfied, interface: "en0", kind: .wifi)
        ), false)
        XCTAssertEqual(ExitPolicyDecision.moduleServiceShouldBeEnabled(
            policy: .wifiPreferred, moduleBSD: "en7", defaultPath: path(.satisfied, interface: "bridge0", kind: .wiredEthernet)
        ), false)
    }

    func testWifiPreferredFallsBackToModule() {
        XCTAssertEqual(ExitPolicyDecision.moduleServiceShouldBeEnabled(
            policy: .wifiPreferred, moduleBSD: "en7", defaultPath: path(.unsatisfied, interface: nil)
        ), true)
        XCTAssertEqual(ExitPolicyDecision.moduleServiceShouldBeEnabled(
            policy: .wifiPreferred, moduleBSD: "en7", defaultPath: path(.satisfied, interface: "en7")
        ), true)
        // Unknown path state is treated as "no other exit": keep 4G up.
        XCTAssertEqual(ExitPolicyDecision.moduleServiceShouldBeEnabled(
            policy: .wifiPreferred, moduleBSD: "en7", defaultPath: path(.unknown, interface: "en0")
        ), true)
    }

    func testWifiPreferredWithoutModuleIdentityHasNoOpinion() {
        XCTAssertNil(ExitPolicyDecision.moduleServiceShouldBeEnabled(
            policy: .wifiPreferred, moduleBSD: nil, defaultPath: path(.satisfied, interface: "en0")
        ))
        XCTAssertNil(ExitPolicyDecision.moduleServiceShouldBeEnabled(
            policy: .wifiPreferred, moduleBSD: "", defaultPath: path(.satisfied, interface: "en0")
        ))
    }

    // MARK: - Settings default

    func testExitPolicySettingsDefaultAndRoundTrip() {
        XCTAssertEqual(ModemSettings.defaults.effectiveExitPolicy, .manual)
        var settings = ModemSettings.defaults
        settings.exitPolicy = "wifiPreferred"
        XCTAssertEqual(settings.effectiveExitPolicy, .wifiPreferred)
        settings.exitPolicy = "bogus"
        XCTAssertEqual(settings.effectiveExitPolicy, .manual)
        settings.exitPolicy = ExitPolicy.allow4G.rawValue
        XCTAssertEqual(settings.effectiveExitPolicy, .allow4G)
    }

    func testExitPolicyCodableRoundTrip() throws {
        let encoded = try JSONEncoder().encode([ExitPolicy.wifiPreferred, .manual, .allow4G])
        let decoded = try JSONDecoder().decode([ExitPolicy].self, from: encoded)
        XCTAssertEqual(decoded, [.wifiPreferred, .manual, .allow4G])
    }

    // MARK: - Link snapshot semantics

    func testInterfaceLinkReadySemantics() {
        var link = InterfaceLinkSnapshot(bsdName: "en7")
        XCTAssertFalse(link.isReady)
        link.isUp = true
        link.isRunning = true
        // Link-local IPv6 alone is not a usable exit.
        link.ipv6Addresses = ["fe80::1"]
        XCTAssertFalse(link.isReady)
        link.ipv4Addresses = ["192.168.0.2"]
        XCTAssertTrue(link.isReady)
    }

    func testInterfaceLinkAddressDisplay() {
        var link = InterfaceLinkSnapshot(bsdName: "en7")
        XCTAssertEqual(link.displayAddresses, "-")
        link.ipv4Addresses = ["10.0.0.2"]
        XCTAssertEqual(link.displayAddresses, "10.0.0.2")
        link.ipv4Addresses = ["10.0.0.2", "10.0.0.3"]
        link.ipv6Addresses = ["2001:db8::1", "fe80::4", "2001:db8::2", "2001:db8::3"]
        XCTAssertEqual(link.displayAddresses, "10.0.0.2, 10.0.0.3, 2001:db8::1, …")
    }

    // MARK: - Status snapshot helpers

    func testExitRidesModule() {
        var status = ModemNetworkStatus(
            nic: ModemNICInfo(
                usbDevice: USBModemDescriptor(
                    vendorID: 0x2c7c, productID: 0x0125, serialNumber: nil, locationID: 0x1000
                ),
                bsdName: "en7",
                macAddress: "aa:bb:cc:dd:ee:ff"
            ),
            service: nil
        )
        status.defaultPath = ExitPathSnapshot(status: .satisfied, interfaceBSD: "en7", interfaceKind: .wiredEthernet)
        XCTAssertTrue(status.exitRidesModule)
        status.defaultPath = ExitPathSnapshot(status: .satisfied, interfaceBSD: "en0", interfaceKind: .wifi)
        XCTAssertFalse(status.exitRidesModule)
        status.defaultPath = ExitPathSnapshot(status: .unsatisfied, interfaceBSD: nil, interfaceKind: .none)
        XCTAssertFalse(status.exitRidesModule)
    }

    // MARK: - System proxy mapping

    func testSystemProxyMapping() {
        XCTAssertEqual(SystemProxySnapshot.fromDictionary(nil).mode, .none)
        XCTAssertEqual(SystemProxySnapshot.fromDictionary([:]).mode, .none)
        XCTAssertEqual(SystemProxySnapshot.fromDictionary(["HTTPEnable": 0]).mode, .none)

        let http = SystemProxySnapshot.fromDictionary([
            "HTTPEnable": 1,
            "HTTPProxy": "192.168.1.1",
            "HTTPPort": 8888
        ])
        XCTAssertEqual(http.mode, .http)
        XCTAssertEqual(http.displayEndpoint, "192.168.1.1:8888")

        let https = SystemProxySnapshot.fromDictionary([
            "HTTPSEnable": 1,
            "HTTPSProxy": "proxy.example.com",
            "HTTPSPort": 3128
        ])
        XCTAssertEqual(https.mode, .http)
        XCTAssertEqual(https.displayEndpoint, "proxy.example.com:3128")

        let socks = SystemProxySnapshot.fromDictionary([
            "SOCKSEnable": 1,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": 1080
        ])
        XCTAssertEqual(socks.mode, .socks)
        XCTAssertEqual(socks.displayEndpoint, "127.0.0.1:1080")

        // Configured host but disabled switch must not count as a proxy.
        XCTAssertEqual(SystemProxySnapshot.fromDictionary([
            "HTTPEnable": 0,
            "HTTPProxy": "192.168.1.1",
            "HTTPPort": 8888
        ]).mode, .none)
    }
}
