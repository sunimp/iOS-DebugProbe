# DebugProbe SDK 更新日志

所有显著更改都将记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

---

## [1.5.0] - 2025-12-17

### 新增

#### 页面耗时监控
- 新增 `PageTimingRecorder` 页面耗时记录器
- 支持 UIKit 自动采集（viewWillAppear → viewDidAppear）
- 支持 SwiftUI UIHostingController 自动采集
- 支持手动 API 精确控制页面生命周期标记
- 支持自定义标记点（markers）
- 支持采样率控制和黑/白名单

#### 性能监控增强
- 新增页面耗时数据上报
- 支持冷启动首屏标记
- 支持页面导航类型（push/pop）

### 修复

- 修复 SwiftUI 页面被错误过滤的问题（shouldTrack 逻辑优化）

---

## [1.4.0] - 2025-12-12

### 新增

#### 性能监控插件
- 新增 `PerformancePlugin` 插件
- 支持 CPU 使用率监控
- 支持内存使用监控
- 支持帧率 (FPS) 监控
- 插件 ID: `performance`

#### 插件系统增强
- 插件数量从 7 个增加到 8 个
- 完善插件生命周期管理
- 优化事件路由机制

### 文档

- 更新 README.md 架构图
- 修正内置插件列表（添加 PerformancePlugin）
- 修正插件 ID（`network` → `http`）
- 更新目录结构说明

---

## [1.3.0] - 2025-12-06

### 新增

#### 断点调试完善
- `BreakpointEngine` 网络层集成完成
- 支持请求断点和响应断点
- `breakpointHit` 消息正确上报到 Debug Hub
- `breakpointResume` 命令正确处理

#### Chaos 故障注入
- `ChaosEngine` 网络层集成完成
- 支持延迟注入
- 支持超时模拟
- 支持连接重置
- 支持错误码注入
- 支持数据损坏
- 支持请求丢弃

#### 数据库检查增强
- SQL 查询超时保护（5 秒自动中断）
- 结果集大小限制（最多 1000 行）
- 并发查询限制（串行队列）
- SQLite 内存安全修复

#### 日志系统优化
- 日志级别调整为 CocoaLumberjack 标准
- 级别顺序：error > warning > info > debug > verbose
- 移除 `fault` 级别，新增 `verbose` 级别

### 修复

- 修复 `tableExists()` 方法的内存 bug
- 使用 `SQLITE_TRANSIENT` 确保字符串正确绑定
- 修复 `BreakpointResumeDTO` 消息格式

---

## [1.2.0] - 2025-12-04

### 新增

#### 请求重放
- 完整实现 `replayRequest` 消息处理
- 使用 `.ephemeral` URLSession 执行重放
- 避免重放请求被重复记录

### 修复

#### 协议兼容性
- 添加缺失的消息类型：`replayRequest`, `updateBreakpointRules`, `breakpointResume`, `updateChaosRules`
- `ReplayRequestPayload` 字段同步：`requestId` → `id`，`body` 类型改为 `String?` (base64)

---

## [1.1.0] - 2025-12-03

### 新增

#### 配置管理
- `DebugProbeSettings` 运行时配置管理
- 支持 Info.plist 配置
- 支持 UserDefaults 持久化
- 配置变更通知机制

#### 网络捕获增强
- HTTP 自动拦截 (`URLSessionConfigurationSwizzle`)
- WebSocket 连接级 Swizzle
- WebSocket 消息级 Hook

#### 可靠性增强
- 事件持久化队列 (SQLite)
- 断线重连自动恢复
- 批量发送优化

#### 内部日志
- `DebugLog` 分级日志系统
- 支持 verbose 开关

### 变更

- 重构为插件化架构
- 统一使用 `PluginManager` 管理所有功能模块

---

## [1.0.0] - 2025-12-02

### 新增

#### 核心功能
- HTTP/HTTPS 请求捕获 (URLProtocol)
- URLSessionTaskMetrics 性能数据
- CocoaLumberjack 日志集成
- os_log 日志捕获
- WebSocket 连接监控
- SQLite 数据库检查

#### 调试功能
- Mock 规则引擎
- 断点调试框架
- 故障注入框架

#### 通信
- WebSocket 连接到 Debug Hub
- 设备信息上报
- 实时事件推送

---

## 版本历史图表

```
1.0.0 ────► 1.1.0 ────► 1.2.0 ────► 1.3.0 ────► 1.4.0 (当前)
  │           │           │           │           │
  │           │           │           │           └─ 性能监控插件
  │           │           │           │              文档更新
  │           │           │           │
  │           │           │           └─ 断点/Chaos 完善
  │           │           │              数据库检查增强
  │           │           │              日志级别优化
  │           │           │
  │           │           └─ 请求重放实现
  │           │              协议兼容性修复
  │           │
  │           └─ 配置管理系统
  │              网络捕获增强
  │              插件化架构
  │
  └─ 核心功能实现
     HTTP/Log/WS/DB 捕获
     Mock/断点/Chaos 框架
```

---

## 升级指南

### 从 1.3.x 升级到 1.4.x

1. **无破坏性变更**，直接更新依赖即可

2. **新增 PerformancePlugin**：
   ```swift
   // 默认自动注册，无需手动操作
   // 如需禁用：
   DebugProbe.shared.setPluginEnabled("performance", enabled: false)
   ```

### 从 1.2.x 升级到 1.3.x

1. **日志级别变更**：
   - 如果使用自定义日志级别映射，需要更新 `fault` → `error`
   - 新增 `verbose` 级别支持

2. **断点功能可用**：
   - 断点和 Chaos 功能现已完全可用
   - 确保 Debug Hub 版本 >= 1.3.0

### 从 1.1.x 升级到 1.2.x

1. **协议兼容**：
   - SDK 会自动处理新消息类型
   - 建议同时升级 Debug Hub

### 从 1.0.x 升级到 1.1.x

1. **配置迁移**：
   ```swift
   // 旧方式（已废弃）
   // DebugProbe.shared.start(hubURL: url, token: token)
   
   // 新方式
   DebugProbeSettings.shared.configure(host: "192.168.1.100", port: 8081)
   DebugProbe.shared.start()
   ```

2. **插件化架构**：
   - 所有功能现通过插件系统管理
   - 可单独启用/禁用各功能模块
