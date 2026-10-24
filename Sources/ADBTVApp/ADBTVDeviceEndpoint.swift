import ADBClientCore
import Foundation

// One identity rule for library edits and backup/restore. Interface names are
// local routing hints and do not identify a different saved TV.
enum ADBTVDeviceEndpoint: Hashable, Sendable {
    case hostPort(String, Int)
    case bonjour(String, String, String)

    init(_ connection: ADBTVDeviceConnection) {
        switch connection {
        case let .hostPort(host, port):
            self = .hostPort(host.lowercased(), port)
        case .bonjour(let service):
            self = .bonjour(
                service.serviceName.lowercased(),
                service.serviceType.lowercased(),
                service.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            )
        }
    }
}
