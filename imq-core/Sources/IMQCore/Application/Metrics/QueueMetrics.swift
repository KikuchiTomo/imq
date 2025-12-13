import Foundation
import Logging

/// Actor-based metrics collection for queue processing
///
/// QueueMetrics tracks various performance and operational metrics for the
/// queue processor, including queue lengths, processing times, success rates,
/// and check durations. All operations are thread-safe via the actor pattern.
///
/// Example usage:
/// ```swift
/// let metrics = QueueMetrics()
///
/// await metrics.recordQueueLength(repository: repo, branch: branch, length: 5)
/// await metrics.recordProcessingTime(duration: 45.2, success: true)
/// await metrics.recordCheckDuration(checkName: "tests", duration: 30.1, status: .passed)
///
/// let summary = await metrics.getSummary()
/// print("Success rate: \(summary.successRate)%")
/// ```
public actor QueueMetrics {
    // MARK: - Types

    /// Processing result record
    private struct ProcessingRecord: Sendable {
        let timestamp: Date
        let duration: TimeInterval
        let success: Bool
        let repositoryID: String?
        let baseBranch: String?
    }

    /// Check execution record
    private struct CheckRecord: Sendable {
        let timestamp: Date
        let checkName: String
        let duration: TimeInterval
        let status: CheckStatus
    }

    /// Queue size record
    private struct QueueSizeRecord: Sendable {
        let timestamp: Date
        let repositoryID: String
        let baseBranch: String
        let length: Int
    }

    // MARK: - Properties

    /// Processing history (limited size)
    private var processingHistory: [ProcessingRecord] = []

    /// Check execution history (limited size)
    private var checkHistory: [CheckRecord] = []

    /// Queue size history (limited size)
    private var queueSizeHistory: [QueueSizeRecord] = []

    /// Maximum history size
    private let maxHistorySize: Int

    /// Logger for metrics
    private let logger: Logger

    /// Aggregated counters
    private var totalProcessed: Int = 0
    private var totalSucceeded: Int = 0
    private var totalFailed: Int = 0
    private var totalProcessingTime: TimeInterval = 0
    private var processorErrors: Int = 0
    private var forcedShutdowns: Int = 0

    // MARK: - Initialization

    /// Creates a new QueueMetrics instance
    ///
    /// - Parameters:
    ///   - maxHistorySize: Maximum number of records to keep in history
    ///   - logger: Logger for metrics operations
    public init(
        maxHistorySize: Int = 1000,
        logger: Logger = Logger(label: "imq.metrics")
    ) {
        self.maxHistorySize = maxHistorySize
        self.logger = logger
    }

    // MARK: - Recording Methods

    /// Records a queue length measurement
    ///
    /// - Parameters:
    ///   - repository: Repository for the queue
    ///   - branch: Base branch name
    ///   - length: Number of entries in the queue
    ///
    /// Example:
    /// ```swift
    /// await metrics.recordQueueLength(
    ///     repository: repo,
    ///     branch: BranchName("main"),
    ///     length: 5
    /// )
    /// ```
    public func recordQueueLength(
        repository: Repository,
        branch: BranchName,
        length: Int
    ) {
        let record = QueueSizeRecord(
            timestamp: Date(),
            repositoryID: repository.id.value,
            baseBranch: branch.value,
            length: length
        )

        queueSizeHistory.append(record)
        trimHistory(&queueSizeHistory)

        logger.trace(
            "Queue length recorded",
            metadata: [
                "repo": "\(repository.fullName)",
                "branch": "\(branch.value)",
                "length": "\(length)"
            ]
        )
    }

    /// Records a queue processing completion
    ///
    /// - Parameters:
    ///   - queue: The queue that was processed
    ///   - success: Whether processing succeeded
    ///   - duration: Processing duration in seconds
    ///
    /// Example:
    /// ```swift
    /// await metrics.recordProcessingTime(
    ///     queue: queue,
    ///     success: true,
    ///     duration: 45.2
    /// )
    /// ```
    public func recordProcessingComplete(
        _ queue: Queue,
        success: Bool,
        duration: TimeInterval
    ) {
        let record = ProcessingRecord(
            timestamp: Date(),
            duration: duration,
            success: success,
            repositoryID: queue.repository.id.value,
            baseBranch: queue.baseBranch.value
        )

        processingHistory.append(record)
        trimHistory(&processingHistory)

        // Update counters
        totalProcessed += 1
        totalProcessingTime += duration

        if success {
            totalSucceeded += 1
        } else {
            totalFailed += 1
        }

        logger.debug(
            "Processing completed",
            metadata: [
                "queue": "\(queue.id.value)",
                "success": "\(success)",
                "duration": "\(String(format: "%.2f", duration))s"
            ]
        )
    }

    /// Records a check execution
    ///
    /// - Parameters:
    ///   - checkName: Name of the check
    ///   - duration: Execution duration in seconds
    ///   - status: Final check status
    ///
    /// Example:
    /// ```swift
    /// await metrics.recordCheckDuration(
    ///     checkName: "tests",
    ///     duration: 30.5,
    ///     status: .passed
    /// )
    /// ```
    public func recordCheckDuration(
        checkName: String,
        duration: TimeInterval,
        status: CheckStatus
    ) {
        let record = CheckRecord(
            timestamp: Date(),
            checkName: checkName,
            duration: duration,
            status: status
        )

        checkHistory.append(record)
        trimHistory(&checkHistory)

        logger.trace(
            "Check duration recorded",
            metadata: [
                "check": "\(checkName)",
                "duration": "\(String(format: "%.2f", duration))s",
                "status": "\(status.rawValue)"
            ]
        )
    }

    /// Records a processor error
    public func recordProcessorError() {
        processorErrors += 1
        logger.debug("Processor error recorded", metadata: ["total": "\(processorErrors)"])
    }

    /// Records a forced shutdown event
    ///
    /// - Parameter taskCount: Number of tasks that were forcefully terminated
    public func recordForcedShutdown(taskCount: Int) {
        forcedShutdowns += 1
        logger.warning(
            "Forced shutdown recorded",
            metadata: [
                "taskCount": "\(taskCount)",
                "totalShutdowns": "\(forcedShutdowns)"
            ]
        )
    }

    // MARK: - Retrieval Methods

    /// Returns a complete metrics summary
    ///
    /// Example:
    /// ```swift
    /// let summary = await metrics.getSummary()
    /// print("Success rate: \(summary.successRate)%")
    /// print("Avg processing time: \(summary.averageProcessingTime)s")
    /// ```
    public func getSummary() -> MetricsSummary {
        MetricsSummary(
            totalProcessed: totalProcessed,
            totalSucceeded: totalSucceeded,
            totalFailed: totalFailed,
            successRate: calculateSuccessRate(),
            averageProcessingTime: calculateAverageProcessingTime(),
            totalProcessingTime: totalProcessingTime,
            processorErrors: processorErrors,
            forcedShutdowns: forcedShutdowns,
            currentQueueSizes: getCurrentQueueSizes(),
            recentCheckDurations: getRecentCheckDurations(),
            recentProcessingTimes: getRecentProcessingTimes()
        )
    }

    /// Returns current queue sizes for all monitored queues
    ///
    /// - Returns: Dictionary mapping "repo/branch" to queue length
    public func getCurrentQueueSizes() -> [String: Int] {
        // Get the most recent size for each queue
        var sizes: [String: (timestamp: Date, length: Int)] = [:]

        for record in queueSizeHistory {
            let key = "\(record.repositoryID)/\(record.baseBranch)"
            if let existing = sizes[key] {
                if record.timestamp > existing.timestamp {
                    sizes[key] = (record.timestamp, record.length)
                }
            } else {
                sizes[key] = (record.timestamp, record.length)
            }
        }

        return sizes.mapValues { $0.length }
    }

    /// Returns average check durations by check name
    ///
    /// - Parameter limit: Maximum number of recent checks to consider
    /// - Returns: Dictionary mapping check name to average duration
    public func getAverageCheckDurations(limit: Int = 100) -> [String: TimeInterval] {
        let recentChecks = Array(checkHistory.suffix(limit))

        var durationsByCheck: [String: [TimeInterval]] = [:]
        for record in recentChecks {
            durationsByCheck[record.checkName, default: []].append(record.duration)
        }

        return durationsByCheck.mapValues { durations in
            durations.reduce(0, +) / Double(durations.count)
        }
    }

    /// Returns check success rates by check name
    ///
    /// - Parameter limit: Maximum number of recent checks to consider
    /// - Returns: Dictionary mapping check name to success rate percentage
    public func getCheckSuccessRates(limit: Int = 100) -> [String: Double] {
        let recentChecks = Array(checkHistory.suffix(limit))

        var statusesByCheck: [String: [CheckStatus]] = [:]
        for record in recentChecks {
            statusesByCheck[record.checkName, default: []].append(record.status)
        }

        return statusesByCheck.mapValues { statuses in
            let passed = statuses.filter { $0 == .passed }.count
            return (Double(passed) / Double(statuses.count)) * 100.0
        }
    }

    /// Resets all metrics
    public func reset() {
        processingHistory.removeAll()
        checkHistory.removeAll()
        queueSizeHistory.removeAll()

        totalProcessed = 0
        totalSucceeded = 0
        totalFailed = 0
        totalProcessingTime = 0
        processorErrors = 0
        forcedShutdowns = 0

        logger.info("Metrics reset")
    }

    // MARK: - Private Methods

    /// Trims history array to max size
    private func trimHistory<T>(_ history: inout [T]) {
        if history.count > maxHistorySize {
            let excess = history.count - maxHistorySize
            history.removeFirst(excess)
        }
    }

    /// Calculates overall success rate
    private func calculateSuccessRate() -> Double {
        guard totalProcessed > 0 else { return 0.0 }
        return (Double(totalSucceeded) / Double(totalProcessed)) * 100.0
    }

    /// Calculates average processing time
    private func calculateAverageProcessingTime() -> TimeInterval {
        guard totalProcessed > 0 else { return 0.0 }
        return totalProcessingTime / Double(totalProcessed)
    }

    /// Gets recent check durations (last 10)
    private func getRecentCheckDurations() -> [(checkName: String, duration: TimeInterval)] {
        Array(checkHistory.suffix(10)).map { ($0.checkName, $0.duration) }
    }

    /// Gets recent processing times (last 10)
    private func getRecentProcessingTimes() -> [TimeInterval] {
        Array(processingHistory.suffix(10)).map { $0.duration }
    }
}

// MARK: - Supporting Types

/// Summary of all metrics
public struct MetricsSummary: Sendable {
    /// Total number of queues processed
    public let totalProcessed: Int

    /// Number of successful processing runs
    public let totalSucceeded: Int

    /// Number of failed processing runs
    public let totalFailed: Int

    /// Success rate as a percentage
    public let successRate: Double

    /// Average processing time in seconds
    public let averageProcessingTime: TimeInterval

    /// Total cumulative processing time
    public let totalProcessingTime: TimeInterval

    /// Number of processor errors
    public let processorErrors: Int

    /// Number of forced shutdowns
    public let forcedShutdowns: Int

    /// Current queue sizes by repository/branch
    public let currentQueueSizes: [String: Int]

    /// Recent check durations
    public let recentCheckDurations: [(checkName: String, duration: TimeInterval)]

    /// Recent processing times
    public let recentProcessingTimes: [TimeInterval]
}
