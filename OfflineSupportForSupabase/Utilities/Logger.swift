//
//  Logger.swift
//  OfflineSupportForSupabase
//
//  Created by Itsuki on 2026/05/26.
//

import OSLog

let bundleId = Bundle.main.bundleIdentifier ?? "com.example.OfflineSupportForSupabase"

nonisolated let logger = Logger(
    subsystem: bundleId,
    category: "OfflineSupportForSupabase"
)

nonisolated func logInfo(_ message: String) {
    logger.log("\(message, privacy: .public)")
}

nonisolated func logError(_ message: String) {
    logger.error("\(message, privacy: .public)")
}
