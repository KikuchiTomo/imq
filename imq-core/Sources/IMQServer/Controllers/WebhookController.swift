import Vapor
import IMQCore
import Crypto

/// Webhook Controller
/// Handles GitHub webhook events
struct WebhookController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(use: handleWebhook)
    }

    /// Handle GitHub webhook
    func handleWebhook(req: Request) async throws -> Response {
        req.logger.info("Received GitHub webhook", metadata: [
            "content-type": "\(req.headers.first(name: .contentType) ?? "none")",
            "event": "\(req.headers.first(name: "X-GitHub-Event") ?? "unknown")",
            "delivery": "\(req.headers.first(name: "X-GitHub-Delivery") ?? "unknown")"
        ])

        // Verify signature if secret is set
        if let webhookSecret = Environment.get("IMQ_WEBHOOK_SECRET"), !webhookSecret.isEmpty {
            guard try verifySignature(req: req, secret: webhookSecret) else {
                req.logger.error("Invalid webhook signature")
                throw Abort(.unauthorized, reason: "Invalid signature")
            }
        }

        // Get event type
        guard let eventType = req.headers.first(name: "X-GitHub-Event") else {
            throw Abort(.badRequest, reason: "Missing X-GitHub-Event header")
        }

        // Parse payload
        let payload = try req.content.decode(GitHubWebhookPayload.self)

        req.logger.info("Processing webhook event", metadata: [
            "event": "\(eventType)",
            "action": "\(payload.action ?? "none")",
            "repository": "\(payload.repository.fullName)"
        ])

        // Handle different event types
        switch eventType {
        case "pull_request":
            try await handlePullRequestEvent(req: req, payload: payload)
        case "pull_request_review":
            req.logger.info("Pull request review event received")
        case "check_suite", "check_run":
            req.logger.info("Check event received")
        case "status":
            req.logger.info("Status event received")
        default:
            req.logger.debug("Unhandled event type", metadata: ["event": "\(eventType)"])
        }

        return Response(status: .ok, body: .init(string: "Webhook processed"))
    }

    /// Handle pull request events
    private func handlePullRequestEvent(req: Request, payload: GitHubWebhookPayload) async throws {
        guard let pr = payload.pullRequest else {
            throw Abort(.badRequest, reason: "Missing pull_request in payload")
        }

        let action = payload.action ?? ""
        req.logger.info("Pull request event", metadata: [
            "action": "\(action)",
            "number": "\(pr.number)",
            "title": "\(pr.title)"
        ])

        // Get trigger label from configuration
        guard let configRepo = req.application.storage[ConfigRepositoryKey.self] else {
            throw Abort(.internalServerError, reason: "Configuration repository not available")
        }
        let config = try await configRepo.get()
        let triggerLabel = config.triggerLabel

        // Check if PR has trigger label
        let hasTriggerLabel = pr.labels.contains { $0.name == triggerLabel }

        guard let queueRepo = req.application.storage[QueueRepositoryKey.self],
              let prRepo = req.application.storage[PullRequestRepositoryKey.self] else {
            throw Abort(.internalServerError, reason: "Repositories not available")
        }

        switch action {
        case "labeled":
            if hasTriggerLabel {
                req.logger.info("PR labeled with trigger label, adding to queue", metadata: [
                    "pr": "\(pr.number)",
                    "label": "\(triggerLabel)"
                ])
                try await addPRToQueue(req: req, pr: pr, payload: payload, queueRepo: queueRepo, prRepo: prRepo)
            }
        case "unlabeled":
            if !hasTriggerLabel {
                req.logger.info("Trigger label removed, removing from queue", metadata: [
                    "pr": "\(pr.number)",
                    "label": "\(triggerLabel)"
                ])
                try await removePRFromQueue(req: req, prNumber: pr.number, payload: payload, queueRepo: queueRepo, prRepo: prRepo)
            }
        case "synchronize":
            if hasTriggerLabel {
                req.logger.info("PR updated, re-queuing", metadata: ["pr": "\(pr.number)"])
                try await removePRFromQueue(req: req, prNumber: pr.number, payload: payload, queueRepo: queueRepo, prRepo: prRepo)
                try await addPRToQueue(req: req, pr: pr, payload: payload, queueRepo: queueRepo, prRepo: prRepo)
            }
        case "closed":
            req.logger.info("PR closed, removing from queue", metadata: ["pr": "\(pr.number)"])
            try await removePRFromQueue(req: req, prNumber: pr.number, payload: payload, queueRepo: queueRepo, prRepo: prRepo)
        default:
            req.logger.debug("Unhandled pull_request action", metadata: ["action": "\(action)"])
        }
    }

    /// Add PR to queue
    private func addPRToQueue(
        req: Request,
        pr: GitHubWebhookPayload.PullRequest,
        payload: GitHubWebhookPayload,
        queueRepo: QueueRepository,
        prRepo: PullRequestRepository
    ) async throws {
        // Save or update PR
        let pullRequest = PullRequest(
            id: 0,
            repositoryID: payload.repository.id,
            number: pr.number,
            title: pr.title,
            headBranch: pr.head.ref,
            baseBranch: pr.base.ref,
            headSHA: pr.head.sha,
            status: .open,
            createdAt: Date(),
            updatedAt: Date()
        )
        let savedPR = try await prRepo.save(pullRequest)

        // Find or create queue for this repository
        let queues = try await queueRepo.getAll()
        var queue = queues.first { $0.repositoryID == payload.repository.id }

        if queue == nil {
            let newQueue = Queue(
                id: 0,
                repositoryID: payload.repository.id,
                status: .active,
                createdAt: Date(),
                updatedAt: Date()
            )
            queue = try await queueRepo.save(newQueue)
        }

        guard let targetQueue = queue else {
            throw Abort(.internalServerError, reason: "Failed to create queue")
        }

        // Check if PR already in queue
        let entries = try await queueRepo.getEntries(queueID: targetQueue.id)
        if entries.contains(where: { $0.pullRequestID == savedPR.id }) {
            req.logger.info("PR already in queue", metadata: ["pr": "\(pr.number)"])
            return
        }

        // Add to queue
        let nextPosition = (entries.map { $0.position }.max() ?? 0) + 1
        let entry = QueueEntry(
            id: 0,
            queueID: targetQueue.id,
            pullRequestID: savedPR.id,
            position: nextPosition,
            status: .pending,
            addedAt: Date()
        )
        let savedEntry = try await queueRepo.addEntry(entry)

        req.logger.info("PR added to queue", metadata: [
            "pr": "\(pr.number)",
            "queueID": "\(targetQueue.id)",
            "position": "\(nextPosition)"
        ])

        await WebSocketController.broadcastQueueEvent(QueueEvent(
            queueID: String(targetQueue.id),
            action: "entry_added",
            entryID: String(savedEntry.id)
        ))
    }

    /// Remove PR from queue
    private func removePRFromQueue(
        req: Request,
        prNumber: Int,
        payload: GitHubWebhookPayload,
        queueRepo: QueueRepository,
        prRepo: PullRequestRepository
    ) async throws {
        // Find PR
        guard let pr = try? await prRepo.getByNumber(repositoryID: payload.repository.id, number: prNumber) else {
            req.logger.debug("PR not found in database", metadata: ["pr": "\(prNumber)"])
            return
        }

        // Find queue
        let queues = try await queueRepo.getAll()
        guard let queue = queues.first(where: { $0.repositoryID == payload.repository.id }) else {
            req.logger.debug("Queue not found for repository", metadata: ["repo": "\(payload.repository.id)"])
            return
        }

        // Find and remove entry
        let entries = try await queueRepo.getEntries(queueID: queue.id)
        guard let entry = entries.first(where: { $0.pullRequestID == pr.id }) else {
            req.logger.debug("PR not in queue", metadata: ["pr": "\(prNumber)"])
            return
        }

        try await queueRepo.removeEntry(id: entry.id)

        req.logger.info("PR removed from queue", metadata: [
            "pr": "\(prNumber)",
            "queueID": "\(queue.id)"
        ])

        await WebSocketController.broadcastQueueEvent(QueueEvent(
            queueID: String(queue.id),
            action: "entry_removed",
            entryID: String(entry.id)
        ))
    }

    /// Verify webhook signature
    private func verifySignature(req: Request, secret: String) throws -> Bool {
        guard let signature = req.headers.first(name: "X-Hub-Signature-256") else {
            return false
        }

        guard let body = req.body.string else {
            return false
        }

        let key = SymmetricKey(data: Data(secret.utf8))
        let hmac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: key)
        let computedSignature = "sha256=" + hmac.map { String(format: "%02x", $0) }.joined()

        return signature == computedSignature
    }
}

// MARK: - DTOs

struct GitHubWebhookPayload: Content {
    let action: String?
    let repository: Repository
    let pullRequest: PullRequest?

    enum CodingKeys: String, CodingKey {
        case action
        case repository
        case pullRequest = "pull_request"
    }

    struct Repository: Content {
        let id: Int
        let name: String
        let fullName: String
        let owner: Owner

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case fullName = "full_name"
            case owner
        }

        struct Owner: Content {
            let login: String
        }
    }

    struct PullRequest: Content {
        let id: Int
        let number: Int
        let title: String
        let state: String
        let htmlUrl: String
        let head: Branch
        let base: Branch
        let labels: [Label]

        enum CodingKeys: String, CodingKey {
            case id
            case number
            case title
            case state
            case htmlUrl = "html_url"
            case head
            case base
            case labels
        }

        struct Branch: Content {
            let ref: String
            let sha: String
        }

        struct Label: Content {
            let name: String
        }
    }
}
