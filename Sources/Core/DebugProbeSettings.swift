// DebugProbeSettings.swift
// DebugProbe
//
// Created by Sun on 2025/12/02.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

/// DebugProbe 配置管理器
/// 支持多层配置优先级：运行时配置 > Info.plist > 默认值
public final class DebugProbeSettings {
    // MARK: - Singleton

    public static let shared = DebugProbeSettings()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let hubHost = "DebugProbe.hubHost"
        static let hubPort = "DebugProbe.hubPort"
        static let token = "DebugProbe.token"
        static let isEnabled = "DebugProbe.isEnabled"
        static let verboseLogging = "DebugProbe.verboseLogging"
        static let captureStackTrace = "DebugProbe.captureStackTrace"
        static let networkCaptureMode = "DebugProbe.networkCaptureMode"
        static let networkCaptureScope = "DebugProbe.networkCaptureScope"
        static let pluginEnabledStates = "DebugProbe.pluginEnabledStates"
    }

    // MARK: - Default Values
    /// 默认启用状态
    public static var defaultEnabled = true
    /// 默认主机地址 (可配置)
    public static var defaultHost = "127.0.0.1"
    /// 默认端口 (可配置)
    public static var defaultPort = 8081
    /// 默认 Token (可配置)
    public static var defaultToken = "debug-token-2025"
    /// 默认缓冲区大小
    public static var defaultMaxBufferSize = 10000
    /// 默认持久化队列大小
    public static var defaultMaxPersistenceQueueSize = 100_000
    /// 默认持久化保留天数
    public static var defaultPersistenceRetentionDays = 3

    // MARK: - Runtime Configuration (non-persisted)

    /// 事件缓冲区最大大小
    public var maxBufferSize: Int = DebugProbeSettings.defaultMaxBufferSize

    /// 是否启用事件持久化（断线时保存到本地，重连后恢复发送）
    public var enablePersistence: Bool = true

    /// 持久化队列最大大小
    public var maxPersistenceQueueSize: Int = DebugProbeSettings.defaultMaxPersistenceQueueSize

    /// 持久化事件最大保留天数
    public var persistenceRetentionDays: Int = DebugProbeSettings.defaultPersistenceRetentionDays

    // MARK: - Properties

    private let userDefaults: UserDefaults

    // MARK: - Lifecycle

    private init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        // 同步日志开关状态
        DebugLog.isEnabled = userDefaults.bool(forKey: Keys.verboseLogging)
    }

    // MARK: - Public API

    /// DebugHub 主机地址
    /// 优先级：UserDefaults > Info.plist > 默认值
    public var hubHost: String {
        get {
            // 1. 先检查运行时配置
            if let saved = userDefaults.string(forKey: Keys.hubHost), !saved.isEmpty {
                return saved
            }
            // 2. 再检查 Info.plist
            if let plistValue = Bundle.main.infoDictionary?["DEBUGHUB_HOST"] as? String, !plistValue.isEmpty {
                return plistValue
            }
            // 3. 使用默认值
            return Self.defaultHost
        }
        set {
            userDefaults.set(newValue, forKey: Keys.hubHost)
            notifyConfigChanged()
        }
    }

    /// DebugHub 端口
    public var hubPort: Int {
        get {
            let saved = userDefaults.integer(forKey: Keys.hubPort)
            if saved > 0 {
                return saved
            }
            if let plistValue = Bundle.main.infoDictionary?["DEBUGHUB_PORT"] as? Int, plistValue > 0 {
                return plistValue
            }
            return Self.defaultPort
        }
        set {
            userDefaults.set(newValue, forKey: Keys.hubPort)
            notifyConfigChanged()
        }
    }

    /// 认证 Token
    public var token: String {
        get {
            if let saved = userDefaults.string(forKey: Keys.token), !saved.isEmpty {
                return saved
            }
            if let plistValue = Bundle.main.infoDictionary?["DEBUGHUB_TOKEN"] as? String, !plistValue.isEmpty {
                return plistValue
            }
            return Self.defaultToken
        }
        set {
            userDefaults.set(newValue, forKey: Keys.token)
            notifyConfigChanged()
        }
    }

    /// 是否启用 DebugProbe（默认 true）
    public var isEnabled: Bool {
        get {
            if userDefaults.object(forKey: Keys.isEnabled) == nil {
                return Self.defaultEnabled
            }
            return userDefaults.bool(forKey: Keys.isEnabled)
        }
        set {
            userDefaults.set(newValue, forKey: Keys.isEnabled)
            notifyConfigChanged()
        }
    }

    /// 是否启用详细日志（默认 false）
    /// 启用后会输出调试级别的日志，功能启用信息不受此开关控制
    public var verboseLogging: Bool {
        get {
            userDefaults.bool(forKey: Keys.verboseLogging)
        }
        set {
            userDefaults.set(newValue, forKey: Keys.verboseLogging)
            DebugLog.isEnabled = newValue
        }
    }

    /// 是否在卡顿事件中捕获调用栈（默认 false）
    /// 注意：启用会有一定性能开销，建议仅在调试时启用
    public var captureStackTrace: Bool {
        get {
            userDefaults.bool(forKey: Keys.captureStackTrace)
        }
        set {
            userDefaults.set(newValue, forKey: Keys.captureStackTrace)
            notifyConfigChanged()
        }
    }

    // MARK: - Plugin States

    /// 获取插件启用状态
    /// - Parameter pluginId: 插件 ID
    /// - Returns: 是否启用，如果没有保存过状态则返回 nil
    public func getPluginEnabled(_ pluginId: String) -> Bool? {
        guard let states = userDefaults.dictionary(forKey: Keys.pluginEnabledStates) as? [String: Bool] else {
            return nil
        }
        return states[pluginId]
    }

    /// 设置插件启用状态
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - enabled: 是否启用
    public func setPluginEnabled(_ pluginId: String, enabled: Bool) {
        var states = (userDefaults.dictionary(forKey: Keys.pluginEnabledStates) as? [String: Bool]) ?? [:]
        states[pluginId] = enabled
        userDefaults.set(states, forKey: Keys.pluginEnabledStates)
    }

    /// 获取所有插件启用状态
    /// - Returns: 插件 ID 到启用状态的映射
    public func getAllPluginStates() -> [String: Bool] {
        (userDefaults.dictionary(forKey: Keys.pluginEnabledStates) as? [String: Bool]) ?? [:]
    }

    /// 网络捕获模式
    ///
    /// - `.automatic`（默认）: 自动拦截所有网络请求，无需修改业务代码
    /// - `.manual`: 需要手动将 protocolClasses 注入到 URLSessionConfiguration
    ///
    /// 自动模式通过 Swizzle URLSessionConfiguration 实现，对 Alamofire、
    /// 自定义 URLSession 等所有网络层都生效，是推荐的使用方式。
    public var networkCaptureMode: NetworkCaptureMode {
        get {
            if let saved = userDefaults.string(forKey: Keys.networkCaptureMode),
               let mode = NetworkCaptureMode(rawValue: saved) {
                return mode
            }
            return .automatic
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: Keys.networkCaptureMode)
            notifyConfigChanged()
        }
    }

    /// 网络捕获范围
    ///
    /// - `.http`: 仅捕获 HTTP/HTTPS 请求
    /// - `.webSocket`: 仅捕获 WebSocket 连接
    /// - `.all`（默认）: 捕获所有网络活动
    ///
    /// WebSocket 捕获仅在 `.automatic` 模式下生效
    public var networkCaptureScope: NetworkCaptureScope {
        get {
            let saved = userDefaults.integer(forKey: Keys.networkCaptureScope)
            if saved > 0 {
                return NetworkCaptureScope(rawValue: saved)
            }
            return .all
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: Keys.networkCaptureScope)
            notifyConfigChanged()
        }
    }

    /// 完整的 Hub URL
    public var hubURL: URL {
        URL(string: "ws://\(hubHost):\(hubPort)/debug-bridge")!
    }

    /// 配置摘要（用于显示，格式为 host:port）
    public var summary: String {
        "\(hubHost):\(hubPort)"
    }

    /// 连接状态详情（用于 BackdoorController 显示）
    /// 返回状态文本、状态颜色和地址信息
    public struct ConnectionStatusDetail {
        public let statusText: String
        public let isGreen: Bool
        public let isOrange: Bool
        public let isRed: Bool
        public let isGray: Bool
        public let address: String
    }

    /// 获取连接状态详情
    public var connectionStatusDetail: ConnectionStatusDetail {
        let address = "\(hubHost):\(hubPort)"

        if !isEnabled {
            return ConnectionStatusDetail(
                statusText: "未启用",
                isGreen: false,
                isOrange: false,
                isRed: false,
                isGray: true,
                address: address
            )
        }

        switch DebugProbe.shared.connectionState {
        case .disconnected:
            return ConnectionStatusDetail(
                statusText: "已断开",
                isGreen: false,
                isOrange: false,
                isRed: true,
                isGray: false,
                address: address
            )
        case .connecting:
            return ConnectionStatusDetail(
                statusText: "连接中...",
                isGreen: false,
                isOrange: true,
                isRed: false,
                isGray: false,
                address: address
            )
        case .connected:
            return ConnectionStatusDetail(
                statusText: "握手中...",
                isGreen: false,
                isOrange: true,
                isRed: false,
                isGray: false,
                address: address
            )
        case .registered:
            return ConnectionStatusDetail(
                statusText: "已连接",
                isGreen: true,
                isOrange: false,
                isRed: false,
                isGray: false,
                address: address
            )
        case .failed:
            return ConnectionStatusDetail(
                statusText: "连接失败",
                isGreen: false,
                isOrange: false,
                isRed: true,
                isGray: false,
                address: address
            )
        }
    }

    /// 连接状态摘要（用于 BackdoorController 显示）
    /// 返回两行：第一行为连接状态，第二行为 host:port
    public var statusSummary: String {
        let detail = connectionStatusDetail
        return "\(detail.statusText)\n\(detail.address)"
    }

    // MARK: - Configuration Changed Notification

    public static let configurationDidChangeNotification = Notification
        .Name("DebugProbeSettings.configurationDidChange")

    private func notifyConfigChanged() {
        NotificationCenter.default.post(name: Self.configurationDidChangeNotification, object: self)
    }

    // MARK: - Reset

    /// 重置为默认值
    public func resetToDefaults() {
        userDefaults.removeObject(forKey: Keys.hubHost)
        userDefaults.removeObject(forKey: Keys.hubPort)
        userDefaults.removeObject(forKey: Keys.token)
        userDefaults.removeObject(forKey: Keys.isEnabled)
        notifyConfigChanged()
    }

    /// 检查是否使用了自定义配置
    public var hasCustomConfiguration: Bool {
        userDefaults.string(forKey: Keys.hubHost) != nil ||
            userDefaults.integer(forKey: Keys.hubPort) > 0 ||
            userDefaults.string(forKey: Keys.token) != nil
    }

    // MARK: - Quick Configuration

    /// 快速配置（用于扫码等场景）
    public func configure(host: String, port: Int = 8081, token: String? = nil) {
        userDefaults.set(host, forKey: Keys.hubHost)
        userDefaults.set(port, forKey: Keys.hubPort)
        if let token {
            userDefaults.set(token, forKey: Keys.token)
        }
        notifyConfigChanged()
    }

    /// 从 URL 解析配置
    /// 支持格式: debughub://host:port?token=xxx
    public func configure(from url: URL) -> Bool {
        guard url.scheme == "debughub" else { return false }

        if let host = url.host, !host.isEmpty {
            hubHost = host
        }
        if url.port != nil {
            hubPort = url.port!
        }
        if
            let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "token" })?
                .value {
            self.token = token
        }
        return true
    }

    /// 生成配置 URL（用于分享或生成二维码）
    public func generateConfigURL() -> URL {
        var components = URLComponents()
        components.scheme = "debughub"
        components.host = hubHost
        components.port = hubPort
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url!
    }
}
