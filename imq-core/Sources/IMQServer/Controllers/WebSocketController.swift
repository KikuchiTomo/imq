import Vapor
import IMQCore

/// WebSocket Controller
/// Handles WebSocket connections for real-time updates
final class WebSocketManager {
    private var clients: [UUID: WebSocket] = [:]
    private let lock = NSLock()

    static let shared = WebSocketManager()

    func addClient(_ id: UUID, _ ws: WebSocket) {
        lock.lock()
        defer { lock.unlock() }
        clients[id] = ws
    }

    func removeClient(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        clients.removeValue(forKey: id)
    }

    func broadcast(_ jsonString: String) {
        lock.lock()
        let currentClients = clients
        lock.unlock()

        for (_, ws) in currentClients {
            ws.eventLoop.execute {
                ws.send(jsonString)
            }
        }
    }
}

struct WebSocketController {
    /// Handle new WebSocket connection
    static func handleConnection(_ req: Request, _ ws: WebSocket) {
        let clientID = UUID()

        req.logger.info("WebSocket connection starting", metadata: ["clientID": "\(clientID)"])

        // Register client
        WebSocketManager.shared.addClient(clientID, ws)
        req.logger.info("Client registered in manager", metadata: ["clientID": "\(clientID)"])

        req.logger.info("WebSocket client connected", metadata: ["clientID": "\(clientID)"])

        // Send welcome message
        let welcomeMessage = WebSocketMessage(
            type: "connected",
            data: ["clientID": clientID.uuidString, "timestamp": Date().iso8601String]
        )

        req.logger.info("Preparing to send welcome message", metadata: ["clientID": "\(clientID)"])

        if let jsonData = try? JSONEncoder().encode(welcomeMessage),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            req.logger.info("Encoded welcome message, scheduling send on eventLoop", metadata: ["clientID": "\(clientID)"])
            req.logger.info("About to call ws.eventLoop.execute", metadata: ["clientID": "\(clientID)"])

            let eventLoop = ws.eventLoop
            req.logger.info("Got ws.eventLoop reference", metadata: ["clientID": "\(clientID)"])

            eventLoop.execute {
                fflush(stdout)
                print("[DEBUG] Inside eventLoop.execute START for client: \(clientID)")
                fflush(stdout)
                ws.send(jsonString)
                fflush(stdout)
                print("[DEBUG] ws.send() completed for client: \(clientID)")
                fflush(stdout)
            }
            req.logger.info("eventLoop.execute scheduled", metadata: ["clientID": "\(clientID)"])
        }

        req.logger.info("About to register ws.onText handler", metadata: ["clientID": "\(clientID)"])

        // Handle incoming messages
        ws.onText { ws, text in
            req.logger.debug("Received WebSocket message", metadata: ["message": "\(text)"])

            // Parse and handle message
            if let data = text.data(using: .utf8),
               let message = try? JSONDecoder().decode(WebSocketMessage.self, from: data) {
                Task {
                    await handleMessage(req, ws, message)
                }
            }
        }

        req.logger.info("ws.onText handler registered", metadata: ["clientID": "\(clientID)"])
        req.logger.info("About to register ws.onClose handler", metadata: ["clientID": "\(clientID)"])

        // Handle connection close
        ws.onClose.whenComplete { _ in
            WebSocketManager.shared.removeClient(clientID)
            req.logger.info("WebSocket client disconnected", metadata: ["clientID": "\(clientID)"])
        }

        req.logger.info("ws.onClose handler registered", metadata: ["clientID": "\(clientID)"])
        req.logger.info("handleConnection completed", metadata: ["clientID": "\(clientID)"])
    }

    /// Handle incoming WebSocket message
    private static func handleMessage(_ req: Request, _ ws: WebSocket, _ message: WebSocketMessage) async {
        switch message.type {
        case "ping":
            let pongMessage = WebSocketMessage(type: "pong", data: ["timestamp": Date().iso8601String])
            if let jsonData = try? JSONEncoder().encode(pongMessage),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                ws.eventLoop.execute {
                    ws.send(jsonString)
                }
            }

        case "subscribe":
            req.logger.info("Client subscribed to events", metadata: ["data": "\(message.data)"])

        case "unsubscribe":
            req.logger.info("Client unsubscribed from events", metadata: ["data": "\(message.data)"])

        default:
            req.logger.warning("Unknown WebSocket message type", metadata: ["type": "\(message.type)"])
        }
    }

    /// Broadcast message to all connected clients
    static func broadcast(_ message: WebSocketMessage) {
        guard let jsonData = try? JSONEncoder().encode(message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        WebSocketManager.shared.broadcast(jsonString)
    }

    /// Broadcast queue event
    static func broadcastQueueEvent(_ event: QueueEvent) {
        let message = WebSocketMessage(type: "queue_event", data: event.toDictionary())
        broadcast(message)
    }

    /// Broadcast PR event
    static func broadcastPREvent(_ event: PREvent) {
        let message = WebSocketMessage(type: "pr_event", data: event.toDictionary())
        broadcast(message)
    }

    /// Broadcast check event
    static func broadcastCheckEvent(_ event: CheckEvent) {
        let message = WebSocketMessage(type: "check_event", data: event.toDictionary())
        broadcast(message)
    }
}

/// WebSocket Message
struct WebSocketMessage: Codable {
    let type: String
    let data: [String: String]
    let timestamp: String

    init(type: String, data: [String: String]) {
        self.type = type
        self.data = data
        self.timestamp = Date().iso8601String
    }
}

/// Queue Event
struct QueueEvent {
    let queueID: String
    let action: String  // added, removed, updated, reordered
    let entryID: String?

    func toDictionary() -> [String: String] {
        var dict: [String: String] = [
            "queueID": queueID,
            "action": action
        ]
        if let entryID = entryID {
            dict["entryID"] = entryID
        }
        return dict
    }
}

/// PR Event
struct PREvent {
    let prNumber: Int
    let action: String  // opened, closed, merged, updated
    let repository: String

    func toDictionary() -> [String: String] {
        return [
            "prNumber": String(prNumber),
            "action": action,
            "repository": repository
        ]
    }
}

/// Check Event
struct CheckEvent {
    let checkID: String
    let status: String  // pending, running, success, failure
    let prNumber: Int

    func toDictionary() -> [String: String] {
        return [
            "checkID": checkID,
            "status": status,
            "prNumber": String(prNumber)
        ]
    }
}
