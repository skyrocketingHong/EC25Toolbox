import Charts
import SwiftUI

private enum NetworkCategory: String, CaseIterable, Identifiable, SettingsCategoryItem {
    case interface
    case routing
    case traffic

    var id: String { rawValue }
    var title: String { "network.category.\(rawValue)" }
    var description: String { "network.category.\(rawValue).description" }

    var systemImage: String {
        switch self {
        case .interface: "externaldrive.connected.to.line.below"
        case .routing: "arrow.triangle.branch"
        case .traffic: "chart.xyaxis.line"
        }
    }
}

/// Network page: identifies the modem's USB network interface and manages its
/// dedicated, DHCP-based system network service through the privileged helper.
/// Exit policy, live diagnostics, and traffic charts land here in later phases.
struct NetworkView: View {
    @EnvironmentObject private var store: ModemStore
    @State private var selectedCategory: NetworkCategory = .interface

    private var network: ModemNetworkStatus { store.state.network }

    var body: some View {
        SettingsCategoryLayout(
            categories: NetworkCategory.allCases,
            owningTab: .network,
            selection: $selectedCategory
        ) {
            SettingsCategoryHeader(
                title: selectedCategory.title,
                description: selectedCategory.description,
                systemImage: selectedCategory.systemImage
            ) {
                Button {
                    store.refreshNetworkStatus()
                } label: {
                    Label(localized("network.action.refresh"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .help(localized("network.action.refresh.help"))
                .disabled(store.state.busy || store.state.refreshing)
            }
        } content: {
            categoryContent
        }
    }

    @ViewBuilder
    private var categoryContent: some View {
        if store.state.remoteManagement.mode == .direct, let nic = network.nic {
            switch selectedCategory {
            case .interface:
                VStack(spacing: 14) {
                    nicCard(nic)
                    serviceCard
                }
            case .routing:
                VStack(spacing: 14) {
                    policyCard
                    exitCard
                }
            case .traffic:
                trafficCard
            }
        } else {
            VStack(spacing: 14) {
                // The tab and category rail stay present even without a NIC;
                // the selected page explains how to restore it.
                EmptyState(
                    title: "network.empty.title",
                    subtitle: emptyReasonKey,
                    systemImage: "network.slash",
                    actionTitleKey: "network.action.refresh",
                    action: { store.refreshNetworkStatus() }
                )
                .frame(minHeight: 220, maxHeight: .infinity)

                if store.state.connected, store.state.remoteManagement.mode == .direct {
                    usbModeHintCard
                }
            }
        }
    }

    private var subtitleKey: String {
        if network.nic == nil { return "network.subtitle.no_nic" }
        return network.hasDedicatedService ? "network.subtitle.service_bound" : "network.subtitle.no_service"
    }

    /// Distinguishes "modem connected, no NIC" (points the user at the
    /// device/USB-mode settings) from "no modem at all" (re-detect).
    private var emptyReasonKey: String {
        if store.state.remoteManagement.mode == .remote { return "network.empty.local_only" }
        return store.state.connected ? "network.empty.no_nic_connected" : "network.empty.disconnected"
    }

    /// Lists the module's current USB network mode so the user can act on
    /// the "no NIC" conclusion (spec R10 §3.4).
    private var usbModeHintCard: some View {
        MacSettingsContentGroup("network.empty.usb_mode", systemImage: "cable.connector") {
            KeyValueRow(
                label: "network.field.usb_mode",
                value: isPlaceholder(store.state.info.usbNetworkMode)
                    ? "-"
                    : store.state.info.usbNetworkMode
            )
        }
    }

    private func nicCard(_ nic: ModemNICInfo) -> some View {
        MacSettingsContentGroup(
            "network.section.nic",
            systemImage: "externaldrive.connected.to.line.below"
        ) {
            ParameterGrid(
                values: nicValues(nic),
                columnCount: 2,
                showsCellBackground: false
            )
        }
    }

    private func nicValues(_ nic: ModemNICInfo) -> [ParameterValue] {
        [
            ParameterValue(label: "network.field.usb", value: nic.usbIdentity),
            ParameterValue(label: "network.field.bsd", value: nic.bsdName),
            ParameterValue(label: "network.field.mac", value: nic.macAddress.isEmpty ? "-" : nic.macAddress)
        ]
    }

    @ViewBuilder
    private var serviceCard: some View {
        MacSettingsContentGroup("network.section.service", systemImage: "gearshape.2") {
            if let service = network.service {
                ParameterGrid(
                    values: serviceValues(service),
                    columnCount: 2,
                    showsCellBackground: false
                )

                HStack(spacing: 8) {
                    Label(
                        localized(service.enabled ? "network.status.enabled" : "network.status.disabled"),
                        systemImage: service.enabled ? "checkmark.circle.fill" : "pause.circle"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(service.enabled ? .green : .secondary)
                    if !service.usesDHCP {
                        Text(localized("network.note.manual_ipv4"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help(localized("network.note.manual_ipv4.help"))
                    }
                    Spacer(minLength: 6)
                    Button {
                        store.setModuleNetworkServiceEnabled(!service.enabled)
                    } label: {
                        Label(
                            localized(service.enabled ? "network.action.disable" : "network.action.enable"),
                            systemImage: service.enabled ? "pause.circle" : "play.circle"
                        )
                    }
                    .controlSize(.small)
                    .disabled(store.state.busy)
                }
            } else {
                EmptyState(
                    title: "network.empty.no_service.title",
                    subtitle: "network.empty.no_service.subtitle",
                    systemImage: "plus.rectangle.on.folder"
                )
                Button {
                    store.configureModuleNetworkService()
                } label: {
                    Label(localized("network.action.configure"), systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.state.busy)
                .help(localized("network.action.configure.help"))
            }
        }
    }

    private func serviceValues(_ service: ModemNetworkServiceInfo) -> [ParameterValue] {
        [
            ParameterValue(label: "network.field.service_name", value: service.name),
            ParameterValue(label: "network.field.ipv4", value: service.ipv4Method ?? "-"),
            ParameterValue(
                label: "network.field.service_id",
                value: service.serviceID.uuidString
            )
        ]
    }

    // MARK: - Exit policy

    private var policyCard: some View {
        MacSettingsContentGroup("network.section.policy", systemImage: "arrow.triangle.branch") {
            Picker(localized("network.policy.label"), selection: policyBinding) {
                ForEach(ExitPolicy.allCases) { policy in
                    Text(localized(policy.localizationKey)).tag(policy)
                }
            }
            .labelsHidden()
            Text(localized("network.policy.hint.\(store.settings.effectiveExitPolicy.rawValue)"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(localized("network.policy.help"))
        }
    }

    private var policyBinding: Binding<ExitPolicy> {
        Binding(
            get: { store.settings.effectiveExitPolicy },
            set: { value in
                store.updateSettings { $0.exitPolicy = value.rawValue }
                store.refreshNetworkStatus()
            }
        )
    }

    // MARK: - Exit diagnostics

    private var exitCard: some View {
        MacSettingsContentGroup(
            "network.section.exit",
            systemImage: "dot.radiowaves.left.and.right"
        ) {
            ParameterGrid(
                values: exitValues,
                columnCount: 2,
                showsCellBackground: false
            )
            if let note = exitNote {
                Text(localized(note))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var exitValues: [ParameterValue] {
        [
            ParameterValue(label: "network.exit.field.default_status", value: localized(network.defaultPath.status.localizationKey)),
            ParameterValue(
                label: "network.exit.field.default_interface",
                value: defaultInterfaceText
            ),
            ParameterValue(label: "network.exit.field.exit_addresses", value: network.exitLink?.displayAddresses ?? "-"),
            ParameterValue(label: "network.exit.field.module_link", value: moduleLinkText),
            ParameterValue(label: "network.exit.field.module_addresses", value: network.moduleLink.displayAddresses),
            ParameterValue(label: "network.exit.field.proxy", value: proxyText),
            ParameterValue(
                label: "network.exit.field.via_module",
                value: localized(network.exitRidesModule ? "network.exit.via_module.yes" : "network.exit.via_module.no")
            )
        ]
    }

    private var defaultInterfaceText: String {
        let kind = localized(network.defaultPath.interfaceKind.localizationKey)
        let name = network.defaultPath.displayInterface
        return name == "-" ? "-" : "\(kind) · \(name)"
    }

    private var moduleLinkText: String {
        guard let nic = network.nic, !nic.bsdName.isEmpty else { return "-" }
        return network.moduleLink.isReady
            ? localizedFormat("network.exit.module_ready", nic.bsdName)
            : localizedFormat("network.exit.module_not_ready", nic.bsdName)
    }

    private var proxyText: String {
        guard network.proxy.mode != .none else { return localized("network.exit.proxy.none") }
        return "\(network.proxy.displayEndpoint)"
    }

    /// Explains why 4G is not the exit right now, when that is noteworthy.
    private var exitNote: String? {
        guard network.nic != nil else { return nil }
        if !network.moduleLink.isReady {
            return "network.exit.note.module_not_ready"
        }
        if store.settings.effectiveExitPolicy == .wifiPreferred,
           !network.exitRidesModule,
           network.defaultPath.status == .satisfied {
            return "network.exit.note.parked"
        }
        if network.defaultPath.status == .unsatisfied {
            return "network.exit.note.no_path"
        }
        return nil
    }

    // MARK: - Traffic

    private var trafficCard: some View {
        MacSettingsContentCard {
            if network.traffic.points.isEmpty {
                EmptyState(
                    title: "network.traffic.empty.title",
                    subtitle: "network.traffic.empty.subtitle",
                    systemImage: "chart.xyaxis.line"
                )
                .frame(minHeight: 120)
            } else {
                Chart {
                    ForEach(network.traffic.points) { point in
                        AreaMark(
                            x: .value(localized("network.traffic.axis.time"), point.date),
                            y: .value(localized("network.traffic.axis.rate"), point.bytesInPerSecond)
                        )
                        .foregroundStyle(by: .value(
                            localized("network.traffic.series.direction"),
                            localized("network.traffic.series.down")
                        ))
                        .interpolationMethod(.monotone)
                    }
                    ForEach(network.traffic.points) { point in
                        AreaMark(
                            x: .value(localized("network.traffic.axis.time"), point.date),
                            y: .value(localized("network.traffic.axis.rate"), point.bytesOutPerSecond)
                        )
                        .foregroundStyle(by: .value(
                            localized("network.traffic.series.direction"),
                            localized("network.traffic.series.up")
                        ))
                        .interpolationMethod(.monotone)
                    }
                }
                .chartLegend(.visible)
                .chartXAxis(.automatic)
                .frame(height: 150)

                ParameterGrid(
                    values: trafficValues,
                    columnCount: 2,
                    showsCellBackground: false
                )
            }
        }
    }

    private var trafficValues: [ParameterValue] {
        let traffic = network.traffic
        let last = traffic.points.last
        let session = traffic.session
        var values = [
            ParameterValue(
                label: "network.traffic.field.rate_down",
                value: last.map { formatRate($0.bytesInPerSecond) } ?? "-"
            ),
            ParameterValue(
                label: "network.traffic.field.rate_up",
                value: last.map { formatRate($0.bytesOutPerSecond) } ?? "-"
            ),
            ParameterValue(
                label: "network.traffic.field.session_down",
                value: session.map { formatBytes(Double($0.bytesIn)) } ?? "-"
            ),
            ParameterValue(
                label: "network.traffic.field.session_up",
                value: session.map { formatBytes(Double($0.bytesOut)) } ?? "-"
            ),
            ParameterValue(
                label: "network.traffic.field.peak_down",
                value: session.map { formatRate($0.peakBytesInPerSecond) } ?? "-"
            ),
            ParameterValue(
                label: "network.traffic.field.peak_up",
                value: session.map { formatRate($0.peakBytesOutPerSecond) } ?? "-"
            )
        ]
        if let previous = network.lastSession {
            values.append(ParameterValue(
                label: "network.traffic.field.last_session",
                value: localizedFormat(
                    "network.traffic.format.last_session",
                    formatBytes(Double(previous.bytesIn)),
                    formatBytes(Double(previous.bytesOut))
                )
            ))
        }
        return values
    }

    private func formatBytes(_ value: Double) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(max(0, value.rounded())),
            countStyle: .file
        )
    }

    private func formatRate(_ bytesPerSecond: Double) -> String {
        localizedFormat("network.traffic.format.rate", formatBytes(bytesPerSecond))
    }
}
