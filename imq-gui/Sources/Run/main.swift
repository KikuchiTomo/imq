import Vapor
import IMQGUILib

var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)

let app = Application(env)
defer { app.shutdown() }

try configureGUI(app)
try app.run()
