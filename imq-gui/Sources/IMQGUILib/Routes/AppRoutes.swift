import Vapor
import Leaf

struct PageContext: Content {
    let title: String
    let config: ConfigContext
}

/// Register web routes for the GUI.
func registerRoutes(_ app: Application, config: GUIConfiguration) throws {
    // Root dashboard
    app.get { req async throws -> View in
        let context = PageContext(title: "Dashboard", config: config.viewContext)
        return try await req.view.render("dashboard", context)
    }

    // Settings
    app.get("settings") { req async throws -> View in
        let context = PageContext(title: "Settings", config: config.viewContext)
        return try await req.view.render("settings", context)
    }

    // Health for uptime checks
    app.get("health") { _ async throws -> [String: String] in
        [
            "status": "ok",
            "service": "imq-gui",
            "version": "1.0.0"
        ]
    }
}
