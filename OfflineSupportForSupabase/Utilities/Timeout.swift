//
//  Timeout.swift
//  OfflineSupportForSupabase
//
//  Created by Itsuki on 2026/06/01.
//

import Foundation

// MARK: - Time out for async operation
// NOTE: If the async function is implemented with Objective C,
// cancellation won't work correctly
func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @Sendable @escaping () async throws -> T,
    cancellationError: Error,
    // required because URLSessionWebSocketTask.receive() is a bridged ObjC API
    // ie: it doesn't check Swift's cancellation flag. When the group cancels the operation task, webSocketTask.receive() just keeps waiting for a message. The group waits forever for it to exit.
    onTimeout: (@Sendable () -> Void)? = nil
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            onTimeout?()
            throw cancellationError
        }
        guard let result = try await group.next() else {
            group.cancelAll()
            throw cancellationError
        }
        group.cancelAll()
        return result
    }
}
