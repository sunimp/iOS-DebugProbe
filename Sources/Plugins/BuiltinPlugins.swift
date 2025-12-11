// BuiltinPlugins.swift
// DebugProbe
//
// Created by Sun on 2025/12/09.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - 内置插件注册

/// 内置插件工厂
/// 负责创建和注册所有内置插件
public enum BuiltinPlugins {
    /// 创建所有内置插件实例
    /// - Returns: 内置插件数组
    public static func createAll() -> [DebugProbePlugin] {
        [
            NetworkPlugin(),
            LogPlugin(),
            WebSocketPlugin(),
            DatabasePlugin(),
            MockPlugin(),
            BreakpointPlugin(),
            ChaosPlugin(),
            PerformancePlugin(),
        ]
    }

    /// 注册所有内置插件到插件管理器
    public static func registerAll() throws {
        let plugins = createAll()
        try PluginManager.shared.register(plugins: plugins)
    }

    /// 创建指定的内置插件
    /// - Parameter pluginId: 插件 ID
    /// - Returns: 插件实例，不存在则返回 nil
    public static func create(pluginId: String) -> DebugProbePlugin? {
        switch pluginId {
        case BuiltinPluginId.network:
            NetworkPlugin()
        case BuiltinPluginId.log:
            LogPlugin()
        case BuiltinPluginId.webSocket:
            WebSocketPlugin()
        case BuiltinPluginId.database:
            DatabasePlugin()
        case BuiltinPluginId.mock:
            MockPlugin()
        case BuiltinPluginId.breakpoint:
            BreakpointPlugin()
        case BuiltinPluginId.chaos:
            ChaosPlugin()
        case BuiltinPluginId.performance:
            PerformancePlugin()
        default:
            nil
        }
    }
}

// MARK: - Breakpoint Plugin

/// 断点调试插件
public final class BreakpointPlugin: DebugProbePlugin, @unchecked Sendable {
    public let pluginId: String = BuiltinPluginId.breakpoint
    public let displayName: String = "Breakpoint"
    public let version: String = "1.0.0"
    public let pluginDescription: String = "HTTP 请求断点调试"
    public let dependencies: [String] = [BuiltinPluginId.network]

    public private(set) var state: PluginState = .uninitialized
    public private(set) var isEnabled: Bool = true

    private weak var context: PluginContext?
    private let stateQueue = DispatchQueue(label: "com.sunimp.debugprobe.breakpoint.state")

    private var breakpointEngine: BreakpointEngine { BreakpointEngine.shared }

    public init() {}

    public func initialize(context: PluginContext) {
        self.context = context
        if let enabled: Bool = context.getConfiguration(for: "breakpoint.enabled") {
            isEnabled = enabled
        }
        state = .stopped
        context.logInfo("BreakpointPlugin initialized")
    }

    public func start() async throws {
        guard state != .running else { return }
        stateQueue.sync { state = .starting }

        // 注册 EventCallbacks 处理器
        registerEventCallbacks()

        stateQueue.sync { state = .running }
        context?.logInfo("BreakpointPlugin started")
    }

    /// 注册 EventCallbacks 处理器
    /// 这些处理器将被 CaptureURLProtocol 调用来执行断点检查
    private func registerEventCallbacks() {
        // 请求阶段断点检查
        EventCallbacks.breakpointCheckRequest = { [weak self] requestId, request in
            guard let self, isEnabled else { return .proceed(request) }
            return await breakpointEngine.checkRequestBreakpoint(requestId: requestId, request: request)
        }

        // 响应阶段断点检查
        EventCallbacks.breakpointCheckResponse = { [weak self] requestId, request, response, body in
            guard let self, isEnabled else { return nil }
            return await breakpointEngine.checkResponseBreakpoint(
                requestId: requestId,
                request: request,
                response: response,
                body: body
            )
        }

        // 检查是否有响应断点规则（同步方法，用于预判断）
        EventCallbacks.breakpointHasResponseRule = { [weak self] request in
            guard let self, isEnabled else { return false }
            return breakpointEngine.hasResponseBreakpoint(for: request)
        }
    }

    /// 注销 EventCallbacks 处理器
    private func unregisterEventCallbacks() {
        EventCallbacks.breakpointCheckRequest = nil
        EventCallbacks.breakpointCheckResponse = nil
        EventCallbacks.breakpointHasResponseRule = nil
    }

    public func pause() async {
        guard state == .running else { return }
        breakpointEngine.updateRules([])
        stateQueue.sync { state = .paused }
        context?.logInfo("BreakpointPlugin paused")
    }

    public func resume() async {
        guard state == .paused else { return }
        if let rules: [BreakpointRule] = context?.getConfiguration(for: "breakpoint.rules") {
            breakpointEngine.updateRules(rules)
        }
        stateQueue.sync { state = .running }
        context?.logInfo("BreakpointPlugin resumed")
    }

    public func stop() async {
        guard state == .running || state == .paused else { return }
        stateQueue.sync { state = .stopping }
        breakpointEngine.updateRules([])

        // 注销 EventCallbacks 处理器
        unregisterEventCallbacks()

        stateQueue.sync { state = .stopped }
        context?.logInfo("BreakpointPlugin stopped")
    }

    public func handleCommand(_ command: PluginCommand) async {
        switch command.commandType {
        case "enable":
            isEnabled = true
            context?.setConfiguration(true, for: "breakpoint.enabled")
            if state == .paused { await resume() }
            sendSuccessResponse(for: command)

        case "disable":
            isEnabled = false
            context?.setConfiguration(false, for: "breakpoint.enabled")
            if state == .running { await pause() }
            sendSuccessResponse(for: command)

        case "update_rules":
            await handleUpdateRules(command)

        case "resume_breakpoint":
            await handleResumeBreakpoint(command)

        default:
            sendErrorResponse(for: command, message: "Unknown command type")
        }
    }

    private func handleUpdateRules(_ command: PluginCommand) async {
        guard let payload = command.payload else {
            sendErrorResponse(for: command, message: "Missing payload")
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let rules = try decoder.decode([BreakpointRule].self, from: payload)
            breakpointEngine.updateRules(rules)
            context?.setConfiguration(rules, for: "breakpoint.rules")
            sendSuccessResponse(for: command)
        } catch {
            sendErrorResponse(for: command, message: "Invalid rules format")
        }
    }

    private func handleResumeBreakpoint(_ command: PluginCommand) async {
        guard let payload = command.payload else {
            sendErrorResponse(for: command, message: "Missing payload")
            return
        }

        do {
            let resume = try JSONDecoder().decode(BreakpointResumePayload.self, from: payload)
            let action = mapBreakpointAction(resume)
            await breakpointEngine.resumeBreakpoint(requestId: resume.requestId, action: action)
            sendSuccessResponse(for: command)
        } catch {
            sendErrorResponse(for: command, message: "Invalid resume payload")
        }
    }

    private func mapBreakpointAction(_ payload: BreakpointResumePayload) -> BreakpointAction {
        switch payload.action.lowercased() {
        case "continue", "resume":
            return .resume
        case "abort":
            return .abort
        case "modify":
            if let mod = payload.modifiedRequest {
                let request = BreakpointRequestSnapshot(
                    method: mod.method ?? "GET",
                    url: mod.url ?? "",
                    headers: mod.headers ?? [:],
                    body: mod.bodyData
                )
                return .modify(BreakpointModification(request: request, response: nil))
            }
            if let mod = payload.modifiedResponse {
                let response = BreakpointResponseSnapshot(
                    statusCode: mod.statusCode ?? 200,
                    headers: mod.headers ?? [:],
                    body: mod.bodyData
                )
                return .modify(BreakpointModification(request: nil, response: response))
            }
            return .resume
        default:
            return .resume
        }
    }

    private func sendSuccessResponse(for command: PluginCommand) {
        let response = PluginCommandResponse(pluginId: pluginId, commandId: command.commandId, success: true)
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

// MARK: - Chaos Plugin

/// 故障注入插件
public final class ChaosPlugin: DebugProbePlugin, @unchecked Sendable {
    public let pluginId: String = BuiltinPluginId.chaos
    public let displayName: String = "Chaos"
    public let version: String = "1.0.0"
    public let pluginDescription: String = "网络故障注入与混沌测试"
    public let dependencies: [String] = [BuiltinPluginId.network]

    public private(set) var state: PluginState = .uninitialized
    public private(set) var isEnabled: Bool = true

    private weak var context: PluginContext?
    private let stateQueue = DispatchQueue(label: "com.sunimp.debugprobe.chaos.state")

    private var chaosEngine: ChaosEngine { ChaosEngine.shared }

    public init() {}

    public func initialize(context: PluginContext) {
        self.context = context
        if let enabled: Bool = context.getConfiguration(for: "chaos.enabled") {
            isEnabled = enabled
        }
        state = .stopped
        context.logInfo("ChaosPlugin initialized")
    }

    public func start() async throws {
        guard state != .running else { return }
        stateQueue.sync { state = .starting }

        // 注册 EventCallbacks 处理器
        registerEventCallbacks()

        stateQueue.sync { state = .running }
        context?.logInfo("ChaosPlugin started")
    }

    /// 注册 EventCallbacks 处理器
    /// 这些处理器将被 CaptureURLProtocol 调用来执行故障注入
    private func registerEventCallbacks() {
        // 请求阶段故障评估
        EventCallbacks.chaosEvaluate = { [weak self] request in
            guard let self, isEnabled else { return .none }
            return chaosEngine.evaluate(request: request)
        }

        // 响应阶段故障评估
        EventCallbacks.chaosEvaluateResponse = { [weak self] request, response, data in
            guard let self, isEnabled else { return .none }
            return chaosEngine.evaluateResponse(request: request, response: response, data: data)
        }
    }

    /// 注销 EventCallbacks 处理器
    private func unregisterEventCallbacks() {
        EventCallbacks.chaosEvaluate = nil
        EventCallbacks.chaosEvaluateResponse = nil
    }

    public func pause() async {
        guard state == .running else { return }
        chaosEngine.updateRules([])
        stateQueue.sync { state = .paused }
        context?.logInfo("ChaosPlugin paused")
    }

    public func resume() async {
        guard state == .paused else { return }
        if let rules: [ChaosRule] = context?.getConfiguration(for: "chaos.rules") {
            chaosEngine.updateRules(rules)
        }
        stateQueue.sync { state = .running }
        context?.logInfo("ChaosPlugin resumed")
    }

    public func stop() async {
        guard state == .running || state == .paused else { return }
        stateQueue.sync { state = .stopping }
        chaosEngine.updateRules([])

        // 注销 EventCallbacks 处理器
        unregisterEventCallbacks()

        stateQueue.sync { state = .stopped }
        context?.logInfo("ChaosPlugin stopped")
    }

    public func handleCommand(_ command: PluginCommand) async {
        switch command.commandType {
        case "enable":
            isEnabled = true
            context?.setConfiguration(true, for: "chaos.enabled")
            if state == .paused { await resume() }
            sendSuccessResponse(for: command)

        case "disable":
            isEnabled = false
            context?.setConfiguration(false, for: "chaos.enabled")
            if state == .running { await pause() }
            sendSuccessResponse(for: command)

        case "update_rules":
            await handleUpdateRules(command)

        default:
            sendErrorResponse(for: command, message: "Unknown command type")
        }
    }

    private func handleUpdateRules(_ command: PluginCommand) async {
        guard let payload = command.payload else {
            sendErrorResponse(for: command, message: "Missing payload")
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let rules = try decoder.decode([ChaosRule].self, from: payload)
            chaosEngine.updateRules(rules)
            context?.setConfiguration(rules, for: "chaos.rules")
            sendSuccessResponse(for: command)
        } catch {
            sendErrorResponse(for: command, message: "Invalid rules format")
        }
    }

    private func sendSuccessResponse(for command: PluginCommand) {
        let response = PluginCommandResponse(pluginId: pluginId, commandId: command.commandId, success: true)
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
