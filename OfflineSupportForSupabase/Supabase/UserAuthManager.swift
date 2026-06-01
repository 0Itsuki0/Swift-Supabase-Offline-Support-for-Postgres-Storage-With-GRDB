//
//  UserAuthManager.swift
//  OfflineSupportForSupabase
//
//  Created by Itsuki on 2026/05/28.
//

//
//  AuthenticationManager.swift
//  Swifly
//
//  Created by Itsuki on 2026/01/02.
//

import Foundation
import Supabase

nonisolated
    struct UserIdDidChange: NotificationCenter.AsyncMessage
{
    typealias Subject = Never
    let userId: UUID?
}
nonisolated
    extension NotificationCenter.MessageIdentifier
where Self == NotificationCenter.BaseMessageIdentifier<UserIdDidChange> {
    static var userIdDidChange: Self { .init() }
}

nonisolated
    final class UserAuthManager: @unchecked Sendable
{

    var userId: UUID? {
        session?.user.id
    }

    var session: Session? = nil {
        didSet {
            guard oldValue?.user.id != self.userId else {
                return
            }
            NotificationCenter.default.post(
                UserIdDidChange(userId: self.userId)
            )
        }
    }

    private let supabaseClient: Supabase.SupabaseClient
    private let userNameDataKey = "username"
    private let timeout: TimeInterval = 5

    private var refreshSessionError: Error?
    private var refreshSessionFinished: Bool = false
    private var refreshingSession: Bool = false

    init(supabaseClient: Supabase.SupabaseClient) {
        self.supabaseClient = supabaseClient

        // session stored in keychain: The session returned by this property may be expired but enough for getting User id here to init database
        // no need to refresh the session here. The sync coordinator will do it upon necessary
        self.session = supabaseClient.auth.currentSession
    }

    func refreshAuthSession() async throws {
        guard !self.refreshingSession else {
            return
        }
        // force refreshing with the server in case there is a local not-expired session,
        // but the user is deleted in the remote Database
        // refreshSession does not break out of group task correctly and therefore we cannot use withTimeout here
        refreshSessionError = nil
        refreshSessionFinished = false
        refreshingSession = true
        defer {
            self.refreshSessionError = nil
            self.refreshSessionFinished = false
            self.refreshingSession = false
        }

        let refreshTask = Task {
            defer {
                refreshSessionFinished = true
            }
            do {
                self.session = try await self.supabaseClient.auth
                    .refreshSession()
            } catch (let e) {
                guard self.refreshingSession else {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                if e.isCancelledError || e.isNoNetworkError {
                    refreshSessionError = SyncError.networkUnavailable
                    return
                }

                if let error = e as? AuthError {
                    if error == .sessionMissing
                        || error.errorCode == .sessionExpired
                        || error.errorCode == .sessionNotFound
                    {
                        self.session = nil
                    }
                }
                refreshSessionError = e
                return
            }
        }

        let waitTask = Task {
            var timeElapsed: TimeInterval = 0
            while !self.refreshSessionFinished
                && timeElapsed < self.timeout * 1000
            {
                try await Task.sleep(for: .milliseconds(10))
                timeElapsed += 10
                if self.refreshSessionFinished || timeElapsed >= self.timeout * 1000 {
                    break
                }
            }
            throw SyncError.networkUnavailable
        }

        // wait for waitTask instead because refreshSession does not respond to task cancellation correctly
        // (due to objective C implementation and checked continuation)
        let result = await waitTask.result
        refreshTask.cancel()
        if self.refreshSessionFinished {
            if let error = self.refreshSessionError {
                try self.handleAuthError(error)
            }
            return
        }

        switch result {
        case .failure(let error):
            try self.handleAuthError(error)
        default:
            break
        }
    }

    private func handleAuthError(_ error: Error) throws {
        logError("Auth Error: \(error)")
        if error.isCancelledError || error.isNoNetworkError {
            throw SyncError.networkUnavailable
        }

        if let error = error as? AuthError {
            if error == .sessionMissing || error.errorCode == .sessionExpired
                || error.errorCode == .sessionNotFound
            {
                self.session = nil
                throw SyncError.notAuthenticated
            }
        }
        throw error
    }

    @MainActor
    public func onOpenURL(
        _ url: URL,
    ) async throws {
        try await withTimeout(
            seconds: self.timeout,
            operation: {
                self.session = try await self.supabaseClient.auth.session(
                    from: url
                )
            },
            cancellationError: SyncError.notAuthenticated
        )
    }

    func signIn(email: String, password: String) async throws {
        try await withTimeout(
            seconds: self.timeout,
            operation: {
                self.session = try await self.supabaseClient.auth.signIn(
                    email: email,
                    password: password
                )
            },
            cancellationError: SyncError.notAuthenticated
        )
    }

    func signUp(
        email: String,
        password: String,
        userName: String,
    ) async throws {
        let response = try await withTimeout(
            seconds: self.timeout,
            operation: {
                let response = try await self.supabaseClient.auth.signUp(
                    email: email,
                    password: password,
                    data: [self.userNameDataKey: .string(userName)],
                    // redirectTo: CustomURLScheme.login.url
                )
                return response
            },
            cancellationError: SyncError.notAuthenticated
        )

        switch response {

        case .session(let session):
            // Sign up with success
            self.session = session
        case .user(_):
            // check email to confirm the sign up
            break
        }
    }

    public func signOut() async throws {
        try await withTimeout(
            seconds: self.timeout,
            operation: {
                try await self.supabaseClient.auth.signOut(scope: .local)
            },
            cancellationError: SyncError.notAuthenticated
        )

        self.session = nil
    }
}
