//
//  WebSocketDemoView.swift
//  DebugProbeDemo
//
//  Created by Sun on 2025/12/11.
//

import SwiftUI

struct WebSocketDemoView: View {
    @StateObject private var wsManager = WebSocketManager()
    @State private var messageText = ""
    @State private var selectedServer = 0
    
    private let servers = [
        ("Echo Server", "wss://echo.websocket.org"),
        ("Postman Echo", "wss://ws.postman-echo.com/raw"),
    ]
    
    var body: some View {
        List {
            // 服务器选择
            Section {
                Picker("服务器", selection: $selectedServer) {
                    ForEach(0..<servers.count, id: \.self) { index in
                        Text(servers[index].0).tag(index)
                    }
                }
                .pickerStyle(.menu)
                
                HStack {
                    Text("URL")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(servers[selectedServer].1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("服务器配置")
            }
            
            // 连接控制
            Section {
                HStack {
                    Text("状态")
                    Spacer()
                    Text(wsManager.statusText)
                        .foregroundStyle(wsManager.isConnected ? .green : .secondary)
                }
                
                if wsManager.isConnected {
                    Button(role: .destructive) {
                        wsManager.disconnect()
                    } label: {
                        Text("断开连接")
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    Button {
                        wsManager.connect(to: servers[selectedServer].1)
                    } label: {
                        Text("连接")
                            .frame(maxWidth: .infinity)
                    }
                }
            } header: {
                Text("连接")
            }
            
            // 发送消息
            if wsManager.isConnected {
                Section {
                    TextField("输入消息", text: $messageText)
                        .textFieldStyle(.roundedBorder)
                    
                    Button {
                        sendMessage()
                    } label: {
                        Text("发送文本消息")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(messageText.isEmpty)
                    
                    Button {
                        sendJSONMessage()
                    } label: {
                        Text("发送 JSON 消息")
                            .frame(maxWidth: .infinity)
                    }
                    
                    Button {
                        sendBinaryMessage()
                    } label: {
                        Text("发送二进制消息")
                            .frame(maxWidth: .infinity)
                    }
                } header: {
                    Text("发送消息")
                }
                
                // 批量测试
                Section {
                    Button {
                        sendBatchMessages(count: 5)
                    } label: {
                        Text("批量发送 5 条消息")
                            .frame(maxWidth: .infinity)
                    }
                    
                    Button {
                        sendBatchMessages(count: 10)
                    } label: {
                        Text("批量发送 10 条消息")
                            .frame(maxWidth: .infinity)
                    }
                } header: {
                    Text("批量测试")
                }
            }
            
            // 消息记录
            if !wsManager.messages.isEmpty {
                Section {
                    ForEach(wsManager.messages.reversed()) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: message.isSent ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                    .foregroundStyle(message.isSent ? .blue : .green)
                                Text(message.isSent ? "发送" : "接收")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(message.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(message.content)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(3)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    HStack {
                        Text("消息记录 (\(wsManager.messages.count))")
                        Spacer()
                        Button("清空") {
                            wsManager.clearMessages()
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("WebSocket")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            wsManager.disconnect()
        }
    }
    
    private func sendMessage() {
        guard !messageText.isEmpty else { return }
        wsManager.send(text: messageText)
        messageText = ""
    }
    
    private func sendJSONMessage() {
        let json: [String: Any] = [
            "type": "demo",
            "message": "Hello from DebugProbe Demo",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "device": UIDevice.current.name
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let text = String(data: data, encoding: .utf8) {
            wsManager.send(text: text)
        }
    }
    
    private func sendBinaryMessage() {
        let data = "Binary message: \(Date())".data(using: .utf8) ?? Data()
        wsManager.send(data: data)
    }
    
    private func sendBatchMessages(count: Int) {
        for i in 1...count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.2) {
                wsManager.send(text: "Batch message #\(i) at \(Date())")
            }
        }
    }
}

#Preview {
    NavigationStack {
        WebSocketDemoView()
    }
}
