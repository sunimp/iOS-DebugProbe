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
/// 负责采集 CPU、内存、FPS、网络流量、磁盘 I/O 等性能指标并上报
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

    /// 是否监控网络流量
    public var monitorNetwork: Bool = true

    /// 是否监控磁盘 I/O
    public var monitorDiskIO: Bool = true

    /// 是否启用智能采样（根据性能状态动态调整采样频率）
    public var smartSamplingEnabled: Bool = true

    /// 告警配置
    public var alertConfig: AlertConfig = .init(rules: AlertConfig.defaultRules)

    // MARK: - Page Timing Configuration

    /// 是否启用页面耗时监控
    public var monitorPageTiming: Bool = true

    /// 页面耗时采样率（0.0 - 1.0）
    public var pageTimingSamplingRate: Double = 1.0

    /// 是否启用 UIKit 自动采集
    public var pageTimingAutoTrackingEnabled: Bool = true

    // MARK: - Private Properties

    private weak var context: PluginContext?
    private let stateQueue = DispatchQueue(label: "com.sunimp.debugprobe.performance.state")

    /// 性能监控器
    private var cpuMonitor: CPUMonitor?
    private var memoryMonitor: MemoryMonitor?
    @MainActor private var fpsMonitor: FPSMonitor?
    private var networkMonitor: NetworkTrafficMonitor?
    private var diskIOMonitor: DiskIOMonitor?

    /// 采样定时器
    private var sampleTimer: DispatchSourceTimer?

    /// 待上报的指标批次
    private var metricsBatch: [PerformanceMetrics] = []
    private let batchLock = NSLock()

    /// 卡顿检测器（public 以便外部可以动态调整 captureStackTrace）
    @MainActor public private(set) var jankDetector: JankDetector?

    /// 告警检测器
    private var alertChecker: AlertChecker?
    /// 智能采样控制器
    private var smartSampler: SmartSampler?

    /// App 启动阶段时间记录
    private static var phaseTimestamps: [LaunchPhase: CFAbsoluteTime] = [:]
    private static var appLaunchMetrics: AppLaunchMetrics?
    private static let launchMetricsLock = NSLock()

    /// PreMain 详细数据缓存
    private static var cachedPreMainDetails: PreMainDetails?

    // MARK: - Lifecycle

    public init() {}

    /// 记录启动阶段时间点
    /// - Parameter phase: 启动阶段
    public static func recordLaunchPhase(_ phase: LaunchPhase) {
        launchMetricsLock.lock()
        defer { launchMetricsLock.unlock() }

        // 如果该阶段已记录，跳过
        guard phaseTimestamps[phase] == nil else { return }

        let now = CFAbsoluteTimeGetCurrent()

        // 对于 processStart，尝试使用系统真正的进程启动时间
        if phase == .processStart {
            if let processStartTime = getProcessStartTime() {
                phaseTimestamps[phase] = processStartTime
            } else {
                phaseTimestamps[phase] = now
            }
        } else if phase == .mainExecuted {
            // main() 执行时，同时标记 PreMainMonitor
            PreMainMonitor.markMainExecuted()
            phaseTimestamps[phase] = now
        } else {
            phaseTimestamps[phase] = now
        }

        // 当首帧渲染完成时，计算最终指标
        if phase == .firstFrameRendered {
            calculateLaunchMetrics()
        }
    }

    /// 获取进程真正的启动时间（CFAbsoluteTime）
    /// 使用 sysctl 获取进程的 kinfo_proc 结构
    private static func getProcessStartTime() -> CFAbsoluteTime? {
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]

        guard sysctl(&mib, UInt32(mib.count), &kinfo, &size, nil, 0) == 0 else {
            return nil
        }

        let startTime = kinfo.kp_proc.p_starttime
        // timeval 转换为 CFAbsoluteTime
        // CFAbsoluteTime 是从 2001-01-01 00:00:00 UTC 开始的秒数
        // timeval 是从 1970-01-01 00:00:00 UTC 开始的秒数
        // 差值是 978307200 秒
        let unixTime = Double(startTime.tv_sec) + Double(startTime.tv_usec) / 1_000_000
        let cfAbsoluteTime = unixTime - 978_307_200
        return cfAbsoluteTime
    }

    /// 兼容旧 API：记录 App 启动开始时间
    @available(*, deprecated, message: "Use recordLaunchPhase(.processStart) instead")
    public static func recordAppLaunchStart() {
        recordLaunchPhase(.processStart)
    }

    /// 兼容旧 API：记录 App 启动完成
    @available(*, deprecated, message: "Use recordLaunchPhase(.firstFrameRendered) instead")
    public static func recordAppLaunchEnd(isWarmLaunch: Bool = false) {
        // 如果没有记录 processStart，先补记
        if phaseTimestamps[.processStart] == nil {
            // 无法追溯，直接记录当前时间
            launchMetricsLock.lock()
            phaseTimestamps[.processStart] = CFAbsoluteTimeGetCurrent()
            launchMetricsLock.unlock()
        }
        recordLaunchPhase(.firstFrameRendered)
    }

    /// 计算启动指标
    private static func calculateLaunchMetrics() {
        guard let firstFrame = phaseTimestamps[.firstFrameRendered] else { return }

        // 如果 processStart 没有被记录，自动补记（使用系统进程启动时间）
        if phaseTimestamps[.processStart] == nil {
            if let processStartTime = getProcessStartTime() {
                phaseTimestamps[.processStart] = processStartTime
            }
        }

        let processStart = phaseTimestamps[.processStart]
        let mainExecuted = phaseTimestamps[.mainExecuted]
        let didFinish = phaseTimestamps[.didFinishLaunching]

        // 计算各阶段耗时（毫秒）
        var preMainTime: Double?
        var mainToLaunchTime: Double?
        var launchToFirstFrameTime: Double?
        var totalLaunchTime: Double?

        // PreMain: 优先使用 PreMainMonitor 的精确数据
        let preMainDurations = PreMainMonitor.durations
        if PreMainMonitor.isMainExecutedMarked, preMainDurations.totalPreMainMs > 0 {
            // 使用 dyld 回调 + mach_absolute_time 的精确数据
            // 加上估算的内核启动时间，得到完整的 PreMain 时间
            preMainTime = preMainDurations.estimatedFullPreMainMs
        } else if let start = processStart, let main = mainExecuted, main > start {
            // 回退到旧的 CFAbsoluteTime 方式
            preMainTime = (main - start) * 1000
        }

        // MainToLaunch: mainExecuted -> didFinishLaunching
        if let main = mainExecuted, let launch = didFinish {
            mainToLaunchTime = (launch - main) * 1000
        }

        // LaunchToFirstFrame: didFinishLaunching -> firstFrameRendered
        if let launch = didFinish {
            launchToFirstFrameTime = (firstFrame - launch) * 1000
        }

        // TotalLaunchTime: processStart -> firstFrameRendered
        if let start = processStart {
            totalLaunchTime = (firstFrame - start) * 1000
        }

        // 缓存 PreMain 详细数据
        if PreMainMonitor.isMainExecutedMarked {
            cachedPreMainDetails = PreMainDetails(
                durations: preMainDurations,
                dylibStats: PreMainMonitor.dylibStats,
                slowestDylibs: PreMainMonitor.getSlowestDylibs(count: 20)
            )
        }

        appLaunchMetrics = AppLaunchMetrics(
            totalTime: totalLaunchTime ?? 0,
            preMainTime: preMainTime,
            mainToLaunchTime: mainToLaunchTime,
            launchToFirstFrameTime: launchToFirstFrameTime,
            timestamp: Date()
        )
    }

    /// 获取 PreMain 详细数据
    /// 包含 dyld 各阶段耗时和 dylib 加载详情
    public static func getPreMainDetails() -> PreMainDetails? {
        launchMetricsLock.lock()
        defer { launchMetricsLock.unlock() }
        return cachedPreMainDetails
    }

    /// 获取所有 dylib 加载信息
    public static func getAllDylibLoadInfo() -> [DylibLoadInfo] {
        PreMainMonitor.getAllDylibs()
    }

    /// 获取加载最慢的 N 个 dylib
    public static func getSlowestDylibs(count: Int) -> [DylibLoadInfo] {
        PreMainMonitor.getSlowestDylibs(count: count)
    }

    /// 获取用户库加载信息（非系统库）
    public static func getUserDylibLoadInfo() -> [DylibLoadInfo] {
        PreMainMonitor.getUserDylibs()
    }

    /// 重置启动记录（用于热启动场景）
    public static func resetLaunchRecording() {
        launchMetricsLock.lock()
        phaseTimestamps.removeAll()
        appLaunchMetrics = nil
        launchMetricsLock.unlock()
    }

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

        // 恢复告警配置
        if
            let alertConfigData: Data = context.getConfiguration(for: "performance.alertConfig"),
            let savedConfig = try? JSONDecoder().decode(AlertConfig.self, from: alertConfigData) {
            alertConfig = savedConfig
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
                // 同步 captureStackTrace 设置
                jankDetector?.captureStackTrace = DebugProbeSettings.shared.captureStackTrace
            }
        }
        if monitorNetwork {
            networkMonitor = NetworkTrafficMonitor()
        }
        if monitorDiskIO {
            diskIOMonitor = DiskIOMonitor()
        }

        // 初始化页面耗时监控
        if monitorPageTiming {
            setupPageTimingRecorder()
        }

        // 初始化告警检测器
        alertChecker = AlertChecker(config: alertConfig) { [weak self] alert in
            self?.reportAlert(alert)
        }

        // 初始化智能采样控制器
        if smartSamplingEnabled {
            smartSampler = SmartSampler(baseInterval: sampleInterval)
        }

        // 启动采样定时器
        startSampleTimer()

        // 上报启动时间指标（如果有）
        reportAppLaunchMetrics()

        stateQueue.sync { state = .running }
        context?
            .logInfo(
                "PerformancePlugin started with interval: \(sampleInterval)s, smart sampling: \(smartSamplingEnabled), pageTiming: \(monitorPageTiming)"
            )
    }

    public func pause() async {
        guard state == .running else { return }

        isEnabled = false
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

        isEnabled = true
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
            fpsMonitor = nil
            jankDetector = nil
        }
        cpuMonitor = nil
        memoryMonitor = nil
        networkMonitor = nil
        diskIOMonitor = nil
        alertChecker = nil
        smartSampler = nil

        // 停止页面耗时记录器
        stopPageTimingRecorder()

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
        let interval = smartSampler?.currentInterval ?? sampleInterval
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
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

    /// 重启定时器（智能采样间隔变化时调用）
    private func restartSampleTimerIfNeeded() {
        guard smartSamplingEnabled, let sampler = smartSampler else { return }
        let newInterval = sampler.currentInterval

        // 仅当间隔变化较大时才重启定时器
        let currentInterval = sampleInterval
        if abs(newInterval - currentInterval) > 0.1 {
            stopSampleTimer()
            startSampleTimer()
        }
    }

    private func collectAndReportMetrics() {
        var cpuMetrics: CPUMetrics?
        var memoryMetrics: MemoryMetrics?
        var fpsMetrics: FPSMetrics?
        var networkMetrics: NetworkTrafficMetrics?
        var diskIOMetrics: DiskIOMetrics?

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

        // 采集网络流量
        if monitorNetwork {
            networkMetrics = networkMonitor?.collect()
        }

        // 采集磁盘 I/O
        if monitorDiskIO {
            diskIOMetrics = diskIOMonitor?.collect()
        }

        let metrics = PerformanceMetrics(
            timestamp: Date(),
            cpu: cpuMetrics,
            memory: memoryMetrics,
            fps: fpsMetrics,
            network: networkMetrics,
            diskIO: diskIOMetrics
        )

        // 智能采样调整
        if let sampler = smartSampler {
            sampler.updateWithMetrics(metrics)
            restartSampleTimerIfNeeded()
        }

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
                cpu: m.cpu.map { CPUMetricsData(
                    usage: $0.usage,
                    userTime: $0.userTime,
                    systemTime: $0.systemTime,
                    threadCount: $0.threadCount
                ) },
                memory: m.memory.map { MemoryMetricsData(
                    usedMemory: $0.usedMemory,
                    peakMemory: $0.peakMemory,
                    freeMemory: $0.freeMemory,
                    memoryPressure: $0.memoryPressure.rawValue,
                    footprintRatio: $0.footprintRatio
                ) },
                fps: m.fps.map { FPSMetricsData(
                    fps: $0.fps,
                    droppedFrames: $0.droppedFrames,
                    jankCount: $0.jankCount,
                    averageRenderTime: $0.averageRenderTime
                ) },
                network: m.network.map { NetworkTrafficMetricsData(
                    bytesReceived: $0.bytesReceived,
                    bytesSent: $0.bytesSent,
                    receivedRate: $0.receivedRate,
                    sentRate: $0.sentRate
                ) },
                diskIO: m.diskIO.map { DiskIOMetricsData(
                    readBytes: $0.readBytes,
                    writeBytes: $0.writeBytes,
                    readOps: $0.readOps,
                    writeOps: $0.writeOps,
                    readRate: $0.readRate,
                    writeRate: $0.writeRate
                ) }
            )
        }

        // 通过 EventCallbacks 直接发送到 BridgeClient
        let performanceEvent = PerformanceEvent(
            eventType: .metrics,
            metrics: metricsData
        )
        EventCallbacks.reportEvent(.performance(performanceEvent))
    }

    /// 上报 App 启动时间指标
    private func reportAppLaunchMetrics() {
        guard let launchMetrics = Self.appLaunchMetrics else { return }

        // 构建 PreMain 细分数据
        var preMainDetailsData: PreMainDetailsData?
        if let details = Self.cachedPreMainDetails {
            let dylibStatsData = DylibStatsData(
                totalCount: details.dylibStats.totalCount,
                systemCount: details.dylibStats.systemCount,
                userCount: details.dylibStats.userCount
            )

            let slowestDylibsData = details.slowestDylibs.map { dylib in
                DylibLoadInfoData(
                    name: dylib.name,
                    loadDurationMs: dylib.loadDurationMs,
                    isSystemLibrary: dylib.isSystemLibrary
                )
            }

            preMainDetailsData = PreMainDetailsData(
                dylibLoadingMs: details.durations.dylibLoadingMs,
                staticInitializerMs: details.durations.staticInitializerMs,
                postDyldToMainMs: details.durations.postDyldToMainMs,
                objcLoadMs: details.durations.objcLoadMs > 0 ? details.durations.objcLoadMs : nil,
                estimatedKernelToConstructorMs: details.durations.estimatedKernelToConstructorMs,
                dylibStats: dylibStatsData,
                slowestDylibs: slowestDylibsData
            )
        }

        let launchData = AppLaunchMetricsData(
            totalTime: launchMetrics.totalTime,
            preMainTime: launchMetrics.preMainTime,
            mainToLaunchTime: launchMetrics.mainToLaunchTime,
            launchToFirstFrameTime: launchMetrics.launchToFirstFrameTime,
            timestamp: launchMetrics.timestamp,
            preMainDetails: preMainDetailsData
        )
        let performanceEvent = PerformanceEvent(
            eventType: .appLaunch,
            appLaunch: launchData
        )
        EventCallbacks.reportEvent(.performance(performanceEvent))

        // 日志输出
        var logParts = ["App launch time reported: total=\(launchMetrics.totalTime)ms"]
        if let preMain = launchMetrics.preMainTime {
            logParts.append("preMain=\(preMain)ms")
        }
        if let mainToLaunch = launchMetrics.mainToLaunchTime {
            logParts.append("mainToLaunch=\(mainToLaunch)ms")
        }
        if let launchToFrame = launchMetrics.launchToFirstFrameTime {
            logParts.append("launchToFirstFrame=\(launchToFrame)ms")
        }
        if let details = preMainDetailsData {
            if let dylibLoading = details.dylibLoadingMs {
                logParts.append("dylibLoading=\(String(format: "%.1f", dylibLoading))ms")
            }
            if let dylibStats = details.dylibStats {
                logParts.append("dylibs=\(dylibStats.totalCount)(\(dylibStats.userCount) user)")
            }
        }
        context?.logInfo(logParts.joined(separator: ", "))

        // 清除已上报的启动指标
        Self.appLaunchMetrics = nil
    }

    // MARK: - Page Timing

    /// 设置页面耗时记录器
    private func setupPageTimingRecorder() {
        let recorder = PageTimingRecorder.shared
        recorder.autoTrackingEnabled = pageTimingAutoTrackingEnabled
        recorder.samplingRate = pageTimingSamplingRate

        // 注册事件回调
        recorder.onPageTimingEvent = { [weak self] event in
            self?.reportPageTimingEvent(event)
        }

        // 同时注册到 EventCallbacks
        EventCallbacks.onPageTimingEvent = { [weak self] event in
            self?.reportPageTimingEvent(event)
        }

        // 启动自动采集
        if pageTimingAutoTrackingEnabled {
            recorder.startAutoTracking()
        }

        context?
            .logInfo(
                "PageTimingRecorder setup: autoTracking=\(pageTimingAutoTrackingEnabled), samplingRate=\(pageTimingSamplingRate)"
            )
    }

    /// 停止页面耗时记录器
    private func stopPageTimingRecorder() {
        PageTimingRecorder.shared.stopAutoTracking()
        PageTimingRecorder.shared.onPageTimingEvent = nil
        EventCallbacks.onPageTimingEvent = nil
    }

    /// 上报页面耗时事件
    private func reportPageTimingEvent(_ event: PageTimingEvent) {
        let performanceEvent = PerformanceEvent(
            eventType: .pageTiming,
            pageTiming: PageTimingData(from: event)
        )
        EventCallbacks.reportEvent(.performance(performanceEvent))

        // 日志输出
        var logParts = ["Page timing: \(event.pageName)"]
        if let appearDuration = event.appearDuration {
            logParts.append("appear=\(String(format: "%.1f", appearDuration))ms")
        }
        if let loadDuration = event.loadDuration {
            logParts.append("load=\(String(format: "%.1f", loadDuration))ms")
        }
        context?.logDebug(logParts.joined(separator: ", "))
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
        var networkMetrics: NetworkTrafficMetrics?
        var diskIOMetrics: DiskIOMetrics?

        if monitorCPU {
            cpuMetrics = cpuMonitor?.collect()
        }
        if monitorMemory {
            memoryMetrics = memoryMonitor?.collect()
        }
        if monitorNetwork {
            networkMetrics = networkMonitor?.collect()
        }
        if monitorDiskIO {
            diskIOMetrics = diskIOMonitor?.collect()
        }

        // FPS 需要在主线程采集，使用返回值方式避免 Swift 6 并发警告
        let fpsMetrics: FPSMetrics? = await {
            if monitorFPS {
                return await MainActor.run { fpsMonitor?.collect() }
            }
            return nil
        }()

        let metrics = PerformanceMetrics(
            timestamp: Date(),
            cpu: cpuMetrics,
            memory: memoryMetrics,
            fps: fpsMetrics,
            network: networkMetrics,
            diskIO: diskIOMetrics
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
                // 持久化告警配置
                persistAlertConfig()
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
                // 持久化告警配置
                persistAlertConfig()
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
                // 持久化告警配置
                persistAlertConfig()
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
                    // 持久化告警配置
                    persistAlertConfig()
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

    /// 持久化告警配置
    private func persistAlertConfig() {
        do {
            let data = try JSONEncoder().encode(alertConfig)
            context?.setConfiguration(data, for: "performance.alertConfig")
        } catch {
            context?.logError("Failed to persist alert config: \(error)")
        }
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

/// 网络流量指标
public struct NetworkTrafficMetrics: Codable, Sendable {
    /// 累计接收字节数
    public let bytesReceived: UInt64
    /// 累计发送字节数
    public let bytesSent: UInt64
    /// 接收速率（字节/秒）
    public let receivedRate: Double
    /// 发送速率（字节/秒）
    public let sentRate: Double
}

/// 磁盘 I/O 指标
public struct DiskIOMetrics: Codable, Sendable {
    /// 累计读取字节数
    public let readBytes: UInt64
    /// 累计写入字节数
    public let writeBytes: UInt64
    /// 读取操作次数
    public let readOps: UInt64
    /// 写入操作次数
    public let writeOps: UInt64
    /// 读取速率（字节/秒）
    public let readRate: Double
    /// 写入速率（字节/秒）
    public let writeRate: Double
}

/// App 启动阶段
public enum LaunchPhase: String, Codable, Sendable, Hashable {
    /// 进程启动（main() 执行前，PreMain 阶段开始）
    case processStart
    /// main() 函数开始执行
    case mainExecuted
    /// application(_:didFinishLaunchingWithOptions:) 完成
    case didFinishLaunching
    /// 首帧渲染完成
    case firstFrameRendered
}

/// PreMain 详细数据
/// 包含 dyld 各阶段耗时和 dylib 加载详情
public struct PreMainDetails: Codable, Sendable {
    /// PreMain 各阶段耗时
    public let durations: PreMainDurations

    /// dylib 统计信息
    public let dylibStats: DylibStats

    /// 加载最慢的 dylib 列表
    public let slowestDylibs: [DylibLoadInfo]

    public init(
        durations: PreMainDurations,
        dylibStats: DylibStats,
        slowestDylibs: [DylibLoadInfo]
    ) {
        self.durations = durations
        self.dylibStats = dylibStats
        self.slowestDylibs = slowestDylibs
    }
}

/// App 启动时间指标（分阶段记录）
public struct AppLaunchMetrics: Codable, Sendable {
    /// 总启动时间（毫秒）：从 processStart 到 firstFrameRendered
    public let totalTime: Double
    /// PreMain 阶段耗时（毫秒）：processStart -> mainExecuted
    public let preMainTime: Double?
    /// Main 到 Launch 阶段耗时（毫秒）：mainExecuted -> didFinishLaunching
    public let mainToLaunchTime: Double?
    /// Launch 到首帧阶段耗时（毫秒）：didFinishLaunching -> firstFrameRendered
    public let launchToFirstFrameTime: Double?
    /// 记录时间戳
    public let timestamp: Date
}

/// 性能指标汇总
public struct PerformanceMetrics: Codable, Sendable {
    public let timestamp: Date
    public let cpu: CPUMetrics?
    public let memory: MemoryMetrics?
    public let fps: FPSMetrics?
    public let network: NetworkTrafficMetrics?
    public let diskIO: DiskIOMetrics?
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
            value > threshold
        case .lessThan:
            value < threshold
        case .greaterThanOrEqual:
            value >= threshold
        case .lessThanOrEqual:
            value <= threshold
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
    public final class JankDetector {
        private var displayLink: CADisplayLink?
        private var lastTimestamp: CFTimeInterval = 0
        private let callback: @Sendable (JankEvent) -> Void
        private var jankStartTime: CFTimeInterval?
        private var consecutiveDrops: Int = 0

        /// 是否启用调用栈捕获（性能开销较大）
        public var captureStackTrace: Bool = false

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
                    let stackTrace = captureStackTrace ? Self.captureMainThreadStackTrace() : nil
                    let event = JankEvent(
                        id: UUID().uuidString,
                        timestamp: Date(),
                        duration: duration,
                        droppedFrames: consecutiveDrops,
                        stackTrace: stackTrace
                    )
                    callback(event)
                }
                jankStartTime = nil
                consecutiveDrops = 0
            }
        }

        /// 捕获主线程调用栈
        /// 注意：这个方法从 CADisplayLink 回调中调用，获取的是当前执行点的调用栈
        /// 由于卡顿检测是在帧渲染结束后进行的，捕获的调用栈可能是渲染完成后的代码
        /// 要获取真正导致卡顿的调用栈，需要使用更高级的方法（如 watchdog 线程）
        private static func captureMainThreadStackTrace() -> String? {
            // 使用 Thread.callStackSymbols 获取当前调用栈
            let symbols = Thread.callStackSymbols

            guard !symbols.isEmpty else { return nil }

            // 需要过滤的系统框架和 DebugProbe 内部代码
            let systemFrameworks = [
                "DebugProbe",
                "CoreFoundation",
                "UIKitCore",
                "UIKit",
                "GraphicsServices",
                "libdyld",
                "libsystem",
                "libSystem",
                "QuartzCore",
                "CoreAnimation",
                "Foundation",
                "libdispatch",
                "libobjc",
                "AttributeGraph",
                "SwiftUI",
                "Combine",
            ]

            // 过滤系统框架，保留用户代码
            // 跳过前 2 帧（captureMainThreadStackTrace 和 displayLinkCallback）
            let filtered = symbols.dropFirst(2).prefix(40).filter { symbol in
                !systemFrameworks.contains { framework in
                    symbol.contains(framework)
                }
            }

            // 如果过滤后为空，返回原始调用栈的前 20 帧（跳过前 2 帧）
            let framesToFormat = filtered.isEmpty
                ? Array(symbols.dropFirst(2).prefix(20))
                : Array(filtered.prefix(25))

            guard !framesToFormat.isEmpty else { return nil }

            // 格式化符号
            let formatted = framesToFormat.enumerated().map { index, symbol in
                formatStackFrame(symbol, index: index)
            }

            return formatted.joined(separator: "\n")
        }

        /// 格式化单个栈帧
        private static func formatStackFrame(_ symbol: String, index: Int) -> String {
            // 原始格式: "4   MyApp    0x0000000100001234 $s5MyApp..."
            // 或: "4   MyApp    0x0000000100001234 _objc_msgSend + 68"
            let parts = symbol.split(whereSeparator: { $0 == " " }).filter { !$0.isEmpty }
            guard parts.count >= 4 else { return "\(index)  \(symbol)" }

            let module = String(parts[1])
            let remaining = parts.dropFirst(3).map(String.init).joined(separator: " ")

            // 尝试 demangle 符号
            let demangled = demangleSymbol(remaining)

            // 简化输出格式，更易读
            // 格式: 序号  模块名  解析后的符号
            return String(format: "%2d  [%@] %@", index, module, demangled)
        }

        /// 符号缓存，避免重复 demangle
        private static var demangleCache: [String: String] = [:]
        private static let demangleCacheLock = NSLock()

        /// 解析符号名（支持 Swift 和 ObjC）
        private static func demangleSymbol(_ symbol: String) -> String {
            // 检查缓存
            demangleCacheLock.lock()
            if let cached = demangleCache[symbol] {
                demangleCacheLock.unlock()
                return cached
            }
            demangleCacheLock.unlock()

            let result: String

            // Swift 符号以 $s、_$s、$S 或 _$S 开头
            if
                symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") ||
                symbol.hasPrefix("$S") || symbol.hasPrefix("_$S") {
                result = demangleSwiftSymbol(symbol) ?? symbol
            } else if symbol.hasPrefix("-[") || symbol.hasPrefix("+[") {
                // ObjC 符号通常格式为 "-[Class method]" 或 "+[Class method]"
                result = symbol
            } else if let plusIndex = symbol.lastIndex(of: "+") {
                // C 函数格式 "function_name + offset"
                let functionPart = symbol[..<plusIndex].trimmingCharacters(in: .whitespaces)
                let offsetPart = symbol[symbol.index(after: plusIndex)...].trimmingCharacters(in: .whitespaces)
                result = "\(functionPart) + \(offsetPart)"
            } else {
                result = symbol
            }

            // 缓存结果（限制缓存大小）
            demangleCacheLock.lock()
            if demangleCache.count < 1000 {
                demangleCache[symbol] = result
            }
            demangleCacheLock.unlock()

            return result
        }

        /// Swift 符号 demangle
        /// 使用私有 API swift_demangle 进行解码
        private static func demangleSwiftSymbol(_ symbol: String) -> String? {
            // 尝试使用 Swift 运行时的 demangle 函数
            if
                let demangled = _stdlib_demangleImpl(symbol),
                !demangled.isEmpty,
                demangled != symbol {
                // 简化输出：移除泛型参数中的完整模块路径
                return simplifySwiftSymbol(demangled)
            }

            // 回退：手动解析简单的 Swift 符号
            return manualDemangleSwift(symbol)
        }

        /// 简化 Swift 符号，移除不必要的细节
        private static func simplifySwiftSymbol(_ symbol: String) -> String {
            var result = symbol

            // 移除 @objc 包装
            if result.hasPrefix("@objc ") {
                result = String(result.dropFirst(6))
            }

            // 简化常见的泛型类型
            result = result.replacingOccurrences(of: "Swift.Optional<", with: "Optional<")
            result = result.replacingOccurrences(of: "Swift.Array<", with: "Array<")
            result = result.replacingOccurrences(of: "Swift.Dictionary<", with: "Dictionary<")
            result = result.replacingOccurrences(of: "Swift.String", with: "String")
            result = result.replacingOccurrences(of: "Swift.Int", with: "Int")
            result = result.replacingOccurrences(of: "Swift.Bool", with: "Bool")

            return result
        }

        /// 调用 Swift 运行时的 demangle 函数
        private static func _stdlib_demangleImpl(_ mangledName: String) -> String? {
            // swift_demangle 是 Swift 运行时的私有函数
            // 函数签名: char *swift_demangle(const char *mangledName, size_t mangledNameLength, char *outputBuffer, size_t *outputBufferSize, uint32_t flags)

            typealias SwiftDemangle = @convention(c) (
                UnsafePointer<CChar>?,
                Int,
                UnsafeMutablePointer<CChar>?,
                UnsafeMutablePointer<Int>?,
                UInt32
            ) -> UnsafeMutablePointer<CChar>?

            // 获取 swift_demangle 函数指针
            guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
            defer { dlclose(handle) }

            guard let sym = dlsym(handle, "swift_demangle") else { return nil }
            let demangle = unsafeBitCast(sym, to: SwiftDemangle.self)

            // 调用 demangle
            let result = mangledName.withCString { cString -> String? in
                guard let demangled = demangle(cString, mangledName.utf8.count, nil, nil, 0) else {
                    return nil
                }
                defer { free(demangled) }
                return String(cString: demangled)
            }

            return result
        }

        /// 手动解析简单的 Swift 符号
        private static func manualDemangleSwift(_ symbol: String) -> String? {
            var s = symbol

            // 移除前缀
            if s.hasPrefix("_$s") {
                s = String(s.dropFirst(3))
            } else if s.hasPrefix("$s") {
                s = String(s.dropFirst(2))
            } else {
                return nil
            }

            // 尝试提取模块名和函数名
            // Swift mangled name 格式较复杂，这里只做简单提取
            var result: [String] = []

            // 查找数字前缀（表示名称长度）
            var index = s.startIndex
            while index < s.endIndex {
                // 读取数字
                var numStr = ""
                while index < s.endIndex, s[index].isNumber {
                    numStr.append(s[index])
                    index = s.index(after: index)
                }

                guard let length = Int(numStr), length > 0 else { break }
                guard s.distance(from: index, to: s.endIndex) >= length else { break }

                let endIndex = s.index(index, offsetBy: length)
                let name = String(s[index..<endIndex])
                result.append(name)
                index = endIndex
            }

            guard result.count >= 2 else { return nil }

            // 格式化输出：Module.Function
            return result.joined(separator: ".")
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
    public final class JankDetector {
        public var captureStackTrace: Bool = false
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
        config = newConfig
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

        let conditionText = switch rule.condition {
        case .greaterThan, .greaterThanOrEqual:
            "超过"
        case .lessThan, .lessThanOrEqual:
            "低于"
        }

        return "\(metricName)\(conditionText)阈值：当前 \(formattedValue)\(unit)，阈值 \(formattedThreshold)\(unit)"
    }
}

// MARK: - Network Traffic Monitor

/// 网络流量监控器
final class NetworkTrafficMonitor: @unchecked Sendable {
    private var lastBytesReceived: UInt64 = 0
    private var lastBytesSent: UInt64 = 0
    private var lastTimestamp: CFAbsoluteTime = 0

    init() {
        // 初始化时采集一次基准值
        let (received, sent) = getNetworkBytes()
        lastBytesReceived = received
        lastBytesSent = sent
        lastTimestamp = CFAbsoluteTimeGetCurrent()
    }

    func collect() -> NetworkTrafficMetrics {
        let currentTime = CFAbsoluteTimeGetCurrent()
        let (currentReceived, currentSent) = getNetworkBytes()

        let timeDelta = currentTime - lastTimestamp
        let receivedDelta = currentReceived >= lastBytesReceived ? currentReceived - lastBytesReceived : currentReceived
        let sentDelta = currentSent >= lastBytesSent ? currentSent - lastBytesSent : currentSent

        let receivedRate = timeDelta > 0 ? Double(receivedDelta) / timeDelta : 0
        let sentRate = timeDelta > 0 ? Double(sentDelta) / timeDelta : 0

        // 更新上次值
        lastBytesReceived = currentReceived
        lastBytesSent = currentSent
        lastTimestamp = currentTime

        return NetworkTrafficMetrics(
            bytesReceived: currentReceived,
            bytesSent: currentSent,
            receivedRate: receivedRate,
            sentRate: sentRate
        )
    }

    private func getNetworkBytes() -> (received: UInt64, sent: UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var totalReceived: UInt64 = 0
        var totalSent: UInt64 = 0

        var ptr = ifaddr
        while ptr != nil {
            if let data = ptr?.pointee.ifa_data {
                let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                totalReceived += UInt64(networkData.ifi_ibytes)
                totalSent += UInt64(networkData.ifi_obytes)
            }
            ptr = ptr?.pointee.ifa_next
        }

        return (totalReceived, totalSent)
    }
}

// MARK: - Disk I/O Monitor

/// 磁盘 I/O 监控器
/// - macOS：使用 proc_pid_rusage 获取进程级磁盘 I/O 统计
/// - iOS：监控应用目录大小变化，估算写入操作
final class DiskIOMonitor: @unchecked Sendable {
    private var lastReadBytes: UInt64 = 0
    private var lastWriteBytes: UInt64 = 0
    private var lastReadOps: UInt64 = 0
    private var lastWriteOps: UInt64 = 0
    private var lastTimestamp: CFAbsoluteTime = 0

    #if os(iOS) || os(tvOS) || os(watchOS)
        /// iOS: 缓存应用目录大小用于估算写入
        private var lastDirectorySize: UInt64 = 0
        /// iOS: 追踪文件读取操作（通过 hook 或估算）
        private var estimatedReadOps: UInt64 = 0
        private var estimatedWriteOps: UInt64 = 0
    #endif

    init() {
        // 初始化时采集一次基准值
        let stats = getDiskIOStats()
        lastReadBytes = stats.readBytes
        lastWriteBytes = stats.writeBytes
        lastReadOps = stats.readOps
        lastWriteOps = stats.writeOps
        lastTimestamp = CFAbsoluteTimeGetCurrent()
    }

    func collect() -> DiskIOMetrics {
        let currentTime = CFAbsoluteTimeGetCurrent()
        let stats = getDiskIOStats()

        let timeDelta = currentTime - lastTimestamp
        let readDelta = stats.readBytes >= lastReadBytes ? stats.readBytes - lastReadBytes : stats.readBytes
        let writeDelta = stats.writeBytes >= lastWriteBytes ? stats.writeBytes - lastWriteBytes : stats.writeBytes

        let readRate = timeDelta > 0 ? Double(readDelta) / timeDelta : 0
        let writeRate = timeDelta > 0 ? Double(writeDelta) / timeDelta : 0

        // 更新上次值
        lastReadBytes = stats.readBytes
        lastWriteBytes = stats.writeBytes
        lastReadOps = stats.readOps
        lastWriteOps = stats.writeOps
        lastTimestamp = currentTime

        return DiskIOMetrics(
            readBytes: stats.readBytes,
            writeBytes: stats.writeBytes,
            readOps: stats.readOps,
            writeOps: stats.writeOps,
            readRate: readRate,
            writeRate: writeRate
        )
    }

    private func getDiskIOStats() -> (readBytes: UInt64, writeBytes: UInt64, readOps: UInt64, writeOps: UInt64) {
        #if os(macOS)
            return getMacOSDiskIOStats()
        #else
            return getiOSDiskIOStats()
        #endif
    }

    #if os(macOS)
        /// macOS: 使用 proc_pid_rusage 获取精确的磁盘 I/O 统计
        private func getMacOSDiskIOStats()
            -> (readBytes: UInt64, writeBytes: UInt64, readOps: UInt64, writeOps: UInt64) {
            var rusage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &rusage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            }

            if result == 0 {
                return (
                    readBytes: rusage.ri_diskio_bytesread,
                    writeBytes: rusage.ri_diskio_byteswritten,
                    readOps: 0,
                    writeOps: 0
                )
            }
            return (0, 0, 0, 0)
        }
    #else
        /// iOS: 通过监控应用目录大小变化和资源使用估算磁盘 I/O
        private func getiOSDiskIOStats() -> (readBytes: UInt64, writeBytes: UInt64, readOps: UInt64, writeOps: UInt64) {
            // 获取应用目录总大小作为累计写入量的估算
            let currentDirectorySize = calculateAppDirectorySize()

            // 写入字节估算：目录大小增长量
            let writeEstimate = currentDirectorySize

            // 读取估算：基于内存映射文件和系统资源使用
            // 使用 getrusage 获取页面错误数作为读取操作的间接指标
            var usage = rusage()
            let readEstimate: UInt64
            let readOps: UInt64
            let writeOps: UInt64

            if getrusage(RUSAGE_SELF, &usage) == 0 {
                // 页面错误（major faults）通常意味着从磁盘读取
                // 每次 major fault 约等于一个页面（通常 16KB）
                let majorFaults = UInt64(max(0, usage.ru_majflt))
                let pageSize: UInt64 = 16384 // iOS 通常使用 16KB 页面

                readEstimate = majorFaults * pageSize
                readOps = majorFaults
                writeOps = estimatedWriteOps
            } else {
                readEstimate = 0
                readOps = 0
                writeOps = 0
            }

            // 检测目录大小变化来估算写入操作次数
            if currentDirectorySize > lastDirectorySize {
                estimatedWriteOps += 1
            }
            lastDirectorySize = currentDirectorySize

            return (
                readBytes: readEstimate,
                writeBytes: writeEstimate,
                readOps: readOps,
                writeOps: estimatedWriteOps
            )
        }

        /// 计算应用目录总大小（用于估算写入量）
        private func calculateAppDirectorySize() -> UInt64 {
            let fileManager = FileManager.default
            var totalSize: UInt64 = 0

            // 主要监控的目录
            let directories: [FileManager.SearchPathDirectory] = [
                .documentDirectory,
                .cachesDirectory,
                .libraryDirectory,
            ]

            for directory in directories {
                guard let path = fileManager.urls(for: directory, in: .userDomainMask).first else {
                    continue
                }

                totalSize += directorySize(at: path)
            }

            // 添加临时目录
            let tempPath = URL(fileURLWithPath: NSTemporaryDirectory())
            totalSize += directorySize(at: tempPath)

            return totalSize
        }

        /// 递归计算目录大小
        private func directorySize(at url: URL) -> UInt64 {
            let fileManager = FileManager.default
            var size: UInt64 = 0

            guard
                let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles],
                    errorHandler: nil
                ) else {
                return 0
            }

            for case let fileURL as URL in enumerator {
                do {
                    let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if resourceValues.isRegularFile == true {
                        size += UInt64(resourceValues.fileSize ?? 0)
                    }
                } catch {
                    // 忽略无法访问的文件
                    continue
                }
            }

            return size
        }
    #endif
}

// MARK: - Smart Sampler

/// 智能采样控制器
/// 根据性能状态动态调整采样频率
final class SmartSampler: @unchecked Sendable {
    private let baseInterval: TimeInterval
    private var _currentInterval: TimeInterval
    private let lock = NSLock()

    /// 采样间隔范围
    private let minInterval: TimeInterval = 0.5
    private let maxInterval: TimeInterval = 5.0

    /// 性能状态评估
    private var recentCPUUsage: [Double] = []
    private var recentMemoryUsage: [Double] = []
    private let maxSamples = 10

    var currentInterval: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return _currentInterval
    }

    init(baseInterval: TimeInterval) {
        self.baseInterval = baseInterval
        _currentInterval = baseInterval
    }

    func updateWithMetrics(_ metrics: PerformanceMetrics) {
        lock.lock()
        defer { lock.unlock() }

        // 记录最近的 CPU 和内存使用率
        if let cpu = metrics.cpu {
            recentCPUUsage.append(cpu.usage)
            if recentCPUUsage.count > maxSamples {
                recentCPUUsage.removeFirst()
            }
        }
        if let memory = metrics.memory {
            recentMemoryUsage.append(memory.footprintRatio * 100)
            if recentMemoryUsage.count > maxSamples {
                recentMemoryUsage.removeFirst()
            }
        }

        // 计算平均值和波动性
        let avgCPU = recentCPUUsage.isEmpty ? 0 : recentCPUUsage.reduce(0, +) / Double(recentCPUUsage.count)
        let avgMemory = recentMemoryUsage.isEmpty ? 0 : recentMemoryUsage.reduce(0, +) / Double(recentMemoryUsage.count)

        // 计算波动性（标准差）
        let cpuVariance = calculateVariance(recentCPUUsage)
        let memoryVariance = calculateVariance(recentMemoryUsage)

        // 调整采样间隔
        var newInterval = baseInterval

        // 高负载或高波动时增加采样频率
        if avgCPU > 80 || avgMemory > 80 || cpuVariance > 100 || memoryVariance > 100 {
            newInterval = minInterval
        } else if avgCPU > 50 || avgMemory > 50 || cpuVariance > 50 || memoryVariance > 50 {
            newInterval = baseInterval * 0.5
        } else if avgCPU < 20, avgMemory < 30, cpuVariance < 10, memoryVariance < 10 {
            // 低负载且稳定时降低采样频率
            newInterval = min(baseInterval * 2, maxInterval)
        }

        _currentInterval = max(minInterval, min(newInterval, maxInterval))
    }

    private func calculateVariance(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let squaredDiffs = values.map { pow($0 - mean, 2) }
        return squaredDiffs.reduce(0, +) / Double(values.count)
    }
}
