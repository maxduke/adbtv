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

public struct ADBBonjourDiscoveryFailure: Error, Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case noAuthorization
        case localNetworkDenied
        case other
    }

    public var reason: Reason
    public var diagnosticDescription: String
    public var dnsErrorCode: Int?

    public init(
        reason: Reason,
        diagnosticDescription: String,
        dnsErrorCode: Int? = nil
    ) {
        self.reason = reason
        self.diagnosticDescription = diagnosticDescription
        self.dnsErrorCode = dnsErrorCode
    }

    public init(dnsErrorCode: Int, diagnosticDescription: String) {
        let reason: Reason
        switch dnsErrorCode {
        case -65_555:
            reason = .noAuthorization
        case -65_570:
            reason = .localNetworkDenied
        default:
            reason = .other
        }
        self.init(
            reason: reason,
            diagnosticDescription: diagnosticDescription,
            dnsErrorCode: dnsErrorCode
        )
    }
}

public enum ADBBonjourDiscoveryBrowserState: Equatable, Sendable {
    case ready
    case waitingForAuthorization(ADBBonjourDiscoveryFailure)
}

#if canImport(Network)
import Dispatch
@preconcurrency import Network

public final class ADBBonjourServiceBrowser: @unchecked Sendable {
    public static let browseDomain: String? = nil

    public typealias UpdateHandler = @MainActor ([ADBDiscoveredService]) -> Void
    public typealias StateHandler = @MainActor (ADBBonjourDiscoveryBrowserState) -> Void
    public typealias FailureHandler = @MainActor (ADBBonjourDiscoveryFailure) -> Void

    private let queue: DispatchQueue
    private var browsers: [NWBrowser]
    private var startedBrowserIndices: Set<Int>
    private var snapshot: ADBBonjourDiscoverySnapshot

    public init(queue: DispatchQueue = DispatchQueue(label: "ADBBonjourServiceBrowser")) {
        self.queue = queue
        self.browsers = []
        self.startedBrowserIndices = []
        self.snapshot = ADBBonjourDiscoverySnapshot(services: [])
    }

    deinit {
        cancel()
    }

    public func start(
        serviceKinds: [ADBWirelessDebuggingServiceKind] = [.connect, .pairing],
        updateHandler: @escaping UpdateHandler,
        stateHandler: @escaping StateHandler = { _ in },
        failureHandler: @escaping FailureHandler
    ) {
        cancel()

        let parameters = NWParameters.tcp
        browsers = serviceKinds.enumerated().map { index, serviceKind in
            let descriptor = NWBrowser.Descriptor.bonjour(
                type: serviceKind.bonjourType,
                domain: Self.browseDomain
            )
            let browser = NWBrowser(for: descriptor, using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.record(
                    results: results,
                    serviceKind: serviceKind,
                    updateHandler: updateHandler
                )
            }
            browser.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let failure):
                    Task { @MainActor in
                        failureHandler(ADBBonjourDiscoveryFailure(failure))
                    }
                case .waiting(let waitingError) where waitingError.isBonjourAuthorizationFailure:
                    Task { @MainActor in
                        stateHandler(.waitingForAuthorization(
                            ADBBonjourDiscoveryFailure(waitingError)
                        ))
                    }
                case .ready:
                    self?.startBrowserIfNeeded(at: index + 1)
                    Task { @MainActor in
                        stateHandler(.ready)
                    }
                default:
                    break
                }
            }
            return browser
        }
        startBrowserIfNeeded(at: 0)
    }

    public func cancel() {
        for browser in browsers {
            browser.cancel()
        }
        browsers = []
        startedBrowserIndices = []
        snapshot = ADBBonjourDiscoverySnapshot(services: [])
    }

    private func startBrowserIfNeeded(at index: Int) {
        guard browsers.indices.contains(index), startedBrowserIndices.insert(index).inserted else {
            return
        }
        // Serialize startup so iOS resolves one local-network authorization request at a time.
        browsers[index].start(queue: queue)
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

private extension ADBBonjourDiscoveryFailure {
    init(_ error: NWError) {
        if let dnsErrorCode = error.dnsErrorCode {
            self.init(
                dnsErrorCode: dnsErrorCode,
                diagnosticDescription: String(describing: error)
            )
        } else {
            self.init(
                reason: .other,
                diagnosticDescription: String(describing: error)
            )
        }
    }
}

private extension NWError {
    var dnsErrorCode: Int? {
        guard case .dns(let code) = self else {
            return nil
        }
        return Int(code)
    }

    var isBonjourAuthorizationFailure: Bool {
        guard let dnsErrorCode else {
            return false
        }
        return dnsErrorCode == -65_555 || dnsErrorCode == -65_570
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
