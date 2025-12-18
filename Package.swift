// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DebugProbe",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "DebugProbe",
            targets: ["DebugProbe"]
        ),
    ],
    dependencies: [
        // CocoaLumberjack 为可选依赖
        // 如果宿主工程需要使用 DDLogBridge，需要在宿主工程中也添加 CocoaLumberjack 依赖
        // .package(url: "https://github.com/CocoaLumberjack/CocoaLumberjack.git", from: "3.8.0"),
    ],
    targets: [
        // C 语言模块：PreMain 监控核心
        // 使用 dyld 回调 + mach_absolute_time 实现纳秒级精度的 PreMain 时间统计
        .target(
            name: "DPPreMainMonitor",
            path: "Sources/Core/PreMain",
            exclude: ["PreMainMonitor.swift"],
            sources: ["DPPreMainMonitor.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ]
        ),
        .target(
            name: "DebugProbe",
            dependencies: [
                "DPPreMainMonitor",
                // CocoaLumberjack 为可选依赖，使用 #if canImport(CocoaLumberjack) 条件编译
            ],
            path: "Sources",
            exclude: ["Core/PreMain/DPPreMainMonitor.c", "Core/PreMain/include"]
        ),
    ]
)
