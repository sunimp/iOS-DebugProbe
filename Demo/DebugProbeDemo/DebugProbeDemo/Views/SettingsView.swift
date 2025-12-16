//
//  SettingsView.swift
//  DebugProbeDemo
//
//  Created by Sun on 2025/12/11.
//

import DebugProbe
import SwiftUI

struct SettingsView: View {
    /// 使用 SDK 内置的配置管理器
    private let settings = DebugProbeSettings.shared

    @State private var hubHost: String = ""
    @State private var hubPort: String = ""
    @State private var token: String = ""
    @State private var deviceAlias: String = ""
    @State private var isEnabled: Bool = true
    @State private var verboseLogging: Bool = false
    @State private var captureStackTrace: Bool = false
    @State private var connectionStatus: DebugProbeSettings.ConnectionStatusDetail?
    @State private var webUIPluginStates: [WebUIPluginState] = []
    /// 插件列表刷新计数器（用于触发 View 刷新）
    @State private var pluginRefreshCounter = 0
    /// 设备别名输入框焦点状态
    @FocusState private var isDeviceAliasFocused: Bool
    /// 禁用父插件时的确认弹窗状态
    @State private var disableParentPluginAlert: (pluginId: String, pluginName: String, childNames: [String])?

    var body: some View {
        List {
            // MARK: - 1. 设备识别（放在最顶部）

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("设备别名")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("输入设备别名", text: $deviceAlias)
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(.primary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($isDeviceAliasFocused)
                        .onSubmit {
                            // 用户按下回车时保存（trim 处理）
                            saveDeviceAlias()
                        }
                        .onChange(of: isDeviceAliasFocused) { focused in
                            if !focused {
                                // 失去焦点时保存（trim 处理）
                                saveDeviceAlias()
                            }
                        }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("设置设备别名后，该名称会显示在 DebugHub 设备列表中，便于在多设备场景下区分不同设备。留空则使用系统默认设备名。")
            }

            // MARK: - 2. DebugProbe 状态

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

            // MARK: - 3. 功能开关

            Section {
                Toggle("启用 DebugProbe", isOn: $isEnabled)
                    .onChange(of: isEnabled) { newValue in
                        settings.isEnabled = newValue
                        // 根据开关状态连接或断开
                        DebugProbe.shared.reconnect()
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
                ForEach(visiblePluginInfos, id: \.pluginId) { pluginInfo in
                    PluginStatusRow(
                        pluginInfo: pluginInfo,
                        onDisableParentPlugin: { pluginId, pluginName, childNames in
                            disableParentPluginAlert = (pluginId, pluginName, childNames)
                        }
                    )
                }
            } header: {
                Text("插件模块")
            } footer: {
                Text("使用开关控制各插件的启用状态。禁用后的插件将停止发送数据到 DebugHub，WebUI 中也无法打开对应功能。")
            }
            .alert("禁用插件", isPresented: Binding(
                get: { disableParentPluginAlert != nil },
                set: { if !$0 { disableParentPluginAlert = nil } }
            )) {
                Button("取消", role: .cancel) {
                    disableParentPluginAlert = nil
                }
                Button("确认关闭", role: .destructive) {
                    if let alert = disableParentPluginAlert {
                        Task {
                            // 先禁用所有子插件
                            for info in pluginInfos where info.isSubPlugin && info.parentPluginId == alert.pluginId {
                                await DebugProbe.shared.pluginManager.setPluginEnabled(info.pluginId, enabled: false)
                            }
                            // 再禁用父插件
                            await DebugProbe.shared.pluginManager.setPluginEnabled(alert.pluginId, enabled: false)
                        }
                        disableParentPluginAlert = nil
                    }
                }
            } message: {
                if let alert = disableParentPluginAlert {
                    Text(
                        "如果关闭 \(alert.pluginName) 插件，其子功能 \(alert.childNames.joined(separator: "、")) 也会一同关闭。\n\n是否确认关闭？"
                    )
                }
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

            // MARK: - 8. 关于

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
        .onReceive(NotificationCenter.default
            .publisher(for: DebugProbeSettings.configurationDidChangeNotification)) { _ in
                loadSettings()
                updateConnectionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebUIPluginStateManager.stateDidChangeNotification)) { _ in
            loadWebUIPluginStates()
        }
        .onReceive(NotificationCenter.default.publisher(for: PluginManager.pluginStateDidChangeNotification)) { _ in
            // 插件状态变化时，刷新插件列表
            // 通过触发 View 重新渲染来刷新 pluginInfos 计算属性
            refreshPluginList()
        }
    }

    // MARK: - Private Computed Properties

    /// 从 DebugProbe 获取设备信息
    private var deviceInfo: DeviceInfo {
        DeviceInfoProvider.current()
    }

    /// 从 PluginManager 获取所有插件信息
    private var pluginInfos: [PluginInfo] {
        // pluginRefreshCounter 变化会触发重新计算
        _ = pluginRefreshCounter
        return DebugProbe.shared.pluginManager.getAllPluginInfos()
    }

    /// 可见的插件列表（父插件禁用时，其子插件不显示）
    private var visiblePluginInfos: [PluginInfo] {
        pluginInfos.filter { info in
            // 如果是子插件，检查父插件是否启用
            if info.isSubPlugin, let parentId = info.parentPluginId {
                let parentEnabled = DebugProbeSettings.shared.getPluginEnabled(parentId) ?? true
                return parentEnabled
            }
            return true
        }
    }

    // MARK: - Private Methods

    private func statusColor(for status: DebugProbeSettings.ConnectionStatusDetail) -> Color {
        if status.isGreen { return .green }
        if status.isOrange { return .orange }
        if status.isRed { return .red }
        return .gray
    }

    /// 保存设备别名（trim 前后空格，全空格视为空）
    private func saveDeviceAlias() {
        let trimmed = deviceAlias.trimmingCharacters(in: .whitespaces)
        // 更新 UI 状态为 trimmed 后的值
        deviceAlias = trimmed
        // 保存到设置（空字符串保存为 nil）
        settings.deviceAlias = trimmed.isEmpty ? nil : trimmed
        // 通知 Hub 设备信息已更新，实时同步到 WebUI
        DebugProbe.shared.notifyDeviceInfoChanged()
    }

    private func loadSettings() {
        hubHost = settings.hubHost
        hubPort = String(settings.hubPort)
        token = settings.token
        deviceAlias = settings.deviceAlias ?? ""
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

    private func refreshPluginList() {
        // 通过改变计数器触发 pluginInfos 重新计算
        pluginRefreshCounter += 1
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

/// 插件状态行（带开关控制）
struct PluginStatusRow: View {
    let pluginInfo: PluginInfo
    /// 禁用父插件时的回调（pluginId, pluginName, childNames）
    var onDisableParentPlugin: ((String, String, [String]) -> Void)?

    /// 开关状态：使用 @State 来驱动 UI 更新
    @State private var isEnabled: Bool = true

    /// 获取已启用的子插件名称列表（只有启用状态的子插件才需要提示）
    private var enabledChildPluginNames: [String] {
        guard !pluginInfo.isSubPlugin else { return [] }
        return DebugProbe.shared.pluginManager.getAllPluginInfos()
            .filter { info in
                info.isSubPlugin &&
                    info.parentPluginId == pluginInfo.pluginId &&
                    (DebugProbeSettings.shared.getPluginEnabled(info.pluginId) ?? true)
            }
            .map(\.displayName)
    }

    /// 从持久化设置读取启用状态
    private var persistedEnabled: Bool {
        DebugProbeSettings.shared.getPluginEnabled(pluginInfo.pluginId) ?? true
    }

    /// 自定义 Toggle 绑定，用于拦截关闭操作
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                // 如果是关闭操作，且有启用的子插件，需要弹窗确认
                if !newValue, !enabledChildPluginNames.isEmpty {
                    // 调用回调显示弹窗，不改变开关状态
                    onDisableParentPlugin?(pluginInfo.pluginId, pluginInfo.displayName, enabledChildPluginNames)
                } else {
                    // 直接更新状态
                    isEnabled = newValue
                    // 执行实际的启用/禁用操作
                    let currentPersisted = persistedEnabled
                    if currentPersisted != newValue {
                        Task {
                            await DebugProbe.shared.pluginManager.setPluginEnabled(
                                pluginInfo.pluginId,
                                enabled: newValue
                            )
                        }
                    }
                }
            }
        )
    }

    var body: some View {
        HStack {
            // 子插件缩进显示
            if pluginInfo.isSubPlugin {
                Spacer()
                    .frame(width: 20)
            }

            Text(pluginInfo.displayName)
            Spacer()

            // 子插件显示父插件标签
            if pluginInfo.isSubPlugin, let parentId = pluginInfo.parentPluginId {
                Text(parentId.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.purple.opacity(0.15))
                    .cornerRadius(3)
            }

            // 运行状态标签
            Text(stateText)
                .font(.caption)
                .foregroundStyle(stateColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(stateColor.opacity(0.15))
                .cornerRadius(4)

            // 开关控制（使用自定义绑定拦截操作）
            Toggle("", isOn: toggleBinding)
                .labelsHidden()
        }
        .onAppear {
            // 初始化时从持久化设置读取
            isEnabled = persistedEnabled
        }
        .onReceive(NotificationCenter.default
            .publisher(for: PluginManager.pluginStateDidChangeNotification)) { _ in
                // 插件状态变化时，同步开关状态
                let newState = persistedEnabled
                if isEnabled != newState {
                    isEnabled = newState
                }
        }
    }

    /// App 端的开关状态（持久化的）
    private var appSwitchEnabled: Bool {
        // 从持久化设置读取，默认为 true
        DebugProbeSettings.shared.getPluginEnabled(pluginInfo.pluginId) ?? true
    }

    private var stateText: String {
        // App 开关优先级最高
        if !appSwitchEnabled {
            return "已禁用" // App 端禁用，无论 WebUI 如何
        }

        switch pluginInfo.state {
        case .uninitialized:
            return "未初始化"
        case .starting:
            return "启动中"
        case .running:
            return "运行中"
        case .paused:
            // App 开关打开但被暂停，只可能是 WebUI 暂停
            return "已暂停"
        case .stopping:
            return "停止中"
        case .stopped:
            return "已停止"
        case .error:
            return "错误"
        }
    }

    private var stateColor: Color {
        // App 开关优先级最高
        if !appSwitchEnabled {
            return .gray // App 端禁用
        }

        switch pluginInfo.state {
        case .running:
            return .green
        case .paused:
            return .orange // WebUI 暂停
        case .error:
            return .red
        case .starting, .stopping:
            return .blue
        case .uninitialized, .stopped:
            return .gray
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
