// MARK: - SyncCoordinator.swift
// App-level orchestrator. Register one SyncEngine per model type,
// then call startAutoSync() at app launch.
//
// Example (in App or AppDelegate):
//
//   let coordinator = SyncCoordinator.shared
//   coordinator.register(SyncEngine<TodoItem>())
//   coordinator.register(SyncEngine<Project>())
//   coordinator.startAutoSync()

import Foundation
import Observation

// MARK: - Type-erased wrapper so heterogeneous engines can be stored together
protocol AnySyncEngine: Sendable {
    static func sync() async -> SyncResult
}

extension SyncEngine: AnySyncEngine {}

actor SyncCoordinator: @unchecked Sendable {

    static let shared = SyncCoordinator()

    private var isSyncing: Bool = false

    nonisolated(unsafe)
        private var engines: [any AnySyncEngine.Type] = []
    private let networkMonitor = AppDependencies.shared.network
    nonisolated(unsafe)
        private var syncTimer: Timer?

    nonisolated(unsafe)
        private var localDBChangeTask: Task<Void, Error>?
    nonisolated(unsafe)
        private var networkChangeTask: Task<Void, Error>?
    private var syncTask: Task<Void, Never>?

    private let queue = DispatchQueue(
        label: "SyncCoordinator",
        qos: .userInitiated
    )

    private init() {
        self.localDBChangeTask = Task {
            for await _ in NotificationCenter.default.messages(
                of: Never.self,
                for: .localDBDidChange
            ) {
                await self.syncIfNeeded()
            }
        }
    }

    // MARK: - Registration
    nonisolated
        func register<R: SyncableRecord>(_ recordType: R.Type)
    {
        engines.append(SyncEngine<R>.self)
    }

    nonisolated
        func register(_ engines: [AnySyncEngine.Type])
    {
        self.engines.append(contentsOf: engines)
    }

    // MARK: - Lifecycle
    nonisolated
        func startAutoSync(interval: TimeInterval = 300)
    {
        // Periodic timer
        syncTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            Task { await self?.syncIfNeeded() }
        }

        // Fire immediately on connectivity restore (per the article)
        self.networkChangeTask = Task {
            for await message in NotificationCenter.default.messages(
                of: Never.self,
                for: .connectivityDidChange
            ) {
                if message.isConnected {
                    await self.syncIfNeeded()
                }
            }
        }

        // Initial sync
        Task { await syncIfNeeded() }
    }

    func stopAutoSync() {
        syncTimer?.invalidate()
        syncTimer = nil
        self.networkChangeTask?.cancel()
        self.networkChangeTask = nil
    }

    // MARK: - Manual trigger

    @discardableResult
    func syncNow() async -> SyncResult {
        self.syncTask?.cancel()
        self.syncTask = nil
        return await sync()
    }

    // reset all previous sync
    @discardableResult
    func fullSync() async -> SyncResult {
        do {
            try await SyncMetadata.clearLastSync()
        } catch (let error) {
            return SyncResult(errors: [
                .databaseError(error.localizedDescription)
            ])
        }
        return await syncNow()
    }

    // MARK: - Internal
    func syncIfNeeded() async {
        guard networkMonitor.isConnected, !isSyncing,
            AppDependencies.shared.remoteClient.userId != nil
        else { return }
        await sync()
    }

    @discardableResult
    private func sync() async -> SyncResult {
        self.isSyncing = true

        defer {
            self.isSyncing = false
        }

        guard networkMonitor.isConnected else {
            return SyncResult(errors: [SyncError.networkUnavailable])
        }

        do {
            try await AppDependencies.shared.remoteClient.userAuthManager
                .refreshAuthSession()
        } catch let error as SyncError {
            logError("Error refreshing authentication session: \(error)")
            return SyncResult(errors: [error])
        } catch (let error) {
            logError("Error refreshing authentication session: \(error)")
            return SyncResult(errors: [.other(error)])
        }

        var combined = SyncResult()

        syncTask?.cancel()
        syncTask = Task {
            return await withTaskGroup(of: SyncResult.self) { group in
                for engine in engines {
                    group.addTask { await engine.sync() }
                }
                for await result in group {
                    combined.pushed += result.pushed
                    combined.pulled += result.pulled
                    combined.conflicts += result.conflicts
                    combined.errors += result.errors
                }
            }
        }

        let result = await syncTask?.result
        self.syncTask = nil
        switch result {
        // should never reach here as the operation within the Task will not throw
        case .failure(let error):
            if !error.isCancelledError {
                combined.errors.append(
                    .other(error)
                )
            }
        default:
            break
        }

        return combined
    }
}
