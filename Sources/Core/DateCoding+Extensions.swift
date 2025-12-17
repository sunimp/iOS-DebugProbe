// DateCoding+Extensions.swift
// DebugProbe
//
// Created by Sun on 2025/12/17.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - ISO8601 with Fractional Seconds

/// 支持毫秒精度的 ISO8601 日期格式化器
/// 格式: yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ (例如: 2025-12-17T18:24:53.123+08:00)
public enum ISO8601WithMilliseconds {
    /// 带毫秒的 ISO8601 格式化器
    public static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 备用的 DateFormatter，用于解析不带毫秒的日期
    private static let fallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 将 Date 编码为带毫秒的 ISO8601 字符串
    public static func encode(_ date: Date) -> String {
        formatter.string(from: date)
    }

    /// 从 ISO8601 字符串解码 Date（支持带毫秒和不带毫秒的格式）
    public static func decode(_ string: String) -> Date? {
        // 先尝试带毫秒的格式
        if let date = formatter.date(from: string) {
            return date
        }
        // 回退到不带毫秒的格式
        return fallbackFormatter.date(from: string)
    }
}

// MARK: - JSONEncoder Extension

public extension JSONEncoder.DateEncodingStrategy {
    /// ISO8601 编码策略，支持毫秒精度
    static var iso8601WithMilliseconds: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601WithMilliseconds.encode(date))
        }
    }
}

// MARK: - JSONDecoder Extension

public extension JSONDecoder.DateDecodingStrategy {
    /// ISO8601 解码策略，支持毫秒精度（兼容不带毫秒的格式）
    static var iso8601WithMilliseconds: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = ISO8601WithMilliseconds.decode(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO8601 date string: \(string)"
                )
            }
            return date
        }
    }
}
