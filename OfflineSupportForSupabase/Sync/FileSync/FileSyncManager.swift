//
//  FileSyncManager.swift
//  OfflineSupportForSupabase
//
//  Created by Itsuki on 2026/05/31.
//

import Foundation
import GRDB
import Storage


// MARK: - File Manager for handle File I/O
nonisolated
    final class FileSyncManager: @unchecked Sendable
{
    private static var local: LocalDatabaseManager { AppDependencies.shared.localDB }

    private static let resourceTimeout: TimeInterval = 60

    private init() {}

    // MARK: - Public

    // Ensures the attachment exists locally.
    // Downloads it if needed.
    // NOT spawning to a separate spread because
    // 1.  when sync, the last updated date cannot be updated until this success
    // 2. sync happens parallel for different tables so this will not effect other tables.
    static func hydrate(_ local: FileAttachment) async throws {

        // Already cached locally
        if local.downloadState == .downloaded,
            let localPath = local.localPath,
            FileManager.default.fileExists(atPath: localPath)
        {
            return
        }
        do {
            // Mark downloading
            try await updateState(
                local,
                state: .downloading
            )

            let data = try await downloadFromRemote(
                storagePath: local.storagePath
            )
            let fileName =
                local.storagePath.split(separator: "/").last.map({ String($0) })
                ?? local.storagePath.replacingOccurrences(of: "/", with: "_")

            let localURL = try localURL(
                for: local.id,
                fileName: fileName,
                userId: local.createdBy
            )

            try data.write(to: localURL, options: .atomic)

            // Update local DB metadata
            var updated = local
            updated.localPath = localURL.path
            updated.downloadState = .downloaded

            try await self.local.save(record: updated.localPayload)

        } catch {
            try await updateState(
                local,
                state: .notDownloaded
            )
            logError("error downloading attachment: \(error.localizedDescription)")
            throw error
        }

    }

    static func pushLocal(_ local: FileAttachment) async throws {
        guard local.downloadState == .downloaded,
            let localPath = local.localPath,
            FileManager.default.fileExists(atPath: localPath)
        else {
            return
        }
        let localURL = URL(fileURLWithPath: localPath)
        let data = try Data(contentsOf: localURL)
        try await self.upsertRemote(storagePath: local.storagePath, with: data)
    }

    static func deleteLocal(_ attachment: FileAttachment) async throws {
        try await evictLocalFile(attachment)
        var updated = attachment
        updated.localPath = nil
        updated.downloadState = .notDownloaded
        updated.syncStatus = .deleted
        updated.updatedAt = Date()
        try await local.save(record: updated.localPayload)
    }

    // Removes local cached file only.
    static func evictLocalFile(_ attachment: FileAttachment) async throws {
        guard
            let localPath = attachment.localPath
        else {
            return
        }

        if FileManager.default.fileExists(atPath: localPath) {
            try FileManager.default.removeItem(atPath: localPath)
        }
    }

    // MARK: - Private
    private static func updateState(
        _ attachment: FileAttachment?,
        state: DownloadState
    ) async throws {
        guard var attachment else {
            return
        }
        attachment.downloadState = state
        try await local.save(record: attachment.localPayload)
    }

    // Downloads from Supabase Storage.
    static func downloadFromRemote(storagePath: String) async throws
        -> Data
    {
        return try await withTimeout(
            seconds: self.resourceTimeout,
            operation: {
                return try await AppDependencies.shared.remoteClient.storage
                    .from(FileAttachment.bucketName)
                    .download(path: storagePath)
            },
            cancellationError: SyncError.networkUnavailable
        )
    }

    static func deleteRemote(storagePath: String) async throws {
        let _ = try await withTimeout(
            seconds: self.resourceTimeout,
            operation: {
                try await AppDependencies.shared.remoteClient.storage
                    .from(FileAttachment.bucketName)
                    .remove(paths: [storagePath])
            },
            cancellationError: SyncError.networkUnavailable
        )
    }

    private static func upsertRemote(storagePath: String, with data: Data)
        async throws
    {
        let _ = try await withTimeout(
            seconds: self.resourceTimeout,
            operation: {
                try await AppDependencies.shared.remoteClient.storage
                    .from(FileAttachment.bucketName)
                    .update(
                        storagePath,
                        data: data,
                        options: .init(upsert: true)
                    )
            },
            cancellationError: SyncError.networkUnavailable
        )

    }

    // Deterministic local cache URL.
    // Remote storage path already starts with the owner user id. however, there is also a possibility where the file is visible to a set of user in additional to the owner and the user downloading the file is not the owner.
    static func localURL(for attachmentId: UUID, fileName: String, userId: UUID)
        throws -> URL
    {

        let url = URL.baseUrlForUser(userId).appendingPathComponent(
            "\(FileAttachment.databaseTableName)/\(attachmentId.uuidString)_\(fileName)"
        )

        // Ensure directory exists
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        return url
    }

    // assumes following RLS policy on storage bucket (user only allows to insert into their own folder)
    //
    // create policy "user can upload to their own folder in attachments" on storage.objects for insert to authenticated
    // with
    //     check (
    //         bucket_id = 'attachments'
    //         and private.case_insensitive_equal (
    //             (storage.foldername (name)) [1],
    //             (
    //                 select
    //                     auth.uid ()::text
    //             )
    //         )
    //     );
    static func storagePath(
        for attachmentId: UUID,
        fileName: String,
        userId: UUID
    )
        -> String
    {
        return
            "\(userId.uuidString)/\(FileAttachment.databaseTableName)/\(attachmentId.uuidString)_\(fileName)"
    }
}
