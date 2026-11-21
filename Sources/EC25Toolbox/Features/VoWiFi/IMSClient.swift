import Foundation

actor IMSClient {
    private static let userAgent = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        .map { "EC25-Toolbox/\($0)" } ?? "EC25-Toolbox"

    typealias SMSHandler = @Sendable (IMSDecodedSMS) async -> Void
    typealias LogHandler = @Sendable (String) async -> Void
    typealias FailureHandler = @Sendable (Error) async -> Void

    private let dataPlane: VoWiFiDataPlane
    private let simAccess: VoWiFiSIMAccess
    private let identity: VoWiFiIdentity
    private let pcscfAddress: String
    private let innerAddress: String
    private let localPort: UInt16
    private let smsHandler: SMSHandler
    private let logHandler: LogHandler
    private let failureHandler: FailureHandler
    private var handlerID: UUID?
    private var inbox: [SIPMessage] = []
    private var binding: IMSRegistrationBinding?
    private var refreshTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var stopped = false
    private var activeLocalPort: UInt16
    private var securityAgreement: IMSIPSecAgreement?
    private var multipartSMS: [String: (date: Date, total: Int, parts: [Int: String])] = [:]

    init(
        dataPlane: VoWiFiDataPlane,
        simAccess: VoWiFiSIMAccess,
        identity: VoWiFiIdentity,
        pcscfAddress: String,
        innerAddress: String,
        localPort: UInt16,
        smsHandler: @escaping SMSHandler,
        logHandler: @escaping LogHandler,
        failureHandler: @escaping FailureHandler
    ) {
        self.dataPlane = dataPlane
        self.simAccess = simAccess
        self.identity = identity
        self.pcscfAddress = pcscfAddress
        self.innerAddress = innerAddress
        self.localPort = localPort
        activeLocalPort = localPort
        self.smsHandler = smsHandler
        self.logHandler = logHandler
        self.failureHandler = failureHandler
    }

    deinit {
        refreshTask?.cancel()
        keepaliveTask?.cancel()
    }

    func start() async throws -> IMSRegistrationBinding {
        stopped = false
        if handlerID == nil {
            handlerID = await dataPlane.addHandler { [weak self] datagram in
                await self?.receive(datagram)
            }
        }
        let result = try await register()
        binding = result
        scheduleRefresh(result)
        scheduleKeepalive()
        return result
    }

    func stop() async {
        stopped = true
        refreshTask?.cancel()
        keepaliveTask?.cancel()
        refreshTask = nil
        keepaliveTask = nil
        if let handlerID {
            await dataPlane.removeHandler(handlerID)
            self.handlerID = nil
        }
        binding = nil
        inbox.removeAll()
    }

    func currentBinding() -> IMSRegistrationBinding? { binding }

    private func register() async throws -> IMSRegistrationBinding {
        await logHandler(localized("vowifi.log.ims_register"))
        let callID = UUID().uuidString + "@" + innerAddress
        let fromTag = randomToken()
        let requestURI = "sip:\(identity.realm)"
        let proposedSecurity = try IMSIPSecAgreement.proposed()
        let contact = "<sip:\(identity.imsi)@\(innerAddress):\(proposedSecurity.localPort);transport=udp>;+sip.instance=\"<urn:uuid:\(UUID().uuidString)>\""
        let first = makeRegister(
            requestURI: requestURI, callID: callID, cseq: 1,
            fromTag: fromTag, contact: contact, authorization: nil,
            securityClient: proposedSecurity.securityClientHeader
        )
        let firstResponse = try await transact(first, callID: callID, cseq: 1)
        if firstResponse.statusCode == 200 {
            return makeBinding(callID: callID, cseq: 2, response: firstResponse)
        }
        guard firstResponse.statusCode == 401 || firstResponse.statusCode == 407,
              let authenticationHeader = firstResponse.header(
                firstResponse.statusCode == 407 ? "Proxy-Authenticate" : "WWW-Authenticate"
              ) else {
            throw VoWiFiError.imsRegistrationFailed(firstResponse.startLine)
        }
        let challenge = try SIPDigestChallenge.parse(authenticationHeader)
        guard challenge.algorithm.uppercased().contains("AKAV1-MD5")
                || challenge.algorithm.uppercased() == "MD5" else {
            throw VoWiFiError.imsRegistrationFailed(localizedFormat(
                "vowifi.error.ims_algorithm", challenge.algorithm
            ))
        }
        let vector = try IMSAKA.challengeVector(nonce: challenge.nonce)
        let aka = try await simAccess.authenticate(
            application: identity.source == .isim ? .isim : .usim,
            rand: vector.rand, autn: vector.autn
        )
        var negotiatedSecurity: IMSIPSecAgreement?
        if let serverSecurity = firstResponse.header("Security-Server") {
            negotiatedSecurity = try IMSIPSecAgreement.negotiated(
                serverHeader: serverSecurity, proposed: proposedSecurity
            )
            let context = try IMSIPSecContext(
                agreement: negotiatedSecurity!, ck: aka.ck, ik: aka.ik
            )
            await dataPlane.installIMSIPSec(context)
            securityAgreement = negotiatedSecurity
            activeLocalPort = negotiatedSecurity!.localPort
        }
        let cnonce = randomToken()
        let authorization = IMSAKA.authorization(
            challenge: challenge, username: identity.impi,
            uri: requestURI, method: "REGISTER", res: aka.res, cnonce: cnonce
        )
        let second = makeRegister(
            requestURI: requestURI, callID: callID, cseq: 2,
            fromTag: fromTag, contact: contact,
            authorization: authorization,
            proxyAuthorization: firstResponse.statusCode == 407,
            securityClient: proposedSecurity.securityClientHeader,
            securityVerify: firstResponse.header("Security-Server")
        )
        let secondResponse = try await transact(
            second, callID: callID, cseq: 2, secure: negotiatedSecurity != nil
        )
        guard secondResponse.statusCode == 200 else {
            throw VoWiFiError.imsRegistrationFailed(secondResponse.startLine)
        }
        await logHandler(localized("vowifi.log.ims_registered"))
        return makeBinding(callID: callID, cseq: 3, response: secondResponse)
    }

    private func makeRegister(
        requestURI: String,
        callID: String,
        cseq: Int,
        fromTag: String,
        contact: String,
        authorization: String?,
        proxyAuthorization: Bool = false,
        securityClient: String,
        securityVerify: String? = nil
    ) -> SIPMessage {
        var headers = commonHeaders(
            method: "REGISTER", requestURI: requestURI,
            callID: callID, cseq: cseq, fromTag: fromTag
        )
        headers.append(contentsOf: [
            ("Contact", contact),
            ("Expires", "3600"),
            ("Allow", "MESSAGE, NOTIFY, OPTIONS"),
            ("Supported", "path, gruu, outbound, sec-agree"),
            ("Security-Client", securityClient),
            ("P-Access-Network-Info", "IEEE-802.11;i-wlan-node-id=\(innerAddress)"),
            ("User-Agent", Self.userAgent)
        ])
        if let authorization {
            headers.append((proxyAuthorization ? "Proxy-Authorization" : "Authorization", authorization))
        }
        if let securityVerify {
            headers.append(("Security-Verify", securityVerify))
            headers.append(("Require", "sec-agree"))
            headers.append(("Proxy-Require", "sec-agree"))
        }
        return SIPMessage(startLine: "REGISTER \(requestURI) SIP/2.0", headers: headers, body: Data())
    }

    private func commonHeaders(
        method: String, requestURI: String, callID: String, cseq: Int, fromTag: String
    ) -> [(String, String)] {
        [
            ("Via", "SIP/2.0/UDP \(innerAddress):\(activeLocalPort);branch=z9hG4bK\(randomToken());rport"),
            ("Max-Forwards", "70"),
            ("From", "<\(identity.impu)>;tag=\(fromTag)"),
            ("To", "<\(identity.impu)>"),
            ("Call-ID", callID),
            ("CSeq", "\(cseq) \(method)"),
            ("Route", "<sip:\(pcscfAddress);lr>"),
            ("P-Preferred-Identity", "<\(identity.impu)>")
        ]
    }

    private func transact(
        _ request: SIPMessage, callID: String, cseq: Int, secure: Bool = false
    ) async throws -> SIPMessage {
        if secure {
            try await dataPlane.sendSecureIMSUDP(to: pcscfAddress, payload: request.encoded())
        } else {
            try await dataPlane.sendUDP(
                to: pcscfAddress, sourcePort: localPort, destinationPort: 5060,
                payload: request.encoded()
            )
        }
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if let index = inbox.firstIndex(where: {
                $0.statusCode != nil && $0.header("Call-ID") == callID
                    && $0.header("CSeq")?.hasPrefix("\(cseq) ") == true
            }) {
                return inbox.remove(at: index)
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw VoWiFiError.imsRegistrationFailed(localized("vowifi.error.sip_timeout"))
    }

    private func receive(_ datagram: VoWiFiUDPDatagram) async {
        guard datagram.destinationPort == activeLocalPort,
              datagram.sourceAddress == pcscfAddress,
              let message = try? SIPMessage.parse(datagram.payload) else { return }
        if message.statusCode != nil {
            inbox.append(message)
            if inbox.count > 32 { inbox.removeFirst(inbox.count - 32) }
            return
        }
        switch message.method?.uppercased() {
        case "MESSAGE":
            await handleIncomingMessage(message)
        case "OPTIONS":
            try? await sendResponse(to: message, code: 200, reason: "OK")
        default:
            try? await sendResponse(to: message, code: 501, reason: "Not Implemented")
        }
    }

    private func handleIncomingMessage(_ message: SIPMessage) async {
        guard let smsBody = extract3GPPSMSBody(from: message) else {
            try? await sendResponse(to: message, code: 415, reason: "Unsupported Media Type")
            return
        }
        do {
            let sms = try IMSSMSCodec.decodeRPData(smsBody)
            try await sendResponse(to: message, code: 200, reason: "OK")
            try await sendRPAck(for: message, reference: sms.messageReference)
            if let complete = assembledSMS(sms) { await smsHandler(complete) }
        } catch {
            try? await sendResponse(to: message, code: 400, reason: "Bad Request")
        }
    }

    private func assembledSMS(_ sms: IMSDecodedSMS) -> IMSDecodedSMS? {
        guard let reference = sms.concatenationReference,
              let part = sms.partNumber, let total = sms.partCount,
              total > 1, part >= 1, part <= total else { return sms }
        let key = "\(sms.sender)|\(reference)|\(total)"
        var item = multipartSMS[key] ?? (sms.timestamp, total, [:])
        item.parts[part] = sms.body
        multipartSMS[key] = item
        multipartSMS = multipartSMS.filter { Date().timeIntervalSince($0.value.date) < 86_400 }
        guard item.parts.count == total,
              (1...total).allSatisfy({ item.parts[$0] != nil }) else { return nil }
        multipartSMS[key] = nil
        var result = sms
        result.timestamp = item.date
        result.body = (1...total).compactMap { item.parts[$0] }.joined()
        result.concatenationReference = nil
        result.partNumber = nil
        result.partCount = nil
        return result
    }

    private func extract3GPPSMSBody(from message: SIPMessage) -> Data? {
        extract3GPPSMSBody(
            body: message.body,
            contentType: message.header("Content-Type") ?? "",
            transferEncoding: message.header("Content-Transfer-Encoding")
        )
    }

    private func extract3GPPSMSBody(
        body: Data, contentType: String, transferEncoding: String?
    ) -> Data? {
        let lowerType = contentType.lowercased()
        if lowerType.contains("application/vnd.3gpp.sms") {
            if transferEncoding?.lowercased().contains("base64") == true {
                let clean = String(data: body, encoding: .utf8)?
                    .filter { !$0.isWhitespace } ?? ""
                return Data(base64Encoded: clean)
            }
            return body
        }
        if lowerType.contains("message/cpim") {
            guard let nested = splitMIMEPart(body) else { return nil }
            return extract3GPPSMSBody(
                body: nested.body,
                contentType: nested.headers["content-type"] ?? "",
                transferEncoding: nested.headers["content-transfer-encoding"]
            )
        }
        if lowerType.contains("multipart/"),
           let boundary = mimeParameter("boundary", in: contentType) {
            let marker = Data(("--" + boundary).utf8)
            var cursor = body.startIndex
            while let range = body.range(of: marker, in: cursor..<body.endIndex) {
                let start = range.upperBound
                guard let next = body.range(of: marker, in: start..<body.endIndex) else { break }
                var part = Data(body[start..<next.lowerBound])
                while part.starts(with: Data("\r\n".utf8)) { part.removeFirst(2) }
                while part.suffix(2) == Data("\r\n".utf8) { part.removeLast(2) }
                if let nested = splitMIMEPart(part),
                   let result = extract3GPPSMSBody(
                    body: nested.body,
                    contentType: nested.headers["content-type"] ?? "",
                    transferEncoding: nested.headers["content-transfer-encoding"]
                   ) { return result }
                cursor = next.upperBound
            }
        }
        return nil
    }

    private func splitMIMEPart(_ data: Data) -> (headers: [String: String], body: Data)? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let text = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            return nil
        }
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return (headers, Data(data[separator.upperBound...]))
    }

    private func mimeParameter(_ name: String, in contentType: String) -> String? {
        for component in contentType.split(separator: ";").dropFirst() {
            let pair = component.split(separator: "=", maxSplits: 1)
            if pair.count == 2,
               pair[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame {
                return pair[1].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    private func sendResponse(to request: SIPMessage, code: Int, reason: String) async throws {
        var headers: [(String, String)] = []
        request.headers(named: "Via").forEach { headers.append(("Via", $0)) }
        for name in ["From", "To", "Call-ID", "CSeq"] {
            if var value = request.header(name) {
                if name == "To", !value.lowercased().contains(";tag=") {
                    value += ";tag=" + randomToken()
                }
                headers.append((name, value))
            }
        }
        let response = SIPMessage(startLine: "SIP/2.0 \(code) \(reason)", headers: headers, body: Data())
        try await sendSIP(response)
    }

    private func sendRPAck(for request: SIPMessage, reference: UInt8) async throws {
        guard var current = binding else { return }
        let target = request.header("From")?.split(separator: ";").first.map(String.init) ?? "sip:smsc@\(identity.realm)"
        let callID = UUID().uuidString + "@" + innerAddress
        let body = IMSSMSCodec.rpAck(messageReference: reference)
        var headers = commonHeaders(
            method: "MESSAGE", requestURI: target,
            callID: callID, cseq: current.nextCSeq, fromTag: randomToken()
        )
        headers.append(("Content-Type", "application/vnd.3gpp.sms"))
        let ack = SIPMessage(startLine: "MESSAGE \(target) SIP/2.0", headers: headers, body: body)
        try await sendSIP(ack)
        current.nextCSeq += 1
        binding = current
    }

    private func makeBinding(callID: String, cseq: Int, response: SIPMessage) -> IMSRegistrationBinding {
        let expires = response.header("Expires").flatMap(TimeInterval.init) ?? 3600
        return IMSRegistrationBinding(
            publicIdentity: identity.impu, privateIdentity: identity.impi,
            localURI: "sip:\(identity.imsi)@\(innerAddress):\(localPort)",
            pcscfAddress: pcscfAddress, localPort: activeLocalPort,
            expiresAt: Date().addingTimeInterval(max(120, expires)),
            callID: callID, nextCSeq: cseq
        )
    }

    private func scheduleRefresh(_ binding: IMSRegistrationBinding) {
        refreshTask?.cancel()
        let delay = max(60, binding.expiresAt.timeIntervalSinceNow - 120)
        refreshTask = Task { [weak self] in
            await self?.runRefresh(after: delay)
        }
    }

    private func runRefresh(after delay: TimeInterval) async {
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, !stopped else { return }
        do {
            let refreshed = try await register()
            binding = refreshed
            scheduleRefresh(refreshed)
        } catch {
            await logHandler(localizedFormat("vowifi.log.ims_refresh_failed", error.localizedDescription))
            await failureHandler(error)
        }
    }

    private func scheduleKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            await self?.keepaliveLoop()
        }
    }

    private func keepaliveLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, !stopped else { return }
            do {
                // IMS UDP outbound keepalive as specified for the SIP flow.
                if securityAgreement != nil {
                    try await dataPlane.sendSecureIMSUDP(
                        to: pcscfAddress, payload: Data("\r\n\r\n".utf8)
                    )
                } else {
                    try await dataPlane.sendUDP(
                        to: pcscfAddress, sourcePort: activeLocalPort,
                        destinationPort: 5060, payload: Data("\r\n\r\n".utf8)
                    )
                }
            } catch {
                await failureHandler(error)
                return
            }
        }
    }

    private func randomToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func sendSIP(_ message: SIPMessage) async throws {
        if securityAgreement != nil {
            try await dataPlane.sendSecureIMSUDP(to: pcscfAddress, payload: message.encoded())
        } else {
            try await dataPlane.sendUDP(
                to: pcscfAddress, sourcePort: activeLocalPort, destinationPort: 5060,
                payload: message.encoded()
            )
        }
    }
}
