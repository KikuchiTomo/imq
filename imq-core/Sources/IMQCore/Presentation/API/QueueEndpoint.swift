import Foundation

/// Queue API Endpoints
public enum QueueEndpoint: APIEndpoint {
    case list
    case get(id: String)
    case create
    case delete(id: String)
    case addEntry(queueID: String, prNumber: Int)
    case removeEntry(queueID: String, entryID: String)
    case getEntries(queueID: String)
    case reorder(queueID: String)

    public var method: HTTPMethod {
        switch self {
        case .list, .get, .getEntries:
            return .GET
        case .create, .addEntry:
            return .POST
        case .delete, .removeEntry:
            return .DELETE
        case .reorder:
            return .PUT
        }
    }

    public var path: String {
        let basePath = "/queues"
        switch self {
        case .list:
            return basePath
        case .get(let id):
            return "\(basePath)/\(id)"
        case .create:
            return basePath
        case .delete(let id):
            return "\(basePath)/\(id)"
        case .addEntry(let queueID, _):
            return "\(basePath)/\(queueID)/entries"
        case .removeEntry(let queueID, let entryID):
            return "\(basePath)/\(queueID)/entries/\(entryID)"
        case .getEntries(let queueID):
            return "\(basePath)/\(queueID)/entries"
        case .reorder(let queueID):
            return "\(basePath)/\(queueID)/reorder"
        }
    }

    public var version: APIVersion {
        return .v1
    }
}
