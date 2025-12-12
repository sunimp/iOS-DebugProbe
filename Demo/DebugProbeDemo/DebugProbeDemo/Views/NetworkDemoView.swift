//
//  NetworkDemoView.swift
//  DebugProbeDemo
//
//  Created by Sun on 2025/12/11.
//

import SwiftUI

struct NetworkDemoView: View {
    @State private var responseText = ""
    @State private var isLoading = false
    @State private var selectedAPI = 0
    
    // 测试 API 列表
    private let apis: [(name: String, url: String, method: String)] = [
        ("JSONPlaceholder - Posts", "https://jsonplaceholder.typicode.com/posts", "GET"),
        ("JSONPlaceholder - Users", "https://jsonplaceholder.typicode.com/users", "GET"),
        ("JSONPlaceholder - Comments", "https://jsonplaceholder.typicode.com/comments?postId=1", "GET"),
        ("HTTPBin - GET", "https://httpbin.org/get", "GET"),
        ("HTTPBin - POST", "https://httpbin.org/post", "POST"),
        ("HTTPBin - Headers", "https://httpbin.org/headers", "GET"),
        ("HTTPBin - Delay 2s", "https://httpbin.org/delay/2", "GET"),
        ("HTTPBin - Status 404", "https://httpbin.org/status/404", "GET"),
        ("HTTPBin - Status 500", "https://httpbin.org/status/500", "GET"),
    ]
    
    var body: some View {
        List {
            // API 选择
            Section {
                Picker("选择 API", selection: $selectedAPI) {
                    ForEach(0..<apis.count, id: \.self) { index in
                        Text(apis[index].name).tag(index)
                    }
                }
                .pickerStyle(.menu)
                
                HStack {
                    Text("URL")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(apis[selectedAPI].url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                HStack {
                    Text("Method")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(apis[selectedAPI].method)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(apis[selectedAPI].method == "GET" ? Color.green.opacity(0.2) : Color.blue.opacity(0.2))
                        .cornerRadius(4)
                }
            } header: {
                Text("API 配置")
            }
            
            // 发送按钮
            Section {
                Button {
                    sendRequest()
                } label: {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Text(isLoading ? "请求中..." : "发送请求")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(isLoading)
            }
            
            // 批量请求
            Section {
                Button {
                    sendBatchRequests(count: 5)
                } label: {
                    Text("批量发送 5 个请求")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isLoading)
                
                Button {
                    sendBatchRequests(count: 10)
                } label: {
                    Text("批量发送 10 个请求")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isLoading)
            } header: {
                Text("批量测试")
            }
            
            // 响应结果
            if !responseText.isEmpty {
                Section {
                    ScrollView {
                        Text(responseText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)
                } header: {
                    Text("响应结果")
                }
            }
        }
        .navigationTitle("HTTP 请求")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func sendRequest() {
        let api = apis[selectedAPI]
        guard let url = URL(string: api.url) else { return }
        
        isLoading = true
        responseText = ""
        
        var request = URLRequest(url: url)
        request.httpMethod = api.method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("DebugProbeDemo/1.0", forHTTPHeaderField: "User-Agent")
        
        // POST 请求添加 body
        if api.method == "POST" {
            let body = ["name": "DebugProbe Demo", "timestamp": ISO8601DateFormatter().string(from: Date())]
            request.httpBody = try? JSONEncoder().encode(body)
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                isLoading = false
                
                if let error = error {
                    responseText = "❌ Error: \(error.localizedDescription)"
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    responseText = "❌ Invalid response"
                    return
                }
                
                var result = "✅ Status: \(httpResponse.statusCode)\n\n"
                
                if let data = data {
                    if let json = try? JSONSerialization.jsonObject(with: data),
                       let prettyData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
                       let prettyString = String(data: prettyData, encoding: .utf8) {
                        result += prettyString
                    } else if let text = String(data: data, encoding: .utf8) {
                        result += text
                    }
                }
                
                responseText = result
            }
        }.resume()
    }
    
    private func sendBatchRequests(count: Int) {
        isLoading = true
        responseText = "发送 \(count) 个请求中...\n"
        
        let group = DispatchGroup()
        var results: [Int: String] = [:]
        
        for i in 0..<count {
            let api = apis[i % apis.count]
            guard let url = URL(string: api.url) else { continue }
            
            group.enter()
            
            var request = URLRequest(url: url)
            request.httpMethod = api.method
            
            URLSession.shared.dataTask(with: request) { _, response, error in
                let status: String
                if let error = error {
                    status = "❌ \(error.localizedDescription)"
                } else if let httpResponse = response as? HTTPURLResponse {
                    status = "✅ \(httpResponse.statusCode)"
                } else {
                    status = "⚠️ Unknown"
                }
                
                DispatchQueue.main.async {
                    results[i] = "[\(i+1)] \(api.name): \(status)"
                }
                group.leave()
            }.resume()
        }
        
        group.notify(queue: .main) {
            isLoading = false
            responseText = "批量请求完成:\n\n"
            for i in 0..<count {
                if let result = results[i] {
                    responseText += result + "\n"
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        NetworkDemoView()
    }
}
