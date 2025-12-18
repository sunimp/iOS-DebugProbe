// DatabaseDescriptor.swift
// DebugProbe
//
// Created by Sun on 2025/12/05.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

/// 数据库描述符
public struct DatabaseDescriptor: Codable, Identifiable, Hashable, Sendable {
    /// 数据库类型（使用字符串以便扩展）
    public typealias Kind = String

    /// 数据库位置
    public enum Location: Codable, Hashable, Sendable {
        case appSupport(relative: String)
        case documents(relative: String)
        case caches(relative: String)
        case group(containerId: String, relative: String)
        case custom(description: String)

        /// 获取完整 URL
        public func resolveURL() -> URL? {
            switch self {
            case let .appSupport(relative):
                FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                    .first?
                    .appendingPathComponent(relative)

            case let .documents(relative):
                FileManager.default
                    .urls(for: .documentDirectory, in: .userDomainMask)
                    .first?
                    .appendingPathComponent(relative)

            case let .caches(relative):
                FileManager.default
                    .urls(for: .cachesDirectory, in: .userDomainMask)
                    .first?
                    .appendingPathComponent(relative)

            case let .group(containerId, relative):
                FileManager.default
                    .containerURL(forSecurityApplicationGroupIdentifier: containerId)?
                    .appendingPathComponent(relative)

            case .custom:
                nil
            }
        }

        /// 位置描述
        public var description: String {
            switch self {
            case let .appSupport(path):
                "Application Support/\(path)"
            case let .documents(path):
                "Documents/\(path)"
            case let .caches(path):
                "Caches/\(path)"
            case let .group(container, path):
                "AppGroup(\(container))/\(path)"
            case let .custom(desc):
                desc
            }
        }
    }

    /// 唯一标识符
    public let id: String

    /// 显示名称
    public let name: String

    /// 数据库类型
    public let kind: Kind

    /// 数据库位置
    public let location: Location

    /// 是否敏感数据（钱包、隐私等）
    public let isSensitive: Bool

    /// 是否在 Inspector 中可见
    public let visibleInInspector: Bool

    /// 是否属于当前活跃用户（多账户场景下用于区分）
    public var isActive: Bool

    /// 初始化
    public init(
        id: String,
        name: String,
        kind: Kind,
        location: Location,
        isSensitive: Bool = false,
        visibleInInspector: Bool = true,
        isActive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.location = location
        self.isSensitive = isSensitive
        self.visibleInInspector = visibleInInspector
        self.isActive = isActive
    }
}
