import Foundation
import Logging

/// Actor-based cache for check results with TTL-based expiration
///
/// CheckResultCache provides thread-safe caching of check results to avoid
/// redundant check executions. Results are keyed by commit SHA + check name
/// and automatically expire after their TTL.
///
/// Example usage:
/// ```swift
/// let cache = CheckResultCache(defaultTTL: 3600)
///
/// // Store a result
/// await cache.set(
///     key: CacheKey(sha: sha, checkName: "tests"),
///     value: .passed,
///     ttl: 3600
/// )
///
/// // Retrieve a result
/// if let result = await cache.get(key: CacheKey(sha: sha, checkName: "tests")) {
///     // Use cached result
/// }
/// ```
public actor CheckResultCache: Sendable {
    // MARK: - Types

    /// Cache key combining commit SHA and check name
    public struct CacheKey: Hashable, Sendable {
        /// Commit SHA
        public let sha: CommitSHA

        /// Check name
        public let checkName: String

        public init(sha: CommitSHA, checkName: String) {
            self.sha = sha
            self.checkName = checkName
        }
    }

    /// Cached entry with value and expiration time
    private struct CacheEntry: Sendable {
        let value: CheckStatus
        let expiresAt: Date
        let createdAt: Date

        var isExpired: Bool {
            Date() > expiresAt
        }
    }

    // MARK: - Properties

    /// Storage for cached entries
    private var storage: [CacheKey: CacheEntry] = [:]

    /// Default TTL in seconds for cached entries
    private let defaultTTL: TimeInterval

    /// Maximum number of entries to keep in cache
    private let maxEntries: Int

    /// Logger for cache operations
    private let logger: Logger

    /// Statistics
    private var hits: Int = 0
    private var misses: Int = 0
    private var evictions: Int = 0

    // MARK: - Initialization

    /// Creates a new CheckResultCache
    ///
    /// - Parameters:
    ///   - defaultTTL: Default time-to-live in seconds for cached entries
    ///   - maxEntries: Maximum number of entries before eviction (default: 10000)
    ///   - logger: Logger for cache operations
    public init(
        defaultTTL: TimeInterval = 3600,
        maxEntries: Int = 10000,
        logger: Logger = Logger(label: "imq.cache.check-results")
    ) {
        precondition(defaultTTL > 0, "TTL must be greater than 0")
        precondition(maxEntries > 0, "Max entries must be greater than 0")

        self.defaultTTL = defaultTTL
        self.maxEntries = maxEntries
        self.logger = logger
    }

    // MARK: - Public Methods

    /// Retrieves a cached check result
    ///
    /// - Parameter key: The cache key (SHA + check name)
    /// - Returns: The cached check status, or nil if not found or expired
    ///
    /// Example:
    /// ```swift
    /// let key = CacheKey(sha: sha, checkName: "lint")
    /// if let status = await cache.get(key: key) {
    ///     // Use cached result
    /// }
    /// ```
    public func get(key: CacheKey) -> CheckStatus? {
        guard let entry = storage[key] else {
            misses += 1
            logger.trace("Cache miss for key: \(key.sha)/\(key.checkName)")
            return nil
        }

        // Check if entry is expired
        if entry.isExpired {
            storage.removeValue(forKey: key)
            misses += 1
            logger.trace("Cache entry expired for key: \(key.sha)/\(key.checkName)")
            return nil
        }

        hits += 1
        logger.trace("Cache hit for key: \(key.sha)/\(key.checkName)")
        return entry.value
    }

    /// Stores a check result in the cache
    ///
    /// - Parameters:
    ///   - key: The cache key (SHA + check name)
    ///   - value: The check status to cache
    ///   - ttl: Time-to-live in seconds (uses default if nil)
    ///
    /// Example:
    /// ```swift
    /// await cache.set(
    ///     key: CacheKey(sha: sha, checkName: "tests"),
    ///     value: .passed,
    ///     ttl: 7200
    /// )
    /// ```
    public func set(key: CacheKey, value: CheckStatus, ttl: TimeInterval? = nil) {
        let effectiveTTL = ttl ?? defaultTTL
        let expiresAt = Date().addingTimeInterval(effectiveTTL)

        let entry = CacheEntry(
            value: value,
            expiresAt: expiresAt,
            createdAt: Date()
        )

        storage[key] = entry

        logger.trace(
            "Cached check result",
            metadata: [
                "sha": "\(key.sha)",
                "check": "\(key.checkName)",
                "status": "\(value)",
                "ttl": "\(effectiveTTL)s"
            ]
        )

        // Evict oldest entries if cache is too large
        if storage.count > maxEntries {
            evictOldest()
        }
    }

    /// Invalidates a specific cache entry
    ///
    /// - Parameter key: The cache key to invalidate
    ///
    /// Example:
    /// ```swift
    /// await cache.invalidate(key: CacheKey(sha: sha, checkName: "tests"))
    /// ```
    public func invalidate(key: CacheKey) {
        if storage.removeValue(forKey: key) != nil {
            logger.debug("Invalidated cache entry: \(key.sha)/\(key.checkName)")
        }
    }

    /// Invalidates all cache entries for a specific commit SHA
    ///
    /// - Parameter sha: The commit SHA to invalidate
    ///
    /// Example:
    /// ```swift
    /// await cache.invalidateAll(for: sha)
    /// ```
    public func invalidateAll(for sha: CommitSHA) {
        let keysToRemove = storage.keys.filter { $0.sha == sha }
        for key in keysToRemove {
            storage.removeValue(forKey: key)
        }

        if !keysToRemove.isEmpty {
            logger.debug("Invalidated \(keysToRemove.count) cache entries for SHA: \(sha)")
        }
    }

    /// Clears the entire cache
    ///
    /// Example:
    /// ```swift
    /// await cache.clear()
    /// ```
    public func clear() {
        let count = storage.count
        storage.removeAll()
        logger.info("Cleared cache (\(count) entries)")
    }

    /// Removes expired entries from the cache
    ///
    /// This method is automatically called periodically, but can also be
    /// invoked manually for immediate cleanup.
    ///
    /// - Returns: Number of entries removed
    ///
    /// Example:
    /// ```swift
    /// let removed = await cache.cleanup()
    /// print("Removed \(removed) expired entries")
    /// ```
    @discardableResult
    public func cleanup() -> Int {
        let now = Date()
        let expiredKeys = storage.filter { $0.value.isExpired }.map { $0.key }

        for key in expiredKeys {
            storage.removeValue(forKey: key)
        }

        if !expiredKeys.isEmpty {
            logger.debug("Cleaned up \(expiredKeys.count) expired cache entries")
        }

        return expiredKeys.count
    }

    // MARK: - Statistics

    /// Returns cache statistics
    ///
    /// Example:
    /// ```swift
    /// let stats = await cache.statistics()
    /// print("Hit rate: \(stats.hitRate)%")
    /// ```
    public func statistics() -> CacheStatistics {
        CacheStatistics(
            size: storage.count,
            maxSize: maxEntries,
            hits: hits,
            misses: misses,
            evictions: evictions,
            hitRate: calculateHitRate()
        )
    }

    /// Resets cache statistics counters
    public func resetStatistics() {
        hits = 0
        misses = 0
        evictions = 0
        logger.debug("Reset cache statistics")
    }

    // MARK: - Private Methods

    /// Evicts oldest entries when cache exceeds max size
    private func evictOldest() {
        let targetSize = Int(Double(maxEntries) * 0.9) // Evict to 90% capacity

        // Sort by creation time and remove oldest
        let sortedKeys = storage.sorted { $0.value.createdAt < $1.value.createdAt }
        let toRemove = storage.count - targetSize

        for i in 0..<min(toRemove, sortedKeys.count) {
            storage.removeValue(forKey: sortedKeys[i].key)
            evictions += 1
        }

        logger.debug("Evicted \(toRemove) oldest cache entries")
    }

    /// Calculates cache hit rate percentage
    private func calculateHitRate() -> Double {
        let total = hits + misses
        guard total > 0 else { return 0.0 }
        return (Double(hits) / Double(total)) * 100.0
    }
}

// MARK: - Supporting Types

/// Cache statistics
public struct CacheStatistics: Sendable {
    /// Current number of entries in cache
    public let size: Int

    /// Maximum cache size
    public let maxSize: Int

    /// Number of cache hits
    public let hits: Int

    /// Number of cache misses
    public let misses: Int

    /// Number of evictions
    public let evictions: Int

    /// Hit rate percentage
    public let hitRate: Double

    /// Usage percentage
    public var usage: Double {
        guard maxSize > 0 else { return 0.0 }
        return (Double(size) / Double(maxSize)) * 100.0
    }
}
