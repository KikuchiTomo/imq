import Vapor
import IMQCore

/// WebSocket Controller
/// Handles WebSocket connections for real-time updates
struct WebSocketController {

    /// Connected WebSocket clients
    private static var clients: [UUID: WebSocket] = [:]

    /// Handle new WebSocket connection
    static func handleConnection(_ req: Request, _ ws: WebSocket) async {
        let clientID = UUID()

        // Register client
        clients[clientID] = ws

        req.logger.info("WebSocket client connected", metadata: ["clientID": "\(clientID)"])

        // Send welcome message
        let welcomeMessage = WebSocketMessage(
            type: "connected",
            data: ["clientID": clientID.uuidString, "timestamp": Date().iso8601String]
        )

        if let jsonData = try? JSONEncoder().encode(welcomeMessage),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            try? await ws.send(jsonString)
        }

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

        // Handle connection close
        ws.onClose.whenComplete { _ in
            clients.removeValue(forKey: clientID)
            req.logger.info("WebSocket client disconnected", metadata: ["clientID": "\(clientID)"])
        }
    }

    /// Handle incoming WebSocket message
    private static func handleMessage(_ req: Request, _ ws: WebSocket, _ message: WebSocketMessage) async {
        switch message.type {
        case "ping":
            let pongMessage = WebSocketMessage(type: "pong", data: ["timestamp": Date().iso8601String])
            if let jsonData = try? JSONEncoder().encode(pongMessage),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                Task {
                    try? await ws.send(jsonString)
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

        for (_, ws) in clients {
            ws.send(jsonString)
        }
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
