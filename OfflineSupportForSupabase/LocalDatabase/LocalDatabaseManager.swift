//
//  LocalDatabaseManager.swift
//  OfflineSupportForSupabase
//
//  Created by Itsuki on 2026/05/28.
//

import Foundation
import GRDB

nonisolated
    struct LocalDBDidChange: NotificationCenter.AsyncMessage
{
    typealias Subject = Never
}
nonisolated
    extension NotificationCenter.MessageIdentifier
where Self == NotificationCenter.BaseMessageIdentifier<LocalDBDidChange> {
    static var localDBDidChange: Self { .init() }
}

// MARK: - LocalDatabaseManager
// Manager for GRDB SQLite
nonisolated
    class LocalDatabaseManager: @unchecked Sendable
{

    static let shared = LocalDatabaseManager()

    var dbPool: DatabasePool {
        get throws {
            guard let db = self._dbPool else {
                throw SyncError.notAuthenticated
            }
            return db
        }
    }

    private var _dbPool: DatabasePool?

    private var userChangeTask: Task<Void, Error>?

    private var dbUserId: UUID?

    private(set) var isReady: Bool = false

    private init() {
        self.registerMigrations()
        // listen for user change to set up db pool accordingly
        self.userChangeTask = Task {
            for await message in NotificationCenter.default.messages(
                of: Never.self,
                for: .userIdDidChange
            ) {
                guard self.isReady else {
                    continue
                }
                guard message.userId != self.dbUserId else {
                    return
                }
                self.setup()
            }
        }
    }

    // MARK: - Setup
    func finalizeBootstrap() {
        isReady = true
        setup()
    }

    func setup() {
        guard let userID = AppDependencies.shared.remoteClient.userId else {
            self.closePool()
            self.dbUserId = nil
            return
        }
        guard userID != self.dbUserId else {
            return
        }
        self.closePool()
        // set user id before open the database connection to avoid SQLite error 5 "database is locked"
        self.dbUserId = userID
        do {
            let url = URL.baseUrlForUser(userID).appendingPathComponent(
                "app.db"
            )
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let _dbPool = try DatabasePool(path: url.path)
            logInfo("pool opened at\n\(url.path)")
            self._dbPool = _dbPool
            try runMigrations(on: _dbPool)
            UserLastAccess.set(for: userID)

            NotificationCenter.default.post(
                LocalDBDidChange()
            )

            Task.detached(priority: .background) {
                UserLastAccess.cleanupCachedUserData(currentUserId: userID)
            }
        } catch (let error) {
            fatalError(
                "Fail to set up local database: \(error.localizedDescription)"
            )
        }
    }

    private func closePool() {
        guard let pool = self._dbPool else {
            return
        }

        // All database accesses must have completed before closing
        // Otherwise we'll get an error
        pool.interrupt()

        do {
            try pool.close()
        } catch {
            logError("Failed to close database pool: \(error)")
        }
        self._dbPool = nil
    }

    // MARK: - Migrations
    private var migrator = DatabaseMigrator()

    private func registerMigrations() {
        let urls =
            Bundle.main.urls(
                forResourcesWithExtension: "sql",
                subdirectory: "Migrations"
            ) ?? []

        do {
            for url in urls.sorted(by: {
                $0.lastPathComponent < $1.lastPathComponent
            }) {
                let sql = try String(contentsOf: url, encoding: .utf8)
                let identifier = url.lastPathComponent.replacingOccurrences(
                    of: ".sql",
                    with: ""
                )
                logInfo("register migration: \(identifier)")
                self.registerMigration(
                    identifier,
                    migrate: { db in
                        try db.execute(sql: sql)
                    }
                )
            }
        } catch (let error) {
            fatalError(
                "Fail to register migration: \(error.localizedDescription)"
            )
        }
    }

    private func registerMigration(
        _ identifier: String,
        migrate: @Sendable @escaping (Database) throws -> Void
    ) {
        migrator.registerMigration(identifier, migrate: migrate)
    }

    private func runMigrations(on pool: DatabasePool) throws {
        try migrator.migrate(pool)
    }
}

// MARK: - CRUD
nonisolated extension LocalDatabaseManager {

    func save<T: MutablePersistableRecord>(record: T) async throws {
        try await dbPool.write { [record] db in
            var record = record
            try record.save(db)
        }
    }
    func fetchOne<T: FetchableRecord & TableRecord>(id: UUID) async throws -> T?
    {
        let existing: T? = try await dbPool.read { db in
            try T.fetchOne(db, key: id)
        }
        return existing
    }

    func fetch<T: FetchableRecord & TableRecord, F: SQLSpecificExpressible>(
        from fromDate: Date? = nil,
        to toDate: Date? = nil,
        filter: F
    ) async throws -> [T] {

        return try await dbPool.read { [filter] db in
            var request = T.all()
            if let fromDate {
                request = request.filter(
                    Column("updated_at") >= fromDate
                )
            }

            if let toDate {
                request = request.filter(
                    Column("updated_at") < toDate
                )
            }

            request = request.filter(filter)

            return try request.fetchAll(db)
        }
    }

    func fetch<T: FetchableRecord & TableRecord>(
        from fromDate: Date? = nil,
        to toDate: Date? = nil
    ) async throws -> [T] {
        return try await dbPool.read { db in
            var request = T.all()
            if let fromDate {
                request = request.filter(
                    Column("updated_at") >= fromDate
                )
            }

            if let toDate {
                request = request.filter(
                    Column("updated_at") < toDate
                )
            }

            return try request.fetchAll(db)
        }
    }

    func delete<T: TableRecord>(id: UUID, for type: T.Type) async throws {
        let _ = try await dbPool.write { db in
            try T.deleteOne(db, key: id)
        }
    }
}
