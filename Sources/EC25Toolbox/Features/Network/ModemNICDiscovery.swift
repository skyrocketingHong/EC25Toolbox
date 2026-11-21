import Foundation
import IOKit
import SystemConfiguration

/// Enumerates the modem's USB-attached network interface and the network
/// services bound to it. Everything here only reads system state — creating or
/// mutating services goes through the privileged helper.
enum ModemNICDiscovery {
    /// Finds Ethernet interfaces whose IORegistry ancestry leads to a supported modem.
    private static func discoverModuleNICs() -> [ModemNICInfo] {
        guard let matching = IOServiceMatching("IOEthernetInterface") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var results: [ModemNICInfo] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let info = moduleNIC(for: service) else { continue }
            results.append(info)
        }
        return results.sorted { $0.bsdName < $1.bsdName }
    }

    /// Reads the user-visible network services. Reading system configuration
    /// needs no privileges; only mutations are routed through the helper.
    static func currentServices() -> [ModemNetworkServiceInfo] {
        guard let preferences = SCPreferencesCreate(
            nil,
            "ing.fuyaoskyrocket.ec25toolbox" as CFString,
            nil
        ), let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            return []
        }
        return services.compactMap { service in
            guard let idString = SCNetworkServiceGetServiceID(service) as String?,
                  let serviceID = UUID(uuidString: idString) else { return nil }
            let interface = SCNetworkServiceGetInterface(service)
            let bsdName = interface.flatMap { SCNetworkInterfaceGetBSDName($0) as String? } ?? ""
            let ipv4Method = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeIPv4)
                .flatMap { SCNetworkProtocolGetConfiguration($0) as? [String: Any] }?[
                    kSCPropNetIPv4ConfigMethod as String
                ] as? String
            return ModemNetworkServiceInfo(
                serviceID: serviceID,
                name: SCNetworkServiceGetName(service) as String? ?? "",
                enabled: SCNetworkServiceGetEnabled(service),
                bsdName: bsdName,
                ipv4Method: ipv4Method
            )
        }
    }

    static func nic(for device: USBModemDescriptor?) -> ModemNICInfo? {
        guard let device else { return nil }
        return ModemNICMatcher.interface(for: device, in: discoverModuleNICs())
    }

    /// Resolves the interface and service for the same physical module.
    static func currentStatus(for device: USBModemDescriptor?) -> ModemNetworkStatus {
        let nic = nic(for: device)
        let service = nic.flatMap { target in
            currentServices().first { $0.bsdName == target.bsdName }
        }
        return ModemNetworkStatus(nic: nic, service: service)
    }

    private static func moduleNIC(for service: io_service_t) -> ModemNICInfo? {
        guard let usbDevice = usbAncestor(of: service),
              let bsdName = stringProperty(service, "BSD Name"), !bsdName.isEmpty else { return nil }
        let mac = macAddress(for: service).flatMap(ModemNICMatcher.formatMAC) ?? ""
        return ModemNICInfo(usbDevice: usbDevice, bsdName: bsdName, macAddress: mac)
    }

    /// Walks the service plane to the USB device owning the network interface.
    private static func usbAncestor(of service: io_service_t) -> USBModemDescriptor? {
        var current = service
        var ownsCurrent = false
        defer { if ownsCurrent { IOObjectRelease(current) } }
        for _ in 0..<24 {
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 {
                guard let vid = uint16Property(current, "idVendor"),
                      let pid = uint16Property(current, "idProduct"),
                      ModemNICMatcher.isSupportedIdentity(usbVID: vid, usbPID: pid) else { return nil }
                return EC25Transport.deviceDescriptor(for: current, vendorID: Int(vid), productID: Int(pid))
            }
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0 else {
                return nil
            }
            if ownsCurrent { IOObjectRelease(current) }
            current = parent
            ownsCurrent = true
        }
        return nil
    }

    /// `IOMACAddress` lives on the interface, with the controller as fallback.
    private static func macAddress(for service: io_service_t) -> [UInt8]? {
        if let bytes = dataProperty(service, "IOMACAddress") { return bytes }
        var current = service
        var ownsCurrent = false
        defer { if ownsCurrent { IOObjectRelease(current) } }
        for _ in 0..<3 {
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0 else {
                return nil
            }
            if ownsCurrent { IOObjectRelease(current) }
            current = parent
            ownsCurrent = true
            if let bytes = dataProperty(current, "IOMACAddress") { return bytes }
        }
        return nil
    }

    private static func stringProperty(_ entry: io_service_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func dataProperty(_ entry: io_service_t, _ key: String) -> [UInt8]? {
        (IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data)?.map { $0 }
    }

    private static func uint16Property(_ entry: io_service_t, _ key: String) -> UInt16? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        if let number = value as? NSNumber { return UInt16(exactly: number.intValue) }
        // Some USB properties surface as 16-bit little-endian data.
        if let data = value as? Data, data.count == 2 {
            return data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) }
        }
        return nil
    }
}
