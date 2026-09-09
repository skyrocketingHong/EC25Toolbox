import Foundation

/// Identity of the modem's USB-attached network interface as presented by
/// macOS: the Quectel USB ancestry, the BSD name, and the NIC's MAC address.
struct ModemNICInfo: Equatable, Sendable {
    var usbVID: UInt16
    var usbPID: UInt16
    var bsdName: String
    var macAddress: String

    var usbIdentity: String {
        String(format: "%04x:%04x", Int(usbVID), Int(usbPID))
    }
}

/// User-readable snapshot of the `SCNetworkService` bound to the modem NIC.
struct ModemNetworkServiceInfo: Equatable, Sendable {
    var serviceID: UUID
    var name: String
    var enabled: Bool
    var bsdName: String
    var ipv4Method: String?

    /// True when the service negotiates its address itself, the configuration
    /// P4-A applies. Anything else belongs to the user and stays untouched.
    var usesDHCP: Bool { ipv4Method == "DHCP" }
}

/// Aggregated network status published by the store.
struct ModemNetworkStatus: Equatable, Sendable {
    var nic: ModemNICInfo?
    var service: ModemNetworkServiceInfo?
    var defaultPath = ExitPathSnapshot()
    var moduleLink = InterfaceLinkSnapshot()
    var exitLink: InterfaceLinkSnapshot?
    var proxy = SystemProxySnapshot()
    var traffic = TrafficStatus()
    var lastSession: TrafficSessionRecord?

    var hasDedicatedService: Bool { service != nil }

    /// True when the default exit currently rides the module interface.
    var exitRidesModule: Bool {
        guard let nic, defaultPath.status == .satisfied else { return false }
        return defaultPath.interfaceBSD == nic.bsdName
    }
}

/// What the store should do to give the module NIC a dedicated, DHCP-based
/// network service. The decision is pure so duplicate protection is testable.
enum ModemNetworkPlan: Equatable, Sendable {
    case noInterface
    case useExisting(ModemNetworkServiceInfo)
    case create(bsdName: String, serviceName: String)

    /// Never creates a second service for the modem interface: any service
    /// already bound to the NIC is reused (re-enabled if necessary), and a new
    /// one is only requested when none exists at all.
    static func servicePlan(
        nic: ModemNICInfo?,
        services: [ModemNetworkServiceInfo],
        preferredName: String
    ) -> ModemNetworkPlan {
        guard let nic else { return .noInterface }
        let bound = services.filter { $0.bsdName == nic.bsdName }
        if let existing = bound.first(where: \.enabled) ?? bound.first {
            return .useExisting(existing)
        }
        return .create(
            bsdName: nic.bsdName,
            serviceName: ModemNetworkPlan.uniqueServiceName(
                preferred: preferredName,
                existingNames: services.map(\.name)
            )
        )
    }

    /// `SCNetworkServiceSetName` fails on collisions, so the caller picks a
    /// name macOS accepts before asking the helper to create the service.
    static func uniqueServiceName(preferred: String, existingNames: [String]) -> String {
        guard !preferred.isEmpty else { return preferred }
        var candidate = preferred
        var suffix = 2
        let taken = Set(existingNames)
        while taken.contains(candidate) {
            candidate = "\(preferred) \(suffix)"
            suffix += 1
        }
        return candidate
    }
}

enum ModemNICMatcher {
    /// Both reversible module identities are supported during first-use setup.
    static let quectelVendorID: UInt16 = 0x2c7c
    static let djiVendorID: UInt16 = 0x2ca3

    static func isModuleVendor(_ usbVID: UInt16, vendorID: UInt16 = quectelVendorID) -> Bool {
        usbVID == vendorID || (vendorID == quectelVendorID && usbVID == djiVendorID)
    }

    static func isSupportedIdentity(usbVID: UInt16, usbPID: UInt16) -> Bool {
        ModuleUSBIdentity.allCases.contains {
            usbVID == UInt16($0.vendorID) && usbPID == UInt16($0.productID)
        }
    }

    /// Formats the six-byte `IOMACAddress` registry value as lowercase
    /// colon-separated hex. Anything else returns nil so the UI can show "-".
    static func formatMAC(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 6 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

/// Errors surfaced by the network service actions.
enum ModemNetworkError: LocalizedError, Equatable {
    case noInterface
    case noService

    var errorDescription: String? {
        switch self {
        case .noInterface: localized("network.error.no_interface")
        case .noService: localized("network.error.no_service")
        }
    }
}
