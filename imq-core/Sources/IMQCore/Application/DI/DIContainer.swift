import Foundation
import AsyncHTTPClient
import Logging

/// Dependency Injection Container
/// Manages the lifecycle and wiring of all application dependencies using the actor model
/// for thread-safe lazy initialization
public actor DIContainer {
    // MARK: - Configuration

    private let config: ApplicationConfiguration

    // MARK: - Lazy Infrastructure Singletons

    private var _sqliteConnectionManager: SQLiteConnectionManager?
    private var _httpClient: HTTPClient?

    // MARK: - Lazy Repository Singletons

    private var _queueRepository: QueueRepository?
    private var _pullRequestRepository: PullRequestRepository?
    private var _repositoryRepository: RepositoryRepository?
    private var _configurationRepository: ConfigurationRepository?

    // MARK: - Lazy Gateway Singletons

    private var _githubGateway: GitHubGateway?

    // MARK: - Lazy Service Singletons

    private var _checkResultCache: CheckResultCache?
    private var _asyncSemaphore: AsyncSemaphore?
    private var _retryPolicy: RetryPolicy?
    private var _eventBus: EventBus?
    private var _queueMetrics: QueueMetrics?
    private var _fairQueueScheduler: FairQueueScheduler?
    private var _queueProcessor: QueueProcessor?

    // MARK: - Lazy Use Case Singletons

    private var _conflictDetectionUseCase: ConflictDetectionUseCase?
    private var _prUpdateUseCase: PRUpdateUseCase?
    private var _checkExecutionUseCase: CheckExecutionUseCase?
    private var _mergingUseCase: MergingUseCase?
    private var _queueProcessingUseCase: QueueProcessingUseCase?

    // MARK: - Lazy Check Execution

    private var _checkExecutorFactory: CheckExecutorFactory?

    // MARK: - Initialization

    init(config: ApplicationConfiguration) {
        self.config = config
    }

    // MARK: - Infrastructure

    func sqliteConnectionManager() async throws -> SQLiteConnectionManager {
        if let existing = _sqliteConnectionManager {
            return existing
        }

        let manager = try SQLiteConnectionManager(
            databasePath: config.databasePath,
            maxConnections: config.databasePoolSize
        )
        _sqliteConnectionManager = manager
        return manager
    }

    func httpClient() async -> HTTPClient {
        if let existing = _httpClient {
            return existing
        }

        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        _httpClient = client
        return client
    }

    func logger(label: String) -> Logger {
        var logger = Logger(label: "imq.\(label)")
        logger.logLevel = config.logLevel.swiftLogLevel
        return logger
    }

    // MARK: - Repositories

    func repositoryRepository() async throws -> RepositoryRepository {
        if let existing = _repositoryRepository {
            return existing
        }

        let db = try await sqliteConnectionManager()
        let logger = self.logger(label: "repository-repository")
        let repo = SQLiteRepositoryRepository(database: db, logger: logger)
        _repositoryRepository = repo
        return repo
    }

    func pullRequestRepository() async throws -> PullRequestRepository {
        if let existing = _pullRequestRepository {
            return existing
        }

        let db = try await sqliteConnectionManager()
        let repoRepo = try await repositoryRepository()
        let logger = self.logger(label: "pull-request-repository")
        let repo = SQLitePullRequestRepository(
            database: db,
            repositoryRepository: repoRepo,
            logger: logger
        )
        _pullRequestRepository = repo
        return repo
    }

    func queueRepository() async throws -> QueueRepository {
        if let existing = _queueRepository {
            return existing
        }

        let db = try await sqliteConnectionManager()
        let repoRepo = try await repositoryRepository()
        let prRepo = try await pullRequestRepository()
        let logger = self.logger(label: "queue-repository")
        let repo = SQLiteQueueRepository(
            database: db,
            repositoryRepository: repoRepo,
            pullRequestRepository: prRepo,
            logger: logger
        )
        _queueRepository = repo
        return repo
    }

    func configurationRepository() async throws -> ConfigurationRepository {
        if let existing = _configurationRepository {
            return existing
        }

        let db = try await sqliteConnectionManager()
        let logger = self.logger(label: "configuration-repository")
        let repo = SQLiteConfigurationRepository(database: db, logger: logger)
        _configurationRepository = repo
        return repo
    }

    // MARK: - Gateways

    func githubGateway() async throws -> GitHubGateway {
        if let existing = _githubGateway {
            return existing
        }

        let client = await httpClient()
        let logger = self.logger(label: "github-gateway")
        let gateway = GitHubGatewayImpl(
            httpClient: client,
            token: config.githubToken,
            logger: logger
        )
        _githubGateway = gateway
        return gateway
    }

    // MARK: - Check Execution

    func checkExecutorFactory() async throws -> CheckExecutorFactory {
        if let existing = _checkExecutorFactory {
            return existing
        }

        let gateway = try await githubGateway()
        let logger = self.logger(label: "check-executor-factory")
        let factory = CheckExecutorFactory(
            githubGateway: gateway,
            logger: logger
        )
        _checkExecutorFactory = factory
        return factory
    }

    // MARK: - Use Cases

    func conflictDetectionUseCase() async throws -> ConflictDetectionUseCase {
        if let existing = _conflictDetectionUseCase {
            return existing
        }

        let gateway = try await githubGateway()
        let logger = self.logger(label: "conflict-detection")
        let useCase = ConflictDetectionUseCaseImpl(
            githubGateway: gateway,
            logger: logger
        )
        _conflictDetectionUseCase = useCase
        return useCase
    }

    func prUpdateUseCase() async throws -> PRUpdateUseCase {
        if let existing = _prUpdateUseCase {
            return existing
        }

        let gateway = try await githubGateway()
        let logger = self.logger(label: "pr-update")
        let useCase = PRUpdateUseCaseImpl(
            githubGateway: gateway,
            logger: logger
        )
        _prUpdateUseCase = useCase
        return useCase
    }

    func checkExecutionUseCase() async throws -> CheckExecutionUseCase {
        if let existing = _checkExecutionUseCase {
            return existing
        }

        let factory = try await checkExecutorFactory()
        let logger = self.logger(label: "check-execution")
        let useCase = CheckExecutionUseCaseImpl(
            checkExecutorFactory: factory,
            logger: logger
        )
        _checkExecutionUseCase = useCase
        return useCase
    }

    func mergingUseCase() async throws -> MergingUseCase {
        if let existing = _mergingUseCase {
            return existing
        }

        let gateway = try await githubGateway()
        let queueRepo = try await queueRepository()
        let logger = self.logger(label: "merging")
        let useCase = MergingUseCaseImpl(
            githubGateway: gateway,
            queueRepository: queueRepo,
            logger: logger
        )
        _mergingUseCase = useCase
        return useCase
    }

    func queueProcessingUseCase() async throws -> QueueProcessingUseCase {
        if let existing = _queueProcessingUseCase {
            return existing
        }

        let queueRepo = try await queueRepository()
        let conflictDetection = try await conflictDetectionUseCase()
        let prUpdate = try await prUpdateUseCase()
        let checkExecution = try await checkExecutionUseCase()
        let merging = try await mergingUseCase()
        let logger = self.logger(label: "queue-processing")
        let useCase = QueueProcessingUseCaseImpl(
            queueRepository: queueRepo,
            conflictDetectionUseCase: conflictDetection,
            prUpdateUseCase: prUpdate,
            checkExecutionUseCase: checkExecution,
            mergingUseCase: merging,
            logger: logger
        )
        _queueProcessingUseCase = useCase
        return useCase
    }

    // MARK: - Services

    func asyncSemaphore(permits: Int) async throws -> AsyncSemaphore {
        if let existing = _asyncSemaphore {
            return existing
        }

        let semaphore = AsyncSemaphore(permits: permits)
        _asyncSemaphore = semaphore
        return semaphore
    }

    func retryPolicy() async -> RetryPolicy {
        if let existing = _retryPolicy {
            return existing
        }

        let policy = RetryPolicy.conservative
        _retryPolicy = policy
        return policy
    }

    func checkResultCache() async throws -> CheckResultCache {
        if let existing = _checkResultCache {
            return existing
        }

        let logger = self.logger(label: "check-result-cache")
        let cache = CheckResultCache(
            defaultTTL: 3600,
            maxEntries: 10000,
            logger: logger
        )
        _checkResultCache = cache
        return cache
    }

    func eventBus() async -> EventBus {
        if let existing = _eventBus {
            return existing
        }

        let logger = self.logger(label: "eventbus")
        let bus = EventBus(logger: logger)
        _eventBus = bus
        return bus
    }

    func queueMetrics() async throws -> QueueMetrics {
        if let existing = _queueMetrics {
            return existing
        }

        let logger = self.logger(label: "queue-metrics")
        let metrics = QueueMetrics(logger: logger)
        _queueMetrics = metrics
        return metrics
    }

    func fairQueueScheduler() async throws -> FairQueueScheduler {
        if let existing = _fairQueueScheduler {
            return existing
        }

        let logger = self.logger(label: "fair-queue-scheduler")
        let scheduler = FairQueueScheduler(logger: logger)
        _fairQueueScheduler = scheduler
        return scheduler
    }

    func queueProcessor() async throws -> QueueProcessor {
        if let existing = _queueProcessor {
            return existing
        }

        let queueRepo = try await queueRepository()
        let queueProcessing = try await queueProcessingUseCase()
        let scheduler = try await fairQueueScheduler()
        let metrics = try await queueMetrics()
        let retryPolicy = await self.retryPolicy()
        let logger = self.logger(label: "queue-processor")
        let processor = QueueProcessor(
            queueRepository: queueRepo,
            queueProcessingUseCase: queueProcessing,
            maxConcurrentProcessing: 3,
            retryPolicy: retryPolicy,
            metrics: metrics,
            scheduler: scheduler,
            logger: logger
        )
        _queueProcessor = processor
        return processor
    }

    // MARK: - Cleanup

    func shutdown() async {
        let logger = self.logger(label: "container")
        logger.info("Shutting down DI Container...")

        // Shutdown HTTP client
        if let httpClient = _httpClient {
            do {
                try await httpClient.shutdown()
                logger.info("HTTP client shut down")
            } catch {
                logger.error("Failed to shutdown HTTP client: \(error)")
            }
        }

        logger.info("DI Container shutdown complete")
    }
}

// MARK: - Configuration Extensions

extension LogLevel {
    var swiftLogLevel: Logger.Level {
        switch self {
        case .trace: return .trace
        case .debug: return .debug
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        case .critical: return .critical
        }
    }
}

