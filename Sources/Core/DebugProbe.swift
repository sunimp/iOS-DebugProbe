// DebugProbe.swift
// DebugProbe
//
// Created by Sun on 2025/12/02.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

/// Debug Probe 主入口，统一管理所有调试功能
public final class DebugProbe {
    // MARK: - Singleton

    public static let shared = DebugProbe()

    // MARK: - Configuration

    public struct Configuration {
        public let hubURL: URL
        public let token: String
        public var maxBufferSize: Int = 10000

        /// 网络捕获模式
        ///
        /// - `.automatic`（默认）: 自动拦截所有网络请求，无需修改业务代码
        /// - `.manual`: 需要手动将 protocolClasses 注入到 URLSessionConfiguration
        ///
        /// 自动模式通过 Swizzle URLSessionConfiguration 实现，对 Alamofire、
        /// 自定义 URLSession 等所有网络层都生效，是推荐的使用方式。
        public var networkCaptureMode: NetworkCaptureMode = .automatic

        /// 网络捕获范围
        ///
        /// - `.http`: 仅捕获 HTTP/HTTPS 请求
        /// - `.webSocket`: 仅捕获 WebSocket 连接
        /// - `.all`（默认）: 捕获所有网络活动
        ///
        /// WebSocket 捕获仅在 `.automatic` 模式下生效
        public var networkCaptureScope: NetworkCaptureScope = .all

        /// 是否启用事件持久化（断线时保存到本地，重连后恢复发送）
        public var enablePersistence: Bool = true

        /// 持久化队列最大大小
        public var maxPersistenceQueueSize: Int = 100_000

        /// 持久化事件最大保留天数
        public var persistenceRetentionDays: Int = 3

        public init(hubURL: URL, token: String) {
            self.hubURL = hubURL
            self.token = token
        }
    }
    
    // MARK: - Versions
    public static var version: String { "1.4.0" }

    // MARK: - Notifications

    /// 连接状态变化通知
    /// userInfo 包含 "state": ConnectionState
    public static let connectionStateDidChangeNotification = Notification.Name("DebugProbe.connectionStateDidChange")

    // MARK: - State

    public private(set) var isStarted: Bool = false
    public private(set) var configuration: Configuration?

    /// 当前连接状态（便捷访问）
    public var connectionState: DebugBridgeClient.ConnectionState {
        bridgeClient.state
    }

    // MARK: - Components

    public let bridgeClient = DebugBridgeClient()

    /// 插件管理器
    public let pluginManager = PluginManager.shared

    /// 插件桥接适配器
    private var pluginBridgeAdapter: PluginBridgeAdapter?

    // MARK: - Lifecycle

    private init() {
        setupCallbacks()
    }

    // MARK: - Setup

    private func setupCallbacks() {
        // 连接状态回调
        bridgeClient.onStateChanged = { [weak self] state in
            DebugLog.debug(.bridge, "State: \(state)")
            // 发送状态变化通知
            NotificationCenter.default.post(
                name: DebugProbe.connectionStateDidChangeNotification,
                object: self,
                userInfo: ["state": state]
            )
        }

        // 错误回调
        bridgeClient.onError = { error in
            DebugLog.error(.bridge, "Error: \(error)")
        }
    }

    // MARK: - Start / Stop

    /// 使用 DebugProbeSettings 中的配置启动 DebugProbe（推荐方式）
    ///
    /// 这是最简单的启动方式，自动从 `DebugProbeSettings.shared` 读取配置。
    /// 配置可通过以下方式设置：
    /// - Info.plist（DEBUGHUB_HOST, DEBUGHUB_PORT, DEBUGHUB_TOKEN）
    /// - 运行时修改 `DebugProbeSettings.shared.hubHost` 等属性
    /// - 调用 `DebugProbeSettings.shared.configure(host:port:token:)`
    ///
    /// 使用示例：
    /// ```swift
    /// // 简单启动（使用默认配置）
    /// DebugProbe.shared.start()
    ///
    /// // 或先修改配置再启动
    /// DebugProbeSettings.shared.configure(host: "192.168.1.100", port: 8081)
    /// DebugProbe.shared.start()
    /// ```
    ///
    /// - Parameters:
    ///   - networkCaptureMode: 网络捕获模式，默认 `.automatic`
    ///   - networkCaptureScope: 网络捕获范围，默认 `.all`
    ///   - enablePersistence: 是否启用持久化，默认 `true`
    public func start(
        networkCaptureMode: NetworkCaptureMode = .automatic,
        networkCaptureScope: NetworkCaptureScope = .all,
        enablePersistence: Bool = true
    ) {
        let settings = DebugProbeSettings.shared

        // 检查是否禁用
        guard settings.isEnabled else {
            DebugLog.debug("DebugProbe is disabled by settings")
            return
        }

        var config = Configuration(
            hubURL: settings.hubURL,
            token: settings.token
        )
        config.networkCaptureMode = networkCaptureMode
        config.networkCaptureScope = networkCaptureScope
        config.enablePersistence = enablePersistence

        start(configuration: config)
    }

    /// 启动 Debug Probe（使用自定义配置）
    ///
    /// 用于需要完全控制配置的高级场景。大多数情况下推荐使用无参数的 `start()` 方法。
    public func start(configuration: Configuration) {
        guard !isStarted else {
            DebugLog.debug("Already started")
            return
        }

        self.configuration = configuration

        // 配置 Bridge Client
        var bridgeConfig = DebugBridgeClient.Configuration(hubURL: configuration.hubURL, token: configuration.token)
        bridgeConfig.maxBufferSize = configuration.maxBufferSize
        bridgeConfig.enablePersistence = configuration.enablePersistence

        // 配置持久化队列
        if configuration.enablePersistence {
            var persistenceConfig = EventPersistenceQueue.Configuration()
            persistenceConfig.maxQueueSize = configuration.maxPersistenceQueueSize
            persistenceConfig.maxRetentionSeconds = TimeInterval(configuration.persistenceRetentionDays * 24 * 3600)
            bridgeConfig.persistenceConfig = persistenceConfig
        }

        // 连接到 Debug Hub
        bridgeClient.connect(configuration: bridgeConfig)

        // 注册并启动插件系统（所有功能通过插件管理）
        registerBuiltinPlugins()

        // 启动插件桥接适配器（先于插件启动，以便接收初始配置）
        pluginBridgeAdapter = PluginBridgeAdapter(
            pluginManager: pluginManager,
            bridgeClient: bridgeClient
        )

        // 启动插件系统（网络、日志等捕获均由插件控制）
        startPluginSystem(configuration: configuration)

        isStarted = true
        DebugLog.info("Started with hub: \(configuration.hubURL)")
        if configuration.enablePersistence {
            DebugLog.info(
                "Persistence enabled (max \(configuration.maxPersistenceQueueSize) events, \(configuration.persistenceRetentionDays) days)"
            )
        }
    }

    /// 停止 Debug Probe
    public func stop() {
        guard isStarted else { return }

        // 停止插件桥接适配器
        pluginBridgeAdapter = nil

        // 停止插件系统（会自动停止所有插件管理的功能）
        stopPluginSystem()

        bridgeClient.disconnect()
        bridgeClient.clearBuffer()

        isStarted = false
        DebugLog.info("Stopped")
    }

    /// 手动重试连接（用于连接失败后的手动恢复）
    /// 适用于连接状态为 `.failed` 时
    public func retryConnection() {
        guard isStarted else {
            DebugLog.debug("Not started, cannot retry")
            return
        }

        DebugLog.info("Manual retry connection requested")
        bridgeClient.retry()
    }

    /// 使用 DebugProbeSettings 中的配置重新连接（推荐方式）
    ///
    /// 当用户在设置界面修改了 hubHost/hubPort/token 后，调用此方法重新连接。
    /// 自动从 `DebugProbeSettings.shared` 读取最新配置。
    ///
    /// 使用示例：
    /// ```swift
    /// // 监听配置变更通知
    /// NotificationCenter.default.addObserver(
    ///     forName: DebugProbeSettings.configurationDidChangeNotification,
    ///     object: nil,
    ///     queue: .main
    /// ) { _ in
    ///     DebugProbe.shared.reconnect()
    /// }
    /// ```
    public func reconnect() {
        let settings = DebugProbeSettings.shared

        // 检查是否禁用
        guard settings.isEnabled else {
            stop()
            return
        }

        // 如果未启动，则启动
        guard isStarted else {
            start()
            return
        }

        // 已启动，使用新配置重连
        reconnect(hubURL: settings.hubURL, token: settings.token)
    }

    /// 使用新的配置重新连接
    /// 用于运行时配置变更后重新连接到新的 DebugHub
    public func reconnect(hubURL: URL, token: String) {
        guard isStarted, let config = configuration else {
            DebugLog.debug("Not started, cannot reconnect")
            return
        }

        DebugLog.debug("Reconnecting to \(hubURL)...")

        // 断开当前连接
        bridgeClient.disconnect()

        // 更新配置
        configuration = Configuration(
            hubURL: hubURL,
            token: token
        )

        // 重新连接
        var bridgeConfig = DebugBridgeClient.Configuration(hubURL: hubURL, token: token)
        bridgeConfig.enablePersistence = config.enablePersistence

        if config.enablePersistence {
            var persistenceConfig = EventPersistenceQueue.Configuration()
            persistenceConfig.maxQueueSize = config.maxPersistenceQueueSize
            persistenceConfig.maxRetentionSeconds = TimeInterval(config.persistenceRetentionDays * 24 * 3600)
            bridgeConfig.persistenceConfig = persistenceConfig
        }

        bridgeClient.connect(configuration: bridgeConfig)
        DebugLog.info("Reconnected to \(hubURL)")
    }

    // MARK: - Capture Control (通过插件系统统一管理)

    /// 设置网络捕获是否启用
    /// - Parameter enabled: 是否启用
    public func setNetworkCaptureEnabled(_ enabled: Bool) {
        Task {
            await pluginManager.setPluginEnabled(BuiltinPluginId.network, enabled: enabled)
        }
    }

    /// 获取网络捕获是否启用
    public func isNetworkCaptureActive() -> Bool {
        pluginManager.isPluginEnabled(BuiltinPluginId.network)
    }

    /// 设置日志捕获是否启用
    /// - Parameter enabled: 是否启用
    public func setLogCaptureEnabled(_ enabled: Bool) {
        Task {
            await pluginManager.setPluginEnabled(BuiltinPluginId.log, enabled: enabled)
        }
    }

    /// 获取日志捕获是否启用
    public func isLogCaptureActive() -> Bool {
        pluginManager.isPluginEnabled(BuiltinPluginId.log)
    }

    /// 设置 WebSocket 捕获是否启用
    /// - Parameter enabled: 是否启用
    public func setWebSocketCaptureEnabled(_ enabled: Bool) {
        Task {
            await pluginManager.setPluginEnabled(BuiltinPluginId.webSocket, enabled: enabled)
        }
    }

    /// 获取 WebSocket 捕获是否启用
    public func isWebSocketCaptureActive() -> Bool {
        pluginManager.isPluginEnabled(BuiltinPluginId.webSocket)
    }

    /// 设置数据库检查器是否启用
    /// - Parameter enabled: 是否启用
    public func setDatabaseInspectorEnabled(_ enabled: Bool) {
        Task {
            await pluginManager.setPluginEnabled(BuiltinPluginId.database, enabled: enabled)
        }
    }

    /// 获取数据库检查器是否启用
    public func isDatabaseInspectorActive() -> Bool {
        pluginManager.isPluginEnabled(BuiltinPluginId.database)
    }

    // MARK: - WebSocket Debug Hooks

    /// 设置 WebSocket 调试钩子的类型别名
    public typealias WSSessionCreatedHook = (_ sessionId: String, _ url: String, _ headers: [String: String]) -> Void
    public typealias WSSessionClosedHook = (_ sessionId: String, _ closeCode: Int?, _ reason: String?) -> Void
    public typealias WSMessageHook = (_ sessionId: String, _ data: Data) -> Void

    /// 获取用于注入到宿主 App 的 WebSocket 调试钩子
    ///
    /// 这些钩子使用延迟绑定，即使在 DebugProbe.start() 之前调用也能正常工作。
    /// 当实际调用钩子时，会动态查找 WebSocketPlugin 并转发事件。
    ///
    /// 使用方式（在 AppDelegate/SceneDelegate 中）：
    /// ```swift
    /// #if DEBUG
    /// import DebugProbe
    ///
    /// // 可以在 DebugProbe.start() 之前设置钩子
    /// let hooks = DebugProbe.shared.getWebSocketHooks()
    /// WebSocketDebugHooks.onSessionCreated = hooks.onSessionCreated
    /// WebSocketDebugHooks.onSessionClosed = hooks.onSessionClosed
    /// WebSocketDebugHooks.onMessageSent = hooks.onMessageSent
    /// WebSocketDebugHooks.onMessageReceived = hooks.onMessageReceived
    /// #endif
    /// ```
    public func getWebSocketHooks() -> (
        onSessionCreated: WSSessionCreatedHook,
        onSessionClosed: WSSessionClosedHook,
        onMessageSent: WSMessageHook,
        onMessageReceived: WSMessageHook
    ) {
        // 使用延迟绑定：返回的闭包在调用时动态查找 WebSocketPlugin
        // 这样即使在 DebugProbe.start() 之前设置钩子也能正常工作
        let onSessionCreated: WSSessionCreatedHook = { [weak self] sessionId, url, headers in
            guard let wsPlugin = self?.pluginManager.getPlugin(pluginId: BuiltinPluginId.webSocket) as? WebSocketPlugin
            else {
                return
            }
            wsPlugin.getHooks().onSessionCreated(sessionId, url, headers)
        }

        let onSessionClosed: WSSessionClosedHook = { [weak self] sessionId, closeCode, reason in
            guard let wsPlugin = self?.pluginManager.getPlugin(pluginId: BuiltinPluginId.webSocket) as? WebSocketPlugin
            else {
                return
            }
            wsPlugin.getHooks().onSessionClosed(sessionId, closeCode, reason)
        }

        let onMessageSent: WSMessageHook = { [weak self] sessionId, data in
            guard let wsPlugin = self?.pluginManager.getPlugin(pluginId: BuiltinPluginId.webSocket) as? WebSocketPlugin
            else {
                return
            }
            wsPlugin.getHooks().onMessageSent(sessionId, data)
        }

        let onMessageReceived: WSMessageHook = { [weak self] sessionId, data in
            guard let wsPlugin = self?.pluginManager.getPlugin(pluginId: BuiltinPluginId.webSocket) as? WebSocketPlugin
            else {
                return
            }
            wsPlugin.getHooks().onMessageReceived(sessionId, data)
        }

        return (onSessionCreated, onSessionClosed, onMessageSent, onMessageReceived)
    }

    // MARK: - Manual Event Submission

    /// 手动提交一个日志事件
    public func log(
        level: LogEvent.Level,
        message: String,
        subsystem: String? = nil,
        category: String? = nil,
        tags: [String] = [],
        traceId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let event = LogEvent(
            source: .osLog,
            level: level,
            subsystem: subsystem,
            category: category,
            thread: Thread.isMainThread ? "main" : Thread.current.description,
            file: (file as NSString).lastPathComponent,
            function: function,
            line: line,
            message: message,
            tags: tags,
            traceId: traceId
        )
        EventCallbacks.reportEvent(.log(event))
    }
}

// MARK: - Convenience Logging Methods

public extension DebugProbe {
    func debug(
        _ message: String,
        tags: [String] = [],
        traceId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(level: .debug, message: message, tags: tags, traceId: traceId, file: file, function: function, line: line)
    }

    func info(
        _ message: String,
        tags: [String] = [],
        traceId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(level: .info, message: message, tags: tags, traceId: traceId, file: file, function: function, line: line)
    }

    func warning(
        _ message: String,
        tags: [String] = [],
        traceId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(level: .warning, message: message, tags: tags, traceId: traceId, file: file, function: function, line: line)
    }

    func error(
        _ message: String,
        tags: [String] = [],
        traceId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(level: .error, message: message, tags: tags, traceId: traceId, file: file, function: function, line: line)
    }
}

// MARK: - Plugin System Extension

public extension DebugProbe {
    /// 注册内置插件
    private func registerBuiltinPlugins() {
        DebugLog.debug("[Plugin] Registering builtin plugins...")

        // 注册核心监控插件
        try? pluginManager.register(plugin: NetworkPlugin())
        try? pluginManager.register(plugin: LogPlugin())
        try? pluginManager.register(plugin: DatabasePlugin())
        try? pluginManager.register(plugin: WebSocketPlugin())
        try? pluginManager.register(plugin: PerformancePlugin())

        // 注册调试工具插件
        try? pluginManager.register(plugin: MockPlugin())
        try? pluginManager.register(plugin: BreakpointPlugin())
        try? pluginManager.register(plugin: ChaosPlugin())

        DebugLog.info("[Plugin] \(pluginManager.getAllPlugins().count) builtin plugins registered")
    }

    /// 启动插件系统
    /// - Parameter configuration: 启动配置
    private func startPluginSystem(configuration: Configuration) {
        DebugLog.debug("[Plugin] Starting plugin system...")

        // 构建设备信息
        let deviceInfo = DeviceInfoProvider.current()

        Task {
            do {
                // 启动插件系统
                try await pluginManager.startAll(deviceInfo: deviceInfo)
                // 各插件的启用/禁用由插件自身管理
            } catch {
                DebugLog.error("[Plugin] Failed to start plugin system: \(error)")
            }
        }
    }

    /// 停止插件系统
    private func stopPluginSystem() {
        DebugLog.debug("[Plugin] Stopping plugin system...")
        Task {
            await pluginManager.stopAll()
        }
    }

    /// 注册自定义插件
    /// - Parameter plugin: 符合 DebugProbePlugin 协议的插件实例
    func registerPlugin(_ plugin: DebugProbePlugin) {
        try? pluginManager.register(plugin: plugin)
    }

    /// 获取指定 ID 的插件
    /// - Parameter id: 插件 ID
    /// - Returns: 插件实例（如果存在）
    func plugin(withId id: String) -> DebugProbePlugin? {
        pluginManager.getPlugin(pluginId: id)
    }
}
