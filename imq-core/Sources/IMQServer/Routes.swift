import Vapor
import IMQCore

/// Configure routes
func routes(_ app: Application) throws {
    // Root health check (no versioning)
    app.get("health") { req async throws -> Response in
        let response: [String: String] = [
            "status": "ok",
            "service": "imq-server",
            "version": "1.0.0"
        ]
        return try await response.encodeResponse(for: req)
    }

    // WebSocket endpoint
    app.webSocket("ws", "events") { req, ws in
        WebSocketController.handleConnection(req, ws)
    }

    // GitHub Webhook endpoint at root (receives from reverse proxy)
    try app.register(collection: WebhookController())

    // API v1 routes
    let v1 = app.grouped("api", "v1")

    // Get repositories from app storage
    guard let configRepo = app.storage[ConfigRepositoryKey.self] else {
        fatalError("ConfigurationRepository not initialized")
    }

    // Register controllers
    try v1.register(collection: QueueController())
    try v1.register(collection: ConfigurationController(repository: configRepo))
    try v1.register(collection: StatsController())
    try v1.register(collection: HealthController())

    // Catch-all for unmatched routes
    app.get("**") { _ -> Response in
        throw Abort(.notFound, reason: "Endpoint not found")
    }
}
