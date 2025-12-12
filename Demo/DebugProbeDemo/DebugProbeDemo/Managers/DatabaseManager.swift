//
//  DatabaseManager.swift
//  DebugProbeDemo
//
//  Created by Sun on 2025/12/11.
//

import Foundation
import SQLite3
import DebugProbe

/// Demo 用户数据模型
struct DemoUser: Identifiable {
    let id: Int
    let name: String
    let email: String
    let createdAt: Date
}

/// 数据库管理器
class DatabaseManager {
    static let shared = DatabaseManager()
    
    private var db: OpaquePointer?
    
    var databasePath: String {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("demo.db").path
    }
    
    private init() {}
    
    /// 初始化数据库并注册到 DebugProbe
    func setupAndRegister() {
        // 打开数据库
        if sqlite3_open(databasePath, &db) != SQLITE_OK {
            print("❌ Failed to open database")
            return
        }
        
        // 创建表
        createTables()
        
        // 注册到 DebugProbe
        #if DEBUG
        let dbURL = URL(fileURLWithPath: databasePath)
        DatabaseRegistry.shared.register(
            id: "demo-db",
            name: "Demo Database",
            url: dbURL,
            kind: "main",
            isSensitive: false
        )
        print("✅ Database registered to DebugProbe: \(databasePath)")
        #endif
    }
    
    private func createTables() {
        let createUsersTable = """
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                email TEXT NOT NULL UNIQUE,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            );
        """
        
        let createPostsTable = """
            CREATE TABLE IF NOT EXISTS posts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL,
                title TEXT NOT NULL,
                content TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (user_id) REFERENCES users(id)
            );
        """
        
        let createSettingsTable = """
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            );
        """
        
        executeSQL(createUsersTable)
        executeSQL(createPostsTable)
        executeSQL(createSettingsTable)
        
        // 插入一些初始设置
        executeSQL("INSERT OR REPLACE INTO settings (key, value) VALUES ('theme', 'dark');")
        executeSQL("INSERT OR REPLACE INTO settings (key, value) VALUES ('language', 'zh-CN');")
        executeSQL("INSERT OR REPLACE INTO settings (key, value) VALUES ('notifications', 'enabled');")
    }
    
    private func executeSQL(_ sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg = errMsg {
                print("❌ SQL Error: \(String(cString: errMsg))")
                sqlite3_free(errMsg)
            }
        }
    }
    
    // MARK: - User CRUD
    
    func insertUser(name: String, email: String) {
        let sql = "INSERT INTO users (name, email) VALUES (?, ?);"
        var stmt: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (email as NSString).utf8String, -1, nil)
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                print("❌ Failed to insert user")
            }
        }
        sqlite3_finalize(stmt)
    }
    
    func getAllUsers() -> [DemoUser] {
        var users: [DemoUser] = []
        let sql = "SELECT id, name, email, created_at FROM users ORDER BY id DESC;"
        var stmt: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(stmt, 0))
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let email = String(cString: sqlite3_column_text(stmt, 2))
                
                var createdAt = Date()
                if let dateText = sqlite3_column_text(stmt, 3) {
                    let dateString = String(cString: dateText)
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    if let date = formatter.date(from: dateString) {
                        createdAt = date
                    }
                }
                
                users.append(DemoUser(id: id, name: name, email: email, createdAt: createdAt))
            }
        }
        sqlite3_finalize(stmt)
        
        return users
    }
    
    func deleteUser(id: Int) {
        let sql = "DELETE FROM users WHERE id = ?;"
        var stmt: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(id))
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                print("❌ Failed to delete user")
            }
        }
        sqlite3_finalize(stmt)
    }
    
    func deleteAllUsers() {
        executeSQL("DELETE FROM users;")
    }
    
    // MARK: - Post CRUD
    
    func insertPost(userId: Int, title: String, content: String) {
        let sql = "INSERT INTO posts (user_id, title, content) VALUES (?, ?, ?);"
        var stmt: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(userId))
            sqlite3_bind_text(stmt, 2, (title as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (content as NSString).utf8String, -1, nil)
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                print("❌ Failed to insert post")
            }
        }
        sqlite3_finalize(stmt)
    }
}
