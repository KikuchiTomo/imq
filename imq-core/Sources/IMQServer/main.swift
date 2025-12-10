import Vapor
import IMQCore

var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)

let app = Application(env)
defer { app.shutdown() }

try configure(app)
try app.run()

/// Configure the Vapor application
func configure(_ app: Application) throws {
    // Configure server
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = 8080

    // Configure JSON encoder/decoder
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: encoder, for: .json)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(decoder: decoder, for: .json)

    // Configure CORS
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: .all,
        allowedMethods: [.GET, .POST, .PUT, .PATCH, .DELETE, .OPTIONS],
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith]
    )
    let cors = CORSMiddleware(configuration: corsConfiguration)
    app.middleware.use(cors)

    // Configure error middleware
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))

    // Register routes
    try routes(app)

    app.logger.info("IMQ Server configured successfully")
    app.logger.info("Server listening on http://\(app.http.server.configuration.hostname):\(app.http.server.configuration.port)")
}
