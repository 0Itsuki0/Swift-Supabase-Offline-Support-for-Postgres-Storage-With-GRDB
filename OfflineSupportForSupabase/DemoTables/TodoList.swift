//
//  TodoList.swift
//  OfflineSupportForSupabase
//
//  Created by Itsuki on 2026/05/30.
//


import Foundation
import GRDB

nonisolated
    struct TodoList: SyncableRecord
{

    // MARK: - SyncableRecord

    static let databaseTableName = "todo_lists"

    var id: UUID = UUID()
        var title: String
        var createdBy: UUID

    var updatedAt: Date = Date()
        var createdAt: Date = Date()

    var syncStatus: SyncStatus = .pending

    var operation: RemoteSyncOperation = .upsert

    // MARK: - RemotePayload

    struct RemotePayload: SyncableRemoteRecord {
        typealias Record = TodoList
        var id: UUID
        var title: String
        var createdBy: UUID
        var createdAt: Date
        var updatedAt: Date
        var operation: RemoteSyncOperation

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case createdBy = "created_by"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case operation
        }
    }

    var remotePayload: RemotePayload {
        RemotePayload(
            id: id,
            title: title,
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            operation: operation
        )
    }

    static func fromRemote(
        _ remotePayload: RemotePayload
    ) -> Self {
        Self(
            id: remotePayload.id,
            title: remotePayload.title,
            createdBy: remotePayload.createdBy,
            updatedAt: remotePayload.updatedAt,
            createdAt: remotePayload.createdAt,
            syncStatus: .pending,
            operation: remotePayload.operation,
        )
    }

    // MARK: - RemotePayload

    struct LocalPayload: SyncableLocalRecord {
        typealias Record = TodoList

        var id: UUID
        var title: String
        var createdBy: UUID
        var createdAt: Date
        var updatedAt: Date
        var syncStatus: SyncStatus

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case createdBy = "created_by"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case syncStatus = "sync_status"
        }
    }

    var localPayload: LocalPayload {
        LocalPayload(
            id: id,
            title: title,
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncStatus: syncStatus
        )
    }

    static func fromLocal(
        _ localPayload: LocalPayload
    ) -> Self {
        Self(
            id: localPayload.id,
            title: localPayload.title,
            createdBy: localPayload.createdBy,
            updatedAt: localPayload.updatedAt,
            createdAt: localPayload.createdAt,
            syncStatus: localPayload.syncStatus,
            operation: .fromSyncStatus(localPayload.syncStatus),
        )
    }
}
