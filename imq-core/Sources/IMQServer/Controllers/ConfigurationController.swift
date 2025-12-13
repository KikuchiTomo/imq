import Vapor
import IMQCore

/// Configuration Controller
/// Handles configuration-related HTTP requests
struct ConfigurationController: RouteCollection {

    func boot(routes: RoutesBuilder) throws {
        let config = routes.grouped("config")

        config.get(use: get)
        config.put(use: update)
        config.post("reset", use: reset)
    }

    /// GET /api/v1/config
    /// Get current configuration
    func get(req: Request) async throws -> ConfigurationDTO {
        // Read configuration from environment variables
        return ConfigurationDTO(
            triggerLabel: Environment.get("IMQ_TRIGGER_LABEL") ?? "A-merge",
            githubMode: Environment.get("IMQ_GITHUB_MODE") ?? "webhook",
            pollingInterval: Double(Environment.get("IMQ_POLLING_INTERVAL") ?? "60") ?? 60.0,
            webhookSecret: Environment.get("IMQ_WEBHOOK_SECRET"),
            checkConfigurations: [],
            notificationTemplates: []
        )
    }

    /// PUT /api/v1/config
    /// Update configuration
    func update(req: Request) async throws -> APIResponse<ConfigurationDTO> {
        let config = try req.content.decode(ConfigurationDTO.self)

        // Note: This is a simplified implementation
        // In production, you would save this to ConfigurationRepository
        // and update the running system configuration

        return .success(config)
    }

    /// POST /api/v1/config/reset
    /// Reset configuration to defaults
    func reset(req: Request) async throws -> APIResponse<String> {
        // TODO: Implement with ConfigurationRepository
        return .success("Configuration reset to defaults")
    }
}
