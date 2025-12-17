// PageTimingRecorder.swift
// DebugProbe
//
// Created by Sun on 2025/12/17.
// Copyright © 2025 Sun. All rights reserved.
//

#if canImport(UIKit)
    import UIKit
#endif
import Foundation

// MARK: - Page Timing Recorder

/// 页面耗时记录器
/// 负责采集页面生命周期事件并上报
public final class PageTimingRecorder: @unchecked Sendable {
    // MARK: - Singleton

    /// 共享实例
    public static let shared = PageTimingRecorder()

    // MARK: - Configuration

    /// 是否启用自动采集（UIKit swizzling）
    public var autoTrackingEnabled: Bool = true

    /// 采样率（0.0 - 1.0，默认 100%）
    public var samplingRate: Double = 1.0

    /// 是否跟踪冷启动后的首个页面
    public var trackColdStartPage: Bool = true

    /// VC 类名黑名单（不采集）
    public var blacklistedClasses: Set<String> = [
        "UINavigationController",
        "UITabBarController",
        "UIPageViewController",
        "UISplitViewController",
        "UIInputWindowController",
        "UIAlertController",
        "UIActivityViewController",
        "UIReferenceLibraryViewController",
        "_UIRemoteInputViewController",
    ]

    /// VC 类名白名单（仅采集这些，为空则不启用白名单模式）
    public var whitelistedClasses: Set<String> = []

    // MARK: - Private Properties

    /// 当前活跃的页面访问状态（按 VC 对象地址索引）
    private var activeVisits: [ObjectIdentifier: PageVisitState] = [:]
    private let visitsLock = NSLock()

    /// 事件上报回调
    var onPageTimingEvent: ((PageTimingEvent) -> Void)?

    /// 是否是冷启动后的首个页面
    private var isFirstPageAfterColdStart: Bool = true

    /// 是否已安装 swizzling
    private var isSwizzled: Bool = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Setup

    /// 启动自动采集（安装 swizzling）
    func startAutoTracking() {
        guard autoTrackingEnabled, !isSwizzled else { return }

        #if canImport(UIKit)
            swizzleViewControllerMethods()
            isSwizzled = true
        #endif
    }

    /// 停止自动采集
    func stopAutoTracking() {
        // 注意：swizzling 通常不需要撤销，因为撤销可能导致问题
        // 这里只是标记停止，实际的 swizzled 方法会检查 autoTrackingEnabled
        autoTrackingEnabled = false
    }

    // MARK: - Manual API

    /// 手动标记页面开始
    /// - Parameters:
    ///   - pageId: 页面标识
    ///   - pageName: 页面名称
    ///   - route: 业务路由（可选）
    ///   - isPush: 是否通过 push 方式进入
    ///   - parentPageId: 父页面 ID
    /// - Returns: visitId，用于后续标记
    @discardableResult
    public func markPageStart(
        pageId: String,
        pageName: String? = nil,
        route: String? = nil,
        isPush: Bool? = nil,
        parentPageId: String? = nil
    ) -> String {
        guard shouldSample() else { return "" }

        let visitId = UUID().uuidString
        let state = PageVisitState(
            visitId: visitId,
            pageId: pageId,
            pageName: pageName ?? pageId,
            route: route,
            startAt: Date(),
            isColdStart: isFirstPageAfterColdStart && trackColdStartPage,
            isPush: isPush,
            parentPageId: parentPageId
        )

        // 重置冷启动标记
        if isFirstPageAfterColdStart {
            isFirstPageAfterColdStart = false
        }

        visitsLock.lock()
        // 使用 visitId 作为 key（手动 API 场景）
        activeVisits[ObjectIdentifier(visitId as NSString)] = state
        visitsLock.unlock()

        return visitId
    }

    /// 手动标记页面首次布局完成
    /// - Parameter visitId: markPageStart 返回的 visitId
    public func markPageFirstLayout(visitId: String) {
        guard !visitId.isEmpty else { return }

        visitsLock.lock()
        if let state = activeVisits[ObjectIdentifier(visitId as NSString)] {
            if !state.hasFirstLayout {
                state.firstLayoutAt = Date()
                state.hasFirstLayout = true
            }
        }
        visitsLock.unlock()
    }

    /// 手动标记页面出现
    /// - Parameter visitId: markPageStart 返回的 visitId
    public func markPageAppear(visitId: String) {
        guard !visitId.isEmpty else { return }

        visitsLock.lock()
        if let state = activeVisits[ObjectIdentifier(visitId as NSString)] {
            state.appearAt = Date()
        }
        visitsLock.unlock()
    }

    /// 手动标记页面结束并上报
    /// - Parameter visitId: markPageStart 返回的 visitId
    public func markPageEnd(visitId: String) {
        guard !visitId.isEmpty else { return }

        visitsLock.lock()
        let state = activeVisits.removeValue(forKey: ObjectIdentifier(visitId as NSString))
        visitsLock.unlock()

        if let state {
            state.endAt = Date()
            reportEvent(state.toEvent())
        }
    }

    /// 添加自定义标记点
    /// - Parameters:
    ///   - name: 标记名称
    ///   - visitId: markPageStart 返回的 visitId
    public func addMarker(name: String, visitId: String) {
        guard !visitId.isEmpty else { return }

        visitsLock.lock()
        activeVisits[ObjectIdentifier(visitId as NSString)]?.addMarker(name: name)
        visitsLock.unlock()
    }

    // MARK: - Internal Methods (for swizzling)

    #if canImport(UIKit)
        /// 处理 viewWillAppear（start）
        func handleViewWillAppear(_ viewController: UIViewController, animated: Bool) {
            guard autoTrackingEnabled, shouldTrack(viewController) else { return }

            let pageId = generatePageId(for: viewController)
            let pageName = generatePageName(for: viewController)

            let state = PageVisitState(
                pageId: pageId,
                pageName: pageName,
                route: nil,
                startAt: Date(),
                isColdStart: isFirstPageAfterColdStart && trackColdStartPage,
                isPush: viewController.navigationController != nil,
                parentPageId: nil
            )

            // 重置冷启动标记
            if isFirstPageAfterColdStart {
                isFirstPageAfterColdStart = false
            }

            visitsLock.lock()
            activeVisits[ObjectIdentifier(viewController)] = state
            visitsLock.unlock()
        }

        /// 处理 viewDidLayoutSubviews（firstLayout）
        func handleViewDidLayoutSubviews(_ viewController: UIViewController) {
            guard autoTrackingEnabled else { return }

            visitsLock.lock()
            if let state = activeVisits[ObjectIdentifier(viewController)], !state.hasFirstLayout {
                state.firstLayoutAt = Date()
                state.hasFirstLayout = true
            }
            visitsLock.unlock()
        }

        /// 处理 viewDidAppear（appear/end）
        func handleViewDidAppear(_ viewController: UIViewController, animated: Bool) {
            guard autoTrackingEnabled else { return }

            visitsLock.lock()
            let state = activeVisits.removeValue(forKey: ObjectIdentifier(viewController))
            visitsLock.unlock()

            if let state {
                state.appearAt = Date()
                state.endAt = Date()
                reportEvent(state.toEvent())
            }
        }

        /// 处理 viewDidDisappear（清理未完成的访问）
        func handleViewDidDisappear(_ viewController: UIViewController, animated: Bool) {
            visitsLock.lock()
            activeVisits.removeValue(forKey: ObjectIdentifier(viewController))
            visitsLock.unlock()
        }
    #endif

    // MARK: - Private Methods

    /// 检查是否应该采样
    private func shouldSample() -> Bool {
        guard samplingRate < 1.0 else { return true }
        return Double.random(in: 0 ..< 1) < samplingRate
    }

    #if canImport(UIKit)
        /// 检查是否应该跟踪此 VC
        private func shouldTrack(_ viewController: UIViewController) -> Bool {
            let className = String(describing: type(of: viewController))

            // 检查黑名单
            if blacklistedClasses.contains(className) {
                return false
            }

            // 系统 VC 类名通常以 _ 开头，但需要排除 SwiftUI 的 UIHostingController
            // SwiftUI 的类名形如 _TtGC7SwiftUI19UIHostingControllerV...
            if className.hasPrefix("_") && !className.contains("UIHostingController") {
                return false
            }

            // 如果启用了白名单模式，检查白名单
            if !whitelistedClasses.isEmpty {
                return whitelistedClasses.contains(className)
            }

            // 采样检查
            return shouldSample()
        }

        /// 生成页面 ID
        private func generatePageId(for viewController: UIViewController) -> String {
            String(describing: type(of: viewController))
        }

        /// 生成页面名称
        private func generatePageName(for viewController: UIViewController) -> String {
            // 优先使用 title
            if let title = viewController.title, !title.isEmpty {
                return title
            }
            // 否则使用类名
            return String(describing: type(of: viewController))
        }
    #endif

    /// 上报事件
    private func reportEvent(_ event: PageTimingEvent) {
        onPageTimingEvent?(event)
    }
}

// MARK: - UIViewController Swizzling

#if canImport(UIKit)
    private extension PageTimingRecorder {
        func swizzleViewControllerMethods() {
            let viewControllerClass: AnyClass = UIViewController.self

            // Swizzle viewWillAppear
            swizzleMethod(
                cls: viewControllerClass,
                originalSelector: #selector(UIViewController.viewWillAppear(_:)),
                swizzledSelector: #selector(UIViewController.debugProbe_viewWillAppear(_:))
            )

            // Swizzle viewDidLayoutSubviews
            swizzleMethod(
                cls: viewControllerClass,
                originalSelector: #selector(UIViewController.viewDidLayoutSubviews),
                swizzledSelector: #selector(UIViewController.debugProbe_viewDidLayoutSubviews)
            )

            // Swizzle viewDidAppear
            swizzleMethod(
                cls: viewControllerClass,
                originalSelector: #selector(UIViewController.viewDidAppear(_:)),
                swizzledSelector: #selector(UIViewController.debugProbe_viewDidAppear(_:))
            )

            // Swizzle viewDidDisappear
            swizzleMethod(
                cls: viewControllerClass,
                originalSelector: #selector(UIViewController.viewDidDisappear(_:)),
                swizzledSelector: #selector(UIViewController.debugProbe_viewDidDisappear(_:))
            )
        }

        func swizzleMethod(cls: AnyClass, originalSelector: Selector, swizzledSelector: Selector) {
            guard let originalMethod = class_getInstanceMethod(cls, originalSelector),
                  let swizzledMethod = class_getInstanceMethod(cls, swizzledSelector)
            else {
                return
            }

            let didAddMethod = class_addMethod(
                cls,
                originalSelector,
                method_getImplementation(swizzledMethod),
                method_getTypeEncoding(swizzledMethod)
            )

            if didAddMethod {
                class_replaceMethod(
                    cls,
                    swizzledSelector,
                    method_getImplementation(originalMethod),
                    method_getTypeEncoding(originalMethod)
                )
            } else {
                method_exchangeImplementations(originalMethod, swizzledMethod)
            }
        }
    }

    // MARK: - UIViewController Extension

    extension UIViewController {
        @objc
        func debugProbe_viewWillAppear(_ animated: Bool) {
            // 调用原始实现
            debugProbe_viewWillAppear(animated)

            // 记录页面开始
            PageTimingRecorder.shared.handleViewWillAppear(self, animated: animated)
        }

        @objc
        func debugProbe_viewDidLayoutSubviews() {
            // 调用原始实现
            debugProbe_viewDidLayoutSubviews()

            // 记录首次布局
            PageTimingRecorder.shared.handleViewDidLayoutSubviews(self)
        }

        @objc
        func debugProbe_viewDidAppear(_ animated: Bool) {
            // 调用原始实现
            debugProbe_viewDidAppear(animated)

            // 记录页面出现
            PageTimingRecorder.shared.handleViewDidAppear(self, animated: animated)
        }

        @objc
        func debugProbe_viewDidDisappear(_ animated: Bool) {
            // 调用原始实现
            debugProbe_viewDidDisappear(animated)

            // 清理未完成的访问
            PageTimingRecorder.shared.handleViewDidDisappear(self, animated: animated)
        }
    }
#endif
