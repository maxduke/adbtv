import Foundation

public enum ADBWirelessDebuggingServiceKind: String, CaseIterable, Codable, Equatable, Sendable {
    case pairing
    case connect

    public init?(bonjourType: String) {
        switch bonjourType {
        case Self.pairing.bonjourType:
            self = .pairing
        case Self.connect.bonjourType:
            self = .connect
        default:
            return nil
        }
    }

    public var bonjourType: String {
        switch self {
        case .pairing:
            return "_adb-tls-pairing._tcp"
        case .connect:
            return "_adb-tls-connect._tcp"
        }
    }

    public var displayName: String {
        switch self {
        case .pairing:
            return "Pairing"
        case .connect:
            return "Connect"
        }
    }
}

public struct ADBDiscoveredService: Codable, Equatable, Identifiable, Sendable {
    public var serviceName: String
    public var serviceType: String
    public var domain: String
    public var interfaceName: String?

    public init(
        serviceName: String,
        serviceType: String,
        domain: String,
        interfaceName: String? = nil
    ) {
        self.serviceName = serviceName
        self.serviceType = serviceType
        self.domain = domain
        self.interfaceName = interfaceName
    }

    public var id: String {
        [
            serviceType,
            domain,
            interfaceName ?? "",
            serviceName
        ].joined(separator: "|")
    }

    public var kind: ADBWirelessDebuggingServiceKind? {
        ADBWirelessDebuggingServiceKind(bonjourType: serviceType)
    }

    public var displayName: String {
        serviceName.isEmpty ? serviceType : serviceName
    }
}

public struct ADBBonjourDiscoverySnapshot: Equatable, Sendable {
    public var services: [ADBDiscoveredService]

    public init(services: [ADBDiscoveredService]) {
        self.services = services.sortedForPresentation()
    }

    mutating func replaceServices(
        of kind: ADBWirelessDebuggingServiceKind,
        with replacements: [ADBDiscoveredService]
    ) {
        services = (
            services.filter { $0.kind != kind }
                + replacements.filter { $0.kind == kind }
        ).sortedForPresentation()
    }
}

public extension Array where Element == ADBDiscoveredService {
    func sortedForPresentation() -> [ADBDiscoveredService] {
        sorted { lhs, rhs in
            let lhsKind = lhs.kind?.rawValue ?? lhs.serviceType
            let rhsKind = rhs.kind?.rawValue ?? rhs.serviceType
            guard lhsKind == rhsKind else {
                return lhsKind < rhsKind
            }

            let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
            guard nameComparison == .orderedSame else {
                return nameComparison == .orderedAscending
            }

            return lhs.id < rhs.id
        }
    }
}

#if canImport(Network)
import Dispatch
@preconcurrency import Network

public final class ADBBonjourServiceBrowser: @unchecked Sendable {
    public typealias UpdateHandler = @MainActor ([ADBDiscoveredService]) -> Void
    public typealias FailureHandler = @MainActor (String) -> Void

    private let queue: DispatchQueue
    private var browsers: [NWBrowser]
    private var snapshot: ADBBonjourDiscoverySnapshot

    public init(queue: DispatchQueue = DispatchQueue(label: "ADBBonjourServiceBrowser")) {
        self.queue = queue
        self.browsers = []
        self.snapshot = ADBBonjourDiscoverySnapshot(services: [])
    }

    deinit {
        cancel()
    }

    public func start(
        serviceKinds: [ADBWirelessDebuggingServiceKind] = ADBWirelessDebuggingServiceKind.allCases,
        updateHandler: @escaping UpdateHandler,
        failureHandler: @escaping FailureHandler
    ) {
        cancel()

        let parameters = NWParameters.tcp
        browsers = serviceKinds.map { serviceKind in
            let descriptor = NWBrowser.Descriptor.bonjour(type: serviceKind.bonjourType, domain: nil)
            let browser = NWBrowser(for: descriptor, using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.record(
                    results: results,
                    serviceKind: serviceKind,
                    updateHandler: updateHandler
                )
            }
            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    Task { @MainActor in
                        failureHandler(String(describing: error))
                    }
                }
            }
            browser.start(queue: queue)
            return browser
        }
    }

    public func cancel() {
        for browser in browsers {
            browser.cancel()
        }
        browsers = []
        snapshot = ADBBonjourDiscoverySnapshot(services: [])
    }

    private func record(
        results: Set<NWBrowser.Result>,
        serviceKind: ADBWirelessDebuggingServiceKind,
        updateHandler: @escaping UpdateHandler
    ) {
        let services = results.compactMap(ADBDiscoveredService.init(result:))
        snapshot.replaceServices(of: serviceKind, with: services)

        let servicesForUpdate = snapshot.services
        Task { @MainActor in
            updateHandler(servicesForUpdate)
        }
    }
}

private extension ADBDiscoveredService {
    init?(result: NWBrowser.Result) {
        guard case let .service(name, type, domain, interface) = result.endpoint else {
            return nil
        }

        self.init(
            serviceName: name,
            serviceType: type,
            domain: domain,
            interfaceName: interface?.name
        )
    }
}
#endif
