// PluginManager.swift
// DebugProbe
//
// Created by Sun on 2025/12/09.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - 插件管理器

/// 插件管理器，负责插件的注册、生命周期管理和消息路由
public final class PluginManager: @unchecked Sendable {
    // MARK: - Singleton

    public static let shared = PluginManager()

    // MARK: - Notifications

    /// 插件状态变化通知
    /// userInfo 包含 "pluginId": String, "state": PluginState
    public static let pluginStateDidChangeNotification = Notification.Name("DebugProbe.pluginStateDidChange")

    // MARK: - Properties

    /// 已注册的插件
    private var plugins: [String: DebugProbePlugin] = [:]

    /// 插件启动顺序（拓扑排序后）
    private var startOrder: [String] = []

    /// 线程安全锁
    private let lock = NSLock()

    /// 上下文实例
    private var context: PluginContextImpl?

    /// 是否已启动
    public private(set) var isStarted: Bool = false

    /// 插件暂停来源映射（pluginId -> PauseSource）
    /// 用于区分是 App 端禁用还是 WebUI 端暂停
    private var pauseSources: [String: PauseSource] = [:]

    // MARK: - Callbacks

    /// 插件状态变化回调
    public var onPluginStateChanged: ((String, PluginState) -> Void)?

    /// 插件事件回调（用于转发到 Bridge）
    public var onPluginEvent: ((PluginEvent) -> Void)?

    /// 插件命令响应回调
    public var onPluginCommandResponse: ((PluginCommandResponse) -> Void)?

    /// 插件启用/禁用状态变化回调（用于通知 Hub）
    public var onPluginEnabledStateChanged: ((String, Bool) -> Void)?

    // MARK: - Internal Methods

    /// 通知插件状态变化（同时触发回调和发送通知）
    private func notifyPluginStateChanged(_ pluginId: String, state: PluginState) {
        // 触发回调
        onPluginStateChanged?(pluginId, state)

        // 发送通知（在主线程）
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: PluginManager.pluginStateDidChangeNotification,
                object: self,
                userInfo: ["pluginId": pluginId, "state": state]
            )
        }
    }

    // MARK: - Lifecycle

    private init() {}

    // MARK: - Plugin Registration

    /// 注册插件
    /// - Parameter plugin: 要注册的插件实例
    /// - Throws: 如果插件 ID 已存在则抛出错误
    public func register(plugin: DebugProbePlugin) throws {
        lock.lock()
        defer { lock.unlock() }

        guard plugins[plugin.pluginId] == nil else {
            throw PluginError.duplicatePluginId(plugin.pluginId)
        }

        plugins[plugin.pluginId] = plugin
        DebugLog.info(.plugin, "Registered plugin: \(plugin.pluginId) (\(plugin.displayName))")
    }

    /// 批量注册插件
    /// - Parameter plugins: 要注册的插件列表
    public func register(plugins: [DebugProbePlugin]) throws {
        for plugin in plugins {
            try register(plugin: plugin)
        }
    }

    /// 注销插件
    /// - Parameter pluginId: 插件 ID
    public func unregister(pluginId: String) async {
        let plugin = withLock { plugins.removeValue(forKey: pluginId) }

        if let plugin {
            await plugin.stop()
            DebugLog.info(.plugin, "Unregistered plugin: \(pluginId)")
        }
    }

    /// 在锁保护下执行闭包
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// 获取插件实例
    /// - Parameter pluginId: 插件 ID
    /// - Returns: 插件实例，不存在则返回 nil
    public func getPlugin(pluginId: String) -> DebugProbePlugin? {
        withLock { plugins[pluginId] }
    }

    /// 获取所有已注册的插件
    public func getAllPlugins() -> [DebugProbePlugin] {
        withLock { Array(plugins.values) }
    }

    /// 主插件固定排序（HTTP、WebSocket、Log、Database、Performance）
    private static let mainPluginOrder: [String] = [
        BuiltinPluginId.http,
        BuiltinPluginId.webSocket,
        BuiltinPluginId.log,
        BuiltinPluginId.database,
        BuiltinPluginId.performance,
    ]

    /// 子插件固定排序（Mock、Breakpoint、Chaos）
    private static let subPluginOrder: [String] = [
        BuiltinPluginId.mock,
        BuiltinPluginId.breakpoint,
        BuiltinPluginId.chaos,
    ]

    /// 获取所有插件信息（固定排序：主插件后紧跟其子插件）
    /// 排序规则：HTTP -> Mock -> Breakpoint -> Chaos -> WebSocket -> Log -> Database -> Performance
    public func getAllPluginInfos() -> [PluginInfo] {
        let allInfos = getAllPlugins().map { plugin in
            var info = PluginInfo(from: plugin)
            // 设置暂停来源
            if plugin.state == .paused {
                info.pauseSource = withLock { pauseSources[plugin.pluginId] }
            }
            return info
        }

        // 分离主插件和子插件
        let mainInfos = allInfos.filter { !$0.isSubPlugin }
        let subInfos = allInfos.filter(\.isSubPlugin)

        // 按固定顺序排列主插件
        let sortedMain = mainInfos.sorted { a, b in
            let aIndex = Self.mainPluginOrder.firstIndex(of: a.pluginId) ?? Int.max
            let bIndex = Self.mainPluginOrder.firstIndex(of: b.pluginId) ?? Int.max
            return aIndex < bIndex
        }

        // 按固定顺序排列子插件
        let sortedSub = subInfos.sorted { a, b in
            let aIndex = Self.subPluginOrder.firstIndex(of: a.pluginId) ?? Int.max
            let bIndex = Self.subPluginOrder.firstIndex(of: b.pluginId) ?? Int.max
            return aIndex < bIndex
        }

        // 将子插件插入到其父插件后面
        var result: [PluginInfo] = []
        for main in sortedMain {
            result.append(main)
            // 添加该主插件的所有子插件
            let children = sortedSub.filter { $0.parentPluginId == main.pluginId }
            result.append(contentsOf: children)
        }

        return result
    }

    /// 获取插件的暂停来源
    public func getPauseSource(for pluginId: String) -> PauseSource? {
        withLock { pauseSources[pluginId] }
    }

    // MARK: - Lifecycle Management

    /// 初始化并启动所有插件
    /// - Parameter deviceInfo: 设备信息
    public func startAll(deviceInfo: DeviceInfo) async throws {
        guard !isStarted else {
            DebugLog.warning(.plugin, "PluginManager already started")
            return
        }

        // 创建上下文
        context = PluginContextImpl(
            deviceInfo: deviceInfo,
            onEvent: { [weak self] event in
                self?.onPluginEvent?(event)
            },
            onCommandResponse: { [weak self] response in
                self?.onPluginCommandResponse?(response)
            }
        )

        // 加载保存的插件启用状态
        let savedStates = DebugProbeSettings.shared.getAllPluginStates()

        // 在初始化前，将保存的状态写入配置上下文
        // 这样插件在 initialize() 中可以读取并应用保存的状态
        for (pluginId, enabled) in savedStates {
            context?.setConfiguration(enabled, for: "\(pluginId).enabled")
        }

        // 拓扑排序确定启动顺序
        try resolveStartOrder()

        // 按顺序初始化和启动插件
        for pluginId in startOrder {
            guard let plugin = plugins[pluginId], let context else { continue }

            DebugLog.info(.plugin, "Initializing plugin: \(pluginId)")

            // 初始化（插件会从配置中读取 enabled 状态）
            plugin.initialize(context: context)

            // 检查保存的状态，如果保存状态为禁用，则不启动
            if let savedEnabled = savedStates[pluginId], !savedEnabled {
                DebugLog.info(.plugin, "Plugin \(pluginId) is disabled by saved state, skipping start")
                // 插件已在 initialize() 中设置 isEnabled = false
                continue
            }

            // 启动
            do {
                try await plugin.start()
                DebugLog.info(.plugin, "Plugin started: \(pluginId)")
                notifyPluginStateChanged(pluginId, state: .running)
            } catch {
                DebugLog.error(.plugin, "Failed to start plugin \(pluginId): \(error)")
                notifyPluginStateChanged(pluginId, state: .error)
                throw PluginError.startFailed(pluginId, error)
            }
        }

        isStarted = true
        DebugLog.info(.plugin, "All plugins started (\(startOrder.count) plugins)")
    }

    /// 停止所有插件
    public func stopAll() async {
        guard isStarted else { return }

        // 逆序停止
        for pluginId in startOrder.reversed() {
            guard let plugin = plugins[pluginId] else { continue }

            DebugLog.info(.plugin, "Stopping plugin: \(pluginId)")
            await plugin.stop()
            notifyPluginStateChanged(pluginId, state: .stopped)
        }

        isStarted = false
        context = nil
        DebugLog.info(.plugin, "All plugins stopped")
    }

    /// 暂停所有插件
    public func pauseAll() async {
        for pluginId in startOrder {
            guard let plugin = plugins[pluginId] else { continue }
            await plugin.pause()
            notifyPluginStateChanged(pluginId, state: .paused)
        }
    }

    /// 恢复所有插件
    public func resumeAll() async {
        for pluginId in startOrder {
            guard let plugin = plugins[pluginId] else { continue }
            await plugin.resume()
            notifyPluginStateChanged(pluginId, state: .running)
        }
    }

    // MARK: - Plugin Control

    /// 启用或禁用指定插件（App 端调用）
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - enabled: 是否启用
    public func setPluginEnabled(_ pluginId: String, enabled: Bool) async {
        guard let plugin = getPlugin(pluginId: pluginId) else {
            DebugLog.warning(.plugin, "Cannot set enabled state: plugin not found: \(pluginId)")
            return
        }

        let previousEnabled = plugin.isEnabled
        var newState: PluginState?

        if enabled {
            // 根据当前状态决定如何启用插件
            switch plugin.state {
            case .paused:
                // 从暂停状态恢复
                _ = withLock { pauseSources.removeValue(forKey: pluginId) }
                await plugin.resume()
                newState = .running

            case .stopped, .uninitialized:
                // 从停止或未初始化状态启动
                do {
                    try await plugin.start()
                    newState = .running
                } catch {
                    DebugLog.error(.plugin, "Failed to start plugin \(pluginId): \(error)")
                    newState = .error
                }

            case .running, .starting, .stopping, .error:
                // 已经在运行或正在转换状态，不需要操作
                break
            }

            // 启用父插件时，同时启用所有子插件
            let childPluginIds = getChildPluginIds(for: pluginId)
            for childId in childPluginIds {
                await enableChildPlugin(childId)
            }
        } else {
            // 禁用插件（暂停而非完全停止，保留状态）
            if plugin.state == .running {
                // 设置暂停来源为 App
                withLock { pauseSources[pluginId] = .app }
                await plugin.pause()
                newState = .paused
            }
        }

        // 检查是否需要更新持久化设置
        // 注意：不能依赖 plugin.isEnabled，因为 start() 方法不会修改它
        // 而是根据新的状态来判断是否启用
        let actualEnabled = newState == .running || (enabled && plugin.state == .running)
        let currentPersisted = DebugProbeSettings.shared.getPluginEnabled(pluginId) ?? true
        if currentPersisted != actualEnabled {
            // 持久化到 UserDefaults
            DebugProbeSettings.shared.setPluginEnabled(pluginId, enabled: actualEnabled)
            // 通知 Hub
            onPluginEnabledStateChanged?(pluginId, actualEnabled)
        }

        // 最后发送状态变化通知（确保持久化已更新）
        if let state = newState {
            notifyPluginStateChanged(pluginId, state: state)
        }

        DebugLog.info(.plugin, "Plugin \(pluginId) \(enabled ? "enabled" : "disabled") by App")
    }

    /// 获取指定插件的所有子插件 ID
    private func getChildPluginIds(for parentId: String) -> [String] {
        getAllPluginInfos()
            .filter { $0.isSubPlugin && $0.parentPluginId == parentId }
            .map(\.pluginId)
    }

    /// 启用子插件（内部方法，不触发级联操作）
    private func enableChildPlugin(_ pluginId: String) async {
        guard let plugin = getPlugin(pluginId: pluginId) else { return }

        var newState: PluginState?

        switch plugin.state {
        case .paused:
            _ = withLock { pauseSources.removeValue(forKey: pluginId) }
            await plugin.resume()
            newState = .running

        case .stopped, .uninitialized:
            do {
                try await plugin.start()
                newState = .running
            } catch {
                DebugLog.error(.plugin, "Failed to start child plugin \(pluginId): \(error)")
                newState = .error
            }

        case .running, .starting, .stopping, .error:
            break
        }

        // 检查是否需要更新持久化设置
        let actualEnabled = newState == .running || plugin.state == .running
        let currentPersisted = DebugProbeSettings.shared.getPluginEnabled(pluginId) ?? true
        if currentPersisted != actualEnabled {
            DebugProbeSettings.shared.setPluginEnabled(pluginId, enabled: actualEnabled)
            onPluginEnabledStateChanged?(pluginId, actualEnabled)
        }

        if let state = newState {
            notifyPluginStateChanged(pluginId, state: state)
        }

        DebugLog.info(.plugin, "Child plugin \(pluginId) auto-enabled with parent")
    }

    /// WebUI 暂停/恢复指定插件
    /// 与 App 端禁用不同，WebUI 暂停不会影响持久化状态
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - paused: 是否暂停
    public func setPluginPausedByWebUI(_ pluginId: String, paused: Bool) async {
        guard let plugin = getPlugin(pluginId: pluginId) else {
            DebugLog.warning(.plugin, "Cannot set paused state: plugin not found: \(pluginId)")
            return
        }

        // 如果插件已被 App 端禁用，WebUI 无法恢复
        if !paused, let source = withLock({ pauseSources[pluginId] }), source == .app {
            DebugLog.warning(.plugin, "Cannot resume plugin \(pluginId) by WebUI: disabled by App")
            return
        }

        if paused {
            // WebUI 暂停插件
            if plugin.state == .running {
                withLock { pauseSources[pluginId] = .webUI }
                await plugin.pause()
                notifyPluginStateChanged(pluginId, state: .paused)
                DebugLog.info(.plugin, "Plugin \(pluginId) paused by WebUI")
            }
        } else {
            // WebUI 恢复插件
            if plugin.state == .paused, withLock({ pauseSources[pluginId] }) == .webUI {
                _ = withLock { pauseSources.removeValue(forKey: pluginId) }
                await plugin.resume()
                notifyPluginStateChanged(pluginId, state: .running)
                DebugLog.info(.plugin, "Plugin \(pluginId) resumed by WebUI")
            }
        }
    }

    /// 获取插件是否启用
    /// - Parameter pluginId: 插件 ID
    /// - Returns: 是否启用（运行中）
    public func isPluginEnabled(_ pluginId: String) -> Bool {
        guard let plugin = getPlugin(pluginId: pluginId) else { return false }
        return plugin.state == .running
    }

    // MARK: - Command Routing

    /// 路由命令到对应插件
    /// - Parameter command: 插件命令
    public func routeCommand(_ command: PluginCommand) async {
        guard let plugin = getPlugin(pluginId: command.pluginId) else {
            DebugLog.warning(.plugin, "Plugin not found for command: \(command.pluginId)")
            let response = PluginCommandResponse(
                pluginId: command.pluginId,
                commandId: command.commandId,
                success: false,
                errorMessage: "Plugin not found: \(command.pluginId)"
            )
            onPluginCommandResponse?(response)
            return
        }

        DebugLog.debug(.plugin, "Routing command to plugin: \(command.pluginId), type: \(command.commandType)")
        await plugin.handleCommand(command)
    }

    // MARK: - Private Methods

    /// 拓扑排序解析启动顺序
    private func resolveStartOrder() throws {
        var visited: Set<String> = []
        var visiting: Set<String> = []
        var order: [String] = []

        func visit(_ pluginId: String) throws {
            if visited.contains(pluginId) { return }
            if visiting.contains(pluginId) {
                throw PluginError.circularDependency(pluginId)
            }

            visiting.insert(pluginId)

            if let plugin = plugins[pluginId] {
                for dep in plugin.dependencies {
                    guard plugins[dep] != nil else {
                        throw PluginError.missingDependency(pluginId, dep)
                    }
                    try visit(dep)
                }
            }

            visiting.remove(pluginId)
            visited.insert(pluginId)
            order.append(pluginId)
        }

        for pluginId in plugins.keys {
            try visit(pluginId)
        }

        startOrder = order
    }
}

// MARK: - Plugin Errors

/// 插件相关错误
public enum PluginError: Error, LocalizedError {
    case duplicatePluginId(String)
    case pluginNotFound(String)
    case circularDependency(String)
    case missingDependency(String, String)
    case startFailed(String, Error)
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case let .duplicatePluginId(id):
            "Plugin ID already registered: \(id)"
        case let .pluginNotFound(id):
            "Plugin not found: \(id)"
        case let .circularDependency(id):
            "Circular dependency detected for plugin: \(id)"
        case let .missingDependency(plugin, dep):
            "Plugin '\(plugin)' depends on missing plugin: \(dep)"
        case let .startFailed(id, error):
            "Failed to start plugin '\(id)': \(error.localizedDescription)"
        case let .invalidConfiguration(msg):
            "Invalid plugin configuration: \(msg)"
        }
    }
}

// MARK: - Plugin Context Implementation

/// 插件上下文具体实现
final class PluginContextImpl: PluginContext, @unchecked Sendable {
    let deviceInfo: DeviceInfo
    private let onEvent: (PluginEvent) -> Void
    private let onCommandResponse: (PluginCommandResponse) -> Void
    private var configurations: [String: Data] = [:]
    private let configLock = NSLock()

    var deviceId: String { deviceInfo.deviceId }

    init(
        deviceInfo: DeviceInfo,
        onEvent: @escaping (PluginEvent) -> Void,
        onCommandResponse: @escaping (PluginCommandResponse) -> Void
    ) {
        self.deviceInfo = deviceInfo
        self.onEvent = onEvent
        self.onCommandResponse = onCommandResponse
    }

    func sendEvent(_ event: PluginEvent) {
        onEvent(event)
    }

    func sendCommandResponse(_ response: PluginCommandResponse) {
        onCommandResponse(response)
    }

    func getConfiguration<T: Decodable>(for key: String) -> T? {
        configLock.lock()
        defer { configLock.unlock() }

        guard let data = configurations[key] else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func setConfiguration(_ value: some Encodable, for key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        configLock.lock()
        configurations[key] = data
        configLock.unlock()
    }

    func log(_ level: PluginLogLevel, _ message: String, file: String, function: String, line: Int) {
        let fileName = (file as NSString).lastPathComponent
        switch level {
        case .debug:
            DebugLog.debug(.plugin, "[\(fileName):\(line)] \(message)")
        case .info:
            DebugLog.info(.plugin, "[\(fileName):\(line)] \(message)")
        case .warning:
            DebugLog.warning(.plugin, "[\(fileName):\(line)] \(message)")
        case .error:
            DebugLog.error(.plugin, "[\(fileName):\(line)] \(message)")
        }
    }
}
