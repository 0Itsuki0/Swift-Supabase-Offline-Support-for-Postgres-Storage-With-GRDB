//
//  UserLastAccess.swift
//  OfflineSupportForSupabase
//
//  Created by Itsuki on 2026/05/31.
//

import Foundation

// MARK: - UserLastAccess
// tracks the last time each user's database was opened.
//
// On every launch, a background task runs `cleanupCachedUserData(currentUserId:)` which:
// 1. Reads the `user_last_access` map from `UserDefaults`
// 2. Skips the current user
// 3. Removes the entire `<userId>/` directory for any user whose last access is older than 30 days
// 4. Removes their entry from the map
nonisolated
    enum UserLastAccess
{
    static let key = "user_last_access"

    static let cutoffInterval = 30.0 * 24.0 * 60.0 * 60.0

    static let userDefaults = UserDefaults(suiteName: appGroupId) ?? .standard
    static var accessMap: [String: TimeInterval] {
        userDefaults.dictionary(forKey: key)
            as? [String: TimeInterval] ?? [:]
    }

    static func set(for userId: UUID) {
        var map = accessMap
        map[userId.uuidString] = Date().timeIntervalSince1970
        userDefaults.set(
            map,
            forKey: UserLastAccess.key
        )
    }

    static func date(for userId: UUID) -> Date? {
        guard let timeInterval = accessMap[userId.uuidString] else {
            return nil
        }
        return Date(timeIntervalSince1970: timeInterval)
    }

    static func cleanupCachedUserData(currentUserId: UUID) {
        var map = accessMap
        let cutoff = Date().timeIntervalSince1970 - cutoffInterval
        for (userId, lastAccess) in self.accessMap {
            guard let userId = UUID(uuidString: userId) else {
                continue
            }
            guard userId != currentUserId else {
                continue
            }
            guard lastAccess < cutoff else {
                continue
            }

            let directoryURL = URL.baseUrlForUser(userId)
            do {
                try FileManager.default.removeItem(at: directoryURL)
                map.removeValue(forKey: userId.uuidString)
            } catch (let error) {
                logError(
                    "Error removing user directory at \(directoryURL): \(error)"
                )
            }
        }

        userDefaults.set(
            UserLastAccess.accessMap,
            forKey: UserLastAccess.key
        )
    }
}
