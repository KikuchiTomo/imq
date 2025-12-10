import Foundation
import Vapor

/// GUI runtime configuration loaded from environment variables.
struct GUIConfiguration {
    let host: String
    let port: Int
    let apiURL: String
    let wsURL: String
    let environment: String
    let debugMode: Bool

    /// Load configuration from environment with sensible defaults.
    static func load(from env: Environment) -> GUIConfiguration {
        GUIConfiguration(
            host: Environment.get("IMQ_GUI_HOST") ?? "0.0.0.0",
            port: Environment.get("IMQ_GUI_PORT").flatMap(Int.init) ?? 8081,
            apiURL: Environment.get("IMQ_GUI_API_URL") ?? "http://localhost:8080",
            wsURL: Environment.get("IMQ_GUI_WS_URL") ?? "ws://localhost:8080/ws/events",
            environment: Environment.get("IMQ_ENVIRONMENT") ?? env.name,
            debugMode: (Environment.get("IMQ_DEBUG") ?? "false").lowercased() == "true"
        )
    }

    /// Context passed to Leaf templates as Encodable.
    var viewContext: ConfigContext {
        ConfigContext(
            apiURL: apiURL,
            wsURL: wsURL,
            environment: environment,
            debugMode: debugMode
        )
    }
}

/// Encodable configuration context for templates.
struct ConfigContext: Content {
    let apiURL: String
    let wsURL: String
    let environment: String
    let debugMode: Bool
}
