// DebugEvent.swift
// DebugProbe
//
// Created by Sun on 2025/12/02.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - 顶层统一事件

/// 所有调试事件的统一枚举，便于网络传输中统一处理
public enum DebugEvent: Codable {
    case http(HTTPEvent)
    case webSocket(WSEvent)
    case log(LogEvent)
    case stats(StatsEvent)
    case performance(PerformanceEvent)

    public var timestamp: Date {
        switch self {
        case let .http(event):
            event.request.startTime
        case let .webSocket(event):
            event.timestamp
        case let .log(event):
            event.timestamp
        case let .stats(event):
            event.timestamp
        case let .performance(event):
            event.timestamp
        }
    }

    public var eventId: String {
        switch self {
        case let .http(event):
            event.request.id
        case let .webSocket(event):
            event.eventId
        case let .log(event):
            event.id
        case let .stats(event):
            event.id
        case let .performance(event):
            event.id
        }
    }
}

// MARK: - HTTP 事件

public struct HTTPEvent: Codable {
    public struct Request: Codable {
        public let id: String
        public let method: String
        public let url: String
        public let queryItems: [String: String]
        public let headers: [String: String]
        public let body: Data?
        public let startTime: Date
        public let traceId: String?

        public init(
            id: String = UUID().uuidString,
            method: String,
            url: String,
            queryItems: [String: String] = [:],
            headers: [String: String] = [:],
            body: Data? = nil,
            startTime: Date = Date(),
            traceId: String? = nil
        ) {
            self.id = id
            self.method = method
            self.url = url
            self.queryItems = queryItems
            self.headers = headers
            self.body = body
            self.startTime = startTime
            self.traceId = traceId
        }
    }

    public struct Response: Codable {
        public let statusCode: Int
        public let headers: [String: String]
        public let body: Data?
        public let endTime: Date
        public let duration: TimeInterval
        public let errorDescription: String?

        public init(
            statusCode: Int,
            headers: [String: String] = [:],
            body: Data? = nil,
            endTime: Date = Date(),
            duration: TimeInterval,
            errorDescription: String? = nil
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.endTime = endTime
            self.duration = duration
            self.errorDescription = errorDescription
        }
    }

    /// 性能时间线，基于 URLSessionTaskMetrics
    public struct Timing: Codable {
        /// DNS 解析耗时（秒）
        public let dnsLookup: TimeInterval?
        /// TCP 连接耗时（秒）
        public let tcpConnection: TimeInterval?
        /// TLS 握手耗时（秒）
        public let tlsHandshake: TimeInterval?
        /// 首字节时间 TTFB（秒）
        public let timeToFirstByte: TimeInterval?
        /// 内容下载耗时（秒）
        public let contentDownload: TimeInterval?
        /// 是否复用连接
        public let connectionReused: Bool
        /// 协议版本（如 "h2", "http/1.1"）
        public let protocolName: String?
        /// 本地地址
        public let localAddress: String?
        /// 远程地址
        public let remoteAddress: String?
        /// 请求体传输字节数
        public let requestBodyBytesSent: Int64?
        /// 响应体接收字节数
        public let responseBodyBytesReceived: Int64?

        public init(
            dnsLookup: TimeInterval? = nil,
            tcpConnection: TimeInterval? = nil,
            tlsHandshake: TimeInterval? = nil,
            timeToFirstByte: TimeInterval? = nil,
            contentDownload: TimeInterval? = nil,
            connectionReused: Bool = false,
            protocolName: String? = nil,
            localAddress: String? = nil,
            remoteAddress: String? = nil,
            requestBodyBytesSent: Int64? = nil,
            responseBodyBytesReceived: Int64? = nil
        ) {
            self.dnsLookup = dnsLookup
            self.tcpConnection = tcpConnection
            self.tlsHandshake = tlsHandshake
            self.timeToFirstByte = timeToFirstByte
            self.contentDownload = contentDownload
            self.connectionReused = connectionReused
            self.protocolName = protocolName
            self.localAddress = localAddress
            self.remoteAddress = remoteAddress
            self.requestBodyBytesSent = requestBodyBytesSent
            self.responseBodyBytesReceived = responseBodyBytesReceived
        }
    }

    /// 重放标记 header 名称
    public static let replayHeaderKey = "X-DebugProbe-Replay"

    public let request: Request
    public var response: Response?
    public let timing: Timing?
    public let isMocked: Bool
    public let mockRuleId: String?
    public let isReplay: Bool

    public init(
        request: Request,
        response: Response? = nil,
        timing: Timing? = nil,
        isMocked: Bool = false,
        mockRuleId: String? = nil,
        isReplay: Bool = false
    ) {
        self.request = request
        self.response = response
        self.timing = timing
        self.isMocked = isMocked
        self.mockRuleId = mockRuleId
        self.isReplay = isReplay
    }
}

// MARK: - WebSocket 事件

public struct WSEvent: Codable {
    public struct Session: Codable {
        public let id: String
        public let url: String
        public let requestHeaders: [String: String]
        public let subprotocols: [String]
        public let connectTime: Date
        public var disconnectTime: Date?
        public var closeCode: Int?
        public var closeReason: String?

        public init(
            id: String = UUID().uuidString,
            url: String,
            requestHeaders: [String: String] = [:],
            subprotocols: [String] = [],
            connectTime: Date = Date(),
            disconnectTime: Date? = nil,
            closeCode: Int? = nil,
            closeReason: String? = nil
        ) {
            self.id = id
            self.url = url
            self.requestHeaders = requestHeaders
            self.subprotocols = subprotocols
            self.connectTime = connectTime
            self.disconnectTime = disconnectTime
            self.closeCode = closeCode
            self.closeReason = closeReason
        }
    }

    public struct Frame: Codable {
        public enum Direction: String, Codable {
            case send
            case receive
        }

        public enum Opcode: String, Codable {
            case text
            case binary
            case ping
            case pong
            case close
        }

        public let id: String
        public let sessionId: String
        public let sessionUrl: String? // 会话 URL，用于在 session 被删除后恢复
        public let direction: Direction
        public let opcode: Opcode
        public let payload: Data
        public let payloadPreview: String?
        public let timestamp: Date
        public let isMocked: Bool
        public let mockRuleId: String?

        public init(
            id: String = UUID().uuidString,
            sessionId: String,
            sessionUrl: String? = nil,
            direction: Direction,
            opcode: Opcode,
            payload: Data,
            payloadPreview: String? = nil,
            timestamp: Date = Date(),
            isMocked: Bool = false,
            mockRuleId: String? = nil
        ) {
            self.id = id
            self.sessionId = sessionId
            self.sessionUrl = sessionUrl
            self.direction = direction
            self.opcode = opcode
            self.payload = payload
            self.payloadPreview = payloadPreview ?? String(data: payload.prefix(500), encoding: .utf8)
            self.timestamp = timestamp
            self.isMocked = isMocked
            self.mockRuleId = mockRuleId
        }
    }

    public enum Kind: Codable {
        case sessionCreated(Session)
        case sessionClosed(Session)
        case frame(Frame)
    }

    public let kind: Kind

    public var timestamp: Date {
        switch kind {
        case let .sessionCreated(session):
            session.connectTime
        case let .sessionClosed(session):
            session.disconnectTime ?? Date()
        case let .frame(frame):
            frame.timestamp
        }
    }

    public var eventId: String {
        switch kind {
        case let .sessionCreated(session):
            "session_created_\(session.id)"
        case let .sessionClosed(session):
            "session_closed_\(session.id)"
        case let .frame(frame):
            frame.id
        }
    }

    public init(kind: Kind) {
        self.kind = kind
    }
}

// MARK: - 日志事件

public struct LogEvent: Codable {
    public enum Source: String, Codable {
        case cocoaLumberjack
        case osLog
    }

    public enum Level: String, Codable, CaseIterable {
        case verbose
        case debug
        case info
        case warning
        case error

        public var emoji: String {
            switch self {
            case .verbose: "📝"
            case .debug: "🔍"
            case .info: "ℹ️"
            case .warning: "⚠️"
            case .error: "❌"
            }
        }
    }

    public let id: String
    public let source: Source
    public let timestamp: Date
    public let level: Level
    public let subsystem: String?
    public let category: String?
    public let loggerName: String?
    public let thread: String?
    public let file: String?
    public let function: String?
    public let line: Int?
    public let message: String
    public let tags: [String]
    public let traceId: String?

    public init(
        id: String = UUID().uuidString,
        source: Source,
        timestamp: Date = Date(),
        level: Level,
        subsystem: String? = nil,
        category: String? = nil,
        loggerName: String? = nil,
        thread: String? = nil,
        file: String? = nil,
        function: String? = nil,
        line: Int? = nil,
        message: String,
        tags: [String] = [],
        traceId: String? = nil
    ) {
        self.id = id
        self.source = source
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.category = category
        self.loggerName = loggerName
        self.thread = thread
        self.file = file
        self.function = function
        self.line = line
        self.message = message
        self.tags = tags
        self.traceId = traceId
    }
}

// MARK: - 统计事件

public struct StatsEvent: Codable {
    public let id: String
    public let timestamp: Date
    public let httpRequestCount: Int
    public let httpErrorCount: Int
    public let wsMessageCount: Int
    public let logCount: Int
    public let memoryUsage: UInt64
    public let cpuUsage: Double

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        httpRequestCount: Int = 0,
        httpErrorCount: Int = 0,
        wsMessageCount: Int = 0,
        logCount: Int = 0,
        memoryUsage: UInt64 = 0,
        cpuUsage: Double = 0
    ) {
        self.id = id
        self.timestamp = timestamp
        self.httpRequestCount = httpRequestCount
        self.httpErrorCount = httpErrorCount
        self.wsMessageCount = wsMessageCount
        self.logCount = logCount
        self.memoryUsage = memoryUsage
        self.cpuUsage = cpuUsage
    }
}

// MARK: - 性能事件

/// 性能监控事件
public struct PerformanceEvent: Codable, Sendable {
    /// 事件唯一 ID
    public let id: String
    /// 事件类型
    public let eventType: PerformanceEventType
    /// 时间戳
    public let timestamp: Date
    /// 性能指标批次（仅当 eventType == .metrics 时有值）
    public let metrics: [PerformanceMetricsData]?
    /// 卡顿事件（仅当 eventType == .jank 时有值）
    public let jank: JankEventData?
    /// 告警事件（仅当 eventType == .alert 时有值）
    public let alert: AlertData?

    public init(
        id: String = UUID().uuidString,
        eventType: PerformanceEventType,
        timestamp: Date = Date(),
        metrics: [PerformanceMetricsData]? = nil,
        jank: JankEventData? = nil,
        alert: AlertData? = nil
    ) {
        self.id = id
        self.eventType = eventType
        self.timestamp = timestamp
        self.metrics = metrics
        self.jank = jank
        self.alert = alert
    }
}

/// 性能事件类型
public enum PerformanceEventType: String, Codable, Sendable {
    case metrics
    case jank
    case alert
    case alertResolved
}

/// 性能指标数据（用于事件传输）
public struct PerformanceMetricsData: Codable, Sendable {
    public let timestamp: Date
    public let cpu: CPUMetricsData?
    public let memory: MemoryMetricsData?
    public let fps: FPSMetricsData?

    public init(
        timestamp: Date = Date(),
        cpu: CPUMetricsData? = nil,
        memory: MemoryMetricsData? = nil,
        fps: FPSMetricsData? = nil
    ) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.memory = memory
        self.fps = fps
    }
}

/// CPU 指标数据
public struct CPUMetricsData: Codable, Sendable {
    public let usage: Double
    public let userTime: Double
    public let systemTime: Double
    public let threadCount: Int

    public init(usage: Double, userTime: Double, systemTime: Double, threadCount: Int) {
        self.usage = usage
        self.userTime = userTime
        self.systemTime = systemTime
        self.threadCount = threadCount
    }
}

/// 内存指标数据
public struct MemoryMetricsData: Codable, Sendable {
    public let usedMemory: UInt64
    public let peakMemory: UInt64
    public let freeMemory: UInt64
    public let memoryPressure: String
    public let footprintRatio: Double

    public init(usedMemory: UInt64, peakMemory: UInt64, freeMemory: UInt64, memoryPressure: String, footprintRatio: Double) {
        self.usedMemory = usedMemory
        self.peakMemory = peakMemory
        self.freeMemory = freeMemory
        self.memoryPressure = memoryPressure
        self.footprintRatio = footprintRatio
    }
}

/// FPS 指标数据
public struct FPSMetricsData: Codable, Sendable {
    public let fps: Double
    public let droppedFrames: Int
    public let jankCount: Int
    public let averageRenderTime: Double

    public init(fps: Double, droppedFrames: Int, jankCount: Int, averageRenderTime: Double) {
        self.fps = fps
        self.droppedFrames = droppedFrames
        self.jankCount = jankCount
        self.averageRenderTime = averageRenderTime
    }
}

/// 卡顿事件数据
public struct JankEventData: Codable, Sendable {
    public let id: String
    public let timestamp: Date
    public let duration: Double
    public let droppedFrames: Int
    public let stackTrace: String?

    public init(id: String = UUID().uuidString, timestamp: Date = Date(), duration: Double, droppedFrames: Int, stackTrace: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.duration = duration
        self.droppedFrames = droppedFrames
        self.stackTrace = stackTrace
    }
}

/// 告警数据
public struct AlertData: Codable, Sendable {
    public let id: String
    public let ruleId: String
    public let metricType: String
    public let severity: String
    public let message: String
    public let currentValue: Double
    public let threshold: Double
    public let timestamp: Date
    public let isResolved: Bool
    public let resolvedAt: Date?

    public init(
        id: String = UUID().uuidString,
        ruleId: String,
        metricType: String,
        severity: String,
        message: String,
        currentValue: Double,
        threshold: Double,
        timestamp: Date = Date(),
        isResolved: Bool = false,
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.ruleId = ruleId
        self.metricType = metricType
        self.severity = severity
        self.message = message
        self.currentValue = currentValue
        self.threshold = threshold
        self.timestamp = timestamp
        self.isResolved = isResolved
        self.resolvedAt = resolvedAt
    }
}
