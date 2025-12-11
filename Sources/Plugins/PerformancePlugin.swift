// PerformancePlugin.swift
// DebugProbe
//
// Created by Sun on 2025/12/11.
// Copyright © 2025 Sun. All rights reserved.
//

#if canImport(UIKit)
    import UIKit
#endif
import Foundation
import QuartzCore

// MARK: - Performance Plugin

/// 性能监控插件
/// 负责采集 CPU、内存、FPS 等性能指标并上报
public final class PerformancePlugin: DebugProbePlugin, @unchecked Sendable {
    // MARK: - Plugin Metadata

    public let pluginId: String = BuiltinPluginId.performance
    public let displayName: String = "Performance"
    public let version: String = "1.0.0"
    public let pluginDescription: String = "App 性能监控"
    public let dependencies: [String] = []

    // MARK: - State

    public private(set) var state: PluginState = .uninitialized
    public private(set) var isEnabled: Bool = true

    // MARK: - Configuration

    /// 采样间隔（秒）
    public var sampleInterval: TimeInterval = 1.0

    /// 上报批次大小
    public var batchSize: Int = 5

    /// 是否监控 FPS
    public var monitorFPS: Bool = true

    /// 是否监控 CPU
    public var monitorCPU: Bool = true

    /// 是否监控内存
    public var monitorMemory: Bool = true

    /// 告警配置
    public var alertConfig: AlertConfig = AlertConfig(rules: AlertConfig.defaultRules)

    // MARK: - Private Properties

    private weak var context: PluginContext?
    private let stateQueue = DispatchQueue(label: "com.sunimp.debugprobe.performance.state")

    /// 性能监控器
    private var cpuMonitor: CPUMonitor?
    private var memoryMonitor: MemoryMonitor?
    private var fpsMonitor: FPSMonitor?

    /// 采样定时器
    private var sampleTimer: DispatchSourceTimer?

    /// 待上报的指标批次
    private var metricsBatch: [PerformanceMetrics] = []
    private let batchLock = NSLock()

    /// 卡顿检测器
    private var jankDetector: JankDetector?

    /// 告警检测器
    private var alertChecker: AlertChecker?

    // MARK: - Lifecycle

    public init() {}

    public func initialize(context: PluginContext) {
        self.context = context

        // 从配置恢复状态
        if let enabled: Bool = context.getConfiguration(for: "performance.enabled") {
            isEnabled = enabled
        }
        if let interval: Double = context.getConfiguration(for: "performance.sampleInterval") {
            sampleInterval = interval
        }
        if let fps: Bool = context.getConfiguration(for: "performance.monitorFPS") {
            monitorFPS = fps
        }
        if let cpu: Bool = context.getConfiguration(for: "performance.monitorCPU") {
            monitorCPU = cpu
        }
        if let memory: Bool = context.getConfiguration(for: "performance.monitorMemory") {
            monitorMemory = memory
        }

        state = .stopped
        context.logInfo("PerformancePlugin initialized")
    }

    public func start() async throws {
        guard state != .running else { return }

        stateQueue.sync { state = .starting }

        // 初始化监控器
        if monitorCPU {
            cpuMonitor = CPUMonitor()
        }
        if monitorMemory {
            memoryMonitor = MemoryMonitor()
        }
        if monitorFPS {
            await MainActor.run {
                fpsMonitor = FPSMonitor()
                jankDetector = JankDetector { [weak self] event in
                    self?.reportJankEvent(event)
                }
            }
        }

        // 初始化告警检测器
        alertChecker = AlertChecker(config: alertConfig) { [weak self] alert in
            self?.reportAlert(alert)
        }

        // 启动采样定时器
        startSampleTimer()

        stateQueue.sync { state = .running }
        context?.logInfo("PerformancePlugin started with interval: \(sampleInterval)s")
    }

    public func pause() async {
        guard state == .running else { return }

        stopSampleTimer()
        await MainActor.run {
            fpsMonitor?.stop()
            jankDetector?.stop()
        }

        stateQueue.sync { state = .paused }
        context?.logInfo("PerformancePlugin paused")
    }

    public func resume() async {
        guard state == .paused else { return }

        startSampleTimer()
        await MainActor.run {
            fpsMonitor?.start()
            jankDetector?.start()
        }

        stateQueue.sync { state = .running }
        context?.logInfo("PerformancePlugin resumed")
    }

    public func stop() async {
        guard state == .running || state == .paused else { return }

        stateQueue.sync { state = .stopping }

        stopSampleTimer()
        await MainActor.run {
            fpsMonitor?.stop()
            jankDetector?.stop()
        }
        fpsMonitor = nil
        jankDetector = nil
        cpuMonitor = nil
        memoryMonitor = nil
        alertChecker = nil

        // 上报剩余批次
        flushMetricsBatch()

        stateQueue.sync { state = .stopped }
        context?.logInfo("PerformancePlugin stopped")
    }

    public func handleCommand(_ command: PluginCommand) async {
        switch command.commandType {
        case "enable":
            await enable()
            sendSuccessResponse(for: command)

        case "disable":
            await disable()
            sendSuccessResponse(for: command)

        case "set_config":
            await handleSetConfig(command)

        case "get_status":
            await handleGetStatus(command)

        case "get_current_metrics":
            await handleGetCurrentMetrics(command)

        // 告警相关命令
        case "get_alert_config":
            await handleGetAlertConfig(command)

        case "set_alert_config":
            await handleSetAlertConfig(command)

        case "add_alert_rule":
            await handleAddAlertRule(command)

        case "remove_alert_rule":
            await handleRemoveAlertRule(command)

        case "update_alert_rule":
            await handleUpdateAlertRule(command)

        case "get_active_alerts":
            await handleGetActiveAlerts(command)

        case "resolve_alert":
            await handleResolveAlert(command)

        default:
            sendErrorResponse(for: command, message: "Unknown command type: \(command.commandType)")
        }
    }

    public func onConfigurationChanged(key: String) {
        guard key.hasPrefix("performance.") else { return }

        switch key {
        case "performance.enabled":
            if let enabled: Bool = context?.getConfiguration(for: key) {
                Task {
                    if enabled {
                        await enable()
                    } else {
                        await disable()
                    }
                }
            }
        case "performance.sampleInterval":
            if let interval: Double = context?.getConfiguration(for: key) {
                sampleInterval = interval
                // 重启定时器以应用新间隔
                if state == .running {
                    stopSampleTimer()
                    startSampleTimer()
                }
            }
        default:
            break
        }
    }

    // MARK: - Private Methods

    private func startSampleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + sampleInterval, repeating: sampleInterval)
        timer.setEventHandler { [weak self] in
            self?.collectAndReportMetrics()
        }
        timer.resume()
        sampleTimer = timer
    }

    private func stopSampleTimer() {
        sampleTimer?.cancel()
        sampleTimer = nil
    }

    private func collectAndReportMetrics() {
        var cpuMetrics: CPUMetrics?
        var memoryMetrics: MemoryMetrics?
        var fpsMetrics: FPSMetrics?

        // 采集 CPU
        if monitorCPU {
            cpuMetrics = cpuMonitor?.collect()
        }

        // 采集内存
        if monitorMemory {
            memoryMetrics = memoryMonitor?.collect()
        }

        // 采集 FPS（需要在主线程）
        if monitorFPS {
            DispatchQueue.main.sync {
                fpsMetrics = fpsMonitor?.collect()
            }
        }

        let metrics = PerformanceMetrics(
            timestamp: Date(),
            cpu: cpuMetrics,
            memory: memoryMetrics,
            fps: fpsMetrics
        )

        // 告警检测
        alertChecker?.checkMetrics(metrics)

        // 添加到批次
        batchLock.lock()
        metricsBatch.append(metrics)
        let shouldFlush = metricsBatch.count >= batchSize
        batchLock.unlock()

        if shouldFlush {
            flushMetricsBatch()
        }
    }

    private func flushMetricsBatch() {
        batchLock.lock()
        let batch = metricsBatch
        metricsBatch = []
        batchLock.unlock()

        guard !batch.isEmpty else { return }

        // 转换为传输数据格式
        let metricsData = batch.map { m in
            PerformanceMetricsData(
                timestamp: m.timestamp,
                cpu: m.cpu.map { CPUMetricsData(usage: $0.usage, userTime: $0.userTime, systemTime: $0.systemTime, threadCount: $0.threadCount) },
                memory: m.memory.map { MemoryMetricsData(usedMemory: $0.usedMemory, peakMemory: $0.peakMemory, freeMemory: $0.freeMemory, memoryPressure: $0.memoryPressure.rawValue, footprintRatio: $0.footprintRatio) },
                fps: m.fps.map { FPSMetricsData(fps: $0.fps, droppedFrames: $0.droppedFrames, jankCount: $0.jankCount, averageRenderTime: $0.averageRenderTime) }
            )
        }

        // 通过 EventCallbacks 直接发送到 BridgeClient
        let performanceEvent = PerformanceEvent(
            eventType: .metrics,
            metrics: metricsData
        )
        EventCallbacks.reportEvent(.performance(performanceEvent))
    }

    private func reportJankEvent(_ event: JankEvent) {
        let jankData = JankEventData(
            id: event.id,
            timestamp: event.timestamp,
            duration: event.duration,
            droppedFrames: event.droppedFrames,
            stackTrace: event.stackTrace
        )
        let performanceEvent = PerformanceEvent(
            eventType: .jank,
            jank: jankData
        )
        EventCallbacks.reportEvent(.performance(performanceEvent))
    }

    private func reportAlert(_ alert: Alert) {
        let alertData = AlertData(
            id: alert.id,
            ruleId: alert.ruleId,
            metricType: alert.metricType.rawValue,
            severity: alert.severity.rawValue,
            message: alert.message,
            currentValue: alert.currentValue,
            threshold: alert.threshold,
            timestamp: alert.timestamp,
            isResolved: alert.isResolved,
            resolvedAt: alert.resolvedAt
        )
        let performanceEvent = PerformanceEvent(
            eventType: alert.isResolved ? .alertResolved : .alert,
            alert: alertData
        )
        EventCallbacks.reportEvent(.performance(performanceEvent))
        context?.logWarning("Performance alert: \(alert.message)")
    }

    // MARK: - Command Handlers

    private func handleSetConfig(_ command: PluginCommand) async {
        struct ConfigPayload: Codable {
            let sampleInterval: Double?
            let monitorFPS: Bool?
            let monitorCPU: Bool?
            let monitorMemory: Bool?
        }

        do {
            if let payload: ConfigPayload = try command.decodePayload(as: ConfigPayload.self) {
                if let interval = payload.sampleInterval {
                    sampleInterval = interval
                    context?.setConfiguration(interval, for: "performance.sampleInterval")
                }
                if let fps = payload.monitorFPS {
                    monitorFPS = fps
                    context?.setConfiguration(fps, for: "performance.monitorFPS")
                }
                if let cpu = payload.monitorCPU {
                    monitorCPU = cpu
                    context?.setConfiguration(cpu, for: "performance.monitorCPU")
                }
                if let memory = payload.monitorMemory {
                    monitorMemory = memory
                    context?.setConfiguration(memory, for: "performance.monitorMemory")
                }

                // 如果正在运行，重启以应用新配置
                if state == .running {
                    await stop()
                    try await start()
                }

                sendSuccessResponse(for: command)
            }
        } catch {
            sendErrorResponse(for: command, message: "Invalid config payload: \(error)")
        }
    }

    private func handleGetStatus(_ command: PluginCommand) async {
        struct StatusResponse: Codable {
            let enabled: Bool
            let state: String
            let sampleInterval: Double
            let monitorFPS: Bool
            let monitorCPU: Bool
            let monitorMemory: Bool
        }

        let status = StatusResponse(
            enabled: isEnabled,
            state: state.rawValue,
            sampleInterval: sampleInterval,
            monitorFPS: monitorFPS,
            monitorCPU: monitorCPU,
            monitorMemory: monitorMemory
        )

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(status)
            let response = PluginCommandResponse(
                pluginId: pluginId,
                commandId: command.commandId,
                success: true,
                payload: data
            )
            context?.sendCommandResponse(response)
        } catch {
            sendErrorResponse(for: command, message: "Failed to encode status: \(error)")
        }
    }

    private func handleGetCurrentMetrics(_ command: PluginCommand) async {
        var cpuMetrics: CPUMetrics?
        var memoryMetrics: MemoryMetrics?
        var fpsMetrics: FPSMetrics?

        if monitorCPU {
            cpuMetrics = cpuMonitor?.collect()
        }
        if monitorMemory {
            memoryMetrics = memoryMonitor?.collect()
        }
        if monitorFPS {
            await MainActor.run {
                fpsMetrics = fpsMonitor?.collect()
            }
        }

        let metrics = PerformanceMetrics(
            timestamp: Date(),
            cpu: cpuMetrics,
            memory: memoryMetrics,
            fps: fpsMetrics
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(metrics)
            let response = PluginCommandResponse(
                pluginId: pluginId,
                commandId: command.commandId,
                success: true,
                payload: data
            )
            context?.sendCommandResponse(response)
        } catch {
            sendErrorResponse(for: command, message: "Failed to encode metrics: \(error)")
        }
    }

    // MARK: - Alert Command Handlers

    private func handleGetAlertConfig(_ command: PluginCommand) async {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(alertConfig)
            let response = PluginCommandResponse(
                pluginId: pluginId,
                commandId: command.commandId,
                success: true,
                payload: data
            )
            context?.sendCommandResponse(response)
        } catch {
            sendErrorResponse(for: command, message: "Failed to encode alert config: \(error)")
        }
    }

    private func handleSetAlertConfig(_ command: PluginCommand) async {
        do {
            if let payload: AlertConfig = try command.decodePayload(as: AlertConfig.self) {
                alertConfig = payload
                alertChecker?.updateConfig(payload)
                sendSuccessResponse(for: command)
            }
        } catch {
            sendErrorResponse(for: command, message: "Invalid alert config payload: \(error)")
        }
    }

    private func handleAddAlertRule(_ command: PluginCommand) async {
        do {
            if let rule: AlertRule = try command.decodePayload(as: AlertRule.self) {
                alertConfig.rules.append(rule)
                alertChecker?.updateConfig(alertConfig)
                sendSuccessResponse(for: command)
            }
        } catch {
            sendErrorResponse(for: command, message: "Invalid alert rule payload: \(error)")
        }
    }

    private func handleRemoveAlertRule(_ command: PluginCommand) async {
        struct RemovePayload: Codable {
            let ruleId: String
        }

        do {
            if let payload: RemovePayload = try command.decodePayload(as: RemovePayload.self) {
                alertConfig.rules.removeAll { $0.id == payload.ruleId }
                alertChecker?.updateConfig(alertConfig)
                sendSuccessResponse(for: command)
            }
        } catch {
            sendErrorResponse(for: command, message: "Invalid remove rule payload: \(error)")
        }
    }

    private func handleUpdateAlertRule(_ command: PluginCommand) async {
        do {
            if let rule: AlertRule = try command.decodePayload(as: AlertRule.self) {
                if let index = alertConfig.rules.firstIndex(where: { $0.id == rule.id }) {
                    alertConfig.rules[index] = rule
                    alertChecker?.updateConfig(alertConfig)
                    sendSuccessResponse(for: command)
                } else {
                    sendErrorResponse(for: command, message: "Rule not found: \(rule.id)")
                }
            }
        } catch {
            sendErrorResponse(for: command, message: "Invalid alert rule payload: \(error)")
        }
    }

    private func handleGetActiveAlerts(_ command: PluginCommand) async {
        let alerts = alertChecker?.getActiveAlerts() ?? []
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(alerts)
            let response = PluginCommandResponse(
                pluginId: pluginId,
                commandId: command.commandId,
                success: true,
                payload: data
            )
            context?.sendCommandResponse(response)
        } catch {
            sendErrorResponse(for: command, message: "Failed to encode alerts: \(error)")
        }
    }

    private func handleResolveAlert(_ command: PluginCommand) async {
        struct ResolvePayload: Codable {
            let alertId: String
        }

        do {
            if let payload: ResolvePayload = try command.decodePayload(as: ResolvePayload.self) {
                alertChecker?.resolveAlert(payload.alertId)
                sendSuccessResponse(for: command)
            }
        } catch {
            sendErrorResponse(for: command, message: "Invalid resolve alert payload: \(error)")
        }
    }

    // MARK: - Helper Methods

    private func sendSuccessResponse(for command: PluginCommand) {
        let response = PluginCommandResponse(
            pluginId: pluginId,
            commandId: command.commandId,
            success: true
        )
        context?.sendCommandResponse(response)
    }

    private func sendErrorResponse(for command: PluginCommand, message: String) {
        let response = PluginCommandResponse(
            pluginId: pluginId,
            commandId: command.commandId,
            success: false,
            errorMessage: message
        )
        context?.sendCommandResponse(response)
    }
}

// MARK: - Enable/Disable

extension PerformancePlugin {
    private func enable() async {
        guard !isEnabled else { return }
        isEnabled = true
        context?.setConfiguration(true, for: "performance.enabled")
        try? await start()
        context?.logInfo("PerformancePlugin enabled")
    }

    private func disable() async {
        guard isEnabled else { return }
        isEnabled = false
        context?.setConfiguration(false, for: "performance.enabled")
        await stop()
        context?.logInfo("PerformancePlugin disabled")
    }
}

// MARK: - Performance Metrics Models

/// CPU 指标
public struct CPUMetrics: Codable, Sendable {
    /// 总 CPU 使用率 (0.0 - 100.0)
    public let usage: Double
    /// 用户态 CPU 时间
    public let userTime: Double
    /// 内核态 CPU 时间
    public let systemTime: Double
    /// 线程数
    public let threadCount: Int
}

/// 内存指标
public struct MemoryMetrics: Codable, Sendable {
    /// 已用内存（字节）
    public let usedMemory: UInt64
    /// 峰值内存（字节）
    public let peakMemory: UInt64
    /// 可用物理内存（字节）
    public let freeMemory: UInt64
    /// 内存压力级别
    public let memoryPressure: MemoryPressureLevel
    /// 物理内存占用比例 (0.0 - 1.0)
    public let footprintRatio: Double
}

/// 内存压力级别
public enum MemoryPressureLevel: String, Codable, Sendable {
    case low
    case medium
    case high
    case critical
}

/// FPS 指标
public struct FPSMetrics: Codable, Sendable {
    /// 当前帧率
    public let fps: Double
    /// 丢帧数
    public let droppedFrames: Int
    /// 卡顿次数（连续丢帧 > 3）
    public let jankCount: Int
    /// 平均渲染时间（毫秒）
    public let averageRenderTime: Double
}

/// 性能指标汇总
public struct PerformanceMetrics: Codable, Sendable {
    public let timestamp: Date
    public let cpu: CPUMetrics?
    public let memory: MemoryMetrics?
    public let fps: FPSMetrics?
}

/// 性能指标批次
public struct PerformanceMetricsBatch: Codable, Sendable {
    public let metrics: [PerformanceMetrics]
}

/// 卡顿事件
public struct JankEvent: Codable, Sendable {
    public let id: String
    public let timestamp: Date
    /// 卡顿持续时间（毫秒）
    public let duration: Double
    /// 丢帧数
    public let droppedFrames: Int
    /// 主线程调用栈（如果可获取）
    public let stackTrace: String?
}

// MARK: - Alert Models

/// 告警级别
public enum AlertSeverity: String, Codable, Sendable {
    case info
    case warning
    case critical
}

/// 告警指标类型
public enum AlertMetricType: String, Codable, Sendable {
    case cpu
    case memory
    case fps
    case jank
}

/// 告警规则
public struct AlertRule: Codable, Sendable {
    public let id: String
    public let metricType: AlertMetricType
    /// 告警阈值
    public let threshold: Double
    /// 触发条件：大于还是小于阈值
    public let condition: AlertCondition
    /// 持续时间阈值（秒），连续超过阈值多长时间才触发告警
    public let durationSeconds: Int
    /// 告警级别
    public let severity: AlertSeverity
    /// 是否启用
    public var isEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        metricType: AlertMetricType,
        threshold: Double,
        condition: AlertCondition,
        durationSeconds: Int = 0,
        severity: AlertSeverity = .warning,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.metricType = metricType
        self.threshold = threshold
        self.condition = condition
        self.durationSeconds = durationSeconds
        self.severity = severity
        self.isEnabled = isEnabled
    }
}

/// 告警条件
public enum AlertCondition: String, Codable, Sendable {
    case greaterThan = "gt"
    case lessThan = "lt"
    case greaterThanOrEqual = "gte"
    case lessThanOrEqual = "lte"

    public func evaluate(_ value: Double, threshold: Double) -> Bool {
        switch self {
        case .greaterThan:
            return value > threshold
        case .lessThan:
            return value < threshold
        case .greaterThanOrEqual:
            return value >= threshold
        case .lessThanOrEqual:
            return value <= threshold
        }
    }
}

/// 告警事件
public struct Alert: Codable, Sendable {
    public let id: String
    public let ruleId: String
    public let metricType: AlertMetricType
    public let severity: AlertSeverity
    public let message: String
    public let currentValue: Double
    public let threshold: Double
    public let timestamp: Date
    /// 告警是否已解决
    public var isResolved: Bool
    /// 解决时间
    public var resolvedAt: Date?

    public init(
        id: String = UUID().uuidString,
        ruleId: String,
        metricType: AlertMetricType,
        severity: AlertSeverity,
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

/// 告警配置
public struct AlertConfig: Codable, Sendable {
    public var rules: [AlertRule]
    /// 告警冷却时间（秒），同一规则触发后多久才能再次触发
    public var cooldownSeconds: Int
    /// 是否启用告警
    public var isEnabled: Bool

    public init(rules: [AlertRule] = [], cooldownSeconds: Int = 60, isEnabled: Bool = true) {
        self.rules = rules
        self.cooldownSeconds = cooldownSeconds
        self.isEnabled = isEnabled
    }

    /// 默认告警规则
    public static var defaultRules: [AlertRule] {
        [
            AlertRule(
                id: "cpu_high",
                metricType: .cpu,
                threshold: 80,
                condition: .greaterThan,
                durationSeconds: 5,
                severity: .warning,
                isEnabled: true
            ),
            AlertRule(
                id: "cpu_critical",
                metricType: .cpu,
                threshold: 95,
                condition: .greaterThan,
                durationSeconds: 3,
                severity: .critical,
                isEnabled: true
            ),
            AlertRule(
                id: "memory_high",
                metricType: .memory,
                threshold: 70,
                condition: .greaterThan,
                durationSeconds: 5,
                severity: .warning,
                isEnabled: true
            ),
            AlertRule(
                id: "memory_critical",
                metricType: .memory,
                threshold: 90,
                condition: .greaterThan,
                durationSeconds: 3,
                severity: .critical,
                isEnabled: true
            ),
            AlertRule(
                id: "fps_low",
                metricType: .fps,
                threshold: 45,
                condition: .lessThan,
                durationSeconds: 5,
                severity: .warning,
                isEnabled: true
            ),
            AlertRule(
                id: "fps_critical",
                metricType: .fps,
                threshold: 30,
                condition: .lessThan,
                durationSeconds: 3,
                severity: .critical,
                isEnabled: true
            ),
        ]
    }
}

// MARK: - CPU Monitor

/// CPU 监控器
final class CPUMonitor: @unchecked Sendable {
    private var lastUserTime: Double = 0
    private var lastSystemTime: Double = 0
    private var lastTimestamp: CFAbsoluteTime = 0

    func collect() -> CPUMetrics {
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        var threadCount = 0
        var cpuUsage: Double = 0
        var userTime: Double = 0
        var systemTime: Double = 0

        if result == KERN_SUCCESS {
            // 获取线程信息来计算 CPU 使用率
            var threadList: thread_act_array_t?
            var threadCountMach: mach_msg_type_number_t = 0

            if task_threads(mach_task_self_, &threadList, &threadCountMach) == KERN_SUCCESS {
                threadCount = Int(threadCountMach)

                for i in 0..<Int(threadCountMach) {
                    var threadInfo = thread_basic_info()
                    var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)

                    let kr = withUnsafeMutablePointer(to: &threadInfo) {
                        $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) {
                            thread_info(threadList![i], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                        }
                    }

                    if kr == KERN_SUCCESS, threadInfo.flags & TH_FLAGS_IDLE == 0 {
                        cpuUsage += Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
                        userTime += Double(threadInfo.user_time.seconds) + Double(threadInfo.user_time.microseconds) /
                            1_000_000.0
                        systemTime += Double(threadInfo.system_time.seconds) +
                            Double(threadInfo.system_time.microseconds) / 1_000_000.0
                    }
                }

                // 释放线程列表
                let size = vm_size_t(MemoryLayout<thread_t>.stride * Int(threadCountMach))
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threadList), size)
            }
        }

        return CPUMetrics(
            usage: min(cpuUsage, 100.0),
            userTime: userTime,
            systemTime: systemTime,
            threadCount: threadCount
        )
    }
}

// MARK: - Memory Monitor

/// 内存监控器
final class MemoryMonitor: @unchecked Sendable {
    private var peakMemory: UInt64 = 0

    func collect() -> MemoryMetrics {
        var taskInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }

        var usedMemory: UInt64 = 0
        var footprintRatio: Double = 0

        if result == KERN_SUCCESS {
            usedMemory = UInt64(taskInfo.phys_footprint)
            peakMemory = max(peakMemory, usedMemory)

            // 计算内存占用比例
            let totalMemory = ProcessInfo.processInfo.physicalMemory
            footprintRatio = Double(usedMemory) / Double(totalMemory)
        }

        // 获取系统可用内存
        let freeMemory = getFreeMemory()

        // 计算内存压力级别
        let pressure = calculateMemoryPressure(used: usedMemory, free: freeMemory)

        return MemoryMetrics(
            usedMemory: usedMemory,
            peakMemory: peakMemory,
            freeMemory: freeMemory,
            memoryPressure: pressure,
            footprintRatio: footprintRatio
        )
    }

    private func getFreeMemory() -> UInt64 {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            return UInt64(vmStats.free_count) * UInt64(pageSize)
        }
        return 0
    }

    private func calculateMemoryPressure(used: UInt64, free: UInt64) -> MemoryPressureLevel {
        let total = ProcessInfo.processInfo.physicalMemory
        let usedRatio = Double(used) / Double(total)

        if usedRatio > 0.9 {
            return .critical
        } else if usedRatio > 0.7 {
            return .high
        } else if usedRatio > 0.5 {
            return .medium
        } else {
            return .low
        }
    }
}

// MARK: - FPS Monitor

#if canImport(UIKit)

    /// FPS 监控器
    @MainActor
    final class FPSMonitor {
        private var displayLink: CADisplayLink?
        private var lastTimestamp: CFTimeInterval = 0
        private var frameCount: Int = 0
        private var totalFrameTime: CFTimeInterval = 0
        private var droppedFrames: Int = 0
        private var jankCount: Int = 0
        private var currentFPS: Double = 60.0
        private var consecutiveDrops: Int = 0

        init() {
            start()
        }

        func start() {
            guard displayLink == nil else { return }

            displayLink = CADisplayLink(target: self, selector: #selector(tick))
            displayLink?.add(to: .main, forMode: .common)
            lastTimestamp = CACurrentMediaTime()
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            let currentTime = link.timestamp
            let frameDuration = currentTime - lastTimestamp
            lastTimestamp = currentTime

            frameCount += 1
            totalFrameTime += frameDuration

            // 计算即时 FPS
            if frameDuration > 0 {
                currentFPS = 1.0 / frameDuration
            }

            // 检测丢帧（假设目标 60fps，帧间隔应 < 20ms）
            let expectedInterval = 1.0 / 60.0
            if frameDuration > expectedInterval * 2 {
                let dropped = Int(frameDuration / expectedInterval) - 1
                droppedFrames += dropped
                consecutiveDrops += dropped

                // 连续丢帧 > 3 视为卡顿
                if consecutiveDrops > 3 {
                    jankCount += 1
                }
            } else {
                consecutiveDrops = 0
            }
        }

        func collect() -> FPSMetrics {
            let avgRenderTime = frameCount > 0 ? (totalFrameTime / Double(frameCount)) * 1000 : 0

            let metrics = FPSMetrics(
                fps: currentFPS,
                droppedFrames: droppedFrames,
                jankCount: jankCount,
                averageRenderTime: avgRenderTime
            )

            // 重置统计
            frameCount = 0
            totalFrameTime = 0
            droppedFrames = 0
            jankCount = 0

            return metrics
        }
    }

    // MARK: - Jank Detector

    /// 卡顿检测器
    @MainActor
    final class JankDetector {
        private var displayLink: CADisplayLink?
        private var lastTimestamp: CFTimeInterval = 0
        private let callback: @Sendable (JankEvent) -> Void
        private var jankStartTime: CFTimeInterval?
        private var consecutiveDrops: Int = 0

        init(callback: @escaping @Sendable (JankEvent) -> Void) {
            self.callback = callback
            start()
        }

        func start() {
            guard displayLink == nil else { return }

            displayLink = CADisplayLink(target: self, selector: #selector(tick))
            displayLink?.add(to: .main, forMode: .common)
            lastTimestamp = CACurrentMediaTime()
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            let currentTime = link.timestamp
            let frameDuration = currentTime - lastTimestamp
            lastTimestamp = currentTime

            let expectedInterval = 1.0 / 60.0

            // 检测卡顿开始
            if frameDuration > expectedInterval * 2 {
                if jankStartTime == nil {
                    jankStartTime = currentTime - frameDuration
                }
                consecutiveDrops += Int(frameDuration / expectedInterval)
            } else {
                // 卡顿结束，上报事件
                if let startTime = jankStartTime, consecutiveDrops > 3 {
                    let duration = (currentTime - startTime) * 1000 // 转换为毫秒
                    let event = JankEvent(
                        id: UUID().uuidString,
                        timestamp: Date(),
                        duration: duration,
                        droppedFrames: consecutiveDrops,
                        stackTrace: nil // 可扩展：获取主线程调用栈
                    )
                    callback(event)
                }
                jankStartTime = nil
                consecutiveDrops = 0
            }
        }
    }

#else

    // macOS 占位实现（macOS 14+ 才支持 CADisplayLink）

    @MainActor
    final class FPSMonitor {
        init() {}
        func start() {}
        func stop() {}
        func collect() -> FPSMetrics {
            FPSMetrics(fps: 60, droppedFrames: 0, jankCount: 0, averageRenderTime: 0)
        }
    }

    @MainActor
    final class JankDetector {
        init(callback: @escaping @Sendable (JankEvent) -> Void) {}
        func start() {}
        func stop() {}
    }

#endif

// MARK: - Alert Checker

/// 告警检测器
/// 负责根据告警规则检测性能指标并触发告警
final class AlertChecker: @unchecked Sendable {
    private var config: AlertConfig
    private let callback: @Sendable (Alert) -> Void
    private let lock = NSLock()

    /// 每个规则的违规开始时间
    private var violationStartTimes: [String: Date] = [:]

    /// 活跃的告警（未解决的）
    private var activeAlerts: [String: Alert] = [:]

    /// 告警冷却：每个规则最后触发告警的时间
    private var lastAlertTimes: [String: Date] = [:]

    init(config: AlertConfig, callback: @escaping @Sendable (Alert) -> Void) {
        self.config = config
        self.callback = callback
    }

    func updateConfig(_ newConfig: AlertConfig) {
        lock.lock()
        defer { lock.unlock() }
        self.config = newConfig
    }

    func checkMetrics(_ metrics: PerformanceMetrics) {
        guard config.isEnabled else { return }

        lock.lock()
        defer { lock.unlock() }

        for rule in config.rules where rule.isEnabled {
            let value = extractValue(for: rule.metricType, from: metrics)
            guard let value else { continue }

            let isViolating = rule.condition.evaluate(value, threshold: rule.threshold)

            if isViolating {
                handleViolation(rule: rule, currentValue: value)
            } else {
                handleRecovery(rule: rule, currentValue: value)
            }
        }
    }

    func getActiveAlerts() -> [Alert] {
        lock.lock()
        defer { lock.unlock() }
        return Array(activeAlerts.values)
    }

    func resolveAlert(_ alertId: String) {
        lock.lock()
        defer { lock.unlock() }

        if var alert = activeAlerts[alertId] {
            alert.isResolved = true
            alert.resolvedAt = Date()
            activeAlerts.removeValue(forKey: alertId)
        }
    }

    // MARK: - Private Methods

    private func extractValue(for metricType: AlertMetricType, from metrics: PerformanceMetrics) -> Double? {
        switch metricType {
        case .cpu:
            return metrics.cpu?.usage
        case .memory:
            // 内存使用率（百分比）
            if let memory = metrics.memory {
                return memory.footprintRatio * 100
            }
            return nil
        case .fps:
            return metrics.fps?.fps
        case .jank:
            return Double(metrics.fps?.jankCount ?? 0)
        }
    }

    private func handleViolation(rule: AlertRule, currentValue: Double) {
        let now = Date()

        // 记录违规开始时间
        if violationStartTimes[rule.id] == nil {
            violationStartTimes[rule.id] = now
        }

        guard let startTime = violationStartTimes[rule.id] else { return }

        // 检查是否满足持续时间要求
        let duration = now.timeIntervalSince(startTime)
        guard duration >= Double(rule.durationSeconds) else { return }

        // 检查冷却时间
        if let lastAlert = lastAlertTimes[rule.id] {
            let cooldownElapsed = now.timeIntervalSince(lastAlert)
            guard cooldownElapsed >= Double(config.cooldownSeconds) else { return }
        }

        // 检查是否已有活跃告警
        let existingAlert = activeAlerts.values.first { $0.ruleId == rule.id && !$0.isResolved }
        guard existingAlert == nil else { return }

        // 触发告警
        let alert = createAlert(rule: rule, currentValue: currentValue)
        activeAlerts[alert.id] = alert
        lastAlertTimes[rule.id] = now

        callback(alert)
    }

    private func handleRecovery(rule: AlertRule, currentValue: Double) {
        // 清除违规开始时间
        violationStartTimes.removeValue(forKey: rule.id)

        // 自动解决与该规则相关的告警
        for (alertId, alert) in activeAlerts where alert.ruleId == rule.id && !alert.isResolved {
            var resolvedAlert = alert
            resolvedAlert.isResolved = true
            resolvedAlert.resolvedAt = Date()
            activeAlerts.removeValue(forKey: alertId)

            // 上报恢复事件
            callback(resolvedAlert)
        }
    }

    private func createAlert(rule: AlertRule, currentValue: Double) -> Alert {
        let message = generateAlertMessage(rule: rule, currentValue: currentValue)

        return Alert(
            id: UUID().uuidString,
            ruleId: rule.id,
            metricType: rule.metricType,
            severity: rule.severity,
            message: message,
            currentValue: currentValue,
            threshold: rule.threshold,
            timestamp: Date(),
            isResolved: false,
            resolvedAt: nil
        )
    }

    private func generateAlertMessage(rule: AlertRule, currentValue: Double) -> String {
        let metricName: String
        let unit: String
        let formattedValue: String
        let formattedThreshold: String

        switch rule.metricType {
        case .cpu:
            metricName = "CPU 使用率"
            unit = "%"
            formattedValue = String(format: "%.1f", currentValue)
            formattedThreshold = String(format: "%.1f", rule.threshold)
        case .memory:
            metricName = "内存使用率"
            unit = "%"
            formattedValue = String(format: "%.1f", currentValue)
            formattedThreshold = String(format: "%.1f", rule.threshold)
        case .fps:
            metricName = "帧率"
            unit = "fps"
            formattedValue = String(format: "%.1f", currentValue)
            formattedThreshold = String(format: "%.1f", rule.threshold)
        case .jank:
            metricName = "卡顿次数"
            unit = "次"
            formattedValue = String(format: "%.0f", currentValue)
            formattedThreshold = String(format: "%.0f", rule.threshold)
        }

        let conditionText: String
        switch rule.condition {
        case .greaterThan, .greaterThanOrEqual:
            conditionText = "超过"
        case .lessThan, .lessThanOrEqual:
            conditionText = "低于"
        }

        return "\(metricName)\(conditionText)阈值：当前 \(formattedValue)\(unit)，阈值 \(formattedThreshold)\(unit)"
    }
}