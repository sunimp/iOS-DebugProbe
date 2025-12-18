//
//  DPPreMainMonitor.h
//  DebugProbe
//
//  PreMain 阶段精确时间监控
//  使用 dyld 回调 + mach_absolute_time 实现纳秒级精度
//
//  Created by Sun on 2025/12/18.
//  Copyright © 2025 Sun. All rights reserved.
//

#ifndef DPPreMainMonitor_h
#define DPPreMainMonitor_h

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - 常量定义

/// 最大记录的 dylib 数量（避免内存无限增长）
#define DP_MAX_DYLIB_COUNT 512

/// dylib 名称最大长度
#define DP_MAX_DYLIB_NAME_LENGTH 256

// MARK: - 数据结构

/// dylib 加载信息
typedef struct {
    /// dylib 名称（仅保留文件名，不含路径）
    char name[DP_MAX_DYLIB_NAME_LENGTH];
    /// 加载时的 mach_absolute_time 值
    uint64_t loadMachTime;
    /// 相对于进程启动的耗时（纳秒）
    uint64_t loadDurationNanos;
    /// 是否为系统库（/usr/lib 或 /System 开头）
    bool isSystemLibrary;
    /// 镜像基地址偏移
    intptr_t slide;
} DPDylibLoadInfo;

/// PreMain 阶段时间点
typedef struct {
    /// 进程启动时间（通过 sysctl 获取的 timeval）
    uint64_t processStartTimeUnixMicros;  // Unix 时间戳（微秒）
    
    /// __attribute__((constructor)) 执行时的 mach_absolute_time
    uint64_t constructorMachTime;
    
    /// 首次 dyld 回调时的 mach_absolute_time
    uint64_t firstDyldCallbackMachTime;
    
    /// 最后一次 dyld 回调时的 mach_absolute_time（所有镜像加载完成）
    uint64_t lastDyldCallbackMachTime;
    
    /// main() 函数执行时的 mach_absolute_time（需要手动调用标记）
    uint64_t mainExecutedMachTime;
    
    /// ObjC +load 方法开始执行时的 mach_absolute_time（可选）
    uint64_t objcLoadStartMachTime;
    
    /// ObjC +load 方法结束执行时的 mach_absolute_time（可选）
    uint64_t objcLoadEndMachTime;
} DPPreMainTimestamps;

/// PreMain 阶段耗时统计（转换为毫秒）
typedef struct {
    /// constructor 到 main 的总耗时（毫秒）- 这是我们能精确测量的 PreMain 时间
    double totalPreMainMs;
    
    /// dyld 镜像加载耗时（first dyld callback -> last dyld callback）
    double dylibLoadingMs;
    
    /// ObjC +load 耗时（如果有记录）
    double objcLoadMs;
    
    /// constructor 到 first dyld callback（静态初始化器执行时间）
    double staticInitializerMs;
    
    /// last dyld callback 到 main（包含 Swift 静态初始化等）
    double postDyldToMainMs;
    
    /// 进程实际启动到 constructor 的估算时间（基于系统时间差）
    double estimatedKernelToConstructorMs;
} DPPreMainDurations;

/// 完整的 PreMain 监控数据
typedef struct {
    /// 时间戳记录
    DPPreMainTimestamps timestamps;
    
    /// 耗时统计
    DPPreMainDurations durations;
    
    /// 已加载的 dylib 数量
    uint32_t dylibCount;
    
    /// 系统库数量
    uint32_t systemDylibCount;
    
    /// 用户库数量（总数 - 系统库）
    uint32_t userDylibCount;
    
    /// 是否已完成 main() 标记
    bool mainExecutedMarked;
    
    /// 是否启用 dylib 细分记录
    bool dylibDetailEnabled;
    
    /// mach_timebase_info 用于时间转换
    uint32_t timebaseNumer;
    uint32_t timebaseDenom;
} DPPreMainData;

// MARK: - 公开 API

/// 获取 PreMain 监控数据（只读）
/// @return 指向全局 PreMain 数据的指针
const DPPreMainData* DPPreMainGetData(void);

/// 标记 main() 函数开始执行
/// 应在 main() 函数的第一行调用，或在 @main / AppDelegate 初始化时调用
void DPPreMainMarkMainExecuted(void);

/// 标记 ObjC +load 开始（可选，用于更精确的阶段细分）
void DPPreMainMarkObjCLoadStart(void);

/// 标记 ObjC +load 结束（可选）
void DPPreMainMarkObjCLoadEnd(void);

/// 获取 dylib 加载详情
/// @param index dylib 索引（0 到 dylibCount-1）
/// @return 指向 dylib 信息的指针，如果索引越界返回 NULL
const DPDylibLoadInfo* DPPreMainGetDylibInfo(uint32_t index);

/// 获取所有 dylib 加载信息（按加载顺序）
/// @param outBuffer 输出缓冲区
/// @param bufferSize 缓冲区大小
/// @return 实际复制的 dylib 数量
uint32_t DPPreMainGetAllDylibs(DPDylibLoadInfo* outBuffer, uint32_t bufferSize);

/// 获取加载耗时最长的 N 个 dylib
/// @param outBuffer 输出缓冲区
/// @param count 请求的数量
/// @return 实际返回的数量
uint32_t DPPreMainGetSlowestDylibs(DPDylibLoadInfo* outBuffer, uint32_t count);

/// 启用/禁用 dylib 细分记录（默认启用）
/// 禁用后可减少内存占用，但无法获取单个 dylib 的加载耗时
void DPPreMainSetDylibDetailEnabled(bool enabled);

/// 将 mach_absolute_time 转换为纳秒
uint64_t DPMachTimeToNanos(uint64_t machTime);

/// 将 mach_absolute_time 转换为毫秒
double DPMachTimeToMillis(uint64_t machTime);

/// 获取当前 mach_absolute_time
uint64_t DPGetCurrentMachTime(void);

/// 重置所有记录（仅用于测试）
void DPPreMainReset(void);

#ifdef __cplusplus
}
#endif

#endif /* DPPreMainMonitor_h */
