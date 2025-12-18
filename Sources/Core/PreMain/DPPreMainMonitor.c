//
//  DPPreMainMonitor.c
//  DebugProbe
//
//  PreMain 阶段精确时间监控实现
//  使用 dyld 回调 + mach_absolute_time 实现纳秒级精度
//
//  执行时机说明：
//  1. __attribute__((constructor)) 在所有 +load 之后、main() 之前执行
//  2. _dyld_register_func_for_add_image 回调在每个镜像加载时触发
//  3. 通过 sysctl 获取进程真正的启动时间来估算 kernel -> constructor 的时间
//
//  Created by Sun on 2025/12/18.
//  Copyright © 2025 Sun. All rights reserved.
//

#include "DPPreMainMonitor.h"

#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <pthread.h>
#include <libkern/OSAtomic.h>
#include <stdatomic.h>
#include <dlfcn.h>

// MARK: - 全局数据

/// 全局 PreMain 数据
static DPPreMainData g_preMainData = {0};

/// dylib 加载信息数组
static DPDylibLoadInfo g_dylibLoadInfos[DP_MAX_DYLIB_COUNT] = {0};

/// 当前 dylib 记录索引（原子操作保证线程安全）
static atomic_uint g_dylibIndex = 0;

/// 初始化完成标志
static atomic_bool g_initialized = false;

/// 互斥锁用于数据访问
static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;

// MARK: - 内部函数声明

static void dp_dyld_image_added_callback(const struct mach_header *mh, intptr_t slide);
static void dp_initialize_timebase(void);
static uint64_t dp_get_process_start_time_unix_micros(void);
static void dp_calculate_durations(void);
static const char* dp_extract_filename(const char* path);
static bool dp_is_system_library(const char* path);

// MARK: - 时间转换

/// 初始化时间基准
static void dp_initialize_timebase(void) {
    mach_timebase_info_data_t timebaseInfo;
    mach_timebase_info(&timebaseInfo);
    g_preMainData.timebaseNumer = timebaseInfo.numer;
    g_preMainData.timebaseDenom = timebaseInfo.denom;
}

uint64_t DPMachTimeToNanos(uint64_t machTime) {
    if (g_preMainData.timebaseDenom == 0) {
        dp_initialize_timebase();
    }
    return machTime * g_preMainData.timebaseNumer / g_preMainData.timebaseDenom;
}

double DPMachTimeToMillis(uint64_t machTime) {
    return (double)DPMachTimeToNanos(machTime) / 1000000.0;
}

uint64_t DPGetCurrentMachTime(void) {
    return mach_absolute_time();
}

// MARK: - 进程启动时间获取

/// 通过 sysctl 获取进程启动时间（Unix 时间戳，微秒）
static uint64_t dp_get_process_start_time_unix_micros(void) {
    struct kinfo_proc kinfo;
    size_t size = sizeof(kinfo);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    
    if (sysctl(mib, 4, &kinfo, &size, NULL, 0) != 0) {
        return 0;
    }
    
    struct timeval startTime = kinfo.kp_proc.p_starttime;
    return (uint64_t)startTime.tv_sec * 1000000 + (uint64_t)startTime.tv_usec;
}

// MARK: - 路径处理

/// 从完整路径提取文件名
static const char* dp_extract_filename(const char* path) {
    if (path == NULL) return "unknown";
    
    const char* lastSlash = strrchr(path, '/');
    if (lastSlash != NULL) {
        return lastSlash + 1;
    }
    return path;
}

/// 判断是否为系统库
static bool dp_is_system_library(const char* path) {
    if (path == NULL) return false;
    
    // 系统库路径前缀
    static const char* systemPrefixes[] = {
        "/usr/lib/",
        "/System/",
        "/Library/Apple/",
        "/private/var/db/dyld/",
        "/AppleInternal/",
        NULL
    };
    
    for (int i = 0; systemPrefixes[i] != NULL; i++) {
        if (strncmp(path, systemPrefixes[i], strlen(systemPrefixes[i])) == 0) {
            return true;
        }
    }
    
    return false;
}

// MARK: - dyld 回调

/// dyld 镜像加载回调
static void dp_dyld_image_added_callback(const struct mach_header *mh, intptr_t slide) {
    uint64_t currentMachTime = mach_absolute_time();
    
    // 记录首次和最后一次回调时间
    pthread_mutex_lock(&g_mutex);
    
    if (g_preMainData.timestamps.firstDyldCallbackMachTime == 0) {
        g_preMainData.timestamps.firstDyldCallbackMachTime = currentMachTime;
    }
    g_preMainData.timestamps.lastDyldCallbackMachTime = currentMachTime;
    
    pthread_mutex_unlock(&g_mutex);
    
    // 如果禁用了细分记录，直接返回
    if (!g_preMainData.dylibDetailEnabled) {
        atomic_fetch_add(&g_dylibIndex, 1);
        return;
    }
    
    // 获取当前索引并递增
    uint32_t index = atomic_fetch_add(&g_dylibIndex, 1);
    
    // 检查是否超出最大记录数
    if (index >= DP_MAX_DYLIB_COUNT) {
        return;
    }
    
    // 获取镜像路径
    Dl_info info;
    const char* imagePath = NULL;
    if (dladdr(mh, &info) && info.dli_fname != NULL) {
        imagePath = info.dli_fname;
    }
    
    // 填充 dylib 信息
    DPDylibLoadInfo* dylibInfo = &g_dylibLoadInfos[index];
    dylibInfo->loadMachTime = currentMachTime;
    dylibInfo->slide = slide;
    
    // 计算相对于 constructor 执行时的耗时
    if (g_preMainData.timestamps.constructorMachTime > 0) {
        uint64_t elapsed = currentMachTime - g_preMainData.timestamps.constructorMachTime;
        dylibInfo->loadDurationNanos = DPMachTimeToNanos(elapsed);
    } else {
        dylibInfo->loadDurationNanos = 0;
    }
    
    // 记录名称
    if (imagePath != NULL) {
        const char* filename = dp_extract_filename(imagePath);
        strncpy(dylibInfo->name, filename, DP_MAX_DYLIB_NAME_LENGTH - 1);
        dylibInfo->name[DP_MAX_DYLIB_NAME_LENGTH - 1] = '\0';
        dylibInfo->isSystemLibrary = dp_is_system_library(imagePath);
    } else {
        strncpy(dylibInfo->name, "unknown", DP_MAX_DYLIB_NAME_LENGTH - 1);
        dylibInfo->isSystemLibrary = false;
    }
    
    // 更新统计
    pthread_mutex_lock(&g_mutex);
    g_preMainData.dylibCount = index + 1;
    if (dylibInfo->isSystemLibrary) {
        g_preMainData.systemDylibCount++;
    } else {
        g_preMainData.userDylibCount++;
    }
    pthread_mutex_unlock(&g_mutex);
}

// MARK: - 耗时计算

/// 计算各阶段耗时
static void dp_calculate_durations(void) {
    DPPreMainTimestamps* ts = &g_preMainData.timestamps;
    DPPreMainDurations* dur = &g_preMainData.durations;
    
    // 如果 main 未标记，无法计算总耗时
    if (!g_preMainData.mainExecutedMarked || ts->mainExecutedMachTime == 0) {
        return;
    }
    
    // constructor 到 main 的总耗时（这是我们能精确测量的）
    if (ts->constructorMachTime > 0) {
        uint64_t totalMachTime = ts->mainExecutedMachTime - ts->constructorMachTime;
        dur->totalPreMainMs = DPMachTimeToMillis(totalMachTime);
    }
    
    // dylib 加载耗时
    if (ts->firstDyldCallbackMachTime > 0 && ts->lastDyldCallbackMachTime > 0) {
        uint64_t dylibMachTime = ts->lastDyldCallbackMachTime - ts->firstDyldCallbackMachTime;
        dur->dylibLoadingMs = DPMachTimeToMillis(dylibMachTime);
    }
    
    // ObjC +load 耗时
    if (ts->objcLoadStartMachTime > 0 && ts->objcLoadEndMachTime > 0) {
        uint64_t objcLoadMachTime = ts->objcLoadEndMachTime - ts->objcLoadStartMachTime;
        dur->objcLoadMs = DPMachTimeToMillis(objcLoadMachTime);
    }
    
    // constructor 到 first dyld callback（静态初始化器）
    if (ts->constructorMachTime > 0 && ts->firstDyldCallbackMachTime > 0) {
        uint64_t staticInitMachTime = ts->firstDyldCallbackMachTime - ts->constructorMachTime;
        dur->staticInitializerMs = DPMachTimeToMillis(staticInitMachTime);
    }
    
    // last dyld callback 到 main
    if (ts->lastDyldCallbackMachTime > 0) {
        uint64_t postDyldMachTime = ts->mainExecutedMachTime - ts->lastDyldCallbackMachTime;
        dur->postDyldToMainMs = DPMachTimeToMillis(postDyldMachTime);
    }
    
    // 估算 kernel 到 constructor 的时间
    // 使用进程启动的 Unix 时间与当前 Unix 时间的差值，再减去已测量的时间
    if (ts->processStartTimeUnixMicros > 0) {
        struct timeval now;
        gettimeofday(&now, NULL);
        uint64_t nowUnixMicros = (uint64_t)now.tv_sec * 1000000 + (uint64_t)now.tv_usec;
        
        // 从进程启动到现在的总时间（毫秒）
        double totalSinceStartMs = (double)(nowUnixMicros - ts->processStartTimeUnixMicros) / 1000.0;
        
        // 从 constructor 到现在的时间
        uint64_t constructorToNowNanos = DPMachTimeToNanos(mach_absolute_time() - ts->constructorMachTime);
        double constructorToNowMs = (double)constructorToNowNanos / 1000000.0;
        
        // 估算 kernel 到 constructor 的时间
        dur->estimatedKernelToConstructorMs = totalSinceStartMs - constructorToNowMs;
        
        // 防止负数（时钟漂移等原因）
        if (dur->estimatedKernelToConstructorMs < 0) {
            dur->estimatedKernelToConstructorMs = 0;
        }
    }
}

// MARK: - 模块初始化

/// 模块初始化函数
/// __attribute__((constructor)) 保证在 main() 之前执行
/// 优先级 101 保证在大多数其他 constructor 之前执行（101 是最低可用优先级，越小越早）
__attribute__((constructor(101)))
static void dp_premain_init(void) {
    // 防止重复初始化
    bool expected = false;
    if (!atomic_compare_exchange_strong(&g_initialized, &expected, true)) {
        return;
    }
    
    // 初始化时间基准
    dp_initialize_timebase();
    
    // 记录 constructor 执行时间
    g_preMainData.timestamps.constructorMachTime = mach_absolute_time();
    
    // 获取进程启动时间
    g_preMainData.timestamps.processStartTimeUnixMicros = dp_get_process_start_time_unix_micros();
    
    // 默认启用 dylib 细分记录
    g_preMainData.dylibDetailEnabled = true;
    
    // 注册 dyld 镜像加载回调
    // 注意：此回调会被所有已加载的镜像触发一次，然后监听新加载的镜像
    _dyld_register_func_for_add_image(dp_dyld_image_added_callback);
}

// MARK: - 公开 API 实现

const DPPreMainData* DPPreMainGetData(void) {
    return &g_preMainData;
}

void DPPreMainMarkMainExecuted(void) {
    uint64_t mainMachTime = mach_absolute_time();
    
    pthread_mutex_lock(&g_mutex);
    
    // 防止重复标记
    if (!g_preMainData.mainExecutedMarked) {
        g_preMainData.timestamps.mainExecutedMachTime = mainMachTime;
        g_preMainData.mainExecutedMarked = true;
        
        // 计算各阶段耗时
        dp_calculate_durations();
    }
    
    pthread_mutex_unlock(&g_mutex);
}

void DPPreMainMarkObjCLoadStart(void) {
    pthread_mutex_lock(&g_mutex);
    if (g_preMainData.timestamps.objcLoadStartMachTime == 0) {
        g_preMainData.timestamps.objcLoadStartMachTime = mach_absolute_time();
    }
    pthread_mutex_unlock(&g_mutex);
}

void DPPreMainMarkObjCLoadEnd(void) {
    pthread_mutex_lock(&g_mutex);
    if (g_preMainData.timestamps.objcLoadEndMachTime == 0) {
        g_preMainData.timestamps.objcLoadEndMachTime = mach_absolute_time();
    }
    pthread_mutex_unlock(&g_mutex);
}

const DPDylibLoadInfo* DPPreMainGetDylibInfo(uint32_t index) {
    if (index >= g_preMainData.dylibCount || index >= DP_MAX_DYLIB_COUNT) {
        return NULL;
    }
    return &g_dylibLoadInfos[index];
}

uint32_t DPPreMainGetAllDylibs(DPDylibLoadInfo* outBuffer, uint32_t bufferSize) {
    if (outBuffer == NULL || bufferSize == 0) {
        return 0;
    }
    
    pthread_mutex_lock(&g_mutex);
    
    uint32_t count = g_preMainData.dylibCount;
    if (count > bufferSize) {
        count = bufferSize;
    }
    if (count > DP_MAX_DYLIB_COUNT) {
        count = DP_MAX_DYLIB_COUNT;
    }
    
    memcpy(outBuffer, g_dylibLoadInfos, count * sizeof(DPDylibLoadInfo));
    
    pthread_mutex_unlock(&g_mutex);
    
    return count;
}

/// 比较函数用于排序（按耗时降序）
static int dp_compare_dylib_by_duration(const void* a, const void* b) {
    const DPDylibLoadInfo* infoA = (const DPDylibLoadInfo*)a;
    const DPDylibLoadInfo* infoB = (const DPDylibLoadInfo*)b;
    
    if (infoA->loadDurationNanos > infoB->loadDurationNanos) return -1;
    if (infoA->loadDurationNanos < infoB->loadDurationNanos) return 1;
    return 0;
}

uint32_t DPPreMainGetSlowestDylibs(DPDylibLoadInfo* outBuffer, uint32_t count) {
    if (outBuffer == NULL || count == 0) {
        return 0;
    }
    
    pthread_mutex_lock(&g_mutex);
    
    uint32_t totalCount = g_preMainData.dylibCount;
    if (totalCount > DP_MAX_DYLIB_COUNT) {
        totalCount = DP_MAX_DYLIB_COUNT;
    }
    
    // 复制到临时缓冲区进行排序
    DPDylibLoadInfo* tempBuffer = malloc(totalCount * sizeof(DPDylibLoadInfo));
    if (tempBuffer == NULL) {
        pthread_mutex_unlock(&g_mutex);
        return 0;
    }
    
    memcpy(tempBuffer, g_dylibLoadInfos, totalCount * sizeof(DPDylibLoadInfo));
    
    pthread_mutex_unlock(&g_mutex);
    
    // 排序
    qsort(tempBuffer, totalCount, sizeof(DPDylibLoadInfo), dp_compare_dylib_by_duration);
    
    // 复制结果
    uint32_t resultCount = (count < totalCount) ? count : totalCount;
    memcpy(outBuffer, tempBuffer, resultCount * sizeof(DPDylibLoadInfo));
    
    free(tempBuffer);
    
    return resultCount;
}

void DPPreMainSetDylibDetailEnabled(bool enabled) {
    pthread_mutex_lock(&g_mutex);
    g_preMainData.dylibDetailEnabled = enabled;
    pthread_mutex_unlock(&g_mutex);
}

void DPPreMainReset(void) {
    pthread_mutex_lock(&g_mutex);
    
    memset(&g_preMainData, 0, sizeof(g_preMainData));
    memset(g_dylibLoadInfos, 0, sizeof(g_dylibLoadInfos));
    atomic_store(&g_dylibIndex, 0);
    g_preMainData.dylibDetailEnabled = true;
    
    // 重新初始化时间基准
    dp_initialize_timebase();
    
    pthread_mutex_unlock(&g_mutex);
}
