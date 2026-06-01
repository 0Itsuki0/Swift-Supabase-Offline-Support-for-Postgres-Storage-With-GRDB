import Foundation
import GRDB

nonisolated
    struct TodoItem: SyncableRecord
{

    // MARK: - SyncableRecord

    static let databaseTableName = "todos"

    var id: UUID = UUID()

    var updatedAt: Date = Date()

    var syncStatus: SyncStatus = .pending

    var operation: RemoteSyncOperation = .upsert

    var title: String
    var createdBy: UUID
    var createdAt: Date = Date()

    var completed: Bool = false

    var listId: UUID
    var attachmentId: UUID?

    // MARK: - RemotePayload

    struct RemotePayload: SyncableRemoteRecord {
        typealias Record = TodoItem
        var id: UUID
        var title: String
        var createdBy: UUID
        var createdAt: Date
        var updatedAt: Date
        var completed: Bool
        var listId: UUID
        var attachmentId: UUID?
        var operation: RemoteSyncOperation

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case createdBy = "created_by"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case completed
            case operation
            case listId = "list_id"
            case attachmentId = "attachment_id"
        }
    }

    var remotePayload: RemotePayload {
        RemotePayload(
            id: id,
            title: title,
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            completed: completed,
            listId: listId,
            attachmentId: attachmentId,
            operation: operation
        )
    }

    static func fromRemote(
        _ remotePayload: RemotePayload
    ) -> Self {
        Self(
            id: remotePayload.id,
            updatedAt: remotePayload.updatedAt,
            syncStatus: .pending,
            operation: remotePayload.operation,
            title: remotePayload.title,
            createdBy: remotePayload.createdBy,
            createdAt: remotePayload.createdAt,
            completed: remotePayload.completed,
            listId: remotePayload.listId,
            attachmentId: remotePayload.attachmentId
        )
    }

    // MARK: - RemotePayload

    struct LocalPayload: SyncableLocalRecord {
        typealias Record = TodoItem

        var id: UUID
        var title: String
        var createdBy: UUID
        var createdAt: Date
        var updatedAt: Date
        var completed: Bool
        var listId: UUID
        var attachmentId: UUID?

        var syncStatus: SyncStatus

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case createdBy = "created_by"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case completed
            case syncStatus = "sync_status"
            case listId = "list_id"
            case attachmentId = "attachment_id"

        }
    }

    var localPayload: LocalPayload {
        LocalPayload(
            id: id,
            title: title,
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            completed: completed,
            listId: listId,
            attachmentId: attachmentId,
            syncStatus: syncStatus,
        )
    }

    static func fromLocal(
        _ localPayload: LocalPayload
    ) -> Self {
        Self(
            id: localPayload.id,
            updatedAt: localPayload.updatedAt,
            syncStatus: localPayload.syncStatus,
            operation: .fromSyncStatus(localPayload.syncStatus),
            title: localPayload.title,
            createdBy: localPayload.createdBy,
            createdAt: localPayload.createdAt,
            completed: localPayload.completed,
            listId: localPayload.listId,
            attachmentId: localPayload.attachmentId
        )
    }
}
