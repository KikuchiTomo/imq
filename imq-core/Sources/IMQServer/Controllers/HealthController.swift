import Vapor
import IMQCore

/// Health Check Controller
/// Handles health check HTTP requests
struct HealthController: RouteCollection {

    private let startTime = Date()

    func boot(routes: RoutesBuilder) throws {
        let health = routes.grouped("health")

        health.get(use: overall)
        health.get("github", use: github)
        health.get("database", use: database)
    }

    /// GET /api/v1/health
    /// Overall health check
    func overall(req: Request) async throws -> HealthResponse {
        let uptime = Date().timeIntervalSince(startTime)

        return HealthResponse(
            status: "healthy",
            version: "1.0.0",
            uptime: uptime
        )
    }

    /// GET /api/v1/health/github
    /// GitHub connection health check
    func github(req: Request) async throws -> GitHubHealthResponse {
        // TODO: Implement GitHub health check
        return GitHubHealthResponse(
            status: "healthy",
            mode: "polling",
            rateLimitRemaining: 5000,
            lastSync: Date().iso8601String
        )
    }

    /// GET /api/v1/health/database
    /// Database health check
    func database(req: Request) async throws -> DatabaseHealthResponse {
        // TODO: Implement database health check
        return DatabaseHealthResponse(
            status: "healthy",
            connectionPoolSize: 5,
            activeConnections: 1
        )
    }
}

struct GitHubHealthResponse: Content {
    let status: String
    let mode: String
    let rateLimitRemaining: Int
    let lastSync: String
}

struct DatabaseHealthResponse: Content {
    let status: String
    let connectionPoolSize: Int
    let activeConnections: Int
}

// Helper extension for Date
extension Date {
    var iso8601String: String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: self)
    }
}
