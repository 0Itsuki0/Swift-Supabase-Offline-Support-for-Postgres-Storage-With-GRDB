//
//  AsyncThrowingStream+Extensions.swift
//  OfflineSupportForSupabase
//
//  Created by Itsuki on 2026/06/02.
//

import Foundation

nonisolated extension AsyncThrowingStream {
    func collect() async throws -> [Element] {
        try await self.reduce(into: []) { $0.append($1) }
    }
}
