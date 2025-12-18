//
//  PreMainMonitor.swift
//  DebugProbe
//
//  PreMain 阶段监控的 Swift 封装
//  将 C 语言的 DPPreMainMonitor 桥接为 Swift 友好的 API
//
//  Created by Sun on 2025/12/18.
//  Copyright © 2025 Sun. All rights reserved.
//

import DPPreMainMonitor
import Foundation

// MARK: - PreMainMonitor

/// PreMain 阶段监控器
/// 使用 dyld 回调 + mach_absolute_time 实现纳秒级精度的 PreMain 时间统计
///
/// ## 使用方式
///
/// 1. 在 main() 函数或 @main 入口第一行调用：
/// ```swift
/// PreMainMonitor.markMainExecuted()
/// ```
///
/// 2. 获取 PreMain 耗时数据：
/// ```swift
/// let durations = PreMainMonitor.durations
/// print("PreMain 总耗时: \(durations.totalPreMainMs)ms")
/// print("dylib 加载耗时: \(durations.dylibLoadingMs)ms")
/// ```
///
/// 3. 获取 dylib 加载详情：
/// ```swift
/// let slowestDylibs = PreMainMonitor.getSlowestDylibs(count: 10)
/// for dylib in slowestDylibs {
///     print("\(dylib.name): \(dylib.loadDurationMs)ms")
/// }
/// ```
public enum PreMainMonitor {
    // MARK: - 公开 API

    /// 标记 main() 函数开始执行
    /// 应在 main() 函数的第一行或 @main / AppDelegate 初始化时调用
    public static func markMainExecuted() {
        DPPreMainMarkMainExecuted()
    }

    /// 标记 ObjC +load 开始（可选，用于更精确的阶段细分）
    public static func markObjCLoadStart() {
        DPPreMainMarkObjCLoadStart()
    }

    /// 标记 ObjC +load 结束（可选）
    public static func markObjCLoadEnd() {
        DPPreMainMarkObjCLoadEnd()
    }

    /// 获取 PreMain 各阶段耗时
    public static var durations: PreMainDurations {
        guard let data = DPPreMainGetData() else {
            return PreMainDurations()
        }
        let dur = data.pointee.durations
        return PreMainDurations(
            totalPreMainMs: dur.totalPreMainMs,
            dylibLoadingMs: dur.dylibLoadingMs,
            objcLoadMs: dur.objcLoadMs,
            staticInitializerMs: dur.staticInitializerMs,
            postDyldToMainMs: dur.postDyldToMainMs,
            estimatedKernelToConstructorMs: dur.estimatedKernelToConstructorMs
        )
    }

    /// 获取 PreMain 时间戳
    public static var timestamps: PreMainTimestamps {
        guard let data = DPPreMainGetData() else {
            return PreMainTimestamps()
        }
        let ts = data.pointee.timestamps
        return PreMainTimestamps(
            processStartTimeUnixMicros: ts.processStartTimeUnixMicros,
            constructorMachTime: ts.constructorMachTime,
            firstDyldCallbackMachTime: ts.firstDyldCallbackMachTime,
            lastDyldCallbackMachTime: ts.lastDyldCallbackMachTime,
            mainExecutedMachTime: ts.mainExecutedMachTime,
            objcLoadStartMachTime: ts.objcLoadStartMachTime,
            objcLoadEndMachTime: ts.objcLoadEndMachTime
        )
    }

    /// 获取 dylib 统计信息
    public static var dylibStats: DylibStats {
        guard let data = DPPreMainGetData() else {
            return DylibStats()
        }
        return DylibStats(
            totalCount: Int(data.pointee.dylibCount),
            systemCount: Int(data.pointee.systemDylibCount),
            userCount: Int(data.pointee.userDylibCount)
        )
    }

    /// main() 是否已标记执行
    public static var isMainExecutedMarked: Bool {
        guard let data = DPPreMainGetData() else {
            return false
        }
        return data.pointee.mainExecutedMarked
    }

    /// 获取所有 dylib 加载信息
    public static func getAllDylibs() -> [DylibLoadInfo] {
        guard let data = DPPreMainGetData() else {
            return []
        }

        let count = min(Int(data.pointee.dylibCount), Int(DP_MAX_DYLIB_COUNT))
        guard count > 0 else { return [] }

        var buffer = [DPDylibLoadInfo](repeating: DPDylibLoadInfo(), count: count)
        let actualCount = DPPreMainGetAllDylibs(&buffer, UInt32(count))

        return buffer.prefix(Int(actualCount)).map { DylibLoadInfo(from: $0) }
    }

    /// 获取加载耗时最长的 N 个 dylib
    /// - Parameter count: 请求的数量
    /// - Returns: 按耗时降序排列的 dylib 列表
    public static func getSlowestDylibs(count: Int) -> [DylibLoadInfo] {
        guard count > 0 else { return [] }

        var buffer = [DPDylibLoadInfo](repeating: DPDylibLoadInfo(), count: count)
        let actualCount = DPPreMainGetSlowestDylibs(&buffer, UInt32(count))

        return buffer.prefix(Int(actualCount)).map { DylibLoadInfo(from: $0) }
    }

    /// 获取用户库列表（非系统库）
    public static func getUserDylibs() -> [DylibLoadInfo] {
        getAllDylibs().filter { !$0.isSystemLibrary }
    }

    /// 获取系统库列表
    public static func getSystemDylibs() -> [DylibLoadInfo] {
        getAllDylibs().filter(\.isSystemLibrary)
    }

    /// 启用/禁用 dylib 细分记录
    /// - Parameter enabled: 是否启用
    ///
    /// 禁用后可减少内存占用，但无法获取单个 dylib 的加载耗时
    public static func setDylibDetailEnabled(_ enabled: Bool) {
        DPPreMainSetDylibDetailEnabled(enabled)
    }

    /// 获取当前 mach_absolute_time
    public static var currentMachTime: UInt64 {
        DPGetCurrentMachTime()
    }

    /// 将 mach_absolute_time 转换为毫秒
    public static func machTimeToMillis(_ machTime: UInt64) -> Double {
        DPMachTimeToMillis(machTime)
    }

    /// 将 mach_absolute_time 转换为纳秒
    public static func machTimeToNanos(_ machTime: UInt64) -> UInt64 {
        DPMachTimeToNanos(machTime)
    }

    /// 重置所有记录（仅用于测试）
    public static func reset() {
        DPPreMainReset()
    }
}

// MARK: - PreMainDurations

/// PreMain 各阶段耗时（毫秒）
public struct PreMainDurations: Codable, Sendable {
    /// constructor 到 main 的总耗时（毫秒）
    /// 这是我们能精确测量的 PreMain 时间
    public let totalPreMainMs: Double

    /// dylib 加载耗时（first dyld callback -> last dyld callback）
    public let dylibLoadingMs: Double

    /// ObjC +load 耗时（如果有记录）
    public let objcLoadMs: Double

    /// constructor 到 first dyld callback（静态初始化器执行时间）
    public let staticInitializerMs: Double

    /// last dyld callback 到 main（包含 Swift 静态初始化等）
    public let postDyldToMainMs: Double

    /// 进程实际启动到 constructor 的估算时间（基于系统时间差）
    /// 包含内核加载、dyld 初始化等
    public let estimatedKernelToConstructorMs: Double

    /// 估算的完整 PreMain 时间（包含内核启动时间）
    public var estimatedFullPreMainMs: Double {
        estimatedKernelToConstructorMs + totalPreMainMs
    }

    public init(
        totalPreMainMs: Double = 0,
        dylibLoadingMs: Double = 0,
        objcLoadMs: Double = 0,
        staticInitializerMs: Double = 0,
        postDyldToMainMs: Double = 0,
        estimatedKernelToConstructorMs: Double = 0
    ) {
        self.totalPreMainMs = totalPreMainMs
        self.dylibLoadingMs = dylibLoadingMs
        self.objcLoadMs = objcLoadMs
        self.staticInitializerMs = staticInitializerMs
        self.postDyldToMainMs = postDyldToMainMs
        self.estimatedKernelToConstructorMs = estimatedKernelToConstructorMs
    }
}

// MARK: - PreMainTimestamps

/// PreMain 阶段时间戳
public struct PreMainTimestamps: Codable, Sendable {
    /// 进程启动时间（Unix 时间戳，微秒）
    public let processStartTimeUnixMicros: UInt64

    /// __attribute__((constructor)) 执行时的 mach_absolute_time
    public let constructorMachTime: UInt64

    /// 首次 dyld 回调时的 mach_absolute_time
    public let firstDyldCallbackMachTime: UInt64

    /// 最后一次 dyld 回调时的 mach_absolute_time
    public let lastDyldCallbackMachTime: UInt64

    /// main() 函数执行时的 mach_absolute_time
    public let mainExecutedMachTime: UInt64

    /// ObjC +load 方法开始执行时的 mach_absolute_time
    public let objcLoadStartMachTime: UInt64

    /// ObjC +load 方法结束执行时的 mach_absolute_time
    public let objcLoadEndMachTime: UInt64

    /// 进程启动时间（Date 格式）
    public var processStartDate: Date? {
        guard processStartTimeUnixMicros > 0 else { return nil }
        let seconds = TimeInterval(processStartTimeUnixMicros) / 1_000_000
        return Date(timeIntervalSince1970: seconds)
    }

    public init(
        processStartTimeUnixMicros: UInt64 = 0,
        constructorMachTime: UInt64 = 0,
        firstDyldCallbackMachTime: UInt64 = 0,
        lastDyldCallbackMachTime: UInt64 = 0,
        mainExecutedMachTime: UInt64 = 0,
        objcLoadStartMachTime: UInt64 = 0,
        objcLoadEndMachTime: UInt64 = 0
    ) {
        self.processStartTimeUnixMicros = processStartTimeUnixMicros
        self.constructorMachTime = constructorMachTime
        self.firstDyldCallbackMachTime = firstDyldCallbackMachTime
        self.lastDyldCallbackMachTime = lastDyldCallbackMachTime
        self.mainExecutedMachTime = mainExecutedMachTime
        self.objcLoadStartMachTime = objcLoadStartMachTime
        self.objcLoadEndMachTime = objcLoadEndMachTime
    }
}

// MARK: - DylibStats

/// dylib 统计信息
public struct DylibStats: Codable, Sendable {
    /// 总 dylib 数量
    public let totalCount: Int

    /// 系统库数量
    public let systemCount: Int

    /// 用户库数量
    public let userCount: Int

    public init(totalCount: Int = 0, systemCount: Int = 0, userCount: Int = 0) {
        self.totalCount = totalCount
        self.systemCount = systemCount
        self.userCount = userCount
    }
}

// MARK: - DylibLoadInfo

/// dylib 加载信息
public struct DylibLoadInfo: Codable, Sendable {
    /// dylib 名称
    public let name: String

    /// 加载时的 mach_absolute_time
    public let loadMachTime: UInt64

    /// 相对于监控开始的加载耗时（纳秒）
    public let loadDurationNanos: UInt64

    /// 是否为系统库
    public let isSystemLibrary: Bool

    /// 镜像基地址偏移
    public let slide: Int

    /// 加载耗时（毫秒）
    public var loadDurationMs: Double {
        Double(loadDurationNanos) / 1_000_000
    }

    public init(
        name: String = "",
        loadMachTime: UInt64 = 0,
        loadDurationNanos: UInt64 = 0,
        isSystemLibrary: Bool = false,
        slide: Int = 0
    ) {
        self.name = name
        self.loadMachTime = loadMachTime
        self.loadDurationNanos = loadDurationNanos
        self.isSystemLibrary = isSystemLibrary
        self.slide = slide
    }

    /// 从 C 结构体初始化
    init(from cInfo: DPDylibLoadInfo) {
        // 将 C 字符数组转换为 Swift String
        let nameBytes = withUnsafePointer(to: cInfo.name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(DP_MAX_DYLIB_NAME_LENGTH)) { charPtr in
                String(cString: charPtr)
            }
        }
        name = nameBytes
        loadMachTime = cInfo.loadMachTime
        loadDurationNanos = cInfo.loadDurationNanos
        isSystemLibrary = cInfo.isSystemLibrary
        slide = cInfo.slide
    }
}

// MARK: - 扩展 PreMainDurations 提供格式化输出

extension PreMainDurations: CustomStringConvertible {
    public var description: String {
        """
        PreMain Durations:
          Total (constructor -> main): \(String(format: "%.2f", totalPreMainMs))ms
          dylib Loading: \(String(format: "%.2f", dylibLoadingMs))ms
          Static Initializers: \(String(format: "%.2f", staticInitializerMs))ms
          Post-dyld to main: \(String(format: "%.2f", postDyldToMainMs))ms
          ObjC +load: \(String(format: "%.2f", objcLoadMs))ms
          Estimated Kernel -> Constructor: \(String(format: "%.2f", estimatedKernelToConstructorMs))ms
          Estimated Full PreMain: \(String(format: "%.2f", estimatedFullPreMainMs))ms
        """
    }
}

// MARK: - 扩展 DylibLoadInfo 提供格式化输出

extension DylibLoadInfo: CustomStringConvertible {
    public var description: String {
        let type = isSystemLibrary ? "System" : "User"
        return "\(name) [\(type)]: \(String(format: "%.2f", loadDurationMs))ms"
    }
}
