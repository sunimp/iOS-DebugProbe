//
//  MockDemoView.swift
//  DebugProbeDemo
//
//  Created by Sun on 2025/12/11.
//

import SwiftUI

struct MockDemoView: View {
    @State private var responseText = ""
    @State private var isLoading = false
    
    var body: some View {
        List {
            // 说明
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mock 和断点功能需要在 Debug Platform WebUI 中配置规则。")
                        .font(.callout)
                    
                    Text("请按以下步骤测试：")
                        .font(.callout)
                        .fontWeight(.medium)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. 打开 Debug Platform WebUI")
                        Text("2. 在 Mock 或 Breakpoint 标签页创建规则")
                        Text("3. 回到此 App 发送请求")
                        Text("4. 观察请求是否被 Mock 或断点拦截")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("使用说明")
            }
            
            // Mock 测试
            Section {
                Button {
                    testMockableRequest()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("发送可 Mock 的请求")
                        Text("GET /api/users")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isLoading)
                
                Button {
                    testMockablePost()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("发送 POST 请求")
                        Text("POST /api/users")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isLoading)
            } header: {
                Text("Mock 测试")
            } footer: {
                Text("在 WebUI 创建 Mock 规则匹配这些请求")
            }
            
            // 断点测试
            Section {
                Button {
                    testBreakpointRequest()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("发送可断点的请求")
                        Text("GET /api/profile")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isLoading)
                
                Button {
                    testBreakpointLogin()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("模拟登录请求")
                        Text("POST /api/auth/login")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isLoading)
            } header: {
                Text("断点测试")
            } footer: {
                Text("在 WebUI 创建断点规则，可以暂停并修改请求/响应")
            }
            
            // Chaos 测试
            Section {
                Button {
                    testChaosRequest()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("发送可注入故障的请求")
                        Text("GET /api/data")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isLoading)
            } header: {
                Text("Chaos 测试")
            } footer: {
                Text("在 WebUI 创建 Chaos 规则，可以注入延迟、超时、错误码等")
            }
            
            // 响应结果
            if !responseText.isEmpty {
                Section {
                    ScrollView {
                        Text(responseText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                } header: {
                    Text("响应结果")
                }
            }
        }
        .navigationTitle("Mock & Breakpoint")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - Mock Tests
    
    private func testMockableRequest() {
        sendRequest(
            url: "https://jsonplaceholder.typicode.com/users",
            method: "GET"
        )
    }
    
    private func testMockablePost() {
        sendRequest(
            url: "https://jsonplaceholder.typicode.com/users",
            method: "POST",
            body: ["name": "Test User", "email": "test@example.com"]
        )
    }
    
    // MARK: - Breakpoint Tests
    
    private func testBreakpointRequest() {
        sendRequest(
            url: "https://jsonplaceholder.typicode.com/users/1",
            method: "GET"
        )
    }
    
    private func testBreakpointLogin() {
        sendRequest(
            url: "https://httpbin.org/post",
            method: "POST",
            body: ["username": "demo", "password": "secret123"]
        )
    }
    
    // MARK: - Chaos Tests
    
    private func testChaosRequest() {
        sendRequest(
            url: "https://httpbin.org/get",
            method: "GET"
        )
    }
    
    // MARK: - Helper
    
    private func sendRequest(url: String, method: String, body: [String: Any]? = nil) {
        guard let requestURL = URL(string: url) else { return }
        
        isLoading = true
        responseText = "请求中...\n\n"
        responseText += "URL: \(url)\n"
        responseText += "Method: \(method)\n"
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let body = body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            responseText += "Body: \(body)\n"
        }
        
        responseText += "\n等待响应...\n"
        
        let startTime = Date()
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            let duration = Date().timeIntervalSince(startTime)
            
            DispatchQueue.main.async {
                isLoading = false
                
                responseText += "\n--- 响应 ---\n"
                responseText += "耗时: \(String(format: "%.2f", duration * 1000))ms\n"
                
                if let error = error {
                    responseText += "❌ Error: \(error.localizedDescription)\n"
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse {
                    responseText += "Status: \(httpResponse.statusCode)\n"
                }
                
                if let data = data {
                    responseText += "Size: \(data.count) bytes\n\n"
                    
                    if let json = try? JSONSerialization.jsonObject(with: data),
                       let prettyData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
                       let prettyString = String(data: prettyData, encoding: .utf8) {
                        // 截断过长的响应
                        if prettyString.count > 500 {
                            responseText += String(prettyString.prefix(500)) + "\n...(truncated)"
                        } else {
                            responseText += prettyString
                        }
                    } else if let text = String(data: data, encoding: .utf8) {
                        if text.count > 500 {
                            responseText += String(text.prefix(500)) + "\n...(truncated)"
                        } else {
                            responseText += text
                        }
                    }
                }
            }
        }.resume()
    }
}

#Preview {
    NavigationStack {
        MockDemoView()
    }
}
