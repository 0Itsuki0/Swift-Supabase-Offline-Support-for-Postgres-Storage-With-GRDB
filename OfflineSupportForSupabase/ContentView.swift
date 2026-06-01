//
//  ContentView.swift
//  OfflineSupportForSupabase
//
//  Created by Itsuki on 2026/05/28.
//

import SwiftUI

// MARK: - Demo View For Local First Off line support with
// - todo list
// - todo items linked to a list
// - attachments for todo items

struct ContentView: View {
    
    @State private var signedIn = false
    
    private let auth = AppDependencies.shared.remoteClient.userAuthManager

    var body: some View {
        Group {
            if !signedIn {
                Button(
                    action: {
                        Task {
                            do {
                                try await self.auth.signIn(
                                    email: userEmail,
                                    password: password
                                )
                            } catch (let error) {
                                print(error)
                            }
                        }
                    },
                    label: {
                        Text("Sign In with Pre-filled credentials")
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.yellow.opacity(0.1))
            } else {
                TodoListView()
            }
        }
        .task {
            self.signedIn = auth.userId != nil
            for await message in NotificationCenter.default.messages(
                of: Never.self,
                for: .userIdDidChange
            ) {
                self.signedIn = message.userId != nil
            }
        }
    }
}

private struct TodoListView: View {
    private let auth = AppDependencies.shared.remoteClient.userAuthManager
    private let network = AppDependencies.shared.network

    @State private var networkConnected: Bool = false
    @State private var syncing: Bool = false
    @State private var initializing: Bool = false

    @State private var todos: [TodoItem] = []
    @State private var list: TodoList?
    private let listID = UUID(
        uuidString: "a437a70b-3a9e-4311-ac5d-95a7f5b700e9"
    )

    var body: some View {
        NavigationStack {
            List {
                if !networkConnected {
                    HStack {
                        Image(systemName: "wifi.slash")
                        Text("Currently offline: changes will sync upon reconnection!")
                            .font(.caption)
                    }
                    .foregroundStyle(.white)
                    .listRowBackground(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if todos.isEmpty {
                    if self.initializing {
                        ProgressView()
                            .padding()
                            .listRowBackground(Color.clear)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        Text("Add some todos to get started!")
                            .font(.caption)
                    }
                    
                }

                ForEach($todos) { $todo in
                    HStack(spacing:24) {
                        VStack(alignment: .leading) {
                            Text(todo.title)
                                .frame(maxWidth: 120)
                                .multilineTextAlignment(.leading)
                            if todo.syncStatus == .pending {
                                Text("Not synced")
                                    .font(.caption)
                            }
                        }

                        if let attachmentId = todo.attachmentId {
                            VStack(alignment: .leading, content: {
                                Button(
                                    action: {
                                        Task {
                                            do {
                                                if let attachment =
                                                    try await FileAttachment
                                                    .fetchOne(attachmentId)
                                                {
                                                    print(attachment)
                                                    let data =
                                                        try await attachment.data
                                                    print(
                                                        "data size: \(data.count)"
                                                    )
                                                    if let string = String(
                                                        data: data,
                                                        encoding: .utf8
                                                    ) {
                                                        print(
                                                            "data string: \(string)"
                                                        )
                                                    }
                                                } else {
                                                    print("attachment not found")
                                                }
                                            } catch (let error) {
                                                print(error)
                                            }
                                        }
                                    },
                                    label: {
                                        Text("log attachment")
                                    }
                                )
                                
                                Button(
                                    action: {
                                        Task {
                                            do {
                                                if var attachment =
                                                    try await FileAttachment
                                                    .fetchOne(attachmentId)
                                                {
                                                    try await attachment.delete()
                                                    // there is a trigger for setting the record attachment id, status, and updated at,
                                                    // Therefore if there is no UI needs to be changed or if the sync doesn't have to happen immediately, we can just return here.
                                                    todo.syncStatus = .pending
                                                    todo.attachmentId = nil
                                                    try await todo.upsert()
                                                } else {
                                                    print("attachment not found")
                                                }
                                            } catch (let error) {
                                                print(error)
                                            }
                                        }
                                    },
                                    label: {
                                        Text("remove attachment")
                                    }
                                )

                            })
                            .foregroundStyle(.link)
                            .font(.caption)
                        } else {
                            Button(
                                action: {
                                    Task {
                                        guard let userId = auth.userId else {
                                            return
                                        }
                                        do {
                                            var attachment = try FileAttachment(
                                                userId: userId,
                                                data: Data(
                                                    Date().ISO8601Format().utf8
                                                ),
                                                fileName: "Date.txt"
                                            )
                                            try await attachment.upsert()
                                            todo.attachmentId = attachment.id
                                            todo.syncStatus = .pending
                                            try await todo.upsert()
                                        } catch (let error) {
                                            print(error)
                                        }
                                    }

                                },
                                label: {
                                    Text("Add String Attachment")
                                }
                            )
                            .foregroundStyle(.link)
                            .font(.caption)

                        }

                        Spacer()
                        Button(
                            action: {
                                toggleDone($todo)
                            },
                            label: {
                                Image(
                                    systemName: todo.completed
                                        ? "checkmark.circle.fill" : "circle"
                                )
                                .foregroundStyle(
                                    todo.completed ? .green : .secondary
                                )
                                .padding(2)
                                .contentShape(Rectangle())

                            }
                        )
                    }
                }
                .onDelete(perform: deleteTodos)
            }
            .buttonStyle(.plain)
            .navigationTitle("Todos")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if syncing {
                        ProgressView()
                    } else {
                        Button("Full Sync") {
                            Task {
                                self.syncing = true
                                await SyncCoordinator.shared.syncNow()
                                self.syncing = false
                                self.loadTodos()
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 24) {
                    Button(self.list == nil ? "Add List" : "Delete List") {
                        guard let listID, let userId = auth.userId else {
                            return
                        }
                        Task {
                            do {
                                if var list {
                                    self.list = nil
                                    // no need to remove database ones as they will be handled by server trigger
                                    self.todos.removeAll(where: {
                                        $0.listId == listID
                                    })
                                    try await list.delete()
                                } else {
                                    var new = TodoList(
                                        id: listID,
                                        title: "new",
                                        createdBy: userId
                                    )
                                    self.list = new
                                    try await new.upsert()
                                }
                            } catch (let error) {
                                print(error)
                            }
                        }
                    }

                    Button("New Todo") { addTodo() }

                    Button("Log Out") {
                        Task {
                            try? await auth.signOut()
                        }
                    }
                }
                .buttonStyle(.borderless)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .refreshable {
                loadTodos()
            }
            .onAppear {
                loadTodos()
                self.networkConnected = network.isConnected

                Task {
                    for await _ in NotificationCenter.default.messages(
                        of: Never.self,
                        for: .localDBDidChange
                    ) {
                        self.loadTodos()
                    }
                }
                
                Task {
                    for await message in NotificationCenter.default.messages(
                        of: Never.self,
                        for: .connectivityDidChange
                    ) {
                        self.networkConnected = message.isConnected
                        print("network: \(message.isConnected), \(network.isConnected)")
                        if message.isConnected {
                            self.loadTodos()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    // automatically sync when possible
    private func loadTodos() {
        print(#function)
        Task {
            do {
                self.initializing = true
                if let listID {
                    self.list = try await TodoList.fetchOne(listID)
                }
                todos = try await TodoItem.all()
            } catch (let error) {
                print(error)
            }
            self.initializing = false
        }
    }

    private func addTodo() {
        guard let userId = auth.userId,
            let listID
        else {
            return
        }

        var new = TodoItem(
            title: Date().ISO8601Format(),
            createdBy: userId,
            listId: listID
        )

        Task {
            do {
                self.todos.insert(new, at: 0)
                try await new.upsert()
                if let index = todos.firstIndex(where: { $0.id == new.id }) {
                    self.todos[index] = new
                } else {
                    self.todos.insert(new, at: 0)
                }
            } catch (let error) {
                print(error)
                self.todos.removeAll(where: { $0.id == new.id })
            }
        }
    }

    private func toggleDone(_ todo: Binding<TodoItem>) {
        todo.wrappedValue.completed = !todo.wrappedValue.completed
        todo.wrappedValue.syncStatus = .pending
        Task {
            do {
                try await todo.wrappedValue.upsert()
                if let index = todos.firstIndex(where: { $0.id == todo.id }) {
                    self.todos[index] = todo.wrappedValue
                } else {
                    self.todos.insert(todo.wrappedValue, at: 0)
                }
            } catch (let error) {
                print(error)
                todo.wrappedValue.completed = !todo.wrappedValue.completed
                todo.wrappedValue.syncStatus = .synced
            }
        }
    }

    private func deleteTodos(at offsets: IndexSet) {
        Task {
            for index in offsets.reversed() {
                var copy = todos[index]
                do {
                    self.todos.remove(at: index)
                    try await copy.delete()
                } catch (let error) {
                    print(error)
                    self.todos.insert(copy, at: index)
                }
            }
        }
    }
}
