import Vapor
import IMQCore

/// Queue Controller
/// Handles all queue-related HTTP requests
struct QueueController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let queues = routes.grouped("queues")

        queues.get(use: list)
        queues.get(":id", use: get)
        queues.post(use: create)
        queues.delete(":id", use: delete)

        queues.get(":id", "entries", use: getEntries)
        queues.post(":id", "entries", use: addEntry)
        queues.delete(":id", "entries", ":entryID", use: removeEntry)
        queues.put(":id", "reorder", use: reorder)
    }

    /// GET /api/v1/queues
    /// List all queues
    func list(req: Request) async throws -> APIResponse<[QueueDTO]> {
        guard let queueRepo = req.application.storage[QueueRepositoryKey.self] else {
            throw Abort(.internalServerError, reason: "Queue repository not available")
        }

        let queues = try await queueRepo.getAll()
        let dtos = queues.map { queue in
            QueueDTO(
                id: queue.id,
                repositoryID: queue.repositoryID,
                status: queue.status.rawValue,
                createdAt: queue.createdAt,
                updatedAt: queue.updatedAt
            )
        }
        return .success(dtos)
    }

    /// GET /api/v1/queues/:id
    /// Get a specific queue by ID
    func get(req: Request) async throws -> APIResponse<QueueDTO> {
        guard let queueIDStr = req.parameters.get("id"),
              let queueID = Int(queueIDStr) else {
            throw Abort(.badRequest, reason: "Valid Queue ID is required")
        }

        guard let queueRepo = req.application.storage[QueueRepositoryKey.self] else {
            throw Abort(.internalServerError, reason: "Queue repository not available")
        }

        let queue = try await queueRepo.get(id: queueID)
        let dto = QueueDTO(
            id: queue.id,
            repositoryID: queue.repositoryID,
            status: queue.status.rawValue,
            createdAt: queue.createdAt,
            updatedAt: queue.updatedAt
        )
        return .success(dto)
    }

    /// POST /api/v1/queues
    /// Create a new queue
    func create(req: Request) async throws -> APIResponse<QueueDTO> {
        let createRequest = try req.content.decode(CreateQueueRequest.self)

        guard let queueRepo = req.application.storage[QueueRepositoryKey.self] else {
            throw Abort(.internalServerError, reason: "Queue repository not available")
        }

        let queue = Queue(
            id: 0,
            repositoryID: createRequest.repositoryID,
            status: .active,
            createdAt: Date(),
            updatedAt: Date()
        )

        let savedQueue = try await queueRepo.save(queue)
        let dto = QueueDTO(
            id: savedQueue.id,
            repositoryID: savedQueue.repositoryID,
            status: savedQueue.status.rawValue,
            createdAt: savedQueue.createdAt,
            updatedAt: savedQueue.updatedAt
        )

        await WebSocketController.broadcastQueueEvent(QueueEvent(
            queueID: String(savedQueue.id),
            action: "created",
            entryID: nil
        ))

        return .success(dto)
    }

    /// DELETE /api/v1/queues/:id
    /// Delete a queue
    func delete(req: Request) async throws -> APIResponse<String> {
        guard let queueIDStr = req.parameters.get("id"),
              let queueID = Int(queueIDStr) else {
            throw Abort(.badRequest, reason: "Valid Queue ID is required")
        }

        guard let queueRepo = req.application.storage[QueueRepositoryKey.self] else {
            throw Abort(.internalServerError, reason: "Queue repository not available")
        }

        try await queueRepo.delete(id: queueID)

        await WebSocketController.broadcastQueueEvent(QueueEvent(
            queueID: String(queueID),
            action: "deleted",
            entryID: nil
        ))

        return .success("Queue deleted successfully")
    }

    /// GET /api/v1/queues/:id/entries
    /// Get all entries in a queue
    func getEntries(req: Request) async throws -> APIResponse<[QueueEntryDTO]> {
        guard let queueIDStr = req.parameters.get("id"),
              let queueID = Int(queueIDStr) else {
            throw Abort(.badRequest, reason: "Valid Queue ID is required")
        }

        guard let queueRepo = req.application.storage[QueueRepositoryKey.self] else {
            throw Abort(.internalServerError, reason: "Queue repository not available")
        }

        let entries = try await queueRepo.getEntries(queueID: queueID)
        let dtos = entries.map { entry in
            QueueEntryDTO(
                id: entry.id,
                queueID: entry.queueID,
                pullRequestID: entry.pullRequestID,
                position: entry.position,
                status: entry.status.rawValue,
                addedAt: entry.addedAt
            )
        }
        return .success(dtos)
    }

    /// POST /api/v1/queues/:id/entries
    /// Add an entry to a queue
    func addEntry(req: Request) async throws -> APIResponse<QueueEntryDTO> {
        guard let queueIDStr = req.parameters.get("id"),
              let queueID = Int(queueIDStr) else {
            throw Abort(.badRequest, reason: "Valid Queue ID is required")
        }

        let addRequest = try req.content.decode(AddEntryRequest.self)

        guard let queueRepo = req.application.storage[QueueRepositoryKey.self] else {
            throw Abort(.internalServerError, reason: "Queue repository not available")
        }

        let entries = try await queueRepo.getEntries(queueID: queueID)
        let nextPosition = entries.map { $0.position }.max() ?? 0 + 1

        let entry = QueueEntry(
            id: 0,
            queueID: queueID,
            pullRequestID: addRequest.pullRequestID,
            position: nextPosition,
            status: .pending,
            addedAt: Date()
        )

        let savedEntry = try await queueRepo.addEntry(entry)
        let dto = QueueEntryDTO(
            id: savedEntry.id,
            queueID: savedEntry.queueID,
            pullRequestID: savedEntry.pullRequestID,
            position: savedEntry.position,
            status: savedEntry.status.rawValue,
            addedAt: savedEntry.addedAt
        )

        await WebSocketController.broadcastQueueEvent(QueueEvent(
            queueID: String(queueID),
            action: "entry_added",
            entryID: String(savedEntry.id)
        ))

        return .success(dto)
    }

    /// DELETE /api/v1/queues/:id/entries/:entryID
    /// Remove an entry from a queue
    func removeEntry(req: Request) async throws -> APIResponse<String> {
        guard let queueIDStr = req.parameters.get("id"),
              let queueID = Int(queueIDStr),
              let entryIDStr = req.parameters.get("entryID"),
              let entryID = Int(entryIDStr) else {
            throw Abort(.badRequest, reason: "Valid Queue ID and Entry ID are required")
        }

        guard let queueRepo = req.application.storage[QueueRepositoryKey.self] else {
            throw Abort(.internalServerError, reason: "Queue repository not available")
        }

        try await queueRepo.removeEntry(id: entryID)

        await WebSocketController.broadcastQueueEvent(QueueEvent(
            queueID: String(queueID),
            action: "entry_removed",
            entryID: String(entryID)
        ))

        return .success("Entry removed successfully")
    }

    /// PUT /api/v1/queues/:id/reorder
    /// Reorder entries in a queue
    func reorder(req: Request) async throws -> APIResponse<String> {
        guard let queueIDStr = req.parameters.get("id"),
              let queueID = Int(queueIDStr) else {
            throw Abort(.badRequest, reason: "Valid Queue ID is required")
        }

        let reorderRequest = try req.content.decode(ReorderQueueRequest.self)

        guard let queueRepo = req.application.storage[QueueRepositoryKey.self] else {
            throw Abort(.internalServerError, reason: "Queue repository not available")
        }

        try await queueRepo.reorderEntries(queueID: queueID, entryIDs: reorderRequest.entryIDs)

        await WebSocketController.broadcastQueueEvent(QueueEvent(
            queueID: String(queueID),
            action: "reordered",
            entryID: nil
        ))

        return .success("Queue reordered successfully")
    }
}

// MARK: - Storage Keys

struct QueueRepositoryKey: StorageKey {
    typealias Value = QueueRepository
}

struct PullRequestRepositoryKey: StorageKey {
    typealias Value = PullRequestRepository
}
