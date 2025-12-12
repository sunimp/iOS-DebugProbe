//
//  ContentView.swift
//  DebugProbeDemo
//
//  Created by Sun on 2025/12/11.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                // 网络请求演示
                Section {
                    NavigationLink {
                        NetworkDemoView()
                    } label: {
                        Label("HTTP 请求", systemImage: "network")
                    }
                    
                    NavigationLink {
                        WebSocketDemoView()
                    } label: {
                        Label("WebSocket", systemImage: "bolt.horizontal")
                    }
                } header: {
                    Text("网络")
                }
                
                // 日志演示
                Section {
                    NavigationLink {
                        LogDemoView()
                    } label: {
                        Label("日志", systemImage: "doc.text")
                    }
                } header: {
                    Text("日志")
                }
                
                // 数据库演示
                Section {
                    NavigationLink {
                        DatabaseDemoView()
                    } label: {
                        Label("数据库", systemImage: "cylinder")
                    }
                } header: {
                    Text("数据库")
                }
                
                // Mock 演示
                Section {
                    NavigationLink {
                        MockDemoView()
                    } label: {
                        Label("Mock 测试", systemImage: "wand.and.stars")
                    }
                } header: {
                    Text("Mock & Breakpoint")
                }
                
                // 设置
                Section {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("设置", systemImage: "gear")
                    }
                } header: {
                    Text("配置")
                }
            }
            .navigationTitle("DebugProbe Demo")
        }
    }
}

#Preview {
    ContentView()
}
