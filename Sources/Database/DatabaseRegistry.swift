// DatabaseRegistry.swift
// DebugProbe
//
// Created by Sun on 2025/12/05.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

/// 数据库注册表 - 管理多个 SQLite 数据库
public final class DatabaseRegistry: @unchecked Sendable {
    /// 单例
    public static let shared = DatabaseRegistry()

    /// 已注册的数据库
    private var databases: [String: RegisteredDatabase] = [:]

    /// 线程安全锁
    private let lock = NSLock()

    /// 注册的数据库结构
    private struct RegisteredDatabase {
        let descriptor: DatabaseDescriptor
        let url: URL
    }

    private init() {}

    // MARK: - Public API

    /// 注册数据库
    /// - Parameters:
    ///   - descriptor: 数据库描述符
    ///   - url: 数据库文件 URL
    public func register(descriptor: DatabaseDescriptor, url: URL) {
        lock.lock()
        defer { lock.unlock() }

        databases[descriptor.id] = RegisteredDatabase(descriptor: descriptor, url: url)
        DebugLog.info("[DatabaseRegistry] Registered database: \(descriptor.id) at \(url.path)")
    }

    /// 注册数据库（自动解析 URL）
    /// - Parameter descriptor: 数据库描述符
    /// - Returns: 是否注册成功
    @discardableResult
    public func register(descriptor: DatabaseDescriptor) -> Bool {
        guard let url = descriptor.location.resolveURL() else {
            DebugLog.warning("[DatabaseRegistry] Failed to resolve URL for: \(descriptor.id)")
            return false
        }
        register(descriptor: descriptor, url: url)
        return true
    }

    /// 注销数据库
    /// - Parameter id: 数据库 ID
    public func unregister(id: String) {
        lock.lock()
        defer { lock.unlock() }

        databases.removeValue(forKey: id)
        DebugLog.info("[DatabaseRegistry] Unregistered database: \(id)")
    }

    /// 获取所有在 Inspector 中可见的数据库描述符
    /// - Returns: 数据库描述符列表
    public func allDescriptors() -> [DatabaseDescriptor] {
        lock.lock()
        defer { lock.unlock() }

        return databases.values
            .map(\.descriptor)
            .filter(\.visibleInInspector)
            .sorted { $0.id < $1.id }
    }

    /// 获取指定数据库的 URL
    /// - Parameter id: 数据库 ID
    /// - Returns: 数据库文件 URL
    public func url(for id: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }

        return databases[id]?.url
    }

    /// 获取指定数据库的描述符
    /// - Parameter id: 数据库 ID
    /// - Returns: 数据库描述符
    public func descriptor(for id: String) -> DatabaseDescriptor? {
        lock.lock()
        defer { lock.unlock() }

        return databases[id]?.descriptor
    }

    /// 检查数据库是否已注册
    /// - Parameter id: 数据库 ID
    /// - Returns: 是否已注册
    public func isRegistered(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return databases[id] != nil
    }

    /// 清空所有注册
    public func clear() {
        lock.lock()
        defer { lock.unlock() }

        databases.removeAll()
        DebugLog.info("[DatabaseRegistry] Cleared all registrations")
    }

    // MARK: - Active State Management (多账户场景)

    /// 设置数据库的账户归属状态
    /// - Parameters:
    ///   - currentUserPathPrefix: 当前用户数据库路径前缀
    ///   - sharedDbNamePatterns: 共享数据库名称/ID 中包含的关键词列表（忽略大小写）
    /// - Note: 匹配优先级：currentUserPathPrefix > sharedDbNamePatterns > otherUser
    public func setOwnership(currentUserPathPrefix: String, sharedDbNamePatterns: [String] = []) {
        lock.lock()
        defer { lock.unlock() }

        var currentUserIds: [String] = []
        var sharedIds: [String] = []
        var otherUserIds: [String] = []

        for (id, var registered) in databases {
            var descriptor = registered.descriptor
            let dbPath = registered.url.path
            let dbName = descriptor.name.lowercased()
            let dbId = id.lowercased()

            // 判断归属（优先级：当前用户 > 共享 > 其他用户）
            let ownership: DatabaseDescriptor.AccountOwnership
            if dbPath.hasPrefix(currentUserPathPrefix) {
                // 路径匹配当前用户
                ownership = .currentUser
                currentUserIds.append(id)
            } else if sharedDbNamePatterns.contains(where: { pattern in
                let p = pattern.lowercased()
                return dbName.contains(p) || dbId.contains(p)
            }) {
                // 名称/ID 包含共享关键词
                ownership = .shared
                sharedIds.append(id)
            } else {
                // 其余为其他用户
                ownership = .otherUser
                otherUserIds.append(id)
            }

            descriptor.ownership = ownership
            registered = RegisteredDatabase(descriptor: descriptor, url: registered.url)
            databases[id] = registered

            DebugLog.debug("[DatabaseRegistry] DB '\(id)' name='\(descriptor.name)' ownership=\(ownership.rawValue)")
        }

        DebugLog.info(
            "[DatabaseRegistry] Ownership updated - currentUser: \(currentUserIds.count), shared: \(sharedIds.count), otherUser: \(otherUserIds.count)"
        )
    }

    /// 设置指定数据库的归属状态
    public func setOwnership(dbId: String, ownership: DatabaseDescriptor.AccountOwnership) {
        lock.lock()
        defer { lock.unlock() }

        guard var registered = databases[dbId] else { return }
        var descriptor = registered.descriptor
        descriptor.ownership = ownership
        registered = RegisteredDatabase(descriptor: descriptor, url: registered.url)
        databases[dbId] = registered

        DebugLog.info("[DatabaseRegistry] Set database \(dbId) ownership: \(ownership.rawValue)")
    }

    /// 将所有数据库标记为共享
    public func setAllShared() {
        lock.lock()
        defer { lock.unlock() }

        for (id, var registered) in databases {
            var descriptor = registered.descriptor
            descriptor.ownership = .shared
            registered = RegisteredDatabase(descriptor: descriptor, url: registered.url)
            databases[id] = registered
        }

        DebugLog.info("[DatabaseRegistry] Set all databases as shared")
    }

    /// 设置包含指定路径前缀的数据库为活跃
    /// - Parameter pathPrefix: 路径前缀（如用户目录）
    /// - Note: 路径匹配使用 URL.path 进行前缀比较
    @available(*, deprecated, message: "Use setOwnership(currentUserPathPrefix:sharedPathPatterns:) instead")
    public func setActiveByPath(prefix pathPrefix: String) {
        lock.lock()
        defer { lock.unlock() }

        var activeIds: [String] = []
        var inactiveIds: [String] = []
        for (id, var registered) in databases {
            var descriptor = registered.descriptor
            let dbPath = registered.url.path
            let isMatch = dbPath.hasPrefix(pathPrefix)
            descriptor.ownership = isMatch ? .currentUser : .otherUser
            registered = RegisteredDatabase(descriptor: descriptor, url: registered.url)
            databases[id] = registered
            if isMatch {
                activeIds.append(id)
            } else {
                inactiveIds.append(id)
            }
            DebugLog.debug("[DatabaseRegistry] DB '\(id)' path=\(dbPath) prefix=\(pathPrefix) match=\(isMatch)")
        }

        DebugLog.info("[DatabaseRegistry] Set active by path prefix '\(pathPrefix)': \(activeIds.joined(separator: ", "))")
    }
}

// MARK: - Simple Registration API (宿主 App 推荐使用)

public extension DatabaseRegistry {
    /// 快速注册数据库
    /// - Parameters:
    ///   - id: 唯一标识符
    ///   - name: 显示名称
    ///   - url: 数据库文件 URL
    ///   - kind: 数据库类型，默认 "other"
    ///   - isSensitive: 是否敏感数据，默认 false
    func register(
        id: String,
        name: String,
        url: URL,
        kind: DatabaseDescriptor.Kind = "other",
        isSensitive: Bool = false
    ) {
        let descriptor = DatabaseDescriptor(
            id: id,
            name: name,
            kind: kind,
            location: .custom(description: url.lastPathComponent),
            isSensitive: isSensitive,
            visibleInInspector: true
        )
        register(descriptor: descriptor, url: url)
    }
}

// MARK: - Batch Registration (批量注册)

public extension DatabaseRegistry {
    /// 数据库配置
    struct DatabaseConfig {
        public let id: String
        public let name: String
        public let filename: String
        public let kind: DatabaseDescriptor.Kind
        public let isSensitive: Bool

        public init(
            id: String,
            name: String,
            filename: String,
            kind: DatabaseDescriptor.Kind = "other",
            isSensitive: Bool = false
        ) {
            self.id = id
            self.name = name
            self.filename = filename
            self.kind = kind
            self.isSensitive = isSensitive
        }
    }

    /// 批量注册目录中的多个数据库
    /// - Parameters:
    ///   - directoryURL: 目录 URL
    ///   - configs: 数据库配置列表
    func register(in directoryURL: URL, configs: [DatabaseConfig]) {
        for config in configs {
            let dbURL = directoryURL.appendingPathComponent(config.filename)
            register(
                id: config.id,
                name: config.name,
                url: dbURL,
                kind: config.kind,
                isSensitive: config.isSensitive
            )
        }

        DebugLog.info("[DatabaseRegistry] Registered \(configs.count) databases from: \(directoryURL.path)")
    }

    /// 自动发现并注册目录中的所有 SQLite 数据库
    /// - Parameters:
    ///   - directoryURL: 要扫描的目录 URL
    ///   - maxDepth: 最大递归深度，默认为 5
    ///   - sensitivePatterns: 包含这些关键词的数据库文件会被标记为敏感（默认为空）
    @discardableResult
    func autoDiscover(in directoryURL: URL, maxDepth: Int = 5, sensitivePatterns: [String] = []) -> [String] {
        var discovered: [String] = []
        let fileManager = FileManager.default
        let basePath = directoryURL.path

        // 递归扫描所有目录中的 .sqlite, .db, .sqlite3 文件
        let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            // 计算当前深度
            let relativePath = fileURL.path.replacingOccurrences(of: basePath, with: "")
            let depth = relativePath.components(separatedBy: "/").count(where: { !$0.isEmpty })

            // 如果超过最大深度，跳过该目录
            if depth > maxDepth {
                enumerator?.skipDescendants()
                continue
            }

            let ext = fileURL.pathExtension.lowercased()
            guard ext == "sqlite" || ext == "db" || ext == "sqlite3" else { continue }

            // 跳过 WAL 和 SHM 文件
            let filename = fileURL.lastPathComponent
            if filename.hasSuffix("-wal") || filename.hasSuffix("-shm") { continue }

            // 生成唯一的 id（使用相对路径，替换 / 为 _）
            let id = relativePath
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "." + ext, with: "")

            // 检查是否是敏感数据库
            let isSensitive = sensitivePatterns.contains { filename.lowercased().contains($0.lowercased()) }

            // 推断数据库类型
            let kind = inferKind(from: filename)

            register(
                id: id,
                name: formatDisplayName(fileURL.deletingPathExtension().lastPathComponent),
                url: fileURL,
                kind: kind,
                isSensitive: isSensitive
            )
            discovered.append(id)
        }

        DebugLog
            .info(
                "[DatabaseRegistry] Auto-discovered \(discovered.count) databases: \(discovered.joined(separator: ", "))"
            )
        return discovered
    }

    /// 根据文件名推断数据库类型
    private func inferKind(from filename: String) -> DatabaseDescriptor.Kind {
        let lowercased = filename.lowercased()
        if lowercased.contains("log") {
            return "log"
        } else if lowercased.contains("cache") {
            return "cache"
        }
        return "other"
    }

    /// 格式化显示名称
    private func formatDisplayName(_ id: String) -> String {
        // 将 snake_case 或 camelCase 转为空格分隔的标题
        let spaced = id.replacingOccurrences(of: "_", with: " ")
        // 首字母大写
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

// MARK: - Conditional Registration

public extension DatabaseRegistry {
    /// 仅在 Debug 模式下注册（生产环境无影响）
    func registerDebugOnly(
        id: String,
        name: String,
        url: URL,
        kind: DatabaseDescriptor.Kind = "other",
        isSensitive: Bool = false
    ) {
        register(id: id, name: name, url: url, kind: kind, isSensitive: isSensitive)
    }
}
