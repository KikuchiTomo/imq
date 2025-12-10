import Foundation
import AsyncHTTPClient
import Logging
import NIOCore
import NIOHTTP1

/// GitHub API client for making HTTP requests
/// Handles authentication, rate limiting, retries, and error handling
actor GitHubAPIClient: Sendable {
    // MARK: - Properties

    private let httpClient: HTTPClient
    private let token: String
    private let logger: Logger
    private var rateLimitRemaining: Int?
    private var rateLimitReset: Date?
    private var etags: [String: String] = [:]

    // MARK: - Configuration

    private struct RetryConfiguration {
        let maxAttempts: Int
        let baseDelay: TimeInterval
        let maxDelay: TimeInterval

        static let `default` = RetryConfiguration(
            maxAttempts: 3,
            baseDelay: 1.0,
            maxDelay: 10.0
        )
    }

    private let retryConfig = RetryConfiguration.default

    // MARK: - Initialization

    /// Initialize GitHub API client
    /// - Parameters:
    ///   - httpClient: AsyncHTTPClient instance
    ///   - token: GitHub personal access token or app token
    ///   - logger: Logger instance for structured logging
    init(httpClient: HTTPClient, token: String, logger: Logger) {
        self.httpClient = httpClient
        self.token = token
        self.logger = logger
    }

    // MARK: - Public API

    /// Execute a GET request
    /// - Parameters:
    ///   - endpoint: API endpoint to call
    ///   - useETag: Whether to use ETag for conditional requests
    /// - Returns: Response data
    func get(
        _ endpoint: GitHubAPIEndpoint,
        useETag: Bool = false
    ) async throws -> Data {
        try await executeRequest(endpoint: endpoint, body: nil, useETag: useETag)
    }

    /// Execute a POST request with JSON body
    /// - Parameters:
    ///   - endpoint: API endpoint to call
    ///   - body: Encodable body to send as JSON
    /// - Returns: Response data
    func post<T: Encodable>(
        _ endpoint: GitHubAPIEndpoint,
        body: T
    ) async throws -> Data {
        let bodyData = try JSONEncoder().encode(body)
        return try await executeRequest(endpoint: endpoint, body: bodyData, useETag: false)
    }

    /// Execute a POST request without body
    /// - Parameter endpoint: API endpoint to call
    /// - Returns: Response data
    func post(_ endpoint: GitHubAPIEndpoint) async throws -> Data {
        try await executeRequest(endpoint: endpoint, body: nil, useETag: false)
    }

    /// Execute a PUT request with JSON body
    /// - Parameters:
    ///   - endpoint: API endpoint to call
    ///   - body: Encodable body to send as JSON
    /// - Returns: Response data
    func put<T: Encodable>(
        _ endpoint: GitHubAPIEndpoint,
        body: T
    ) async throws -> Data {
        let bodyData = try JSONEncoder().encode(body)
        return try await executeRequest(endpoint: endpoint, body: bodyData, useETag: false)
    }

    /// Execute a PUT request without body
    /// - Parameter endpoint: API endpoint to call
    /// - Returns: Response data
    func put(_ endpoint: GitHubAPIEndpoint) async throws -> Data {
        try await executeRequest(endpoint: endpoint, body: nil, useETag: false)
    }

    /// Get current rate limit status
    /// - Returns: Tuple of remaining requests and reset time
    func getRateLimitStatus() -> (remaining: Int?, resetTime: Date?) {
        return (rateLimitRemaining, rateLimitReset)
    }

    // MARK: - Private Methods

    /// Execute HTTP request with retry logic
    private func executeRequest(
        endpoint: GitHubAPIEndpoint,
        body: Data?,
        useETag: Bool
    ) async throws -> Data {
        var lastError: Error?

        for attempt in 1...retryConfig.maxAttempts {
            do {
                logger.debug(
                    "Executing GitHub API request",
                    metadata: [
                        "endpoint": .string(endpoint.path),
                        "method": .string(String(describing: endpoint.method)),
                        "attempt": .stringConvertible(attempt)
                    ]
                )

                let response = try await performRequest(
                    endpoint: endpoint,
                    body: body,
                    useETag: useETag
                )

                return response
            } catch let error as GitHubAPIError {
                lastError = error

                // Don't retry certain errors
                if !shouldRetry(error) {
                    logger.error(
                        "Non-retryable GitHub API error",
                        metadata: [
                            "endpoint": .string(endpoint.path),
                            "error": .string(String(describing: error))
                        ]
                    )
                    throw error
                }

                // Calculate exponential backoff delay
                if attempt < retryConfig.maxAttempts {
                    let delay = calculateBackoffDelay(attempt: attempt)
                    logger.info(
                        "Retrying GitHub API request",
                        metadata: [
                            "endpoint": .string(endpoint.path),
                            "attempt": .stringConvertible(attempt),
                            "delay": .stringConvertible(delay)
                        ]
                    )
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        throw lastError ?? GitHubAPIError.unknown(
            NSError(domain: "GitHubAPIClient", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Request failed after \(retryConfig.maxAttempts) attempts"
            ])
        )
    }

    /// Perform single HTTP request
    private func performRequest(
        endpoint: GitHubAPIEndpoint,
        body: Data?,
        useETag: Bool
    ) async throws -> Data {
        // Build request
        var request = HTTPClientRequest(url: endpoint.url())
        request.method = convertMethod(endpoint.method)

        // Set headers
        request.headers.add(name: "Accept", value: "application/vnd.github+json")
        request.headers.add(name: "Authorization", value: "Bearer \(token)")
        request.headers.add(name: "X-GitHub-Api-Version", value: GitHubAPIVersion.v1.versionHeader)
        request.headers.add(name: "User-Agent", value: "IMQ-Core/1.0")

        // Add ETag if available and requested
        if useETag, let etag = etags[endpoint.path] {
            request.headers.add(name: "If-None-Match", value: etag)
        }

        // Add body if present
        if let body = body {
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(data: body))
        }

        // Execute request
        let response = try await httpClient.execute(request, timeout: .seconds(30))

        // Update rate limit information
        updateRateLimit(from: response.headers)

        // Handle response status
        let statusCode = Int(response.status.code)
        guard (200...299).contains(statusCode) else {
            let body = try await response.body.collect(upTo: 1024 * 1024) // 1MB limit
            let errorMessage = String(buffer: body)

            logger.error(
                "GitHub API request failed",
                metadata: [
                    "endpoint": .string(endpoint.path),
                    "status": .stringConvertible(statusCode),
                    "error": .string(errorMessage)
                ]
            )

            throw mapHTTPError(statusCode: statusCode, message: errorMessage)
        }

        // Handle 304 Not Modified (ETag match)
        if statusCode == 304 {
            return Data()
        }

        // Store ETag if present
        if let etag = response.headers.first(name: "ETag") {
            etags[endpoint.path] = etag
        }

        // Read response body
        let bodyBuffer = try await response.body.collect(upTo: 10 * 1024 * 1024) // 10MB limit
        return Data(buffer: bodyBuffer)
    }

    /// Update rate limit information from response headers
    private func updateRateLimit(from headers: HTTPHeaders) {
        if let remainingStr = headers.first(name: "X-RateLimit-Remaining"),
           let remaining = Int(remainingStr) {
            rateLimitRemaining = remaining
        }

        if let resetStr = headers.first(name: "X-RateLimit-Reset"),
           let resetTimestamp = TimeInterval(resetStr) {
            rateLimitReset = Date(timeIntervalSince1970: resetTimestamp)
        }

        // Log rate limit warnings
        if let remaining = rateLimitRemaining, remaining < 100 {
            logger.warning(
                "GitHub API rate limit running low",
                metadata: [
                    "remaining": .stringConvertible(remaining),
                    "reset": .string(rateLimitReset?.description ?? "unknown")
                ]
            )
        }
    }

    /// Map HTTP status code to GitHubAPIError
    private func mapHTTPError(statusCode: Int, message: String) -> GitHubAPIError {
        switch statusCode {
        case 401:
            return .unauthorized
        case 403:
            // Check if it's rate limit or forbidden
            if message.contains("rate limit") {
                return .rateLimitExceeded
            }
            return .forbidden
        case 404:
            return .notFound
        case 422:
            return .validationFailed(message)
        default:
            return .httpError(statusCode: statusCode, message: message)
        }
    }

    /// Determine if an error should be retried
    private func shouldRetry(_ error: GitHubAPIError) -> Bool {
        switch error {
        case .networkError:
            return true
        case .httpError(let statusCode, _):
            return statusCode >= 500
        case .rateLimitExceeded,
             .unauthorized,
             .forbidden,
             .notFound,
             .validationFailed,
             .decodingError,
             .unknown:
            return false
        }
    }

    /// Calculate exponential backoff delay with jitter
    private func calculateBackoffDelay(attempt: Int) -> TimeInterval {
        let exponentialDelay = retryConfig.baseDelay * pow(2.0, Double(attempt - 1))
        let cappedDelay = min(exponentialDelay, retryConfig.maxDelay)

        // Add jitter (±20%)
        let jitterRange = cappedDelay * 0.2
        let jitter = Double.random(in: -jitterRange...jitterRange)

        return cappedDelay + jitter
    }

    /// Convert our GitHubHTTPMethod enum to AsyncHTTPClient HTTPMethod
    private func convertMethod(_ method: GitHubHTTPMethod) -> NIOHTTP1.HTTPMethod {
        switch method {
        case .get:
            return .GET
        case .post:
            return .POST
        case .put:
            return .PUT
        case .delete:
            return .DELETE
        case .patch:
            return .PATCH
        }
    }
}
