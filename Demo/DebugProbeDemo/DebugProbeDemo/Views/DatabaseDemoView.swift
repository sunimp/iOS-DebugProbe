//
//  DatabaseDemoView.swift
//  DebugProbeDemo
//
//  Created by Sun on 2025/12/11.
//

import SwiftUI

struct DatabaseDemoView: View {
    @State private var users: [DemoUser] = []
    @State private var newUserName = ""
    @State private var newUserEmail = ""
    @State private var selectedUser: DemoUser?
    @State private var showingAddSheet = false
    
    var body: some View {
        List {
            // 数据库信息
            Section {
                HStack {
                    Text("数据库路径")
                    Spacer()
                    Text(DatabaseManager.shared.databasePath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                HStack {
                    Text("用户数量")
                    Spacer()
                    Text("\(users.count)")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("数据库信息")
            }
            
            // 操作
            Section {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("添加用户", systemImage: "person.badge.plus")
                }
                
                Button {
                    addRandomUser()
                } label: {
                    Label("添加随机用户", systemImage: "dice")
                }
                
                Button {
                    addBatchUsers(count: 10)
                } label: {
                    Label("批量添加 10 个用户", systemImage: "person.3")
                }
                
                Button(role: .destructive) {
                    deleteAllUsers()
                } label: {
                    Label("删除所有用户", systemImage: "trash")
                }
            } header: {
                Text("数据操作")
            }
            
            // 用户列表
            Section {
                if users.isEmpty {
                    Text("暂无用户数据")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ForEach(users) { user in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(user.name)
                                .font(.headline)
                            Text(user.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Text("ID: \(user.id)")
                                Spacer()
                                Text(user.createdAt, style: .date)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteUser(user)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("用户列表")
                    Spacer()
                    Button("刷新") {
                        refreshUsers()
                    }
                    .font(.caption)
                }
            }
        }
        .navigationTitle("数据库")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshUsers()
        }
        .sheet(isPresented: $showingAddSheet) {
            addUserSheet
        }
    }
    
    private var addUserSheet: some View {
        NavigationStack {
            Form {
                TextField("姓名", text: $newUserName)
                TextField("邮箱", text: $newUserEmail)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
            }
            .navigationTitle("添加用户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showingAddSheet = false
                        newUserName = ""
                        newUserEmail = ""
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        addUser()
                    }
                    .disabled(newUserName.isEmpty || newUserEmail.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
    
    private func refreshUsers() {
        users = DatabaseManager.shared.getAllUsers()
    }
    
    private func addUser() {
        DatabaseManager.shared.insertUser(name: newUserName, email: newUserEmail)
        showingAddSheet = false
        newUserName = ""
        newUserEmail = ""
        refreshUsers()
    }
    
    private func addRandomUser() {
        let names = ["Alice", "Bob", "Charlie", "Diana", "Eve", "Frank", "Grace", "Henry"]
        let domains = ["gmail.com", "outlook.com", "icloud.com", "yahoo.com"]
        let randomName = names.randomElement()!
        let randomDomain = domains.randomElement()!
        let email = "\(randomName.lowercased())\(Int.random(in: 100...999))@\(randomDomain)"
        
        DatabaseManager.shared.insertUser(name: randomName, email: email)
        refreshUsers()
    }
    
    private func addBatchUsers(count: Int) {
        for i in 1...count {
            let name = "User \(i)"
            let email = "user\(i)_\(Int.random(in: 1000...9999))@example.com"
            DatabaseManager.shared.insertUser(name: name, email: email)
        }
        refreshUsers()
    }
    
    private func deleteUser(_ user: DemoUser) {
        DatabaseManager.shared.deleteUser(id: user.id)
        refreshUsers()
    }
    
    private func deleteAllUsers() {
        DatabaseManager.shared.deleteAllUsers()
        refreshUsers()
    }
}

#Preview {
    NavigationStack {
        DatabaseDemoView()
    }
}
