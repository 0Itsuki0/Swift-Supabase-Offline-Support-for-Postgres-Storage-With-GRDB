//
//  AppDependencies.swift
//  OfflineSupportForSupabase
//
//  Created by Itsuki on 2026/05/31.
//

// MARK: - App Dependencies
// Central dependency container.
// Subclass it in tests to inject mocks. Every layer accesses `local` and `remote` through this — never directly via `.shared`.

// To Test:
// 1. subclass LocalDatabaseManager and SupabaseClient
// ex:  class MockDB: LocalDatabaseManager, @unchecked Sendable { }
// 2. sub class AppDependencies
// class MockAppDependencies: AppDependencies {
//    override var localDB: LocalDatabaseManager { MockDB.shared }
//    override var remoteClient: SupabaseClient { MockSupabase.shared }
// }
// 3. in test set up. override shared
// ex: AppDependencies.shared = MockAppDependencies()

nonisolated
class AppDependencies {
    static var shared = AppDependencies()
    
    var localDB: LocalDatabaseManager {
        LocalDatabaseManager.shared
    }
    
    var remoteClient: SupabaseClient {
        SupabaseClient.shared
    }
    
    var network: NetworkMonitor {
        NetworkMonitor.shared
    }
}
