import Foundation
import Vapor

/// Generic API Response
public struct APIResponse<T: Content>: Content {
    public let success: Bool
    public let data: T?
    public let error: ErrorDTO?
    public let timestamp: Date

    public init(success: Bool, data: T?, error: ErrorDTO? = nil) {
        self.success = success
        self.data = data
        self.error = error
        self.timestamp = Date()
    }

    public static func success(_ data: T) -> APIResponse<T> {
        return APIResponse(success: true, data: data)
    }

    public static func failure(_ error: ErrorDTO) -> APIResponse<T> {
        return APIResponse(success: false, data: nil, error: error)
    }
}

/// Error Data Transfer Object
public struct ErrorDTO: Content {
    public let code: String
    public let message: String
    public let details: String?

    public init(code: String, message: String, details: String? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

/// Health Check Response
public struct HealthResponse: Content {
    public let status: String
    public let version: String
    public let uptime: TimeInterval
    public let timestamp: Date

    public init(status: String, version: String, uptime: TimeInterval) {
        self.status = status
        self.version = version
        self.uptime = uptime
        self.timestamp = Date()
    }
}

/// Stats Overview Response
public struct StatsOverviewResponse: Content {
    public let totalQueues: Int
    public let totalEntries: Int
    public let processingEntries: Int
    public let completedToday: Int
    public let failedToday: Int

    public init(totalQueues: Int, totalEntries: Int, processingEntries: Int, completedToday: Int, failedToday: Int) {
        self.totalQueues = totalQueues
        self.totalEntries = totalEntries
        self.processingEntries = processingEntries
        self.completedToday = completedToday
        self.failedToday = failedToday
    }
}

/// Configuration Response
public struct ConfigurationDTO: Content {
    public let triggerLabel: String
    public let webhookSecret: String?
    public let webhookProxyUrl: String?
    public let checkConfigurations: [String]
    public let notificationTemplates: [String]

    public init(
        triggerLabel: String,
        webhookSecret: String?,
        webhookProxyUrl: String?,
        checkConfigurations: [String],
        notificationTemplates: [String]
    ) {
        self.triggerLabel = triggerLabel
        self.webhookSecret = webhookSecret
        self.webhookProxyUrl = webhookProxyUrl
        self.checkConfigurations = checkConfigurations
        self.notificationTemplates = notificationTemplates
    }
}
