import Foundation
import IOKit
import IOUSBHost

/// Errors surfaced by the native USB AT transport.
enum EC25TransportError: LocalizedError {
    /// A command was attempted before a USB session was opened.
    case notOpen
    /// No suitable modem interface could be opened.
    case openFailed(String)
    /// An AT transaction failed.
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .notOpen:
            localized("transport.not_open")
        case let .openFailed(message), let .sendFailed(message):
            message
        }
    }
}

/// Serializes direct USB access through Apple's native IOUSBHost framework.
actor EC25Transport {
    private let targetDevice: USBModemDescriptor?
    private var hostInterface: IOUSBHostInterface?
    private var inputReader: EC25InputReader?
    private var outputPipe: IOUSBHostPipe?
    private var sessionDescription = ""
    /// USB interface number currently claimed for AT, so the independent
    /// NMEA endpoint can probe the remaining interfaces.
    private(set) var activeInterfaceNumber: Int?
    /// Supported USB identity currently claimed by the AT session.
    private(set) var activeUSBIdentity: ModuleUSBIdentity?
    /// Physical module currently claimed by this transport.
    private(set) var activeDevice: USBModemDescriptor?
    private let eventBus = EC25EventBus()
    private var eventLoopTask: Task<Void, Never>?

    init(targetDevice: USBModemDescriptor? = nil) {
        self.targetDevice = targetDevice
    }

    /// Subscribes to modem events. The current stream finishes when the USB
    /// session ends; call again after reconnecting for a fresh stream.
    nonisolated func events() -> AsyncStream<ModemEvent> {
        eventBus.addSubscriber().stream
    }

    /// Opens the requested physical module, or probes the supported USB
    /// identities in connection order when no module is selected.
    func open() throws -> String {
        if let targetDevice {
            return try open(
                vid: UInt16(targetDevice.vendorID),
                pid: UInt16(targetDevice.productID)
            )
        }
        var failures: [String] = []
        for identity in ModuleUSBIdentity.connectionOrder {
            do {
                return try open(
                    vid: UInt16(identity.vendorID),
                    pid: UInt16(identity.productID)
                )
            } catch {
                failures.append("\(identity.displayValue): \(error.localizedDescription)")
            }
        }
        throw EC25TransportError.openFailed(localizedFormat(
            "transport.supported_devices_not_found",
            failures.joined(separator: " · ")
        ))
    }

    /// Opens the first bulk interface on the target modem that responds to `AT`.
    func open(vid: UInt16, pid: UInt16) throws -> String {
        close()

        var iterator: io_iterator_t = 0
        let matching = Self.matchingDictionary(vid: vid, pid: pid)
        let consumedMatching = Unmanaged.passRetained(matching)
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            consumedMatching.takeUnretainedValue(),
            &iterator
        )
        guard result == KERN_SUCCESS else {
            throw EC25TransportError.openFailed(localizedFormat("transport.enumeration_failed", Self.ioMessage(result)))
        }
        defer { IOObjectRelease(iterator) }

        var services: [io_service_t] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            services.append(service)
        }
        defer { services.forEach { IOObjectRelease($0) } }

        // Quectel's 2c7c:0125 composition normally exposes AT on interface 2,
        // with interface 3 as the modem-command fallback. Probe those before
        // diagnostic/GNSS interfaces so a healthy device connects immediately.
        services.sort {
            let lhs = Self.interfaceNumber(for: $0)
            let rhs = Self.interfaceNumber(for: $1)
            let lhsPriority = Self.probePriority(interfaceNumber: lhs)
            let rhsPriority = Self.probePriority(interfaceNumber: rhs)
            return lhsPriority == rhsPriority ? lhs < rhs : lhsPriority < rhsPriority
        }

        var foundInterface = false
        var lastFailure = ""

        for service in services {
            guard let descriptor = Self.deviceDescriptor(
                for: service,
                vendorID: Int(vid),
                productID: Int(pid)
            ), targetDevice == nil || descriptor.id == targetDevice?.id else {
                continue
            }
            foundInterface = true

            let interface: IOUSBHostInterface
            do {
                interface = try IOUSBHostInterface(
                    __ioService: service,
                    options: [],
                    queue: DispatchQueue(label: "ing.fuyaoskyrocket.ec25toolbox.usb"),
                    interestHandler: nil
                )
            } catch {
                lastFailure = error.localizedDescription
                continue
            }

            guard let addresses = Self.bulkEndpointAddresses(for: interface) else {
                interface.destroy()
                continue
            }
            let interfaceNumber = Self.interfaceNumber(for: service)

            let input: IOUSBHostPipe
            let output: IOUSBHostPipe
            do {
                input = try interface.copyPipe(withAddress: Int(addresses.input))
                output = try interface.copyPipe(withAddress: Int(addresses.output))
            } catch {
                lastFailure = error.localizedDescription
                interface.destroy()
                continue
            }

            // A dedicated reader owns the input endpoint for the whole session,
            // starting with the AT handshake probe.
            let reader = EC25InputReader(pipe: input)
            reader.start()
            do {
                _ = try Self.transact(
                    command: "AT",
                    payload: nil,
                    timeout: 3,
                    reader: reader,
                    source: reader,
                    outputPipe: output
                )
            } catch {
                let initialFailure = Self.detailedError(error)
                let recoveryFailures = Self.clearStalls(
                    inputPipe: input,
                    inputAddress: addresses.input,
                    outputPipe: output,
                    outputAddress: addresses.output
                )

                do {
                    _ = try Self.transact(
                        command: "AT",
                        payload: nil,
                        timeout: 3,
                        reader: reader,
                        source: reader,
                        outputPipe: output
                    )
                } catch {
                    let recoverySuffix = recoveryFailures.isEmpty
                        ? ""
                        : localizedFormat(
                            "transport.stall_recovery_failed",
                            recoveryFailures.joined(separator: ", ")
                        )
                    lastFailure = localizedFormat(
                        "transport.interface_probe_failed",
                        interfaceNumber,
                        Int(addresses.output),
                        Int(addresses.input),
                        initialFailure,
                        Self.detailedError(error),
                        recoverySuffix
                    )
                    reader.stop()
                    interface.destroy()
                    continue
                }
            }

            let description = String(
                format: "USB %04x:%04x serial=%@ if%d out=0x%02x in=0x%02x",
                Int(vid),
                Int(pid),
                descriptor.displaySerial,
                interfaceNumber,
                Int(addresses.output),
                Int(addresses.input)
            )

            hostInterface = interface
            inputReader = reader
            outputPipe = output
            sessionDescription = description
            activeInterfaceNumber = interfaceNumber
            activeUSBIdentity = ModuleUSBIdentity(vendorID: Int(vid), productID: Int(pid))
            activeDevice = descriptor
            eventBus.reset()
            startEventLoop(for: reader)
            return description
        }

        if !foundInterface {
            throw EC25TransportError.openFailed(localizedFormat(
                "transport.interface_not_found",
                String(format: "%04x:%04x", Int(vid), Int(pid))
            ))
        }

        let suffix = lastFailure.isEmpty ? "" : "：\(lastFailure)"
        throw EC25TransportError.openFailed(localizedFormat("transport.at_interface_not_found", suffix))
    }

    /// Stable probe order for the standard EC25 USB composition.
    static func probePriority(interfaceNumber: Int) -> Int {
        switch interfaceNumber {
        case 2: 0
        case 3: 1
        case 1: 2
        case 0: 3
        default: interfaceNumber == Int.max ? Int.max : 4 + max(0, interfaceNumber)
        }
    }

    /// Releases the reader, the native interface, and all endpoint pipes, and
    /// finishes every event stream.
    func close() {
        eventLoopTask?.cancel()
        eventLoopTask = nil
        inputReader?.stop()
        inputReader = nil
        outputPipe = nil
        eventBus.deliverClosed(reason: nil)
        hostInterface?.destroy()
        hostInterface = nil
        sessionDescription = ""
        activeInterfaceNumber = nil
        activeUSBIdentity = nil
        activeDevice = nil
    }

    /// Pumps framed input from the continuous reader into the event bus until
    /// the reader stops or the session closes.
    private func startEventLoop(for reader: EC25InputReader) {
        let bus = eventBus
        eventLoopTask = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                let deadline = Date().addingTimeInterval(2)
                switch reader.wait(until: deadline) {
                case let .event(event):
                    bus.deliver(event)
                case let .closed(message):
                    bus.deliverClosed(reason: message)
                    return
                case .timedOut:
                    continue
                }
            }
        }
    }

    /// Current USB session description, or an empty string when closed.
    func description() -> String {
        sessionDescription
    }

    /// Sends one AT command through the native USB pipes.
    func send(command: String, payload: String? = nil, timeoutMs: Int32 = 4_000) throws -> [String] {
        guard let inputReader, let outputPipe else { throw EC25TransportError.notOpen }

        let mailbox = eventBus.beginTransaction()
        defer { eventBus.endTransaction() }

        do {
            let outcome = try Self.transact(
                command: command,
                payload: payload,
                timeout: max(0.001, Double(timeoutMs) / 1_000),
                reader: inputReader,
                source: mailbox,
                outputPipe: outputPipe
            )
            eventBus.emitURCs(outcome.urcs)
            return outcome.lines
        } catch let error as EC25TransportError {
            throw error
        } catch {
            throw EC25TransportError.sendFailed(error.localizedDescription)
        }
    }

    /// USB interface matching dictionary for the modem's vendor/product IDs.
    /// Internal so the independent NMEA endpoint probes the same device.
    static func matchingDictionary(vid: UInt16, pid: UInt16) -> CFMutableDictionary {
        let matching = IOServiceMatching("IOUSBHostInterface")!
        let key = "IOPropertyMatch" as CFString
        let properties = NSDictionary(dictionary: [
            "idVendor": NSNumber(value: vid),
            "idProduct": NSNumber(value: pid)
        ])
        CFDictionarySetValue(
            matching,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(properties).toOpaque()
        )
        return matching
    }

    /// Enumerates every supported physical module once, grouping the many
    /// IOUSBHostInterface services exposed by one USB composite device under
    /// its serial number (or USB location fallback).
    nonisolated static func discoverDevices() -> [USBModemDescriptor] {
        var discovered: [String: USBModemDescriptor] = [:]
        for identity in ModuleUSBIdentity.connectionOrder {
            var iterator: io_iterator_t = 0
            let matching = matchingDictionary(
                vid: UInt16(identity.vendorID),
                pid: UInt16(identity.productID)
            )
            let consumed = Unmanaged.passRetained(matching)
            guard IOServiceGetMatchingServices(
                kIOMainPortDefault,
                consumed.takeUnretainedValue(),
                &iterator
            ) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            while true {
                let service = IOIteratorNext(iterator)
                guard service != 0 else { break }
                let descriptor = deviceDescriptor(
                    for: service,
                    vendorID: identity.vendorID,
                    productID: identity.productID
                )
                IOObjectRelease(service)
                guard let descriptor else { continue }
                discovered[descriptor.id] = descriptor
            }
        }
        return discovered.values.sorted {
            if $0.serialNumber != $1.serialNumber {
                return ($0.serialNumber ?? $0.displaySerial)
                    .localizedStandardCompare($1.serialNumber ?? $1.displaySerial) == .orderedAscending
            }
            return $0.id < $1.id
        }
    }

    /// Resolves the physical USB parent identity for one interface service.
    /// Internal so the NMEA endpoint can remain pinned to the same module.
    nonisolated static func deviceDescriptor(
        for service: io_service_t,
        vendorID: Int,
        productID: Int
    ) -> USBModemDescriptor? {
        let serial: String? = ancestorProperty(
            for: service,
            keys: ["USB Serial Number", "kUSBSerialNumberString"]
        )
        let productName: String? = ancestorProperty(
            for: service,
            keys: ["USB Product Name", "kUSBProductString"]
        )
        let locationNumber: NSNumber? = ancestorProperty(
            for: service,
            keys: ["locationID"]
        )
        let location = locationNumber?.uint32Value
        guard serial != nil || location != nil else { return nil }
        return USBModemDescriptor(
            vendorID: vendorID,
            productID: productID,
            serialNumber: serial,
            locationID: location,
            productName: productName
        )
    }

    private nonisolated static func ancestorProperty<Value>(
        for service: io_service_t,
        keys: [String]
    ) -> Value? {
        var current = service
        var ownsCurrent = false
        defer {
            if ownsCurrent, current != 0 { IOObjectRelease(current) }
        }

        while current != 0 {
            for key in keys {
                if let value = IORegistryEntryCreateCFProperty(
                    current,
                    key as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue() as? Value {
                    return value
                }
            }

            // USB serial and location belong to this device, never its hub.
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 { break }

            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if ownsCurrent { IOObjectRelease(current) }
            guard result == KERN_SUCCESS, parent != 0 else {
                current = 0
                ownsCurrent = false
                break
            }
            current = parent
            ownsCurrent = true
        }
        return nil
    }

    /// USB interface number of one service, or `Int.max` when unreadable.
    /// Internal so the independent NMEA endpoint can avoid the AT interface.
    static func interfaceNumber(for service: io_service_t) -> Int {
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "bInterfaceNumber" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber else { return Int.max }
        return value.intValue
    }

    private static func clearStalls(
        inputPipe: IOUSBHostPipe,
        inputAddress: UInt8,
        outputPipe: IOUSBHostPipe,
        outputAddress: UInt8
    ) -> [String] {
        var failures: [String] = []
        do {
            try inputPipe.clearStall()
        } catch {
            failures.append(String(format: "0x%02x=%@", Int(inputAddress), detailedError(error)))
        }
        do {
            try outputPipe.clearStall()
        } catch {
            failures.append(String(format: "0x%02x=%@", Int(outputAddress), detailedError(error)))
        }
        return failures
    }

    private static func detailedError(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
    }

    /// Bulk in/out endpoint addresses of an interface, or nil when the
    /// interface lacks a bulk pair. Internal so the NMEA endpoint can reuse
    /// the same discovery.
    static func bulkEndpointAddresses(for interface: IOUSBHostInterface) -> (input: UInt8, output: UInt8)? {
        let configuration = interface.configurationDescriptor
        let descriptor = interface.interfaceDescriptor
        var current: UnsafePointer<IOUSBDescriptorHeader>?
        var input: UInt8?
        var output: UInt8?

        for _ in 0..<Int(descriptor.pointee.bNumEndpoints) {
            guard let endpoint = IOUSBGetNextEndpointDescriptor(configuration, descriptor, current) else { break }
            current = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)

            guard IOUSBGetEndpointType(endpoint) == UInt8(kIOUSBEndpointTypeBulk.rawValue) else { continue }
            let address = IOUSBGetEndpointAddress(endpoint)
            if address & 0x80 == 0 {
                output = address
            } else {
                input = address
            }
        }

        guard let input, let output else { return nil }
        return (input, output)
    }

    private static func transact(
        command: String,
        payload: String?,
        timeout: TimeInterval,
        reader: EC25InputReader,
        source: any EC25InputSource,
        outputPipe: IOUSBHostPipe
    ) throws -> (lines: [String], urcs: [String]) {
        reader.purge()
        try write(Data((command + "\r").utf8), to: outputPipe, timeout: timeout)

        if let payload {
            var urcs = try waitForPrompt(from: source, timeout: min(timeout, 5))
            try write(Data(payload.utf8), to: outputPipe, timeout: timeout)
            let outcome = try readResponse(from: source, reader: reader, command: command, timeout: timeout)
            urcs.append(contentsOf: outcome.urcs)
            return (outcome.lines, urcs)
        }

        let outcome = try readResponse(from: source, reader: reader, command: command, timeout: timeout)
        return (outcome.lines, outcome.urcs)
    }

    private static func write(_ data: Data, to pipe: IOUSBHostPipe, timeout: TimeInterval) throws {
        var offset = 0
        while offset < data.count {
            let buffer = NSMutableData(data: data.subdata(in: offset..<data.count))
            var transferred = 0
            try pipe.__sendIORequest(
                with: buffer,
                bytesTransferred: &transferred,
                completionTimeout: timeout
            )
            guard transferred > 0 else {
                throw EC25TransportError.sendFailed(localized("transport.write_stalled"))
            }
            offset += transferred
        }
    }

    /// Waits for the modem data prompt, diverting unsolicited lines that
    /// arrive meanwhile.
    private static func waitForPrompt(from source: any EC25InputSource, timeout: TimeInterval) throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var collector = ATResponseCollector(pendingCommand: nil)

        while deadline.timeIntervalSinceNow > 0 {
            switch source.wait(until: deadline) {
            case .event(.prompt):
                return collector.urcs
            case let .event(other):
                _ = collector.accept(other)
                continue
            case let .closed(message):
                throw EC25TransportError.sendFailed(readerClosedMessage(message))
            case .timedOut:
                continue
            }
        }
        throw EC25TransportError.sendFailed(localized("transport.prompt_timeout"))
    }

    private static func readResponse(
        from source: any EC25InputSource,
        reader: EC25InputReader,
        command: String?,
        timeout: TimeInterval
    ) throws -> (lines: [String], urcs: [String]) {
        let deadline = Date().addingTimeInterval(timeout)
        var collector = ATResponseCollector(pendingCommand: command)

        while deadline.timeIntervalSinceNow > 0 {
            let event: EC25InputEvent
            switch source.wait(until: deadline) {
            case let .event(received):
                event = received
            case let .closed(message):
                throw EC25TransportError.sendFailed(readerClosedMessage(message))
            case .timedOut:
                continue
            }

            switch collector.accept(event) {
            case .continueReading:
                continue
            case .done:
                return (collector.responseLines, collector.urcs)
            case let .failed(message):
                throw EC25TransportError.sendFailed(message ?? localized("transport.command_timeout"))
            }
        }

        switch collector.finishWithTail(reader.flushPendingLine()) {
        case .done:
            return (collector.responseLines, collector.urcs)
        case let .failed(message):
            throw EC25TransportError.sendFailed(message ?? localized("transport.command_timeout"))
        case .continueReading:
            throw EC25TransportError.sendFailed(localized("transport.command_timeout"))
        }
    }

    private static func readerClosedMessage(_ message: String?) -> String {
        guard let message, !message.isEmpty else {
            return localized("transport.device_lost")
        }
        return localizedFormat("transport.device_lost_detail", message)
    }

    /// IOKit error message helper; internal so the NMEA endpoint shares it.
    static func ioMessage(_ result: kern_return_t) -> String {
        String(cString: mach_error_string(result))
    }
}
