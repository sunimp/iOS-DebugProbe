// DeviceInfo.swift
// DebugProbe
//
// Created by Sun on 2025/12/02.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation
import Security

#if canImport(UIKit)
    import UIKit
#endif

// MARK: - Keychain Device ID Manager

/// 使用 Keychain 持久化存储设备 ID
/// - App 卸载重装后设备 ID 保持不变
/// - 不同 Bundle ID 的 App 有不同的设备 ID
private enum KeychainDeviceIdManager {
    /// Keychain service 名称（包含 bundle ID 以区分不同 App）
    private static var service: String {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.unknown.app"
        return "com.debugprobe.deviceid.\(bundleId)"
    }

    /// Keychain account 名称
    private static let account = "device_id"

    /// 获取或创建设备 ID
    /// - 首先尝试从 Keychain 读取
    /// - 如果不存在，生成新的 UUID 并保存到 Keychain
    static func getOrCreateDeviceId() -> String {
        // 尝试从 Keychain 读取
        if let existingId = readFromKeychain() {
            return existingId
        }

        // 生成新的设备 ID 并保存
        let newId = UUID().uuidString
        saveToKeychain(newId)
        return newId
    }

    /// 从 Keychain 读取设备 ID
    private static func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard
            status == errSecSuccess,
            let data = result as? Data,
            let deviceId = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return deviceId
    }

    /// 保存设备 ID 到 Keychain
    private static func saveToKeychain(_ deviceId: String) {
        guard let data = deviceId.data(using: .utf8) else { return }

        // 先尝试删除已存在的项
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // 添加新项
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // 设置为 App 卸载后数据仍保留
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("[DebugProbe] Failed to save device ID to Keychain: \(status)")
        }
    }
}

/// 设备信息模型，用于向 Debug Hub 注册设备
public struct DeviceInfo: Codable {
    public let deviceId: String
    /// 原始设备名称（系统设备名）
    public let deviceName: String
    /// 用户设置的设备别名（可选）
    public let deviceAlias: String?
    public let deviceModel: String
    public let systemName: String
    public let systemVersion: String
    public let appName: String
    public let appVersion: String
    public let buildNumber: String
    public let platform: String
    public let isSimulator: Bool
    public let appIcon: String?

    public init(
        deviceId: String,
        deviceName: String,
        deviceAlias: String? = nil,
        deviceModel: String,
        systemName: String,
        systemVersion: String,
        appName: String,
        appVersion: String,
        buildNumber: String,
        platform: String = "iOS",
        isSimulator: Bool = false,
        appIcon: String? = nil
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceAlias = deviceAlias
        self.deviceModel = deviceModel
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.appName = appName
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.platform = platform
        self.isSimulator = isSimulator
        self.appIcon = appIcon
    }
}

public enum DeviceInfoProvider {
    public static func current() -> DeviceInfo {
        let bundle = Bundle.main

        // 公共字段（App 相关）
        let appName = bundle.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleName"] as? String
            ?? "Unknown"

        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0.0.0"

        let buildNumber = bundle.infoDictionary?[kCFBundleVersionKey as String] as? String
            ?? "0"

        // 平台相关字段
        #if canImport(UIKit)
            let device = UIDevice.current

            #if targetEnvironment(simulator)
                let isSimulator = true
            #else
                let isSimulator = false
            #endif

            // 使用 Keychain 持久化的设备 ID（重装后保持不变，不同 App 有不同 ID）
            let deviceId = KeychainDeviceIdManager.getOrCreateDeviceId()
            // deviceName 始终使用系统设备名称
            let deviceName = device.name
            // deviceAlias 为用户设置的别名
            let deviceAlias = DebugProbeSettings.shared.deviceAlias
            let deviceModel = getDeviceModel()
            let systemName = device.systemName
            let systemVersion = device.systemVersion
            // 根据设备类型区分 iPadOS 和 iOS
            let platform = device.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
            let appIcon = getAppIconBase64()

        #else
            let isSimulator = false
            // 使用 Keychain 持久化的设备 ID（重装后保持不变，不同 App 有不同 ID）
            let deviceId = KeychainDeviceIdManager.getOrCreateDeviceId()
            // macOS 上 deviceName 使用系统名称，deviceAlias 为用户设置的别名
            let deviceName = Host.current().localizedName ?? "Mac"
            let deviceAlias = DebugProbeSettings.shared.deviceAlias
            let deviceModel = macDeviceModel()
            let systemName = "macOS"
            let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
            let platform = "macOS"
            let appIcon: String? = nil
        #endif

        return DeviceInfo(
            deviceId: deviceId,
            deviceName: deviceName,
            deviceAlias: deviceAlias,
            deviceModel: deviceModel,
            systemName: systemName,
            systemVersion: systemVersion,
            appName: appName,
            appVersion: appVersion,
            buildNumber: buildNumber,
            platform: platform,
            isSimulator: isSimulator,
            appIcon: appIcon
        )
    }

    // MARK: - 私有平台实现

    #if canImport(UIKit)
        /// 获取设备型号标识符（如 iPhone15,2）
        private static func getDeviceModel() -> String {
            var systemInfo = utsname()
            uname(&systemInfo)
            let machineMirror = Mirror(reflecting: systemInfo.machine)
            let identifier = machineMirror.children.reduce("") { identifier, element in
                guard let value = element.value as? Int8, value != 0 else {
                    return identifier
                }
                return identifier + String(UnicodeScalar(UInt8(value)))
            }
            return identifier
        }

        private static func getAppIconBase64() -> String? {
            guard
                let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
                let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
                let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
                let lastIcon = iconFiles.last,
                let image = UIImage(named: lastIcon)
            else {
                return nil
            }
            return image.pngData()?.base64EncodedString()
        }
    #else
        private static func macDeviceModel() -> String {
            var size: size_t = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)

            var model = [CChar](repeating: 0, count: Int(size))
            sysctlbyname("hw.model", &model, &size, nil, 0)

            return String(cString: model)
        }
    #endif
}
