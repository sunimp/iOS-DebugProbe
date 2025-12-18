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

    public static let shared: DebugProbe = // C 语言 constructor 已自动记录启动时间，无需手动调用
        .init()

    // MARK: - Versions

    public static var version: String { "1.5.0" }

    // MARK: - Notifications

    /// 连接状态变化通知
    /// userInfo 包含 "state": ConnectionState
    public static let connectionStateDidChangeNotification = Notification.Name("DebugProbe.connectionStateDidChange")

    // MARK: - State

    public private(set) var isStarted: Bool = false

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

    /// 启动 DebugProbe
    ///
    /// 所有配置通过 `DebugProbeSettings.shared` 管理，包括：
    /// - hubHost/hubPort/token: 连接配置
    /// - networkCaptureMode: 网络捕获模式（自动/手动）
    /// - networkCaptureScope: 网络捕获范围（HTTP/WebSocket/全部）
    /// - enablePersistence: 是否启用事件持久化
    /// - 其他高级配置
    ///
    /// 配置可通过以下方式设置：
    /// - Info.plist（DEBUGHUB_HOST, DEBUGHUB_PORT, DEBUGHUB_TOKEN）
    /// - 运行时修改 `DebugProbeSettings.shared` 属性
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
    public func start() {
        let settings = DebugProbeSettings.shared

        // 检查是否禁用
        guard settings.isEnabled else {
            DebugLog.debug("DebugProbe is disabled by settings")
            return
        }

        guard !isStarted else {
            DebugLog.debug("Already started")
            return
        }

        // 配置 Bridge Client
        var bridgeConfig = DebugBridgeClient.Configuration(hubURL: settings.hubURL, token: settings.token)
        bridgeConfig.maxBufferSize = settings.maxBufferSize
        bridgeConfig.enablePersistence = settings.enablePersistence

        // 配置持久化队列
        if settings.enablePersistence {
            var persistenceConfig = EventPersistenceQueue.Configuration()
            persistenceConfig.maxQueueSize = settings.maxPersistenceQueueSize
            persistenceConfig.maxRetentionSeconds = TimeInterval(settings.persistenceRetentionDays * 24 * 3600)
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

        // 启动插件系统
        startPluginSystem()

        isStarted = true
        DebugLog.info("Started with hub: \(settings.hubURL)")
        if settings.enablePersistence {
            DebugLog.debug("Persistence enabled, max queue: \(settings.maxPersistenceQueueSize)")
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
        guard isStarted else {
            DebugLog.debug("Not started, cannot reconnect")
            return
        }

        let settings = DebugProbeSettings.shared

        DebugLog.debug("Reconnecting to \(hubURL)...")

        // 断开当前连接
        bridgeClient.disconnect()

        // 重新连接
        var bridgeConfig = DebugBridgeClient.Configuration(hubURL: hubURL, token: token)
        bridgeConfig.enablePersistence = settings.enablePersistence

        if settings.enablePersistence {
            var persistenceConfig = EventPersistenceQueue.Configuration()
            persistenceConfig.maxQueueSize = settings.maxPersistenceQueueSize
            persistenceConfig.maxRetentionSeconds = TimeInterval(settings.persistenceRetentionDays * 24 * 3600)
            bridgeConfig.persistenceConfig = persistenceConfig
        }

        bridgeClient.connect(configuration: bridgeConfig)
        DebugLog.info("Reconnected to \(hubURL)")
    }

    // MARK: - Device Info Update

    /// 通知 DebugHub 设备信息已更新（如设备别名变更）
    ///
    /// 当用户在设置界面修改了设备别名后，调用此方法将更新实时同步到 WebUI。
    /// 此方法不会重新建立连接，仅发送设备信息更新消息。
    ///
    /// 使用示例：
    /// ```swift
    /// // 在保存设备别名后调用
    /// DebugProbeSettings.shared.deviceAlias = newAlias
    /// DebugProbe.shared.notifyDeviceInfoChanged()
    /// ```
    public func notifyDeviceInfoChanged() {
        guard isStarted else {
            DebugLog.debug("Not started, cannot notify device info change")
            return
        }

        bridgeClient.sendDeviceInfoUpdate()
    }

    // MARK: - Capture Control (通过插件系统统一管理)

    /// 设置网络捕获是否启用
    /// - Parameter enabled: 是否启用
    public func setNetworkCaptureEnabled(_ enabled: Bool) {
        Task {
            await pluginManager.setPluginEnabled(BuiltinPluginId.http, enabled: enabled)
        }
    }

    /// 获取网络捕获是否启用
    public func isNetworkCaptureActive() -> Bool {
        pluginManager.isPluginEnabled(BuiltinPluginId.http)
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
        try? pluginManager.register(plugin: HttpPlugin())
        try? pluginManager.register(plugin: LogPlugin())
        try? pluginManager.register(plugin: DatabasePlugin())
        try? pluginManager.register(plugin: WebSocketPlugin())
        try? pluginManager.register(plugin: PerformancePlugin())

        // 注册调试工具插件
        try? pluginManager.register(plugin: HttpMockPlugin())
        try? pluginManager.register(plugin: HttpBreakpointPlugin())
        try? pluginManager.register(plugin: HttpChaosPlugin())

        DebugLog.info("[Plugin] \(pluginManager.getAllPlugins().count) builtin plugins registered")
    }

    /// 启动插件系统
    private func startPluginSystem() {
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

    /// 获取指定类型的插件
    /// - Parameter type: 插件类型
    /// - Returns: 插件实例（如果存在且类型匹配）
    func plugin<T: DebugProbePlugin>(ofType type: T.Type) -> T? {
        pluginManager.getAllPlugins().first { $0 is T } as? T
    }
}
