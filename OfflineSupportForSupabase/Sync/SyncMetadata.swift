//
//  SyncMetadata.swift
//  OfflineSupportForSupabase
//
//  Created by Itsuki on 2026/06/01.
//

import Foundation
import GRDB

// MARK: - Sync Metadata (per table)
// extendable to include
// - sync version
// - last error
// - server cursor
// - ETag
// - pagination token
// - sync generation
// - backoff timestamp
struct SyncMetadata: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_metadata"

    var tableName: String
    var lastSyncAt: Date?

    // for pagination
    var lastCursorUpdatedAt: Date?
    var lastCursorId: UUID?

    var cursor: SyncCursor? {
        if let cursorId = self.lastCursorId,
            let cursorUpdatedAt = self.lastCursorUpdatedAt
        {
            return SyncCursor(updatedAt: cursorUpdatedAt, id: cursorId)
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case tableName = "table_name"
        case lastSyncAt = "last_sync_at"
        case lastCursorUpdatedAt = "last_cursor_updated_at"
        case lastCursorId = "last_cursor_id"

    }

    private static var local: LocalDatabaseManager {
        AppDependencies.shared.localDB
    }

    static func clearLastSync() async throws {
        let _ = try await self.local.dbPool.write { db in
            try Self.deleteAll(db)
        }
    }

    mutating func updateLastSyncAt(_ date: Date) async throws {
        if let lastSyncAt, date < lastSyncAt { return }
        self.lastSyncAt = date
        try await Self.local.save(record: self)
    }

    mutating func updateCursor(_ cursor: SyncCursor?) async throws {
        // proposed new one is older
        if let lastCursorUpdatedAt, lastCursorId != nil, let cursor,
            cursor.updatedAt <= lastCursorUpdatedAt, cursor.id == lastCursorId
        {
            return
        }

        self.lastCursorId = cursor?.id
        self.lastCursorUpdatedAt = cursor?.updatedAt
        try await Self.local.save(record: self)
    }

    static func metadata(for tableName: String) async throws -> SyncMetadata {
        return try await self.local.dbPool.write { db in
            if let existing = try Self.fetchOne(db, key: tableName) {
                return existing
            }
            let record = SyncMetadata(tableName: tableName)
            try record.save(db)
            return record
        }
    }
}

struct SyncCursor: Codable {
    var updatedAt: Date
    var id: UUID
}
