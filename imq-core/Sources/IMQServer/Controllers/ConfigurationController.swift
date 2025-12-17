import Vapor
import IMQCore

/// Configuration Controller
/// Handles configuration-related HTTP requests
struct ConfigurationController: RouteCollection {
    let repository: ConfigurationRepository

    func boot(routes: RoutesBuilder) throws {
        let config = routes.grouped("config")

        config.get(use: get)
        config.put(use: update)
        config.post("reset", use: reset)
    }

    /// GET /api/v1/config
    /// Get current configuration (merged with environment variables)
    func get(req: Request) async throws -> ConfigurationDTO {
        let config = try await repository.get()

        return ConfigurationDTO(
            triggerLabel: config.triggerLabel,
            webhookSecret: config.webhookSecret,
            webhookProxyUrl: config.webhookProxyUrl,
            checkConfigurations: parseJSONArray(config.checkConfigurations),
            notificationTemplates: parseJSONArray(config.notificationTemplates)
        )
    }

    /// PUT /api/v1/config
    /// Update configuration
    func update(req: Request) async throws -> APIResponse<ConfigurationDTO> {
        let dto = try req.content.decode(ConfigurationDTO.self)

        let config = SystemConfiguration(
            triggerLabel: dto.triggerLabel,
            webhookSecret: dto.webhookSecret, // Not saved, just passed through
            webhookProxyUrl: dto.webhookProxyUrl, // Not saved, just passed through
            checkConfigurations: serializeJSONArray(dto.checkConfigurations),
            notificationTemplates: serializeJSONArray(dto.notificationTemplates),
            updatedAt: Date()
        )

        try await repository.save(config)

        // Return updated config
        let updated = try await repository.get()
        return .success(ConfigurationDTO(
            triggerLabel: updated.triggerLabel,
            webhookSecret: updated.webhookSecret,
            webhookProxyUrl: updated.webhookProxyUrl,
            checkConfigurations: parseJSONArray(updated.checkConfigurations),
            notificationTemplates: parseJSONArray(updated.notificationTemplates)
        ))
    }

    /// POST /api/v1/config/reset
    /// Reset configuration to defaults
    func reset(req: Request) async throws -> APIResponse<String> {
        let defaultConfig = SystemConfiguration(
            triggerLabel: "A-merge",
            checkConfigurations: "[]",
            notificationTemplates: "[]"
        )

        try await repository.save(defaultConfig)

        return .success("Configuration reset to defaults")
    }

    // MARK: - Helpers

    private func parseJSONArray(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return array
    }

    private func serializeJSONArray(_ array: [String]) -> String {
        guard let data = try? JSONEncoder().encode(array),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}
