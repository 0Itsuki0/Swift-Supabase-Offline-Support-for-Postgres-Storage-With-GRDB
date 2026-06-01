//
//  Attachment.swift
//  OfflineSupportForSupabase
//
//  Created by Itsuki on 2026/05/29.
//

import Foundation
import GRDB
import Storage

// MARK: - FileAttachment: Syncable record for `attachments` table:
// `attachments` table: A universal join point that any table can reference to associate files with records, keeping storage paths, sync state, and local cache metadata in one place instead of scattering them across individual tables.
// Every other table references it by `attachment_id` — never store a storage path directly on the referencing table.
// Add `FileAttachment` if using Supabase Storage.
nonisolated
    struct FileAttachment: SyncableRecord
{
    static let databaseTableName: String = "attachments"

    static let bucketName: String = "attachments"

    var id: UUID
    var createdBy: UUID
    // Remote storage key/path
    var storagePath: String
    var updatedAt: Date
    var createdAt: Date

    // MARK: - Remote Only
    var operation: RemoteSyncOperation

    // MARK: - Local Only
    // Device-local cache path
    var localPath: String?
    // Cache state only (NOT authoritative)
    var downloadState: DownloadState
    var syncStatus: SyncStatus

    var data: Data {
        get async throws {
            do {
                try await FileSyncManager.hydrate(self)
                guard let localPath else {
                    throw SyncError.fileHydrationError(
                        "failed to get local cache."
                    )
                }
                let data = try Data(contentsOf: URL(filePath: localPath))
                return data
            } catch (let error) {
                throw SyncError.fileHydrationError(error.localizedDescription)
            }
        }
    }

    // create new instance for local upsert
    // Not uploading yet. It will be done on upsert-ing the row
    init(
        userId: UUID,
        originalFilePath: String,
    ) throws {
        self.id = UUID()

        self.createdBy = userId
        self.syncStatus = .pending
        self.downloadState = .downloaded
        self.operation = .upsert

        let fileName =
            originalFilePath.split(separator: "/").last.map({
                String($0)
            }) ?? self.id.uuidString

        let localURL = try FileSyncManager.localURL(
            for: self.id,
            fileName: fileName,
            userId: userId
        )
        try FileManager.default.copyItem(
            atPath: originalFilePath,
            toPath: localURL.path
        )
        self.localPath = localURL.path
        self.storagePath = FileSyncManager.storagePath(
            for: self.id,
            fileName: fileName,
            userId: userId
        )
        let now = Date()
        self.updatedAt = now
        self.createdAt = now
    }

    init(
        userId: UUID,
        data: Data,
        fileName: String
    ) throws {
        self.id = UUID()

        self.createdBy = userId
        self.syncStatus = .pending
        self.downloadState = .downloaded
        self.operation = .upsert

        let localURL = try FileSyncManager.localURL(
            for: self.id,
            fileName: fileName,
            userId: userId
        )
        try data.write(to: localURL)
        self.localPath = localURL.path
        self.storagePath = FileSyncManager.storagePath(
            for: self.id,
            fileName: fileName,
            userId: userId
        )
        let now = Date()
        self.updatedAt = now
        self.createdAt = now
    }

    private init(
        id: UUID,
        createdBy: UUID,
        storagePath: String,
        updatedAt: Date,
        createdAt: Date,
        localPath: String?,
        downloadState: DownloadState,
        syncStatus: SyncStatus,
        operation: RemoteSyncOperation
    ) {
        self.id = id
        self.createdBy = createdBy
        self.storagePath = storagePath
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.localPath = localPath
        self.downloadState = downloadState
        self.syncStatus = syncStatus
        self.operation = operation
    }
}

// MARK: - Local DB Type
nonisolated extension FileAttachment {

    struct LocalPayload: SyncableLocalRecord {
        typealias Record = FileAttachment
        var id: UUID
        var createdBy: UUID
        var storagePath: String
        var updatedAt: Date
        var createdAt: Date

        // Device-local cache path
        var localPath: String?

        // Cache state only (NOT authoritative)
        var downloadState: DownloadState

        var syncStatus: SyncStatus

        enum CodingKeys: String, CodingKey {
            case id
            case storagePath = "storage_path"
            case localPath = "local_path"
            case downloadState = "download_state"
            case syncStatus = "sync_status"
            case updatedAt = "updated_at"
            case createdBy = "created_by"
            case createdAt = "created_at"

        }
    }

    var localPayload: LocalPayload {
        return LocalPayload(
            id: id,
            createdBy: createdBy,
            storagePath: storagePath,
            updatedAt: updatedAt,
            createdAt: createdAt,
            localPath: localPath,
            downloadState: downloadState,
            syncStatus: syncStatus
        )
    }

    static func fromLocal(_ localPayload: LocalPayload) -> FileAttachment {
        .init(
            id: localPayload.id,
            createdBy: localPayload.createdBy,
            storagePath: localPayload.storagePath,
            updatedAt: localPayload.updatedAt,
            createdAt: localPayload.createdAt,
            localPath: localPayload.localPath,
            downloadState: localPayload.downloadState,
            syncStatus: localPayload.syncStatus,
            operation: .fromSyncStatus(localPayload.syncStatus)
        )
    }

}

// MARK: - Remote DB Type
nonisolated extension FileAttachment {

    struct RemotePayload: SyncableRemoteRecord {
        typealias Record = FileAttachment
        var id: UUID
        var createdBy: UUID
        var storagePath: String

        var updatedAt: Date
        var createdAt: Date

        var operation: RemoteSyncOperation

        enum CodingKeys: String, CodingKey {
            case id
            case storagePath = "storage_path"
            case updatedAt = "updated_at"
            case operation
            case createdBy = "created_by"
            case createdAt = "created_at"

        }
    }

    var remotePayload: RemotePayload {
        RemotePayload(
            id: id,
            createdBy: createdBy,
            storagePath: storagePath,
            updatedAt: updatedAt,
            createdAt: createdAt,
            operation: operation
        )
    }

    static func fromRemote(
        _ remotePayload: RemotePayload,
    ) -> Self {
        Self(
            id: remotePayload.id,
            createdBy: remotePayload.createdBy,
            storagePath: remotePayload.storagePath,
            updatedAt: remotePayload.updatedAt,
            createdAt: remotePayload.createdAt,
            localPath: nil,
            downloadState: .notDownloaded,
            syncStatus: .pending,
            operation: remotePayload.operation
        )
    }

}

// MARK: - Custom Diff Handling
nonisolated extension FileAttachment {

    static func handleRemoteChange(
        remote: FileAttachment,
        local: FileAttachment?
    ) async throws -> ChangeHandlingResult<FileAttachment> {
        // local does not exist
        guard let local else {
            switch remote.operation {
            case .upsert:
                var local = remote
                try await FileSyncManager.hydrate(local)
                local.syncStatus = .synced
                try await AppDependencies.shared.localDB.save(
                    record: local.localPayload
                )
                return .handled(local)

            // clean up any files if there is any
            case .delete:
                try await hardDeleteLocal(remote)
                return .handled(nil)
            }
        }

        return try await self.handleDiff(remote: remote, local: local)

    }

    static func handleLocalDiff(remote: FileAttachment?, local: FileAttachment)
        async throws -> ChangeHandlingResult<FileAttachment>
    {
        guard let remote else {
            switch local.syncStatus {
            // delete local
            case .synced:
                try await hardDeleteLocal(local)
                return .handled(nil)
            case .deleted:
                return .handled(nil)

            case .pending:
                var local = local
                try await FileSyncManager.pushLocal(local)
                local.operation = .fromSyncStatus(local.syncStatus)
                let _ = try await AppDependencies.shared.remoteClient.upsert(
                    into: Self.databaseTableName,
                    record: local.remotePayload
                )
                local.syncStatus = .synced
                try await AppDependencies.shared.localDB.save(
                    record: local.localPayload
                )
                return .handled(local)
            }
        }

        return try await self.handleDiff(remote: remote, local: local)

    }

    private static func handleDiff(
        remote: FileAttachment,
        local: FileAttachment
    ) async throws -> ChangeHandlingResult<FileAttachment> {
        var local = local
        // assume remote always update updatedAt when things changes
        if local.updatedAt == remote.updatedAt
            && local.downloadState == .downloaded
        {
            switch remote.operation {
            case .upsert:
                return .handled(local)
            case .delete:
                try await hardDeleteLocal(local)
                return .handled(nil)
            }
        }

        // local is newer
        // even if local shows synced, still treat it as pending
        if local.updatedAt > remote.updatedAt {
            if local.syncStatus == .deleted {
                try await FileSyncManager.deleteRemote(
                    storagePath: local.storagePath
                )
                local.operation = .delete
                let _ = try await AppDependencies.shared.remoteClient.upsert(
                    into: Self.databaseTableName,
                    record: local.remotePayload
                )
                try await self.hardDeleteLocal(local)
                return .handled(nil)
            }

            try await FileSyncManager.pushLocal(local)
            local.operation = .upsert
            let _ = try await AppDependencies.shared.remoteClient.upsert(
                into: Self.databaseTableName,
                record: local.remotePayload
            )
            local.syncStatus = .synced
            try await AppDependencies.shared.localDB.save(
                record: local.localPayload
            )
            return .handled(local)
        }

        // remote is newer
        switch remote.operation {
        case .upsert:
            var updated = remote
            try await FileSyncManager.hydrate(updated)
            updated.syncStatus = .synced
            updated = try await self.upsertLocal(updated)
            return .handled(updated)

        case .delete:
            try await hardDeleteLocal(local)
            return .handled(nil)
        }
    }
}

// MARK: - CRUD override
nonisolated extension FileAttachment {
    mutating func upsert() async throws {
        self.syncStatus = .pending
        self = try await Self.upsertLocal(self)
        guard AppDependencies.shared.network.isConnected else { return }

        do {
            try await FileSyncManager.pushLocal(self)
            self.operation = .upsert
            // manually update updated_at again (right before upsert-ing to server) to make sure that they reflects the current time so that other clients can pick it up.
            self.updatedAt = Date()
            let _ = try await AppDependencies.shared.remoteClient.upsert(
                into: Self.databaseTableName,
                record: self.remotePayload
            )
        } catch (let error) {
            logError("Fail to upload file: \(error)")
            return
        }

        do {
            self.syncStatus = .synced
            try await AppDependencies.shared.localDB.save(
                record: self.localPayload
            )
        } catch (let error) {
            logError("Fail to sync: \(error)")
        }
    }

    mutating func delete() async throws {
        try await FileSyncManager.deleteLocal(self)
        guard AppDependencies.shared.network.isConnected else { return }

        do {
            try await FileSyncManager.deleteRemote(
                storagePath: self.storagePath
            )
            self.operation = .delete
            // manually update updated_at again (right before upsert-ing to server) to make sure that they reflects the current time so that other clients can pick it up.
            self.updatedAt = Date()
            let _ = try await AppDependencies.shared.remoteClient.upsert(
                into: Self.databaseTableName,
                record: self.remotePayload
            )
        } catch (let error) {
            logError("Fail to delete file: \(error)")
            return
        }

        do {
            try await AppDependencies.shared.localDB.delete(
                id: self.id,
                for: Self.LocalPayload.self
            )
        } catch (let error) {
            logError("Fail to sync: \(error)")
        }
    }

    private static func hardDeleteLocal(_ attachment: FileAttachment)
        async throws
    {
        try await FileSyncManager.evictLocalFile(attachment)
        try await AppDependencies.shared.localDB.delete(
            id: attachment.id,
            for: Self.LocalPayload.self
        )
    }

    static private func upsertLocal(_ record: Self) async throws -> Self {
        var record = record
        record.updatedAt = Date()
        try await AppDependencies.shared.localDB.save(
            record: record.localPayload
        )
        return record

    }
}

// MARK: - Local file download state
nonisolated
    enum DownloadState: String, Codable, DatabaseValueConvertible
{
    case notDownloaded
    case downloading
    case downloaded
}
