# DebugProbe

iOS 调试探针 SDK，用于实时捕获和分析 iOS App 的网络请求、日志、数据库等调试信息。

> [!IMPORTANT]
>
> **本项目全部代码和文档均由 Agent AI 生成**

## 功能特性

### 🌐 网络捕获
- **HTTP/HTTPS 请求捕获** - 自动拦截所有网络请求，包括 URLSession、Alamofire 等
- **WebSocket 监控** - 捕获 WebSocket 连接和消息
- **请求/响应详情** - 完整的 Headers、Body、Timing 信息
- **gRPC & Protobuf 支持** - 自动解析 Protobuf 格式数据

### 🎭 Mock Engine
- **请求 Mock** - 拦截请求并返回自定义响应
- **延迟注入** - 模拟网络延迟
- **条件匹配** - 支持 URL、Method、Header 等多种匹配规则

### 🔧 断点调试
- **请求断点** - 暂停请求并允许修改
- **响应断点** - 拦截响应并允许修改后返回
- **实时编辑** - 在 Web UI 中直接编辑请求/响应内容

### 💥 Chaos Engineering
- **延迟注入** - 模拟网络延迟
- **超时模拟** - 模拟请求超时
- **错误码注入** - 返回指定的 HTTP 错误码
- **连接重置** - 模拟网络中断
- **数据损坏** - 模拟响应数据损坏

### 📋 日志捕获
- **CocoaLumberjack 集成** - 自动捕获 DDLog 日志
- **OSLog 支持** - 捕获系统日志
- **自定义日志** - 支持自定义日志级别和分类

### 🗄️ 数据库检查
- **SQLite 浏览** - 查看 App 内的 SQLite 数据库
- **表数据查询** - 支持分页、排序、SQL 查询
- **Schema 查看** - 查看表结构

## 安装

### Swift Package Manager

在 `Package.swift` 中添加依赖：

```swift
dependencies: [
    .package(url: "https://github.com/aspect-build/DebugProbe.git", from: "1.0.0")
]
```

或在 Xcode 中：
1. File → Add Package Dependencies
2. 输入仓库 URL
3. 选择版本并添加到目标

## 快速开始

### 1. 初始化

```swift
import DebugProbe

// 在 AppDelegate 或 App 入口处初始化
func application(_ application: UIApplication, didFinishLaunchingWithOptions...) -> Bool {
    
    #if DEBUG
    let config = DebugProbe.Configuration(
        hubURL: URL(string: "ws://192.168.1.100:8081/debug-bridge")!,
        token: "your-device-token"
    )
    DebugProbe.shared.start(with: config)
    #endif
    
    return true
}
```

### 2. 配置选项

```swift
var config = DebugProbe.Configuration(
    hubURL: URL(string: "ws://localhost:8081/debug-bridge")!,
    token: "device-token"
)

// 网络捕获模式（默认自动）
config.networkCaptureMode = .automatic  // 自动拦截所有请求
// config.networkCaptureMode = .manual  // 手动注入 protocolClasses

// 网络捕获范围
config.networkCaptureScope = .all       // HTTP + WebSocket
// config.networkCaptureScope = .http   // 仅 HTTP
// config.networkCaptureScope = .webSocket // 仅 WebSocket

// 日志捕获
config.enableLogCapture = true

// 持久化（断线重连后恢复发送）
config.enablePersistence = true
config.maxPersistenceQueueSize = 100_000
config.persistenceRetentionDays = 3

DebugProbe.shared.start(with: config)
```

### 3. 注册数据库（可选）

```swift
import DebugProbe

// 注册要检查的数据库
DatabaseRegistry.shared.register(
    path: databasePath,
    name: "MyDatabase",
    kind: .main,
    isSensitive: false
)
```

### 4. 自定义日志（可选）

```swift
// 发送自定义调试日志
DebugProbe.shared.log(
    level: .info,
    message: "用户登录成功",
    subsystem: "Auth",
    category: "Login"
)
```

## 架构

```
DebugProbe/
├── Sources/
│   ├── Core/
│   │   ├── DebugProbe.swift          # 主入口
│   │   ├── DebugBridgeClient.swift   # WebSocket 通信
│   │   ├── DebugEventBus.swift       # 事件总线
│   │   ├── BreakpointEngine.swift    # 断点引擎
│   │   ├── ChaosEngine.swift         # 混沌工程引擎
│   │   └── EventPersistenceQueue.swift # 事件持久化
│   ├── Network/
│   │   ├── CaptureURLProtocol.swift  # HTTP 拦截
│   │   └── WebSocketInterceptor.swift # WebSocket 拦截
│   ├── Mock/
│   │   └── MockRuleEngine.swift      # Mock 规则引擎
│   ├── Log/
│   │   └── DebugProbeDDLogger.swift  # CocoaLumberjack 集成
│   ├── Database/
│   │   └── DatabaseRegistry.swift    # 数据库注册
│   └── Models/
│       └── ...                       # 数据模型
└── Package.swift
```

## 与 DebugHub 配合使用

DebugProbe 需要配合 [DebugHub](../DebugPlatform/DebugHub) 服务端使用：

1. 启动 DebugHub 服务器
2. 在 iOS App 中配置 DebugProbe 连接到 DebugHub
3. 打开 Web UI (http://localhost:8081) 查看调试信息

## 要求

- iOS 14.0+
- macOS 12.0+
- Swift 5.9+
- Xcode 15.0+

## 可选依赖

- [CocoaLumberjack](https://github.com/CocoaLumberjack/CocoaLumberjack) - 用于日志捕获集成

## License

MIT License

## 相关项目

- [DebugPlatform](../DebugPlatform) - 完整的调试平台（包含 DebugHub 服务端和 Web UI）
