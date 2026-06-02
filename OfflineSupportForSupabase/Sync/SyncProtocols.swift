// MARK: - SyncProtocols.swift
// Core protocols that any model must conform to in order to participate in syncing.

import Foundation
import GRDB

// MARK: - Local SyncStatus
nonisolated
    enum SyncStatus: String, Codable, DatabaseValueConvertible
{
    case synced  // Confirmed up-to-date with server
    case pending  // Created/updated locally, not yet pushed
    case deleted  // Soft-deleted locally, not yet pushed

    // uncomment if the app supports conflicting versions coexist temporarily
    // ex: google doc, Figma, and etc
    // case conflict    // Server and local versions diverged
}

// MARK: - Remote Operation
nonisolated
    enum RemoteSyncOperation: String, Codable
{
    case upsert
    case delete

    static func fromSyncStatus(_ status: SyncStatus) -> RemoteSyncOperation {
        switch status {
        case .synced: return .upsert
        case .pending: return .upsert
        case .deleted: return .delete
        }
    }
}

// MARK: - Remote Payload
// Removing unnecessary local properties such as sync status
nonisolated protocol SyncableRemoteRecord: Codable & Identifiable
where ID == UUID {
    associatedtype Record: SyncableRecord
    static var databaseTableName: String { get }
    var operation: RemoteSyncOperation { get set }
}

nonisolated
    extension SyncableRemoteRecord
{
    static var databaseTableName: String {
        Record.databaseTableName
    }
}

// MARK: - Local Payload
// Removing unnecessary remote properties such as operation as well as adding local-specific properties such as download state, local path for files
nonisolated protocol SyncableLocalRecord: Codable & FetchableRecord
        & MutablePersistableRecord & Identifiable
where ID == UUID {
    associatedtype Record: SyncableRecord
    static var databaseTableName: String { get }
    var syncStatus: SyncStatus { get set }
}

nonisolated
    extension SyncableLocalRecord
{
    static var databaseTableName: String {
        Record.databaseTableName
    }
}

// MARK: - Custom Conflict Handling per record if needed
nonisolated
    enum ChangeHandlingResult<T: SyncableRecord>
{
    case handled(T?)  // record has custom handling
    case notHandled  // use the default LWW implementation in SyncEngine
}

// MARK: - SyncableRecord
//
// Table model must conform to this. It extends GRDB's FetchableRecord + PersistableRecord
// so the sync engine can read/write it generically.
nonisolated
    protocol SyncableRecord:
        Identifiable
where ID == UUID {

    // Supabase table name (also used as GRDB table name)
    static var databaseTableName: String { get }

    // ISO8601 timestamp of the last modification (either local or server)
    var updatedAt: Date { get set }

    // Tracks whether this row needs to be pushed or pulled
    var syncStatus: SyncStatus { get set }

    var operation: RemoteSyncOperation { get set }

    // for Supabase CRUD. We don't want the syncStatus to be reflected to remote
    associatedtype RemotePayload: SyncableRemoteRecord
    var remotePayload: RemotePayload { get }

    // local sync status does not matter as we only cares about the record operation when created from remote payload
    static func fromRemote(
        _ remotePayload: RemotePayload
    ) -> Self

    static func handleRemoteChange(
        remote: Self,  // RemoteSyncOperation can be inferred from the remote record
        local: Self?
    ) async throws -> ChangeHandlingResult<Self>

    static func handleLocalDiff(
        remote: Self?,  // RemoteSyncOperation can be inferred from the remote record
        local: Self
    ) async throws -> ChangeHandlingResult<Self>

    associatedtype LocalPayload: SyncableLocalRecord
    var localPayload: LocalPayload { get }

    // remote operation does not matter as we only cares about the record sync status when created from local payload
    static func fromLocal(
        _ localPayload: LocalPayload
    ) -> Self

    mutating func upsert() async throws
    mutating func delete() async throws

    // Fetches return async stream for responsive UI:
    // - yield Local first
    // - try to sync with the server if possible
    // - yield the final
    static func fetchOne(_ id: UUID) -> AsyncThrowingStream<Self?, Error>
    static func all() -> AsyncThrowingStream<[Self], Error>
    static func fetch(from fromDate: Date?, to toDate: Date?)
        -> AsyncThrowingStream<[Self], Error>

    // overload with regular async await
    static func fetchOne(_ id: UUID) async throws -> Self?
    static func all() async throws -> [Self]
    static func fetch(from fromDate: Date?, to toDate: Date?) async throws
        -> [Self]

}

// MARK: - default CRUD implementations
nonisolated extension SyncableRecord {

    mutating func upsert() async throws {
        let new = try await SyncEngine<Self>.upsert(record: self)
        self = new
    }
    mutating func delete() async throws {
        try await SyncEngine<Self>.delete(record: self)
    }

    // Fetches return async stream for responsive UI:
    // - yield Local first
    // - try to sync with the server if possible
    // - yield the final
    static func fetchOne(_ id: UUID) -> AsyncThrowingStream<Self?, Error> {
        return SyncEngine<Self>.fetchOne(id: id)
    }

    static func all() -> AsyncThrowingStream<[Self], Error> {
        return Self.fetch(from: nil, to: nil)
    }

    static func fetch(from fromDate: Date?, to toDate: Date?)
        -> AsyncThrowingStream<[Self], Error>
    {
        return SyncEngine<Self>.fetch(from: fromDate, to: toDate)
    }

    static func fetchOne(_ id: UUID) async throws -> Self? {
        return try await self.fetchOne(id).collect().last ?? nil
    }

    static func all() async throws -> [Self] {
        return try await self.fetch(from: nil, to: nil)
    }

    static func fetch(from fromDate: Date?, to toDate: Date?) async throws
        -> [Self]
    {
        let stream: AsyncThrowingStream<[Self], Error> = self.fetch(
            from: fromDate,
            to: toDate
        )
        return try await stream.collect().last ?? []
    }

}

// MARK: - default conflict handler
// returning .notHandled to use the default LWW behavior implemented in the SyncEngine
nonisolated extension SyncableRecord {
    static func handleRemoteChange(
        remote: Self,  // RemoteSyncOperation can be inferred from the remote record
        local: Self?
    ) async throws -> ChangeHandlingResult<Self> {
        return .notHandled
    }

    static func handleLocalDiff(
        remote: Self?,  // RemoteSyncOperation can be inferred from the remote record
        local: Self
    ) async throws -> ChangeHandlingResult<Self> {
        return .notHandled
    }
}

// MARK: - SyncResult
// The result can be stored in a database table if sync tracking/audit is needed.
nonisolated
    struct SyncResult
{
    var pushed: Int = 0
    var pulled: Int = 0
    var conflicts: Int = 0
    var errors: [SyncError] = []

    var succeeded: Bool { errors.isEmpty }
}

// MARK: - SyncError
nonisolated
    enum SyncError: Error, LocalizedError
{
    case notAuthenticated
    case networkUnavailable
    case databaseError(String)

    case other(Error)

    case fileHydrationError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "User not authenticated."
        case .networkUnavailable: return "Network is unavailable"
        case .databaseError(let e): return "DB error: \(e)"
        case .fileHydrationError(let e): return "Failed to download file. \(e)"
        case .other(let errors):
            return "Failed to sync: \(errors.localizedDescription)"
        }
    }

    var code: Int {
        switch self {
        case .notAuthenticated: return 0
        case .networkUnavailable: return 1
        case .databaseError: return 2
        case .fileHydrationError: return 3
        case .other: return 4
        }
    }
}
