//
//  LogDemoView.swift
//  DebugProbeDemo
//
//  Created by Sun on 2025/12/11.
//

import SwiftUI
import DebugProbe
import os.log
#if canImport(CocoaLumberjack)
import CocoaLumberjack
import CocoaLumberjackSwift
#endif

// MARK: - OSLog Logger

/// 自定义 OSLog Logger
private let demoLogger = Logger(subsystem: "com.debugprobe.demo", category: "General")
private let networkLogger = Logger(subsystem: "com.debugprobe.demo", category: "Network")
private let uiLogger = Logger(subsystem: "com.debugprobe.demo", category: "UI")

struct LogDemoView: View {
    @State private var customMessage = ""
    @State private var selectedLevel = 2 // info
    
    private let levels = ["Verbose", "Debug", "Info", "Warning", "Error"]
    
    var body: some View {
        List {
            // os_log 示例
            Section {
                Button {
                    logOSLogDebug()
                } label: {
                    HStack {
                        Image(systemName: "apple.logo")
                            .foregroundStyle(.blue)
                        Text("os_log Debug")
                    }
                }
                
                Button {
                    logOSLogInfo()
                } label: {
                    HStack {
                        Image(systemName: "apple.logo")
                            .foregroundStyle(.green)
                        Text("os_log Info")
                    }
                }
                
                Button {
                    logOSLogError()
                } label: {
                    HStack {
                        Image(systemName: "apple.logo")
                            .foregroundStyle(.red)
                        Text("os_log Error")
                    }
                }
                
                Button {
                    logOSLogNetwork()
                } label: {
                    HStack {
                        Image(systemName: "network")
                            .foregroundStyle(.purple)
                        Text("os_log Network 请求")
                    }
                }
            } header: {
                Text("OSLog (iOS 14+)")
            } footer: {
                Text("使用 Apple 原生 os.log API，DebugProbe 自动捕获")
            }
            
            #if canImport(CocoaLumberjack)
            // CocoaLumberjack 示例
            Section {
                Button {
                    logLumberjackVerbose()
                } label: {
                    HStack {
                        Image(systemName: "tree.fill")
                            .foregroundStyle(.gray)
                        Text("DDLog Verbose")
                    }
                }
                
                Button {
                    logLumberjackDebug()
                } label: {
                    HStack {
                        Image(systemName: "tree.fill")
                            .foregroundStyle(.blue)
                        Text("DDLog Debug")
                    }
                }
                
                Button {
                    logLumberjackInfo()
                } label: {
                    HStack {
                        Image(systemName: "tree.fill")
                            .foregroundStyle(.green)
                        Text("DDLog Info")
                    }
                }
                
                Button {
                    logLumberjackWarn()
                } label: {
                    HStack {
                        Image(systemName: "tree.fill")
                            .foregroundStyle(.yellow)
                        Text("DDLog Warn")
                    }
                }
                
                Button {
                    logLumberjackError()
                } label: {
                    HStack {
                        Image(systemName: "tree.fill")
                            .foregroundStyle(.red)
                        Text("DDLog Error")
                    }
                }
            } header: {
                Text("CocoaLumberjack")
            } footer: {
                Text("需要添加 CocoaLumberjack 依赖并配置 DDLogProbeLogger")
            }
            #endif
            
            // 快速日志（DebugProbe 原生 API）
            Section {
                Button {
                    logVerbose()
                } label: {
                    HStack {
                        Circle()
                            .fill(.gray)
                            .frame(width: 8, height: 8)
                        Text("Verbose 日志")
                    }
                }
                
                Button {
                    logDebug()
                } label: {
                    HStack {
                        Circle()
                            .fill(.blue)
                            .frame(width: 8, height: 8)
                        Text("Debug 日志")
                    }
                }
                
                Button {
                    logInfo()
                } label: {
                    HStack {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Info 日志")
                    }
                }
                
                Button {
                    logWarning()
                } label: {
                    HStack {
                        Circle()
                            .fill(.yellow)
                            .frame(width: 8, height: 8)
                        Text("Warning 日志")
                    }
                }
                
                Button {
                    logError()
                } label: {
                    HStack {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("Error 日志")
                    }
                }
            } header: {
                Text("DebugProbe 原生 API")
            } footer: {
                Text("直接使用 DebugProbe.shared.log() 方法")
            }
            
            // 自定义日志
            Section {
                TextField("日志内容", text: $customMessage)
                    .textFieldStyle(.roundedBorder)
                
                Picker("日志级别", selection: $selectedLevel) {
                    ForEach(0..<levels.count, id: \.self) { index in
                        Text(levels[index]).tag(index)
                    }
                }
                .pickerStyle(.menu)
                
                Button {
                    sendCustomLog()
                } label: {
                    Text("发送自定义日志")
                        .frame(maxWidth: .infinity)
                }
                .disabled(customMessage.isEmpty)
            } header: {
                Text("自定义日志")
            }
            
            // 批量日志
            Section {
                Button {
                    sendBatchLogs(count: 10)
                } label: {
                    Text("批量发送 10 条日志")
                        .frame(maxWidth: .infinity)
                }
                
                Button {
                    sendBatchLogs(count: 50)
                } label: {
                    Text("批量发送 50 条日志")
                        .frame(maxWidth: .infinity)
                }
                
                Button {
                    sendMixedLogs()
                } label: {
                    Text("发送混合级别日志")
                        .frame(maxWidth: .infinity)
                }
            } header: {
                Text("批量测试")
            }
            
            // 模拟场景
            Section {
                Button {
                    simulateUserFlow()
                } label: {
                    Text("模拟用户登录流程")
                        .frame(maxWidth: .infinity)
                }
                
                Button {
                    simulateNetworkError()
                } label: {
                    Text("模拟网络错误")
                        .frame(maxWidth: .infinity)
                }
                
                Button {
                    simulateCrashLog()
                } label: {
                    Text("模拟崩溃日志")
                        .frame(maxWidth: .infinity)
                }
            } header: {
                Text("模拟场景")
            }
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - OSLog Methods
    
    private func logOSLogDebug() {
        demoLogger.debug("OSLog Debug: 这是一条 Debug 级别的日志，时间 \(Date())")
    }
    
    private func logOSLogInfo() {
        demoLogger.info("OSLog Info: 应用启动完成，版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")
    }
    
    private func logOSLogError() {
        demoLogger.error("OSLog Error: 发生了一个错误 - 数据解析失败")
    }
    
    private func logOSLogNetwork() {
        networkLogger.info("OSLog Network: 开始请求 https://api.example.com/users")
        
        // 模拟延迟后的响应
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            networkLogger.debug("OSLog Network: 请求发送成功，等待响应...")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            networkLogger.info("OSLog Network: 收到响应，状态码 200")
        }
    }
    
    #if canImport(CocoaLumberjack)
    // MARK: - CocoaLumberjack Methods
    
    private func logLumberjackVerbose() {
        DDLogVerbose("CocoaLumberjack Verbose: 详细调试信息，时间 \(Date())")
    }
    
    private func logLumberjackDebug() {
        DDLogDebug("CocoaLumberjack Debug: 调试信息 - 用户点击了按钮")
    }
    
    private func logLumberjackInfo() {
        DDLogInfo("CocoaLumberjack Info: 用户已登录成功")
    }
    
    private func logLumberjackWarn() {
        DDLogWarn("CocoaLumberjack Warn: 磁盘空间不足，请清理缓存")
    }
    
    private func logLumberjackError() {
        DDLogError("CocoaLumberjack Error: 网络请求失败 - 服务器返回 500")
    }
    #endif
    
    // MARK: - DebugProbe Quick Logs
    
    private func logVerbose() {
        DebugProbe.shared.log(
            level: .verbose,
            message: "Verbose: App state changed at \(Date())",
            subsystem: "Demo",
            category: "State"
        )
    }
    
    private func logDebug() {
        DebugProbe.shared.log(
            level: .debug,
            message: "Debug: Button tapped, performing action",
            subsystem: "Demo",
            category: "UI"
        )
    }
    
    private func logInfo() {
        DebugProbe.shared.log(
            level: .info,
            message: "Info: User completed onboarding",
            subsystem: "Demo",
            category: "Analytics"
        )
    }
    
    private func logWarning() {
        DebugProbe.shared.log(
            level: .warning,
            message: "Warning: Low memory detected, consider releasing resources",
            subsystem: "Demo",
            category: "Performance"
        )
    }
    
    private func logError() {
        DebugProbe.shared.log(
            level: .error,
            message: "Error: Failed to load user profile - Network timeout",
            subsystem: "Demo",
            category: "Network"
        )
    }
    
    // MARK: - Custom Log
    
    private func sendCustomLog() {
        let level: LogEvent.Level = switch selectedLevel {
        case 0: .verbose
        case 1: .debug
        case 2: .info
        case 3: .warning
        case 4: .error
        default: .info
        }
        
        DebugProbe.shared.log(
            level: level,
            message: customMessage,
            subsystem: "Demo",
            category: "Custom"
        )
        
        customMessage = ""
    }
    
    // MARK: - Batch Logs
    
    private func sendBatchLogs(count: Int) {
        for i in 1...count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                DebugProbe.shared.log(
                    level: .info,
                    message: "Batch log #\(i) of \(count)",
                    subsystem: "Demo",
                    category: "Batch"
                )
            }
        }
    }
    
    private func sendMixedLogs() {
        let levels: [LogEvent.Level] = [.verbose, .debug, .info, .warning, .error]
        
        for (index, level) in levels.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.1) {
                DebugProbe.shared.log(
                    level: level,
                    message: "Mixed log test - Level: \(level)",
                    subsystem: "Demo",
                    category: "Mixed"
                )
            }
        }
    }
    
    // MARK: - Simulate Scenarios
    
    private func simulateUserFlow() {
        let steps: [(LogEvent.Level, String)] = [
            (.info, "User opened login screen"),
            (.debug, "Validating email format..."),
            (.debug, "Email validation passed"),
            (.info, "Sending login request..."),
            (.debug, "Request sent to /api/auth/login"),
            (.info, "Login successful, token received"),
            (.debug, "Storing token in keychain"),
            (.info, "Navigating to home screen"),
        ]
        
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.3) {
                DebugProbe.shared.log(
                    level: step.0,
                    message: step.1,
                    subsystem: "Demo",
                    category: "Auth"
                )
            }
        }
    }
    
    private func simulateNetworkError() {
        let logs: [(LogEvent.Level, String)] = [
            (.info, "Starting API request to /api/users"),
            (.debug, "Request URL: https://api.example.com/users"),
            (.debug, "Request method: GET"),
            (.warning, "Request taking longer than expected..."),
            (.error, "Network error: The request timed out"),
            (.error, "Error code: NSURLErrorTimedOut (-1001)"),
            (.info, "Scheduling retry in 5 seconds"),
        ]
        
        for (index, log) in logs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.2) {
                DebugProbe.shared.log(
                    level: log.0,
                    message: log.1,
                    subsystem: "Demo",
                    category: "Network"
                )
            }
        }
    }
    
    private func simulateCrashLog() {
        let logs: [(LogEvent.Level, String)] = [
            (.error, "⚠️ FATAL: Unhandled exception caught"),
            (.error, "Exception type: NSInvalidArgumentException"),
            (.error, "Reason: -[__NSCFString objectAtIndex:]: unrecognized selector"),
            (.error, "Stack trace:"),
            (.error, "  0   CoreFoundation  0x00007fff2043f6fb __exceptionPreprocess + 250"),
            (.error, "  1   libobjc.A.dylib 0x00007fff201c3530 objc_exception_throw + 48"),
            (.error, "  2   CoreFoundation  0x00007fff204bdf5c -[__NSCFString objectAtIndex:] + 0"),
            (.error, "  3   DebugProbeDemo  0x0000000104a2b3f0 ContentView.body.getter + 128"),
        ]
        
        for (index, log) in logs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.1) {
                DebugProbe.shared.log(
                    level: log.0,
                    message: log.1,
                    subsystem: "Demo",
                    category: "Crash"
                )
            }
        }
    }
}

#Preview {
    NavigationStack {
        LogDemoView()
    }
}
