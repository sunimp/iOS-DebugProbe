// EventPersistenceQueue.swift
// DebugProbe
//
// Created by Sun on 2025/12/02.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation
import SQLite3

/// 事件持久化队列
/// 负责在断线期间将事件存储到本地 SQLite 数据库，并在重连后恢复发送
public final class EventPersistenceQueue {
    // MARK: - Singleton

    public static let shared = EventPersistenceQueue()

    // MARK: - Configuration

    public struct Configuration {
        /// 数据库文件名
        public var databaseName: String = "debug_events_queue.sqlite"

        /// 最大队列大小（超过时删除最旧的）
        public var maxQueueSize: Int = 100_000

        /// 事件最大保留时间（秒）
        public var maxRetentionSeconds: TimeInterval = 3 * 24 * 3600 // 3 days

        /// 批量读取大小
        public var batchSize: Int = 100

        public init() {}
    }

    // MARK: - State

    private var db: OpaquePointer?
    private var configuration: Configuration = .init()
    private let queue = DispatchQueue(label: "com.sunimp.debugplatform.persistence", qos: .utility)
    private var isInitialized = false

    // MARK: - Statistics

    /// 当前队列中的事件数量
    public var queueCount: Int {
        var count = 0
        queue.sync {
            count = queryCount()
        }
        return count
    }

    // MARK: - Lifecycle

    private init() {}

    deinit {
        close()
    }

    // MARK: - Initialization

    /// 初始化持久化队列
    public func initialize(configuration: Configuration = .init()) {
        queue.sync {
            guard !isInitialized else { return }
            self.configuration = configuration

            do {
                try openDatabase()
                try createTableIfNeeded()
                try cleanupExpiredEvents()
                isInitialized = true
                DebugLog.info(.persistence, "Initialized with \(queryCount()) pending events")
            } catch {
                DebugLog.error(.persistence, "Failed to initialize: \(error)")
            }
        }
    }

    /// 关闭数据库
    public func close() {
        queue.sync {
            if db != nil {
                sqlite3_close(db)
                db = nil
                isInitialized = false
            }
        }
    }

    // MARK: - Database Operations

    private func getDatabasePath() -> String {
        let fileManager = FileManager.default
        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let debugDir = cacheDir.appendingPathComponent("DebugPlatform", isDirectory: true)

        // 确保目录存在
        if !fileManager.fileExists(atPath: debugDir.path) {
            try? fileManager.createDirectory(at: debugDir, withIntermediateDirectories: true)
        }

        return debugDir.appendingPathComponent(configuration.databaseName).path
    }

    private func openDatabase() throws {
        let path = getDatabasePath()

        if sqlite3_open(path, &db) != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw PersistenceError.databaseOpenFailed(errorMessage)
        }

        // 启用 WAL 模式以提高并发性能
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    private func createTableIfNeeded() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS event_queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_id TEXT NOT NULL UNIQUE,
            event_type TEXT NOT NULL,
            event_data BLOB NOT NULL,
            created_at REAL NOT NULL,
            retry_count INTEGER DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_created_at ON event_queue(created_at);
        CREATE INDEX IF NOT EXISTS idx_event_id ON event_queue(event_id);
        """

        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let error = errMsg != nil ? String(cString: errMsg!) : "Unknown error"
            sqlite3_free(errMsg)
            throw PersistenceError.tableCreationFailed(error)
        }
    }

    // MARK: - Enqueue

    /// 将事件入队到持久化存储
    public func enqueue(_ event: DebugEvent) {
        queue.async { [weak self] in
            self?.internalEnqueue(event)
        }
    }

    /// 批量入队事件
    public func enqueue(_ events: [DebugEvent]) {
        queue.async { [weak self] in
            guard let self else { return }
            for event in events {
                internalEnqueue(event)
            }
        }
    }

    private func internalEnqueue(_ event: DebugEvent) {
        guard isInitialized, db != nil else { return }

        do {
            // 检查队列大小
            let currentCount = queryCount()
            if currentCount >= configuration.maxQueueSize {
                // 删除最旧的 10%
                let deleteCount = max(1, configuration.maxQueueSize / 10)
                deleteOldestEvents(count: deleteCount)
            }

            // 编码事件
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601WithMilliseconds
            let eventData = try encoder.encode(event)

            // 获取事件类型
            let eventType = switch event {
            case .http: "http"
            case .webSocket: "websocket"
            case .log: "log"
            case .stats: "stats"
            case .performance: "performance"
            }

            // 插入数据库
            let sql = """
            INSERT OR REPLACE INTO event_queue (event_id, event_type, event_data, created_at)
            VALUES (?, ?, ?, ?)
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw PersistenceError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, event.eventId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, eventType, -1, SQLITE_TRANSIENT)
            _ = eventData.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(eventData.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw PersistenceError.insertFailed(String(cString: sqlite3_errmsg(db)))
            }
        } catch {
            DebugLog.error(.persistence, "Failed to enqueue event: \(error)")
        }
    }

    // MARK: - Dequeue

    /// 获取并移除一批待发送的事件
    public func dequeueBatch(maxCount: Int? = nil) -> [DebugEvent] {
        var events: [DebugEvent] = []

        queue.sync {
            guard isInitialized, db != nil else { return }

            let limit = maxCount ?? configuration.batchSize
            let sql = "SELECT id, event_data FROM event_queue ORDER BY created_at ASC LIMIT ?"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                DebugLog.error(.persistence, "Failed to prepare dequeue: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(limit))

            var idsToDelete: [Int64] = []
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601WithMilliseconds

            while sqlite3_step(stmt) == SQLITE_ROW {
                let rowId = sqlite3_column_int64(stmt, 0)

                if let blobPointer = sqlite3_column_blob(stmt, 1) {
                    let blobSize = Int(sqlite3_column_bytes(stmt, 1))
                    let data = Data(bytes: blobPointer, count: blobSize)

                    do {
                        let event = try decoder.decode(DebugEvent.self, from: data)
                        events.append(event)
                        idsToDelete.append(rowId)
                    } catch {
                        // 解码失败的事件也要删除
                        idsToDelete.append(rowId)
                        DebugLog.error(.persistence, "Failed to decode event: \(error)")
                    }
                } else {
                    idsToDelete.append(rowId)
                }
            }

            // 删除已读取的事件
            if !idsToDelete.isEmpty {
                deleteEvents(ids: idsToDelete)
            }
        }

        return events
    }

    /// 查看但不移除一批事件
    public func peekBatch(maxCount: Int? = nil) -> [DebugEvent] {
        var events: [DebugEvent] = []

        queue.sync {
            guard isInitialized, db != nil else { return }

            let limit = maxCount ?? configuration.batchSize
            let sql = "SELECT event_data FROM event_queue ORDER BY created_at ASC LIMIT ?"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(limit))

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601WithMilliseconds

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let blobPointer = sqlite3_column_blob(stmt, 0) {
                    let blobSize = Int(sqlite3_column_bytes(stmt, 0))
                    let data = Data(bytes: blobPointer, count: blobSize)

                    if let event = try? decoder.decode(DebugEvent.self, from: data) {
                        events.append(event)
                    }
                }
            }
        }

        return events
    }

    // MARK: - Helpers

    private func queryCount() -> Int {
        guard db != nil else { return 0 }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM event_queue", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    private func deleteOldestEvents(count: Int) {
        guard db != nil else { return }

        let sql = """
        DELETE FROM event_queue WHERE id IN (
            SELECT id FROM event_queue ORDER BY created_at ASC LIMIT ?
        )
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(count))
        sqlite3_step(stmt)
    }

    private func deleteEvents(ids: [Int64]) {
        guard db != nil, !ids.isEmpty else { return }

        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "DELETE FROM event_queue WHERE id IN (\(placeholders))"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        for (index, id) in ids.enumerated() {
            sqlite3_bind_int64(stmt, Int32(index + 1), id)
        }
        sqlite3_step(stmt)
    }

    private func cleanupExpiredEvents() throws {
        guard db != nil else { return }

        let cutoffTime = Date().timeIntervalSince1970 - configuration.maxRetentionSeconds
        let sql = "DELETE FROM event_queue WHERE created_at < ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw PersistenceError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, cutoffTime)

        if sqlite3_step(stmt) != SQLITE_DONE {
            throw PersistenceError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }

        let deletedCount = sqlite3_changes(db)
        if deletedCount > 0 {
            DebugLog.debug(.persistence, "Cleaned up \(deletedCount) expired events")
        }
    }

    /// 清空所有队列事件
    public func clear() {
        queue.async { [weak self] in
            guard let self, let db else { return }

            var errMsg: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, "DELETE FROM event_queue", nil, nil, &errMsg)
            sqlite3_free(errMsg)
            DebugLog.debug(.persistence, "Queue cleared")
        }
    }

    /// 确认事件已成功发送（从队列中移除）
    public func confirmDelivered(eventIds: [String]) {
        guard !eventIds.isEmpty else { return }

        queue.async { [weak self] in
            guard let self, let db else { return }

            let placeholders = eventIds.map { _ in "?" }.joined(separator: ",")
            let sql = "DELETE FROM event_queue WHERE event_id IN (\(placeholders))"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            for (index, eventId) in eventIds.enumerated() {
                sqlite3_bind_text(stmt, Int32(index + 1), eventId, -1, SQLITE_TRANSIENT)
            }
            sqlite3_step(stmt)
        }
    }

    // MARK: - Error Types

    public enum PersistenceError: LocalizedError {
        case databaseOpenFailed(String)
        case tableCreationFailed(String)
        case prepareFailed(String)
        case insertFailed(String)
        case deleteFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .databaseOpenFailed(msg): "Database open failed: \(msg)"
            case let .tableCreationFailed(msg): "Table creation failed: \(msg)"
            case let .prepareFailed(msg): "Prepare statement failed: \(msg)"
            case let .insertFailed(msg): "Insert failed: \(msg)"
            case let .deleteFailed(msg): "Delete failed: \(msg)"
            }
        }
    }
}

// MARK: - SQLite Constants

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
