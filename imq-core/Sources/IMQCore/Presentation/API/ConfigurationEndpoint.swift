import Foundation

/// Configuration API Endpoints
public enum ConfigurationEndpoint: APIEndpoint {
    case get
    case update
    case reset

    public var method: HTTPMethod {
        switch self {
        case .get:
            return .GET
        case .update:
            return .PUT
        case .reset:
            return .POST
        }
    }

    public var path: String {
        let basePath = "/config"
        switch self {
        case .get, .update:
            return basePath
        case .reset:
            return "\(basePath)/reset"
        }
    }

    public var version: APIVersion {
        return .v1
    }
}
