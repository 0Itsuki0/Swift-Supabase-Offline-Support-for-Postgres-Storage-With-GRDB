//
//  Error+Extensions.swift
//  OfflineSupportForSupabase
//
//  Created by Itsuki on 2026/06/01.
//

import Foundation

nonisolated
    extension Error
{
    // in a case of 100% loss, network monitor will still show connected while actual request will fail with NSURLErrorNetworkConnectionLost
    var isNoNetworkError: Bool {
        if let syncError = self as? SyncError {
            return syncError.code == SyncError.networkUnavailable.code
        }
        let nsError = self as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return false
        }
        return nsError.code == NSURLErrorNotConnectedToInternet
            || nsError.code == NSURLErrorNetworkConnectionLost
    }

    var isCancelledError: Bool {
        self is CancellationError
    }
}
