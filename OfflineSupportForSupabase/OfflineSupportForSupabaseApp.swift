//
//  OfflineSupportForSupabaseApp.swift
//  OfflineSupportForSupabase
//
//  Created by Itsuki on 2026/05/28.
//

import GRDB
import SwiftUI

// testing credentials
nonisolated let appGroupId = "group.example.common"
nonisolated let supabaseURL = "https://xxx.supabase.co"
nonisolated let anonKey = "sb_publishable_xxx"
nonisolated let userEmail = "example@gmail.com"
nonisolated let password = "xxxx"


@main
struct OfflineSupportForSupabaseApp: App {
    let syncCoordinator = SyncCoordinator.shared
    let appDependencies = AppDependencies.shared

    init() {
        bootstrapSync()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    // MARK: - Setup

    // LocalDatabaseManager.setup will be called when receive a user auth change notification within the manager
    // whenever there is a user change
    private func bootstrapSync() {
        // order doesn't matter as migrations are run with raw sql files in file order
        let records: [any SyncableRecord.Type] = [
            FileAttachment.self, TodoList.self, TodoItem.self,
        ]
        for record in records {
            syncCoordinator.register(record)
        }
        appDependencies.localDB.finalizeBootstrap()
        syncCoordinator.startAutoSync(interval: 300)  // sync every 5 min + on reconnect
    }
}
