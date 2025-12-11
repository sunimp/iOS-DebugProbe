// PluginBridgeAdapter.swift
// DebugProbe
//
// Created by Sun on 2025/12/09.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - 插件 Bridge 适配器

/// 负责将插件事件/命令与 Bridge 通信协议进行适配
/// 主要职责：将 BridgeMessage 路由到对应的 PluginCommand
public final class PluginBridgeAdapter: @unchecked Sendable {
    // MARK: - Properties

    /// 对 DebugBridgeClient 的弱引用
    private weak var bridgeClient: DebugBridgeClient?

    /// 插件管理器引用
    private let pluginManager: PluginManager

    // MARK: - Lifecycle

    /// 创建插件桥接适配器
    /// - Parameters:
    ///   - pluginManager: 插件管理器
    ///   - bridgeClient: Bridge 客户端
    public init(
        pluginManager: PluginManager,
        bridgeClient: DebugBridgeClient
    ) {
        self.pluginManager = pluginManager
        self.bridgeClient = bridgeClient

        setup()
    }

    // MARK: - Setup

    /// 设置双向连接
    private func setup() {
        // 设置插件管理器的事件回调
        pluginManager.onPluginEvent = { [weak self] event in
            self?.handlePluginEvent(event)
        }

        pluginManager.onPluginCommandResponse = { [weak self] response in
            self?.handlePluginCommandResponse(response)
        }

        // 订阅 BridgeClient 的命令回调
        bridgeClient?.onPluginCommandReceived = { [weak self] pluginId, commandType, payloadObject in
            Task {
                // 将参数转换为 PluginCommand
                var payload: Data?
                if let payloadObject {
                    payload = try? JSONSerialization.data(withJSONObject: payloadObject)
                }
                let command = PluginCommand(
                    pluginId: pluginId,
                    commandType: commandType,
                    payload: payload
                )
                await self?.pluginManager.routeCommand(command)
            }
        }

        // 订阅 BridgeClient 的消息回调（用于将旧消息类型路由到插件系统）
        bridgeClient?.onBridgeMessageReceived = { [weak self] message in
            Task {
                await self?.routeMessageToPlugin(message)
            }
        }

        DebugLog.info(.plugin, "PluginBridgeAdapter setup completed")
    }

    // MARK: - Event Handling

    /// 处理插件事件
    /// 内置插件（network, log, websocket, performance）的原始事件已通过 EventCallbacks.reportEvent() 直接发送到 BridgeClient
    /// 这里收到的 PluginEvent 主要用于插件系统内部状态管理，通常只需日志记录
    /// 自定义插件的事件可能需要特殊处理
    private func handlePluginEvent(_ event: PluginEvent) {
        switch event.pluginId {
        case BuiltinPluginId.network,
             BuiltinPluginId.log,
             BuiltinPluginId.webSocket,
             BuiltinPluginId.performance:
            // 内置插件事件已通过 EventCallbacks 直接发送到 BridgeClient
            // 这里只做日志记录
            DebugLog.debug(.plugin, "Plugin event from \(event.pluginId): \(event.eventType)")

        case BuiltinPluginId.database:
            // 数据库插件事件通常是响应式的（查询结果等），不主动上报
            handleDatabasePluginEvent(event)

        case BuiltinPluginId.mock,
             BuiltinPluginId.breakpoint,
             BuiltinPluginId.chaos:
            // 规则型插件事件，通常是配置变更通知
            DebugLog.debug(.plugin, "Rule plugin event from \(event.pluginId): \(event.eventType)")

        default:
            // 自定义插件事件，可能需要特殊处理
            sendGenericPluginEvent(event)
        }
    }

    /// 处理数据库插件事件
    private func handleDatabasePluginEvent(_ event: PluginEvent) {
        // DB 事件通常是响应式的（如查询结果），不主动上报到 Hub
        // 这里可以处理 DB 变更追踪等未来功能
        DebugLog.debug(.plugin, "Database plugin event: \(event.eventType)")
    }

    /// 发送通用插件事件
    /// 用于处理自定义插件的事件，发送到 Hub
    private func sendGenericPluginEvent(_ event: PluginEvent) {
        DebugLog.debug(.plugin, "Sending plugin event: \(event.pluginId)/\(event.eventType)")
        bridgeClient?.sendPluginEvent(event)
    }

    /// 处理插件命令响应
    private func handlePluginCommandResponse(_ response: PluginCommandResponse) {
        DebugLog.debug(
            .plugin,
            "Plugin command response: \(response.pluginId), success: \(response.success)"
        )

        // 根据插件类型发送对应的 BridgeMessage 响应
        switch response.pluginId {
        case BuiltinPluginId.database:
            // 数据库插件响应需要解码 payload 并发送 BridgeMessage.dbResponse
            guard let payload = response.payload else {
                DebugLog.warning(.plugin, "Database response missing payload")
                return
            }
            do {
                let dbResponse = try JSONDecoder().decode(DBResponse.self, from: payload)
                bridgeClient?.sendDBResponse(dbResponse)
            } catch {
                DebugLog.error(.plugin, "Failed to decode DB response: \(error)")
            }

        default:
            // 其他插件响应暂时只记录日志
            break
        }
    }

    // MARK: - Command Routing

    /// 将 Bridge 消息转换为插件命令并路由
    /// - Parameter message: Bridge 消息
    public func routeMessageToPlugin(_ message: BridgeMessage) async {
        // 根据消息类型转换为插件命令

        switch message {
        case let .updateMockRules(rules):
            // 路由到 Mock 插件
            await routeMockRulesUpdate(rules)

        case let .updateBreakpointRules(rules):
            // 路由到断点插件
            await routeBreakpointRulesUpdate(rules)

        case let .updateChaosRules(rules):
            // 路由到故障注入插件
            await routeChaosRulesUpdate(rules)

        case let .dbCommand(command):
            // 路由到数据库插件
            await routeDBCommand(command)

        default:
            break
        }
    }

    /// 路由 Mock 规则更新
    private func routeMockRulesUpdate(_ rules: [MockRule]) async {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let payload = try encoder.encode(rules)

            let command = PluginCommand(
                pluginId: BuiltinPluginId.mock,
                commandType: "update_rules",
                payload: payload
            )
            await pluginManager.routeCommand(command)
        } catch {
            DebugLog.error(.plugin, "Failed to encode mock rules: \(error)")
        }
    }

    /// 路由断点规则更新
    private func routeBreakpointRulesUpdate(_ rules: [BreakpointRule]) async {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let payload = try encoder.encode(rules)

            let command = PluginCommand(
                pluginId: BuiltinPluginId.breakpoint,
                commandType: "update_rules",
                payload: payload
            )
            await pluginManager.routeCommand(command)
        } catch {
            DebugLog.error(.plugin, "Failed to encode breakpoint rules: \(error)")
        }
    }

    /// 路由故障注入规则更新
    private func routeChaosRulesUpdate(_ rules: [ChaosRule]) async {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let payload = try encoder.encode(rules)

            let command = PluginCommand(
                pluginId: BuiltinPluginId.chaos,
                commandType: "update_rules",
                payload: payload
            )
            await pluginManager.routeCommand(command)
        } catch {
            DebugLog.error(.plugin, "Failed to encode chaos rules: \(error)")
        }
    }

    /// 路由数据库命令
    private func routeDBCommand(_ command: DBCommand) async {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let payload = try encoder.encode(command)

            let pluginCommand = PluginCommand(
                pluginId: BuiltinPluginId.database,
                commandType: "db_command",
                commandId: command.requestId,
                payload: payload
            )
            await pluginManager.routeCommand(pluginCommand)
        } catch {
            DebugLog.error(.plugin, "Failed to encode DB command: \(error)")
        }
    }
}
