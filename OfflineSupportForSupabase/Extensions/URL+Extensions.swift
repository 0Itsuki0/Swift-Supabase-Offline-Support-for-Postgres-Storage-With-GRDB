//
//  URL+Extensions.swift
//  OfflineSupportForSupabase
//
//  Created by Itsuki on 2026/06/01.
//

import Foundation

nonisolated
    extension URL
{
    static var appBaseURL: URL {
        guard
            let url = FileManager.default
                .containerURL(
                    forSecurityApplicationGroupIdentifier:
                        appGroupId
                )
        else {
            fatalError("Fail to set up local database")
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

        } catch (let error) {
            fatalError(
                "Fail to set up local database: \(error.localizedDescription)"
            )
        }

        return url
    }

    static func baseUrlForUser(_ userId: UUID) -> URL {
        let url = self.appBaseURL.appendingPathComponent(userId.uuidString)

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

        } catch (let error) {
            fatalError(
                "Fail to set up local database: \(error.localizedDescription)"
            )
        }

        return url
    }
}
