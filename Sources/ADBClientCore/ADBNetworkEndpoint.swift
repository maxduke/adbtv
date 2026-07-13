#if canImport(Network)
@preconcurrency import Network

public struct ADBNetworkEndpoint: Equatable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    var nwEndpoint: NWEndpoint {
        .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    }
}

public enum ADBNetworkTarget: Equatable, Sendable {
    case hostPort(ADBNetworkEndpoint)
    case bonjourService(ADBDiscoveredService)

    public init(endpoint: ADBNetworkEndpoint) {
        self = .hostPort(endpoint)
    }

    var nwEndpoint: NWEndpoint {
        switch self {
        case .hostPort(let endpoint):
            return endpoint.nwEndpoint
        case .bonjourService(let service):
            return .service(
                name: service.serviceName,
                type: service.serviceType,
                domain: service.domain,
                interface: nil
            )
        }
    }
}
#endif
