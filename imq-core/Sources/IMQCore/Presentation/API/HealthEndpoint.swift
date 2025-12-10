import Foundation

/// Health Check API Endpoints
public enum HealthEndpoint: APIEndpoint {
    case overall
    case github
    case database

    public var method: HTTPMethod {
        return .GET
    }

    public var path: String {
        let basePath = "/health"
        switch self {
        case .overall:
            return basePath
        case .github:
            return "\(basePath)/github"
        case .database:
            return "\(basePath)/database"
        }
    }

    public var version: APIVersion {
        return .v1
    }
}
