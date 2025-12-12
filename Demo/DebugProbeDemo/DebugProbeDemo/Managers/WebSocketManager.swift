//
//  WebSocketManager.swift
//  DebugProbeDemo
//
//  Created by Sun on 2025/12/11.
//

import Foundation
import Combine
import DebugProbe

/// WebSocket 消息模型
struct WSMessage: Identifiable {
    let id = UUID()
    let content: String
    let isSent: Bool
    let timestamp: Date
}

/// WebSocket 管理器
///
/// 使用 `InstrumentedWebSocketClient` 以获取完整的 WebSocket 消息级别监控。
/// 这样 DebugProbe 可以捕获每一帧的发送和接收。
class WebSocketManager: ObservableObject {
    @Published var isConnected = false
    @Published var statusText = "未连接"
    @Published var messages: [WSMessage] = []
    
    /// 使用 DebugProbe 提供的 InstrumentedWebSocketClient
    /// 以支持完整的消息级别监控
    private var wsClient: InstrumentedWebSocketClient?
    
    init() {}
    
    func connect(to urlString: String) {
        guard let url = URL(string: urlString) else {
            statusText = "无效 URL"
            return
        }
        
        disconnect()
        
        statusText = "连接中..."
        
        // 使用 InstrumentedWebSocketClient 替代原生 URLSessionWebSocketTask
        // 这样 DebugProbe 可以捕获每一帧的发送和接收
        wsClient = InstrumentedWebSocketClient(
            url: url,
            headers: [
                "User-Agent": "DebugProbeDemo/1.0",
                "X-Demo-Client": "true"
            ]
        )
        
        wsClient?.onConnected = { [weak self] in
            DispatchQueue.main.async {
                self?.isConnected = true
                self?.statusText = "已连接"
            }
        }
        
        wsClient?.onDisconnected = { [weak self] closeCode, reason in
            DispatchQueue.main.async {
                self?.isConnected = false
                self?.statusText = "已断开 (code: \(closeCode ?? -1))"
            }
        }
        
        wsClient?.onText = { [weak self] text in
            DispatchQueue.main.async {
                self?.messages.append(WSMessage(content: text, isSent: false, timestamp: Date()))
            }
        }
        
        wsClient?.onData = { [weak self] data in
            DispatchQueue.main.async {
                let content = String(data: data, encoding: .utf8) ?? "(binary: \(data.count) bytes)"
                self?.messages.append(WSMessage(content: content, isSent: false, timestamp: Date()))
            }
        }
        
        wsClient?.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.statusText = "错误: \(error.localizedDescription)"
            }
        }
        
        wsClient?.connect()
    }
    
    func disconnect() {
        wsClient?.disconnect()
        wsClient = nil
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.statusText = "已断开"
        }
    }
    
    func send(text: String) {
        wsClient?.send(text: text)
        DispatchQueue.main.async {
            self.messages.append(WSMessage(content: text, isSent: true, timestamp: Date()))
        }
    }
    
    func send(data: Data) {
        wsClient?.send(data: data)
        DispatchQueue.main.async {
            let content = String(data: data, encoding: .utf8) ?? "(binary: \(data.count) bytes)"
            self.messages.append(WSMessage(content: content, isSent: true, timestamp: Date()))
        }
    }
    
    func clearMessages() {
        messages.removeAll()
    }
}
