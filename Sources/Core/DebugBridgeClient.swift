// DebugBridgeClient.swift
// DebugProbe
//
// Created by Sun on 2025/12/02.
// Copyright © 2025 Sun. All rights reserved.
//
// 负责与 Debug Hub 的 WebSocket 通信
// 内置事件缓冲，通过 EventCallbacks.onDebugEvent 接收事件
//

import Foundation

/// Debug Bridge 客户端，负责与 Debug Hub 通信
public final class DebugBridgeClient: NSObject {
    // MARK: - Configuration

    public struct Configuration {
        public let hubURL: URL
        public let token: String

        /// 初始重连间隔（秒）
        public var reconnectInterval: TimeInterval = 2.0

        /// 最大重连间隔（秒）- 指数退避上限
        public var maxReconnectInterval: TimeInterval = 30.0

        /// 最大重连尝试次数（默认 10 次，0 = 无限重试）
        /// 达到最大次数后状态变为 .failed，不再自动重连
        public var maxReconnectAttempts: Int = 10

        /// 心跳间隔（秒）- 用于检测连接状态
        /// 配合 ping/pong 机制可以更快检测到连接断开
        public var heartbeatInterval: TimeInterval = 10.0

        public var batchSize: Int = 100
        public var flushInterval: TimeInterval = 1.0

        /// 是否启用事件持久化（断线时保存到本地）
        public var enablePersistence: Bool = true

        /// 重连后恢复发送的批量大小
        public var recoveryBatchSize: Int = 50

        /// 持久化队列配置
        public var persistenceConfig: EventPersistenceQueue.Configuration = .init()

        /// 事件缓冲区最大容量
        public var maxBufferSize: Int = 10000

        /// 事件丢弃策略
        public var dropPolicy: DropPolicy = .dropOldest

        public init(hubURL: URL, token: String) {
            self.hubURL = hubURL
            self.token = token
        }
    }

    /// 事件丢弃策略
    public enum DropPolicy {
        case dropOldest // 丢弃最旧的事件
        case dropNewest // 丢弃最新的事件
        case sample(rate: Double) // 采样保留
    }

    // MARK: - State

    public enum ConnectionState: CustomStringConvertible {
        case disconnected
        case connecting
        case connected
        case registered
        /// 连接失败（达到最大重试次数后）
        case failed

        public var description: String {
            switch self {
            case .disconnected: "disconnected"
            case .connecting: "connecting"
            case .connected: "connected"
            case .registered: "registered"
            case .failed: "failed"
            }
        }
    }

    public private(set) var state: ConnectionState = .disconnected
    public private(set) var sessionId: String?

    // MARK: - Callbacks

    public var onStateChanged: ((ConnectionState) -> Void)?
    public var onError: ((Error) -> Void)?

    /// 插件命令回调：(pluginId, command, payload)
    /// payload 可以是字典 [String: Any] 或数组 [[String: Any]] 等任意 JSON 对象
    public var onPluginCommandReceived: ((String, String, Any?) -> Void)?

    /// Bridge 消息回调（用于插件系统路由）
    public var onBridgeMessageReceived: ((BridgeMessage) -> Void)?

    // MARK: - Private Properties

    private var configuration: Configuration?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var heartbeatTimer: Timer?
    private var flushTimer: Timer?
    private var reconnectTimer: Timer?
    private var recoveryTimer: Timer?
    private let workQueue = DispatchQueue(label: "com.sunimp.debugplatform.bridge", qos: .utility)
    private var isManualDisconnect = false
    private var isRecovering = false
    private var pendingEventIds: [String] = [] // 正在发送中的事件ID

    /// 事件缓冲区
    private var eventBuffer: [DebugEvent] = []
    private let bufferQueue = DispatchQueue(label: "com.sunimp.debugplatform.bridge.buffer", qos: .utility)

    /// 重连尝试次数
    private var reconnectAttempts = 0

    /// 当前重连间隔（指数退避）
    private var currentReconnectInterval: TimeInterval = 5.0

    /// 是否正在重连中
    private var isReconnecting = false
    private var isFlushing = false

    /// 是否已发送注册请求（防止重复发送）
    private var hasRegistered = false

    // MARK: - Lifecycle

    override public init() {
        super.init()
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection Management

    /// 连接到 Debug Hub
    public func connect(configuration: Configuration) {
        self.configuration = configuration

        workQueue.async { [weak self] in
            self?.internalConnect()
        }
    }

    /// 断开连接
    public func disconnect() {
        isManualDisconnect = true
        workQueue.async { [weak self] in
            self?.internalDisconnect()
        }
    }

    /// 手动重试连接（用于连接失败后的手动恢复）
    /// 会重置重连计数器，重新开始连接尝试
    public func retry() {
        guard configuration != nil else {
            DebugLog.error(.bridge, "Cannot retry: no configuration available")
            return
        }

        DebugLog.info(.bridge, "Manual retry requested")

        workQueue.async { [weak self] in
            guard let self else { return }

            // 重置状态
            resetReconnectState()
            isManualDisconnect = false

            // 确保先断开
            internalDisconnect()

            // 重新连接
            internalConnect()
        }
    }

    private func internalConnect() {
        guard let configuration else { return }

        // 防止重复连接
        guard state == .disconnected || state == .failed else {
            DebugLog.debug(.bridge, "Already connecting/connected, ignoring connect request (state=\(state))")
            return
        }

        updateState(.connecting)
        isManualDisconnect = false
        hasRegistered = false // 重置注册标记

        // 注册事件回调（接收来自插件的事件）
        registerEventCallback()

        // 初始化持久化队列
        if configuration.enablePersistence {
            EventPersistenceQueue.shared.initialize(configuration: configuration.persistenceConfig)
        }

        // 创建 WebSocket 连接
        var request = URLRequest(url: configuration.hubURL)
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        urlSession = session
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()

        // 开始接收消息
        receiveMessage()
    }

    private func internalDisconnect() {
        stopTimers()

        // 注销事件回调
        EventCallbacks.onDebugEvent = nil

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionId = nil
        hasRegistered = false // 重置注册标记

        updateState(.disconnected)
    }

    // MARK: - Message Handling

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case let .success(message):
                self?.handleMessage(message)
                self?.receiveMessage() // 继续接收下一条消息
            case let .failure(error):
                self?.handleError(error)
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case let .string(text):
            data = Data(text.utf8)
        case let .data(d):
            data = d
        @unknown default:
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let bridgeMessage = try decoder.decode(BridgeMessage.self, from: data)
            handleBridgeMessage(bridgeMessage)
        } catch {
            DebugLog.error(.bridge, "Failed to decode message: \(error)")
        }
    }

    private func handleBridgeMessage(_ message: BridgeMessage) {
        switch message {
        case let .registered(sessionId):
            self.sessionId = sessionId
            updateState(.registered)
            startTimers()

            // 连接成功，重置重连状态
            resetReconnectState()

            // 连接成功后，开始恢复发送持久化的事件
            if configuration?.enablePersistence == true {
                startRecovery()
            }

        case let .replayRequest(payload):
            DebugLog.info(.bridge, "Received replay request for \(payload.url)")
            executeReplayRequest(payload)

        case let .pluginCommand(command):
            DebugLog.info(.bridge, "Received plugin command: \(command.commandType) for plugin: \(command.pluginId)")
            // 解析 payload 为 JSON 对象（可能是字典或数组）
            var payloadObject: Any?
            if
                let payloadData = command.payload,
                let object = try? JSONSerialization.jsonObject(with: payloadData) {
                payloadObject = object
            }
            DispatchQueue.main.async { [weak self] in
                self?.onPluginCommandReceived?(command.pluginId, command.commandType, payloadObject)
            }

        case let .error(code, errorMessage):
            let error = NSError(domain: "DebugBridge", code: code, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            handleError(error)

        default:
            // 所有其他消息类型（updateMockRules, updateBreakpointRules,
            // updateChaosRules, breakpointResume, dbCommand 等）都通过插件系统路由
            DispatchQueue.main.async { [weak self] in
                self?.onBridgeMessageReceived?(message)
            }
        }
    }

    /// 执行请求重放
    private func executeReplayRequest(_ payload: ReplayRequestPayload) {
        guard let url = URL(string: payload.url) else {
            DebugLog.error(.bridge, "Invalid URL for replay: \(payload.url)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = payload.method

        // 设置请求头
        for (key, value) in payload.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // 设置请求体
        request.httpBody = payload.bodyData

        // 使用非监控的 session 执行请求，避免重放请求也被记录
        let session = URLSession(configuration: .ephemeral)

        DebugLog.info(.bridge, "Executing replay request: \(payload.method) \(payload.url)")

        session.dataTask(with: request) { _, response, error in
            if let error {
                DebugLog.error(.bridge, "Replay request failed: \(error.localizedDescription)")
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                DebugLog.info(.bridge, "Replay request completed: \(httpResponse.statusCode)")
            }

            // 可选：发送重放结果回服务端
            // self?.sendReplayResult(id: payload.id, response: response, data: data, error: error)
        }.resume()
    }

    private func handleError(_ error: Error) {
        // 过滤掉预期的断开错误，减少日志噪音
        let nsError = error as NSError
        let isExpectedDisconnect = nsError.domain == NSPOSIXErrorDomain && nsError.code == 57 // Socket is not connected

        if !isExpectedDisconnect {
            DispatchQueue.main.async { [weak self] in
                self?.onError?(error)
            }
        }

        if !isManualDisconnect, state != .disconnected {
            scheduleReconnect()
        }
    }

    // MARK: - Sending Messages

    /// 发送断点命中事件
    public func sendBreakpointHit(_ hit: BreakpointHit) {
        send(.breakpointHit(hit))
    }

    /// 发送数据库响应
    public func sendDBResponse(_ response: DBResponse) {
        send(.dbResponse(response))
    }

    /// 发送插件事件
    public func sendPluginEvent(_ event: PluginEvent) {
        send(.pluginEvent(event))
    }

    /// 发送插件状态变化消息
    public func sendPluginStateChange(pluginId: String, isEnabled: Bool) {
        send(.pluginStateChange(pluginId: pluginId, isEnabled: isEnabled))
    }

    private func send(_ message: BridgeMessage, completion: ((Error?) -> Void)? = nil) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601WithMilliseconds
            let data = try encoder.encode(message)

            webSocketTask?.send(.data(data)) { [weak self] error in
                if let error {
                    self?.handleError(error)
                }
                completion?(error)
            }
        } catch {
            DebugLog.error(.bridge, "Failed to encode message: \(error)")
            completion?(error)
        }
    }

    /// 发送设备注册请求
    private func sendRegister() {
        guard let configuration else { return }

        // 防止重复发送注册请求
        guard !hasRegistered else {
            DebugLog.debug(.bridge, "Already registered, ignoring duplicate register request")
            return
        }
        hasRegistered = true

        let deviceInfo = DeviceInfoProvider.current()

        // 获取所有插件的启用状态
        var pluginStates: [String: Bool] = [:]
        for plugin in PluginManager.shared.getAllPlugins() {
            pluginStates[plugin.pluginId] = plugin.isEnabled
        }

        DebugLog.debug(.bridge, "Sending register request for device: \(deviceInfo.deviceId), plugins: \(pluginStates)")
        send(.register(deviceInfo, token: configuration.token, pluginStates: pluginStates))
    }

    /// 发送设备信息更新（如别名变更）
    /// 仅在已注册状态下发送，不会重新建立连接
    public func sendDeviceInfoUpdate() {
        guard state == .registered else {
            DebugLog.debug(.bridge, "Not registered, ignoring device info update")
            return
        }

        let deviceInfo = DeviceInfoProvider.current()
        DebugLog.debug(.bridge, "Sending device info update: \(deviceInfo.deviceName)")
        send(.updateDeviceInfo(deviceInfo))
    }

    /// 发送心跳
    private func sendHeartbeat() {
        send(.heartbeat)
    }

    /// 批量发送事件
    private func flushEvents() {
        guard let configuration else { return }
        guard !isFlushing else { return }

        // 从内置缓冲区获取事件
        var events: [DebugEvent] = []
        bufferQueue.sync {
            events = Array(eventBuffer.prefix(configuration.batchSize))
        }
        guard !events.isEmpty else { return }

        // 如果已连接，直接发送
        if state == .registered {
            isFlushing = true
            DebugLog.debug(.bridge, "Flushing \(events.count) events to hub")

            send(.events(events)) { [weak self] error in
                guard let self else { return }
                if error == nil {
                    // 成功发送，从缓冲区移除
                    bufferQueue.async {
                        let removeCount = min(events.count, self.eventBuffer.count)
                        self.eventBuffer.removeFirst(removeCount)
                    }
                } else {
                    DebugLog.error(.bridge, "Failed to flush events, keeping in queue")
                }

                workQueue.async {
                    self.isFlushing = false
                }
            }
        } else {
            DebugLog.debug(.bridge, "Not registered (state=\(state)), events pending: \(events.count)")
            if configuration.enablePersistence {
                // 未连接时，将事件存入持久化队列
                var eventsToSave: [DebugEvent] = []
                bufferQueue.sync {
                    eventsToSave = eventBuffer
                    eventBuffer.removeAll()
                }
                if !eventsToSave.isEmpty {
                    EventPersistenceQueue.shared.enqueue(eventsToSave)
                    DebugLog.debug(.persistence, "Persisted \(eventsToSave.count) events (offline)")
                }
            }
        }
    }

    // MARK: - Event Buffer Management

    /// 注册事件回调
    /// 插件通过 EventCallbacks.reportEvent() 发送事件
    private func registerEventCallback() {
        EventCallbacks.onDebugEvent = { [weak self] event in
            self?.enqueueEvent(event)
        }
    }

    /// 入队一个调试事件
    private func enqueueEvent(_ event: DebugEvent) {
        guard let configuration else { return }

        bufferQueue.async { [weak self] in
            guard let self else { return }

            // 检查缓冲区是否已满
            if eventBuffer.count >= configuration.maxBufferSize {
                switch configuration.dropPolicy {
                case .dropOldest:
                    eventBuffer.removeFirst()
                case .dropNewest:
                    return // 不添加新事件
                case let .sample(rate):
                    // rate 表示保留率：rate=0.8 意味着保留 80% 的事件
                    if Double.random(in: 0...1) > rate {
                        return // 不满足采样条件，丢弃此事件
                    }
                    if eventBuffer.count >= configuration.maxBufferSize {
                        eventBuffer.removeFirst()
                    }
                }
            }

            eventBuffer.append(event)

            // 打印事件入队日志（便于调试）
            switch event {
            case let .http(httpEvent):
                DebugLog.debug(
                    .bridge,
                    "Event queued: HTTP \(httpEvent.request.method) \(httpEvent.request.url.prefix(80))... (buffer: \(eventBuffer.count))"
                )
            case let .log(logEvent):
                DebugLog.debug(
                    .bridge,
                    "Event queued: Log [\(logEvent.level)] \(logEvent.message.prefix(50))... (buffer: \(eventBuffer.count))"
                )
            case let .webSocket(wsEvent):
                DebugLog.debug(.bridge, "Event queued: WebSocket \(wsEvent) (buffer: \(eventBuffer.count))")
            case .stats:
                DebugLog.debug(.bridge, "Event queued: Stats (buffer: \(eventBuffer.count))")
            case let .performance(perfEvent):
                DebugLog.debug(.bridge, "Event queued: Performance \(perfEvent.eventType.rawValue) (buffer: \(eventBuffer.count))")
            }
        }
    }

    /// 获取当前缓冲区大小
    public var bufferCount: Int {
        var count = 0
        bufferQueue.sync {
            count = eventBuffer.count
        }
        return count
    }

    /// 清空缓冲区
    public func clearBuffer() {
        bufferQueue.async { [weak self] in
            self?.eventBuffer.removeAll()
        }
    }

    // MARK: - Recovery (断线恢复)

    /// 开始恢复发送持久化的事件
    private func startRecovery() {
        guard let configuration, configuration.enablePersistence else { return }

        let pendingCount = EventPersistenceQueue.shared.queueCount
        guard pendingCount > 0 else {
            DebugLog.debug(.bridge, "No pending events to recover")
            return
        }

        DebugLog.debug(.bridge, "Starting recovery of \(pendingCount) persisted events")
        isRecovering = true

        // 使用定时器分批恢复，避免一次性发送太多
        DispatchQueue.main.async { [weak self] in
            self?.recoveryTimer = Timer.scheduledTimer(
                withTimeInterval: 0.5, // 每 500ms 发送一批
                repeats: true
            ) { [weak self] _ in
                self?.workQueue.async {
                    self?.recoverBatch()
                }
            }
        }
    }

    /// 恢复一批事件
    private func recoverBatch() {
        guard let configuration, state == .registered, isRecovering else {
            stopRecovery()
            return
        }

        let events = EventPersistenceQueue.shared.dequeueBatch(maxCount: configuration.recoveryBatchSize)

        if events.isEmpty {
            // 恢复完成
            stopRecovery()
            DebugLog.debug(.bridge, "Recovery completed")
            return
        }

        // 发送事件
        send(.events(events))
        DebugLog.debug(
            .bridge,
            "Recovered \(events.count) events, remaining: \(EventPersistenceQueue.shared.queueCount)"
        )
    }

    /// 停止恢复
    private func stopRecovery() {
        isRecovering = false
        DispatchQueue.main.async { [weak self] in
            self?.recoveryTimer?.invalidate()
            self?.recoveryTimer = nil
        }
    }

    // MARK: - Timers

    private func startTimers() {
        guard let configuration else { return }

        // 心跳定时器
        DispatchQueue.main.async { [weak self] in
            self?.heartbeatTimer = Timer.scheduledTimer(
                withTimeInterval: configuration.heartbeatInterval,
                repeats: true
            ) { [weak self] _ in
                self?.workQueue.async {
                    self?.sendHeartbeatWithHealthCheck()
                }
            }

            // 事件刷新定时器
            self?.flushTimer = Timer
                .scheduledTimer(withTimeInterval: configuration.flushInterval, repeats: true) { [weak self] _ in
                    self?.workQueue.async {
                        self?.flushEvents()
                    }
                }
        }
    }

    /// 发送心跳并检测连接健康状态
    private func sendHeartbeatWithHealthCheck() {
        guard state == .registered else { return }

        // 使用 WebSocket 的 ping 检测连接是否真正活跃
        webSocketTask?.sendPing { [weak self] error in
            guard let self else { return }

            if let error {
                DebugLog.error(.bridge, "WebSocket ping failed: \(error.localizedDescription)")
                // ping 失败，说明连接已断开，触发重连
                workQueue.async {
                    if !self.isManualDisconnect {
                        self.scheduleReconnect()
                    }
                }
            } else {
                // ping 成功，发送业务心跳
                sendHeartbeat()
            }
        }
    }

    private func stopTimers() {
        DispatchQueue.main.async { [weak self] in
            self?.heartbeatTimer?.invalidate()
            self?.heartbeatTimer = nil
            self?.flushTimer?.invalidate()
            self?.flushTimer = nil
            self?.reconnectTimer?.invalidate()
            self?.reconnectTimer = nil
            self?.recoveryTimer?.invalidate()
            self?.recoveryTimer = nil
        }
        isRecovering = false
    }

    private func scheduleReconnect() {
        guard let configuration, !isManualDisconnect else {
            DebugLog.debug(.bridge, "Reconnect skipped: manual disconnect or no configuration")
            return
        }

        guard !isReconnecting else {
            DebugLog.debug(.bridge, "Reconnect already in progress")
            return
        }

        // 检查是否超过最大重试次数
        if configuration.maxReconnectAttempts > 0, reconnectAttempts >= configuration.maxReconnectAttempts {
            DebugLog.error(.bridge, "Max reconnect attempts (\(configuration.maxReconnectAttempts)) reached, giving up")
            updateState(.failed)
            isReconnecting = false
            return
        }

        isReconnecting = true
        reconnectAttempts += 1

        // 计算当前重连间隔（指数退避）
        if reconnectAttempts > 1 {
            currentReconnectInterval = min(
                currentReconnectInterval * 2,
                configuration.maxReconnectInterval
            )
        } else {
            currentReconnectInterval = configuration.reconnectInterval
        }

        DebugLog.info(
            .bridge,
            "Scheduling reconnect in \(currentReconnectInterval)s (attempt \(reconnectAttempts)/\(configuration.maxReconnectAttempts == 0 ? "∞" : "\(configuration.maxReconnectAttempts)"))"
        )

        internalDisconnect()

        DispatchQueue.main.async { [weak self] in
            self?.reconnectTimer = Timer.scheduledTimer(
                withTimeInterval: self?.currentReconnectInterval ?? 5.0,
                repeats: false
            ) { [weak self] _ in
                guard let self else { return }
                DebugLog.debug(.bridge, "Reconnect timer fired, attempting connection...")
                isReconnecting = false
                workQueue.async {
                    self.internalConnect()
                }
            }
        }
    }

    /// 重置重连状态（连接成功后调用）
    private func resetReconnectState() {
        reconnectAttempts = 0
        currentReconnectInterval = configuration?.reconnectInterval ?? 5.0
        isReconnecting = false
    }

    // MARK: - State Management

    private func updateState(_ newState: ConnectionState) {
        state = newState
        DispatchQueue.main.async { [weak self] in
            self?.onStateChanged?(newState)
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension DebugBridgeClient: URLSessionWebSocketDelegate {
    public func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didOpenWithProtocol _: String?
    ) {
        DebugLog.info(.bridge, "WebSocket connection opened")
        updateState(.connected)
        sendRegister()
    }

    public func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        DebugLog.info(.bridge, "WebSocket closed with code: \(closeCode.rawValue), reason: \(reasonString)")

        if !isManualDisconnect {
            scheduleReconnect()
        }
    }
}
