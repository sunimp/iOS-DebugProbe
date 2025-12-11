// PluginProtocol.swift
// DebugProbe
//
// Created by Sun on 2025/12/09.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - 插件标识

/// 内置插件 ID 常量
public enum BuiltinPluginId {
    public static let network = "network"
    public static let log = "log"
    public static let database = "database"
    public static let webSocket = "websocket"
    public static let mock = "mock"
    public static let breakpoint = "breakpoint"
    public static let chaos = "chaos"
    public static let performance = "performance"
}

// MARK: - 插件生命周期状态

/// 插件运行状态
public enum PluginState: String, Codable, Sendable {
    case uninitialized
    case starting
    case running
    case paused
    case stopping
    case stopped
    case error
}

// MARK: - 插件事件

/// 插件级别的事件封装
/// 所有插件产生的事件都通过此结构上报
public struct PluginEvent: Codable, Sendable {
    /// 来源插件 ID
    public let pluginId: String

    /// 事件类型（由各插件自定义，如 "http_request", "log_entry"）
    public let eventType: String

    /// 事件唯一 ID
    public let eventId: String

    /// 事件时间戳
    public let timestamp: Date

    /// 事件负载数据（JSON 编码后的 Data）
    public let payload: Data

    public init(
        pluginId: String,
        eventType: String,
        eventId: String = UUID().uuidString,
        timestamp: Date = Date(),
        payload: Data
    ) {
        self.pluginId = pluginId
        self.eventType = eventType
        self.eventId = eventId
        self.timestamp = timestamp
        self.payload = payload
    }

    /// 便捷初始化：自动编码 Codable payload
    public init(
        pluginId: String,
        eventType: String,
        eventId: String = UUID().uuidString,
        timestamp: Date = Date(),
        encodable: some Encodable
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.pluginId = pluginId
        self.eventType = eventType
        self.eventId = eventId
        self.timestamp = timestamp
        payload = try encoder.encode(encodable)
    }

    /// 解码 payload 为指定类型
    public func decodePayload<T: Decodable>(as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: payload)
    }
}

// MARK: - 插件命令

/// 从服务端下发到插件的命令
public struct PluginCommand: Codable, Sendable {
    /// 目标插件 ID
    public let pluginId: String

    /// 命令类型（由各插件自定义，如 "set_config", "enable", "disable"）
    public let commandType: String

    /// 命令唯一 ID（用于响应匹配）
    public let commandId: String

    /// 命令负载数据
    public let payload: Data?

    public init(
        pluginId: String,
        commandType: String,
        commandId: String = UUID().uuidString,
        payload: Data? = nil
    ) {
        self.pluginId = pluginId
        self.commandType = commandType
        self.commandId = commandId
        self.payload = payload
    }

    /// 解码 payload 为指定类型
    public func decodePayload<T: Decodable>(as type: T.Type) throws -> T? {
        guard let payload else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: payload)
    }
}

// MARK: - 插件命令响应

/// 插件对命令的响应
public struct PluginCommandResponse: Codable, Sendable {
    /// 来源插件 ID
    public let pluginId: String

    /// 对应的命令 ID
    public let commandId: String

    /// 是否成功
    public let success: Bool

    /// 错误信息（失败时）
    public let errorMessage: String?

    /// 响应数据
    public let payload: Data?

    public init(
        pluginId: String,
        commandId: String,
        success: Bool,
        errorMessage: String? = nil,
        payload: Data? = nil
    ) {
        self.pluginId = pluginId
        self.commandId = commandId
        self.success = success
        self.errorMessage = errorMessage
        self.payload = payload
    }
}

// MARK: - 插件上下文

/// 插件运行上下文，提供插件可用的能力
public protocol PluginContext: AnyObject, Sendable {
    /// 设备 ID
    var deviceId: String { get }

    /// 设备信息
    var deviceInfo: DeviceInfo { get }

    /// 发送插件事件
    func sendEvent(_ event: PluginEvent)

    /// 发送命令响应
    func sendCommandResponse(_ response: PluginCommandResponse)

    /// 获取插件配置
    func getConfiguration<T: Decodable>(for key: String) -> T?

    /// 存储插件配置
    func setConfiguration(_ value: some Encodable, for key: String)

    /// 日志记录
    func log(_ level: PluginLogLevel, _ message: String, file: String, function: String, line: Int)
}

/// 插件日志级别
public enum PluginLogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

// MARK: - PluginContext 日志便捷方法扩展

public extension PluginContext {
    func logDebug(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(.debug, message, file: file, function: function, line: line)
    }

    func logInfo(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(.info, message, file: file, function: function, line: line)
    }

    func logWarning(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(.warning, message, file: file, function: function, line: line)
    }

    func logError(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(.error, message, file: file, function: function, line: line)
    }
}

// MARK: - 插件协议

/// 所有 DebugProbe 插件必须实现的协议
public protocol DebugProbePlugin: AnyObject, Sendable {
    /// 插件唯一 ID
    /// 必须唯一，推荐使用 BuiltinPluginId 中的常量或自定义字符串
    var pluginId: String { get }

    /// 插件显示名称
    var displayName: String { get }

    /// 插件版本
    var version: String { get }

    /// 插件描述
    var pluginDescription: String { get }

    /// 插件依赖的其他插件 ID（可选）
    /// 框架会确保依赖插件先启动
    var dependencies: [String] { get }

    /// 当前状态
    var state: PluginState { get }

    /// 插件是否已启用
    var isEnabled: Bool { get }

    /// 初始化插件
    /// - Parameter context: 插件上下文，提供与框架交互的能力
    func initialize(context: PluginContext)

    /// 启动插件
    /// 在此方法中完成资源初始化、hook 注册等
    func start() async throws

    /// 暂停插件（可选实现）
    /// 暂停数据采集但保持资源
    func pause() async

    /// 恢复插件（可选实现）
    func resume() async

    /// 停止插件
    /// 释放所有资源
    func stop() async

    /// 处理来自服务端的命令
    /// - Parameter command: 插件命令
    func handleCommand(_ command: PluginCommand) async

    /// 插件配置变更通知
    /// - Parameter key: 变更的配置键
    func onConfigurationChanged(key: String)
}

// MARK: - 默认实现

public extension DebugProbePlugin {
    var dependencies: [String] { [] }

    func pause() async {
        // 默认空实现
    }

    func resume() async {
        // 默认空实现
    }

    func onConfigurationChanged(key: String) {
        // 默认空实现
    }
}

// MARK: - 插件信息

/// 插件元信息（用于展示和注册）
public struct PluginInfo: Codable, Sendable {
    public let pluginId: String
    public let displayName: String
    public let version: String
    public let description: String
    public let dependencies: [String]
    public var state: PluginState
    public var isEnabled: Bool

    public init(from plugin: DebugProbePlugin) {
        pluginId = plugin.pluginId
        displayName = plugin.displayName
        version = plugin.version
        description = plugin.pluginDescription
        dependencies = plugin.dependencies
        state = plugin.state
        isEnabled = plugin.isEnabled
    }
}
