//
//  SettingsView.swift
//  DebugProbeDemo
//
//  Created by Sun on 2025/12/11.
//

import SwiftUI
import DebugProbe

struct SettingsView: View {
    /// 使用 SDK 内置的配置管理器
    private let settings = DebugProbeSettings.shared
    
    @State private var hubHost: String = ""
    @State private var hubPort: String = ""
    @State private var token: String = ""
    @State private var isEnabled: Bool = true
    @State private var verboseLogging: Bool = false
    @State private var captureStackTrace: Bool = false
    @State private var connectionStatus: DebugProbeSettings.ConnectionStatusDetail?
    @State private var webUIPluginStates: [WebUIPluginState] = []
    
    var body: some View {
        List {
            // MARK: - 1. DebugProbe 状态
            Section {
                HStack {
                    Text("状态")
                    Spacer()
                    if let status = connectionStatus {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor(for: status))
                                .frame(width: 8, height: 8)
                            Text(status.statusText)
                                .foregroundStyle(statusColor(for: status))
                        }
                    }
                }
                
                HStack {
                    Text("Hub URL")
                    Spacer()
                    Text(settings.hubURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } header: {
                Text("DebugProbe 状态")
            }
            
            // MARK: - 2. 功能开关
            Section {
                Toggle("启用 DebugProbe", isOn: $isEnabled)
                    .onChange(of: isEnabled) { newValue in
                        settings.isEnabled = newValue
                    }
                
                Toggle("详细日志", isOn: $verboseLogging)
                    .onChange(of: verboseLogging) { newValue in
                        settings.verboseLogging = newValue
                    }
                
                Toggle("捕获卡顿调用栈", isOn: $captureStackTrace)
                    .onChange(of: captureStackTrace) { newValue in
                        settings.captureStackTrace = newValue
                        // 同步更新 PerformancePlugin 的 JankDetector
                        Task { @MainActor in
                            if let plugin = DebugProbe.shared.plugin(ofType: PerformancePlugin.self) {
                                plugin.jankDetector?.captureStackTrace = newValue
                            }
                        }
                    }
            } header: {
                Text("功能开关")
            } footer: {
                Text("「捕获卡顿调用栈」会有一定性能开销，建议仅在调试时启用")
            }
            
            // MARK: - 3. 连接配置
            Section {
                HStack {
                    Text("主机地址")
                    Spacer()
                    TextField(DebugProbeSettings.defaultHost, text: $hubHost)
                        .multilineTextAlignment(.trailing)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                }
                
                HStack {
                    Text("端口")
                    Spacer()
                    TextField(String(DebugProbeSettings.defaultPort), text: $hubPort)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                }
                
                HStack {
                    Text("Token")
                    Spacer()
                    TextField(DebugProbeSettings.defaultToken, text: $token)
                        .multilineTextAlignment(.trailing)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            } header: {
                Text("连接配置")
            } footer: {
                Text("修改配置后点击「应用配置」生效")
            }
            
            // MARK: - 4. 操作
            Section {
                Button {
                    applyConfiguration()
                } label: {
                    HStack {
                        Spacer()
                        Text("应用配置")
                        Spacer()
                    }
                }
                
                Button {
                    reconnect()
                } label: {
                    HStack {
                        Spacer()
                        Text("重新连接")
                        Spacer()
                    }
                }
                
                Button(role: .destructive) {
                    resetToDefaults()
                } label: {
                    HStack {
                        Spacer()
                        Text("重置为默认值")
                        Spacer()
                    }
                }
            } header: {
                Text("操作")
            }
            
            // MARK: - 5. 插件模块
            Section {
                ForEach(pluginInfos, id: \.pluginId) { pluginInfo in
                    PluginStatusRow(pluginInfo: pluginInfo)
                }
            } header: {
                Text("插件模块")
            } footer: {
                Text("插件状态由 WebUI 统一控制，在 WebUI 中启用/禁用插件会同步到 SDK")
            }
            
            // MARK: - 6. 设备信息
            Section {
                HStack {
                    Text("设备名称")
                    Spacer()
                    Text(deviceInfo.deviceName)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Text("系统版本")
                    Spacer()
                    Text("\(deviceInfo.platform) \(deviceInfo.systemVersion)")
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Text("App 版本")
                    Spacer()
                    Text(deviceInfo.appVersion)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("设备信息")
            }
            
            // MARK: - 7. 关于
            Section {
                HStack {
                    Text("DebugProbe 版本")
                    Spacer()
                    Text(DebugProbe.version)
                        .foregroundStyle(.secondary)
                }
                
                Link(destination: URL(string: "https://github.com/example/DebugProbe")!) {
                    HStack {
                        Text("GitHub 仓库")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    }
                }
                
                Link(destination: URL(string: "http://\(settings.hubHost):\(settings.hubPort)")!) {
                    HStack {
                        Text("打开 WebUI")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("关于")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadSettings()
            updateConnectionStatus()
            loadWebUIPluginStates()
        }
        .onReceive(NotificationCenter.default.publisher(for: DebugProbe.connectionStateDidChangeNotification)) { _ in
            updateConnectionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: DebugProbeSettings.configurationDidChangeNotification)) { _ in
            loadSettings()
            updateConnectionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebUIPluginStateManager.stateDidChangeNotification)) { _ in
            loadWebUIPluginStates()
        }
    }
    
    // MARK: - Private Computed Properties
    
    /// 从 DebugProbe 获取设备信息
    private var deviceInfo: DeviceInfo {
        DeviceInfoProvider.current()
    }
    
    /// 从 PluginManager 获取所有插件信息
    private var pluginInfos: [PluginInfo] {
        DebugProbe.shared.pluginManager.getAllPluginInfos()
    }
    
    // MARK: - Private Methods
    
    private func statusColor(for status: DebugProbeSettings.ConnectionStatusDetail) -> Color {
        if status.isGreen { return .green }
        if status.isOrange { return .orange }
        if status.isRed { return .red }
        return .gray
    }
    
    private func loadSettings() {
        hubHost = settings.hubHost
        hubPort = String(settings.hubPort)
        token = settings.token
        isEnabled = settings.isEnabled
        verboseLogging = settings.verboseLogging
        captureStackTrace = settings.captureStackTrace
    }
    
    private func updateConnectionStatus() {
        connectionStatus = settings.connectionStatusDetail
    }
    
    private func applyConfiguration() {
        let port = Int(hubPort) ?? DebugProbeSettings.defaultPort
        settings.configure(host: hubHost, port: port, token: token)
        
        // configure() 会发出通知，如果监听了通知会自动重连
        // 但为了立即生效，这里主动调用 reconnect()
        DebugProbe.shared.reconnect()
    }
    
    private func reconnect() {
        // 使用无参数 reconnect() 方法
        // 自动从 DebugProbeSettings 读取配置，处理启动/停止/重连逻辑
        DebugProbe.shared.reconnect()
    }
    
    private func resetToDefaults() {
        settings.resetToDefaults()
        loadSettings()
        
        // 重置后重新连接
        DebugProbe.shared.reconnect()
    }
    
    private func loadWebUIPluginStates() {
        webUIPluginStates = WebUIPluginStateManager.shared.getAllStates()
    }
}

struct FeatureRow: View {
    let name: String
    let enabled: Bool
    
    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(enabled ? .green : .red)
        }
    }
}

// MARK: - PluginStatusRow

/// 插件状态行（显示统一的运行状态）
struct PluginStatusRow: View {
    let pluginInfo: PluginInfo

    var body: some View {
        HStack {
            Text(pluginInfo.displayName)
            Spacer()

            // 运行状态标签
            Text(stateText)
                .font(.caption)
                .foregroundStyle(stateColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(stateColor.opacity(0.15))
                .cornerRadius(4)
        }
    }

    private var stateText: String {
        switch pluginInfo.state {
        case .uninitialized:
            "未初始化"
        case .starting:
            "启动中"
        case .running:
            "运行中"
        case .paused:
            "已暂停"
        case .stopping:
            "停止中"
        case .stopped:
            "已禁用"
        case .error:
            "错误"
        }
    }

    private var stateColor: Color {
        switch pluginInfo.state {
        case .running:
            .green
        case .paused:
            .orange
        case .error:
            .red
        case .starting, .stopping:
            .blue
        case .uninitialized, .stopped:
            .gray
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
