import Foundation

/// HTTP Method
public enum HTTPMethod: String {
    case GET
    case POST
    case PUT
    case PATCH
    case DELETE
}

/// API Version
public enum APIVersion: String {
    case v1 = "v1"
    case v2 = "v2"  // Future extension

    public var pathPrefix: String {
        return "/api/\(self.rawValue)"
    }
}

/// API Endpoint Protocol
/// All endpoints must conform to this protocol
public protocol APIEndpoint {
    var method: HTTPMethod { get }
    var path: String { get }
    var version: APIVersion { get }
    var fullPath: String { get }
}

/// Default implementation
public extension APIEndpoint {
    var fullPath: String {
        return "\(version.pathPrefix)\(path)"
    }
}
