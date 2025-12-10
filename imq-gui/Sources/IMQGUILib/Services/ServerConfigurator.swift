import Vapor
import Leaf

/// Configure Vapor application for GUI server.
public func configureGUI(_ app: Application) throws {
    let guiConfig = GUIConfiguration.load(from: app.environment)

    // Server host/port
    app.http.server.configuration.hostname = guiConfig.host
    app.http.server.configuration.port = guiConfig.port

    // View rendering
    app.views.use(.leaf)
    app.leaf.configuration.rootDirectory = app.directory.workingDirectory + "Resources/Views"

    // Static files
    let publicDirectory = app.directory.workingDirectory + "Resources/Public"
    app.middleware.use(FileMiddleware(publicDirectory: publicDirectory))

    // JSON date handling
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: encoder, for: .json)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(decoder: decoder, for: .json)

    // Routes
    try registerRoutes(app, config: guiConfig)

    app.logger.info("IMQ GUI configured", metadata: [
        "host": .string(guiConfig.host),
        "port": .string("\(guiConfig.port)"),
        "apiURL": .string(guiConfig.apiURL),
        "wsURL": .string(guiConfig.wsURL)
    ])
}
