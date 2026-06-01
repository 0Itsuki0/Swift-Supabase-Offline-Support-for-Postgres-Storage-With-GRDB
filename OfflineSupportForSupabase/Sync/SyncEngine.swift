// MARK: - SyncEngine.swift
// The generic heart of the sync layer.
//
// Usage:
//   let engine = SyncEngine<TodoItem>()
//   let result = try await engine.sync()
//
// The engine is fully generic — instantiate one per model type.

import Foundation
import GRDB

nonisolated
    final class SyncEngine<Record: SyncableRecord>: @unchecked Sendable
{

    // MARK: - Dependencies
    private static var local: LocalDatabaseManager {
        AppDependencies.shared.localDB
    }
    private static var remote: SupabaseClient {
        AppDependencies.shared.remoteClient
    }
    private static var network: NetworkMonitor {
        AppDependencies.shared.network
    }

    // MARK: - Last Sync Timestamp
    // single table sync date
    static var syncMetadata: SyncMetadata? {
        get async {
            return try? await SyncMetadata.metadata(
                for: Record.databaseTableName
            )
        }
    }

    // MARK: - Public API

    /// Full bidirectional sync: push local changes first, then pull remote changes.
    @discardableResult
    static func sync() async -> SyncResult {
        var result = SyncResult()

        let pushResult = await push()
        result.pushed = pushResult.pushed
        result.errors += pushResult.errors

        if result.errors.contains(where: { $0.isNoNetworkError }) {
            return result
        }

        let pullResult = await pull()
        result.pulled = pullResult.pulled
        result.conflicts = pullResult.conflicts
        result.errors += pullResult.errors

        // NOTE: Only checking pull result (from the server) because
        // (1) when pushing, we only cares about the sync status of the local record
        // (2) last_sync_at on effect what we pull
        if pullResult.errors.isEmpty {
            // fetch the new one again as it might change as processing the ones above.
            var metadata = await self.syncMetadata
            try? await metadata?.updateLastSyncAt(Date())
        }

        return result
    }

    /// Push all locally pending/deleted records to Supabase.
    @discardableResult
    static func push() async -> SyncResult {
        var result = SyncResult()
        let pending: [Record]

        do {
            pending = try await self.pendingSyncedRecords()
        } catch (let error) {
            result.errors.append(.databaseError(error.localizedDescription))
            return result
        }
        for record in pending {
            do {
                let payload: Record.RemotePayload? = try await self.remote
                    .fetchOne(
                        table: Record.databaseTableName,
                        id: record.id
                    )
                let remote = payload.map({ Record.fromRemote($0) })

                try await resolvePendingLocal(
                    local: record,
                    remote: remote,
                    result: &result
                )
            } catch {
                let isNetworkError = self.handleError(error, result: &result)
                // network lost. No reason to continue
                if isNetworkError {
                    return result
                }
            }
        }

        return result
    }

    /// Pull remote changes since the last successful pull timestamp.
    @discardableResult
    static func pull() async -> SyncResult {
        var result = SyncResult()

        var hasMore = false

        repeat {
            // fetch new ones every loop in case other sync on the same table running in parallel.
            let metadata = await self.syncMetadata
            let cursor = metadata?.cursor
            let since = metadata?.lastSyncAt
            let (payloads, newHasMore): ([Record.RemotePayload], Bool)
            do {
                (payloads, newHasMore) =
                    try await remote.fetch(
                        table: Record.databaseTableName,
                        from: since,
                        cursor: cursor,
                    )
            } catch {
                let _ = self.handleError(error, result: &result)
                return result
            }

            hasMore = newHasMore

            // sync status here won't matter because only the syncStatus on the local ones will be checked
            let remoteRecords = payloads.map {
                Record.fromRemote($0)
            }
            for remoteRecord in remoteRecords {
                let localPayload: Record.LocalPayload?

                do {
                    localPayload = try await self.local
                        .fetchOne(id: remoteRecord.id)
                } catch (let error) {
                    result.errors.append(
                        .databaseError(error.localizedDescription)
                    )
                    continue
                }

                let localRecord: Record? = localPayload.map({ .fromLocal($0) })
                do {
                    try await mergeRemote(
                        remote: remoteRecord,
                        local: localRecord,
                        result: &result
                    )
                } catch {
                    let isNetworkError = self.handleError(
                        error,
                        result: &result
                    )
                    // network lost. No reason to continue
                    if isNetworkError {
                        return result
                    }
                }
            }

            if let last = remoteRecords.last {
                let newCursor = SyncCursor(
                    updatedAt: last.updatedAt,
                    id: last.id
                )

                // fetch the new one again as it might change as processing the ones above.
                do {
                    var metadata = await self.syncMetadata
                    try await metadata?.updateCursor(newCursor)
                } catch (let error) {
                    result.errors.append(
                        .databaseError(error.localizedDescription)
                    )
                    return result
                }
            }

        } while hasMore

        return result
    }

    // MARK: - Merge Remote to Local: LWW (last-write-wins)
    @discardableResult
    static private func mergeRemote(
        remote: Record,
        local: Record?,
        result: inout SyncResult
    )
        async throws -> Record?
    {
        // ── Case 1: No local copy ────────────────────────────────────────
        // Nothing pending locally; safe to insert the remote row as-is.
        guard var local else {
            if case .handled(let t) = try await Record.handleRemoteChange(
                remote: remote,
                local: nil
            ) {
                result.pulled += 1
                return t
            }

            let handled = try await self.handleRemote(record: remote)
            result.pulled += 1
            return handled
        }

        // ── Case 2: The remote is newer (or equal); accept it ─────────────────────────────
        if remote.updatedAt >= local.updatedAt {
            if case .handled(let t) = try await Record.handleRemoteChange(
                remote: remote,
                local: local
            ) {
                result.pulled += 1
                return t
            }

            let handled = try await self.handleRemote(record: remote)
            if local.syncStatus == .synced {
                result.pulled += 1
            } else {
                result.conflicts += 1
            }
            return handled
        }

        // Case 3: local is newer: push it (operation set based on the sync status).
        if case .handled(let t) = try await Record.handleLocalDiff(
            remote: remote,
            local: local
        ) {
            result.pushed += 1
            return t
        }
        local.operation = .fromSyncStatus(local.syncStatus)
        // manually update updated_at again (right before upsert-ing to server) to make sure that they reflects the current time so that other clients can pick it up.
        local.updatedAt = Date()
        let _ = try await self.remote.upsert(
            into: Record.databaseTableName,
            record: local.remotePayload
        )
        let synced = try await saveSynced(record: local)
        result.pushed += 1
        return synced
    }

    // MARK: - Merge Local to Remote: LWW (last-write-wins)
    @discardableResult
    private static func resolvePendingLocal(
        local: Record,
        remote: Record?,
        result: inout SyncResult
    ) async throws -> Record? {
        // remote is newer, accept it
        if let remote, remote.updatedAt >= local.updatedAt {
            let handled = try await Record.handleRemoteChange(
                remote: remote,
                local: local
            )
            if case .handled(let t) = handled {
                result.pulled += 1
                return t
            }
            let saved = try await self.handleRemote(record: remote)
            result.pulled += 1
            return saved
        }

        // remote doesn't exist, or local is newer
        if case .handled(let t) = try await Record.handleLocalDiff(
            remote: remote,
            local: local
        ) {
            result.pushed += 1
            return t
        }

        // remote doesn't exist, but local show as synced
        if remote == nil, local.syncStatus == .synced {
            try await self.local.delete(
                id: local.id,
                for: Record.LocalPayload.self
            )
            return nil
        }

        var local = local
        local.operation = .fromSyncStatus(local.syncStatus)
        // manually update updated_at again (right before upsert-ing to server) to make sure that they reflects the current time so that other clients can pick it up.
        local.updatedAt = Date()

        let _ = try await self.remote.upsert(
            into: Record.databaseTableName,
            record: local.remotePayload
        )
        result.pushed += 1

        switch local.syncStatus {
        case .pending:
            let synced = try await saveSynced(record: local)
            return synced
        case .deleted:
            try await self.local.delete(
                id: local.id,
                for: Record.LocalPayload.self
            )
            return nil
        default:
            return local
        }
    }

    // returning: isNetworkError
    private static func handleError(_ error: Error, result: inout SyncResult)
        -> Bool
    {
        if let syncError = error as? SyncError {
            result.errors.append(syncError)
            return syncError.isNoNetworkError
        }
        // network lost. No reason to continue
        if error.isNoNetworkError {
            result.errors.append(.networkUnavailable)
            return true
        } else {
            result.errors.append(.other(error))
            return false
        }
    }

    // MARK: - GRDB Helpers
    @discardableResult
    static private func saveSynced(record: Record) async throws -> Record {
        var updated = record
        updated.syncStatus = .synced
        try await local.save(record: updated.localPayload)
        return updated
    }

    @discardableResult
    static private func handleRemote(record: Record) async throws -> Record? {
        if record.operation == .delete {
            // remote deleted. hard delete local copy
            try await self.local.delete(
                id: record.id,
                for: Record.LocalPayload.self
            )
            return nil
        }
        let updated = try await self.saveSynced(record: record)
        return updated
    }

    static private func pendingSyncedRecords() async throws -> [Record] {
        let localPayloads: [Record.LocalPayload] = try await self.local.fetch(
            filter: Column("sync_status") == SyncStatus.pending.rawValue
                || Column("sync_status") == SyncStatus.deleted.rawValue
        )
        return localPayloads.map({ .fromLocal($0) })
    }

    // MARK: - CRUD helpers

    static func upsert(record: Record) async throws -> Record {
        var record = record
        record.syncStatus = .pending
        record.updatedAt = Date()
        try await self.local.save(record: record.localPayload)
        guard network.isConnected else { return record }

        do {
            let _ = try await remote.upsert(
                into: Record.databaseTableName,
                record: record.remotePayload
            )
            return try await saveSynced(record: record)
        } catch (let error) {
            logError("Fail to sync: \(error)")
            return record
        }
    }

    static func delete(record: Record) async throws {
        var record = record
        record.syncStatus = .deleted
        record.updatedAt = Date()
        try await self.local.save(record: record.localPayload)

        guard network.isConnected else {
            return
        }
        do {
            record.operation = .delete
            let _ = try await remote.upsert(
                into: Record.databaseTableName,
                record: record.remotePayload
            )
            try await self.local.delete(
                id: record.id,
                for: Record.LocalPayload.self
            )
        } catch (let error) {
            logError("Fail to delete: \(error)")
        }
        return
    }

    // - checks local
    // - checks remote if connected
    // - merges
    // - persists
    // - resolves deletion
    // - syncs pending states
    static func fetchOne(id: UUID) async throws -> Record? {
        let payload: Record.LocalPayload? = try await self.local.fetchOne(
            id: id
        )

        let local: Record? = payload.map({ .fromLocal($0) })

        guard network.isConnected else {
            return visibleRecord(local)
        }

        do {
            var result = SyncResult()

            let remote: Record.RemotePayload? = try await remote.fetchOne(
                table: Record.databaseTableName,
                id: id
            )

            if let remote {
                let remote = Record.fromRemote(remote)
                let resolvedRecord = try await self.mergeRemote(
                    remote: remote,
                    local: local,
                    result: &result
                )
                return resolvedRecord
            }

            // remote doesn't exist but local does
            if let local, remote == nil {
                return try await resolvePendingLocal(
                    local: local,
                    remote: nil,
                    result: &result
                )
            }

            return nil
        } catch (let error) {
            logError("Error syncing with remote: \(error)")
            return visibleRecord(local)
        }
    }

    private static func visibleRecord(
        _ record: Record?
    ) -> Record? {
        record?.syncStatus == .deleted ? nil : record
    }

    static func fetch(from fromDate: Date? = nil, to toDate: Date? = nil)
        async throws -> [Record]
    {
        if network.isConnected {
            let result = await self.sync()
            if !result.errors.isEmpty {
                logError("Error syncing with remote: \(result.errors)")
            }
        }
        let local: [Record.LocalPayload] = try await self.local.fetch(
            from: fromDate,
            to: toDate,
            filter: Column("sync_status") != SyncStatus.deleted.rawValue
        )
        return local.map({ .fromLocal($0) })
    }
}

