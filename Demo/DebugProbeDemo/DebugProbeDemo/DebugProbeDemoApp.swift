//
//  DebugProbeDemoApp.swift
//  DebugProbeDemo
//
//  Created by Sun on 2025/12/11.
//

import SwiftUI
import DebugProbe
#if canImport(CocoaLumberjack)
import CocoaLumberjack
import CocoaLumberjackSwift
#endif

@main
struct DebugProbeDemoApp: App {
    
    init() {
        setupDebugProbe()
        // 记录 didFinishLaunching 完成（SwiftUI App.init 相当于 didFinishLaunching）
        // 注意：processStart 阶段在首次访问 DebugProbe.shared 时自动记录
        // mainExecuted 阶段在 SwiftUI 中无法精确获取，跳过
        PerformancePlugin.recordLaunchPhase(.didFinishLaunching)
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // 首屏渲染完成，记录启动结束时间
                    // 注意：processStart 阶段由 DebugProbe.shared 访问时自动记录
                    #if DEBUG
                    PerformancePlugin.recordLaunchPhase(.firstFrameRendered)
                    print("✅ App launch phases recorded")
                    #endif
                }
        }
    }
    
    private func setupDebugProbe() {
        #if DEBUG
        // 使用简化的无参数启动方式
        // 自动从 DebugProbeSettings.shared 读取配置（hubHost, hubPort, token）
        // 内部会检查 settings.isEnabled，如果禁用则不启动
        // 注意：首次访问 DebugProbe.shared 时会自动记录启动开始时间
        DebugProbe.shared.start()
        
        // 注册 Demo 数据库
        if DebugProbe.shared.isStarted {
            DatabaseManager.shared.setupAndRegister()
            print("✅ DebugProbe started with hub: \(DebugProbeSettings.shared.hubURL)")
            
            // 配置 CocoaLumberjack（如果可用）
            setupCocoaLumberjack()
        } else {
            print("⚠️ DebugProbe is disabled")
        }
        #endif
    }
    
    private func setupCocoaLumberjack() {
        #if canImport(CocoaLumberjack)
        // 添加本地日志桥接器
        // DDLogBridgeLocal 会将 CocoaLumberjack 的日志转发到 DebugProbe
        DDLog.add(DDLogBridgeLocal())
        print("✅ CocoaLumberjack -> DebugProbe bridge configured")
        
        // 可选：同时保留控制台输出
        DDLog.add(DDOSLogger.sharedInstance)
        #endif
    }
}
