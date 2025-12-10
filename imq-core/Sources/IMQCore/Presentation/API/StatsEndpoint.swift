import Foundation

/// Stats API Endpoints
public enum StatsEndpoint: APIEndpoint {
    case overview
    case queueStats(queueID: String)
    case checkStats
    case githubStats

    public var method: HTTPMethod {
        return .GET
    }

    public var path: String {
        let basePath = "/stats"
        switch self {
        case .overview:
            return basePath
        case .queueStats(let queueID):
            return "\(basePath)/queues/\(queueID)"
        case .checkStats:
            return "\(basePath)/checks"
        case .githubStats:
            return "\(basePath)/github"
        }
    }

    public var version: APIVersion {
        return .v1
    }
}
