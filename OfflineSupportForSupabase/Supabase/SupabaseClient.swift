// MARK: - SupabaseClient.swift
// Thin wrapper around the official Supabase Swift SDK.
//
// Package dependency (Package.swift or Xcode SPM):
//   https://github.com/supabase/supabase-swift  — "Supabase"
//
// The SyncEngine only calls this file, so all SDK details stay here.

import Foundation
import Supabase

// MARK: - Singleton
nonisolated
    final class SupabaseClient: Sendable
{

    static let shared = SupabaseClient()

    var userId: UUID? {
        userAuthManager.userId
    }

    private let client: Supabase.SupabaseClient

    var storage: SupabaseStorageClient {
        self.client.storage
    }

    let userAuthManager: UserAuthManager

    private let networkTimeout: TimeInterval = 10

    private init() {
        guard let url = URL(string: supabaseURL) else {
            fatalError("Missing Supabase configuration")
        }
        let authOption = SupabaseClientOptions.AuthOptions(
            emitLocalSessionAsInitialSession: true
        )
        let client = Supabase.SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: .init(auth: authOption)
        )

        self.userAuthManager = UserAuthManager(supabaseClient: client)
        self.client = client
    }

    // MARK: - Public API used by SyncEngine

    // Fetch rows updated after `since` for incremental pull with pagination.
    func fetch<T: Decodable & Sendable>(
        table: String,
        from fromDate: Date? = nil,
        to toDate: Date? = nil,
        cursor: SyncCursor? = nil,
        pageSize: Int = 500
    ) async throws -> (records: [T], hasMore: Bool) {
        var filterQuery: PostgrestFilterBuilder =
            client
            .from(table)
            .select()

        if let fromDate {
            // PostgREST filter: updated_at >= since
            let iso = ISO8601DateFormatter.full.string(from: fromDate)
            filterQuery =
                filterQuery
                .gte("updated_at", value: iso)
        }

        if let toDate {
            // PostgREST filter: updated_at >= since
            let iso = ISO8601DateFormatter.full.string(from: toDate)
            filterQuery =
                filterQuery
                .lt("updated_at", value: iso)
        }

        if let cursor {
            // make sure to use the ISO format with milliseconds as the postgres columns
            // `timestamp with time zone` contains those
            let isoDate = ISO8601DateFormatter.full.string(
                from: cursor.updatedAt
            )
            // or means chain together with above using and, expressions with in or using or
            // in this case, AND updated_at > isoDate or (updated_at == isoDate AND id > cursor id)
            filterQuery = filterQuery.or(
                "updated_at.gt.\(isoDate),and(updated_at.eq.\(isoDate),id.gt.\(cursor.id))"
            )
        }

        let query = filterQuery.order("updated_at", ascending: true).order(
            "id",
            ascending: true
        )
        .limit(pageSize)

        let response: [T] = try await withTimeout(
            seconds: self.networkTimeout,
            operation: {
                let response: [T] = try await query.execute().value
                return response
            },
            cancellationError: SyncError.networkUnavailable
        )

        return (response, response.count == pageSize)
    }

    func fetchOne<T: Decodable & Sendable>(
        table: String,
        id: UUID
    ) async throws -> T? {
        let query =
            client
            .from(table)
            .select().eq("id", value: id).limit(1)

        let response: [T] = try await withTimeout(
            seconds: self.networkTimeout,
            operation: {
                let response: [T] =
                    try await query
                    .execute().value
                return response
            },
            cancellationError: SyncError.networkUnavailable
        )

        return response.first
    }

    // Upsert a single record and return the server's version of it.
    // The SDK decodes the returned row for us.
    @discardableResult
    func upsert<T: Encodable & Decodable & Sendable>(
        into table: String,
        record: T
    ) async throws -> T {
        let query =
            try client
            .from(table)
            .upsert(record, returning: .representation)

        let response: [T] = try await withTimeout(
            seconds: self.networkTimeout,
            operation: {
                let response: [T] =
                    try await query
                    .execute().value
                return response
            },
            cancellationError: SyncError.networkUnavailable
        )

        guard let first = response.first else {
            throw SyncError.databaseError("Failed to upsert record")
        }
        return first
    }

    // Hard-delete a row by primary key.
    func delete(from table: String, id: UUID) async throws {
        let query =
            client
            .from(table)
            .delete()
            .eq("id", value: id)

        let _ = try await withTimeout(
            seconds: self.networkTimeout,
            operation: {
                try await query.execute()
            },
            cancellationError: SyncError.networkUnavailable
        )
    }
}

// MARK: - ISO8601 helpers

nonisolated
    extension ISO8601DateFormatter
{
    static let full: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

