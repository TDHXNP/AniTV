//
//  AniTVDatabase+SystemSettings.swift
//  AniTV
//
//  Created by Codex on 2026/5/3.
//

import Foundation
import GRDB
import SQLiteData

enum SkipOPEDMode: String, CaseIterable, Sendable {
    case prompt = "prompt"
    case auto = "auto"
    case off = "off"

    var displayTitle: String {
        switch self {
        case .prompt:
            return "提示跳过"
        case .auto:
            return "自动跳过"
        case .off:
            return "关闭"
        }
    }
}

extension AniTVDatabase {
    nonisolated static let playbackCompletionThresholdSettingKey = "player.playback_completion_threshold"
    nonisolated static let defaultPlaybackCompletionThreshold = 0.9
    nonisolated static let autoPlayNextSettingKey = "player.auto_play_next"
    nonisolated static let defaultAutoPlayNext = true
    nonisolated static let skipOPEDModeSettingKey = "player.skip_oped_mode"
    nonisolated static let defaultSkipOPEDMode: SkipOPEDMode = .prompt
    nonisolated static let fallbackOPSkipSecondsSettingKey = "player.fallback_op_skip_seconds"
    nonisolated static let defaultFallbackOPSkipSeconds = 85
    nonisolated static let rememberDanmakuStateSettingKey = "player.remember_danmaku_state"
    nonisolated static let defaultRememberDanmakuState = true
    nonisolated static let lastDanmakuEnabledSettingKey = "player.last_danmaku_enabled"
    nonisolated static let defaultLastDanmakuEnabled = true
    nonisolated static let danmakuDisplayAreaSettingKey = "player.danmaku_display_area"
    nonisolated static let defaultDanmakuDisplayArea = 1.0
    nonisolated static let danmuApiBaseURLSettingKey = "danmaku.danmu_api_base_url"
    nonisolated static let defaultDanmuApiBaseURL = "https://danmu.tdhxnp.com/APTX4869"
    nonisolated static let danmuApiTokenSettingKey = "danmaku.danmu_api_token"
    nonisolated static let defaultDanmuApiToken = ""
    nonisolated static let playbackSearchConcurrencySettingKey = "media_source.search_concurrency"
    nonisolated static let defaultPlaybackSearchConcurrency = 5
    nonisolated static let defaultMediaSourceNameSettingKey = "media_source.default_source_name"
    nonisolated static let bangumiOAuthRedirectURISettingKey = "bangumi_oauth_redirect_uri"
    nonisolated static let bangumiOAuthRefreshBlockedSettingKey = "bangumi_oauth_refresh_blocked"

    nonisolated static let systemSettingsSchema = """
    CREATE TABLE "system_settings" (
      "key" TEXT PRIMARY KEY NOT NULL,
      "value" TEXT NOT NULL,
      "value_type" TEXT NOT NULL DEFAULT 'string',
      "created_at" TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      "updated_at" TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    ) STRICT
    """

    nonisolated static func registerSystemSettingsMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create system_settings table") { db in
            try #sql(
                """
                CREATE TABLE "system_settings" (
                  "key" TEXT PRIMARY KEY NOT NULL,
                  "value" TEXT NOT NULL,
                  "value_type" TEXT NOT NULL DEFAULT 'string',
                  "created_at" TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                  "updated_at" TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                ) STRICT
                """
            )
            .execute(db)
        }
        migrator.registerMigration("Seed playback completion threshold setting") { db in
            try upsertSystemSetting(
                key: playbackCompletionThresholdSettingKey,
                value: String(defaultPlaybackCompletionThreshold),
                valueType: "double",
                in: db
            )
        }
        migrator.registerMigration("Seed playback search concurrency setting") { db in
            try upsertSystemSetting(
                key: playbackSearchConcurrencySettingKey,
                value: String(defaultPlaybackSearchConcurrency),
                valueType: "integer",
                in: db
            )
        }
        migrator.registerMigration("Seed auto play next setting") { db in
            try upsertSystemSetting(
                key: autoPlayNextSettingKey,
                value: defaultAutoPlayNext ? "1" : "0",
                valueType: "boolean",
                in: db
            )
        }
        migrator.registerMigration("Seed remember danmaku state setting") { db in
            try upsertSystemSetting(
                key: rememberDanmakuStateSettingKey,
                value: defaultRememberDanmakuState ? "1" : "0",
                valueType: "boolean",
                in: db
            )
        }
        migrator.registerMigration("Seed last danmaku enabled setting") { db in
            try upsertSystemSetting(
                key: lastDanmakuEnabledSettingKey,
                value: defaultLastDanmakuEnabled ? "1" : "0",
                valueType: "boolean",
                in: db
            )
        }
        migrator.registerMigration("Seed danmaku display area setting") { db in
            try upsertSystemSetting(
                key: danmakuDisplayAreaSettingKey,
                value: String(defaultDanmakuDisplayArea),
                valueType: "double",
                in: db
            )
        }
        migrator.registerMigration("Seed default media source setting") { db in
            try upsertSystemSetting(
                key: defaultMediaSourceNameSettingKey,
                value: "",
                valueType: "string",
                in: db
            )
        }
        migrator.registerMigration("Seed skip OP/ED settings") { db in
            try upsertSystemSetting(
                key: skipOPEDModeSettingKey,
                value: defaultSkipOPEDMode.rawValue,
                valueType: "string",
                in: db
            )
            try upsertSystemSetting(
                key: fallbackOPSkipSecondsSettingKey,
                value: String(defaultFallbackOPSkipSeconds),
                valueType: "integer",
                in: db
            )
        }
        migrator.registerMigration("Seed danmu_api settings") { db in
            try upsertSystemSetting(
                key: danmuApiBaseURLSettingKey,
                value: defaultDanmuApiBaseURL,
                valueType: "string",
                in: db
            )
            try upsertSystemSetting(
                key: danmuApiTokenSettingKey,
                value: defaultDanmuApiToken,
                valueType: "string",
                in: db
            )
        }
        migrator.registerMigration("Populate default danmu_api endpoint if empty") { db in
            let currentURL = try String.fetchOne(
                db,
                sql: "SELECT \"value\" FROM \"system_settings\" WHERE \"key\" = ? LIMIT 1",
                arguments: [danmuApiBaseURLSettingKey]
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if currentURL.isEmpty {
                try upsertSystemSetting(
                    key: danmuApiBaseURLSettingKey,
                    value: defaultDanmuApiBaseURL,
                    valueType: "string",
                    in: db
                )
                try upsertSystemSetting(
                    key: danmuApiTokenSettingKey,
                    value: defaultDanmuApiToken,
                    valueType: "string",
                    in: db
                )
            }
        }
    }

    nonisolated static func systemSettingValue(
        forKey key: String,
        in database: any DatabaseWriter
    ) async throws -> String? {
        try await database.read { db in
            try #sql(
                """
                SELECT "value"
                FROM "system_settings"
                WHERE "key" = \(bind: key)
                LIMIT 1
                """,
                as: String.self
            )
            .fetchOne(db)
        }
    }

    nonisolated static func upsertSystemSetting(
        key: String,
        value: String,
        valueType: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO "system_settings" ("key", "value", "value_type", "created_at", "updated_at")
            VALUES (?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            ON CONFLICT("key") DO UPDATE SET
              "value" = excluded."value",
              "value_type" = excluded."value_type",
              "updated_at" = CURRENT_TIMESTAMP
            """,
            arguments: [key, value, valueType]
        )
    }

    nonisolated static func playbackCompletionThreshold(
        in database: any DatabaseWriter
    ) async throws -> Double {
        let value = try await systemSettingValue(
            forKey: playbackCompletionThresholdSettingKey,
            in: database
        )
        guard let value, let threshold = Double(value), threshold > 0, threshold <= 1 else {
            return defaultPlaybackCompletionThreshold
        }
        return threshold
    }

    nonisolated static func setPlaybackCompletionThreshold(
        _ threshold: Double,
        in database: any DatabaseWriter
    ) async throws {
        try await database.write { db in
            try upsertSystemSetting(
                key: playbackCompletionThresholdSettingKey,
                value: String(threshold),
                valueType: "double",
                in: db
            )
        }
    }

    nonisolated static func playbackSearchConcurrency(
        in database: any DatabaseWriter
    ) async throws -> Int {
        let value = try await systemSettingValue(
            forKey: playbackSearchConcurrencySettingKey,
            in: database
        )
        guard let value, let concurrency = Int(value), concurrency > 0 else {
            return defaultPlaybackSearchConcurrency
        }
        return concurrency
    }

    nonisolated static func setPlaybackSearchConcurrency(
        _ concurrency: Int,
        in database: any DatabaseWriter
    ) async throws {
        try await database.write { db in
            try upsertSystemSetting(
                key: playbackSearchConcurrencySettingKey,
                value: String(concurrency),
                valueType: "integer",
                in: db
            )
        }
    }

    nonisolated static func isAutoPlayNextEnabled(
        in database: any DatabaseWriter
    ) async throws -> Bool {
        let value = try await systemSettingValue(
            forKey: autoPlayNextSettingKey,
            in: database
        )
        guard let value else { return defaultAutoPlayNext }
        return value == "1"
    }

    nonisolated static func setAutoPlayNextEnabled(
        _ enabled: Bool,
        in database: any DatabaseWriter
    ) async throws {
        try await database.write { db in
            try upsertSystemSetting(
                key: autoPlayNextSettingKey,
                value: enabled ? "1" : "0",
                valueType: "boolean",
                in: db
            )
        }
    }

    nonisolated static func isRememberDanmakuStateEnabled(
        in database: any DatabaseWriter
    ) async throws -> Bool {
        let value = try await systemSettingValue(
            forKey: rememberDanmakuStateSettingKey,
            in: database
        )
        guard let value else { return defaultRememberDanmakuState }
        return value == "1"
    }

    nonisolated static func setRememberDanmakuStateEnabled(
        _ enabled: Bool,
        in database: any DatabaseWriter
    ) async throws {
        UserDefaults.standard.set(enabled, forKey: rememberDanmakuStateSettingKey)
        try await database.write { db in
            try upsertSystemSetting(
                key: rememberDanmakuStateSettingKey,
                value: enabled ? "1" : "0",
                valueType: "boolean",
                in: db
            )
        }
    }

    nonisolated static func isLastDanmakuEnabled(
        in database: any DatabaseWriter
    ) async throws -> Bool {
        let value = try await systemSettingValue(
            forKey: lastDanmakuEnabledSettingKey,
            in: database
        )
        guard let value else { return defaultLastDanmakuEnabled }
        return value == "1"
    }

    nonisolated static func setLastDanmakuEnabled(
        _ enabled: Bool,
        in database: any DatabaseWriter
    ) async throws {
        UserDefaults.standard.set(enabled, forKey: lastDanmakuEnabledSettingKey)
        try await database.write { db in
            try upsertSystemSetting(
                key: lastDanmakuEnabledSettingKey,
                value: enabled ? "1" : "0",
                valueType: "boolean",
                in: db
            )
        }
    }

    nonisolated static func resolvedInitialDanmakuEnabled() -> Bool {
        let shouldRemember: Bool
        if let stored = UserDefaults.standard.object(forKey: rememberDanmakuStateSettingKey) as? Bool {
            shouldRemember = stored
        } else {
            shouldRemember = defaultRememberDanmakuState
        }

        guard shouldRemember else { return true }

        if let storedState = UserDefaults.standard.object(forKey: lastDanmakuEnabledSettingKey) as? Bool {
            return storedState
        }
        return defaultLastDanmakuEnabled
    }

    nonisolated static func persistDanmakuStateIfRememberEnabled(
        _ enabled: Bool,
        in database: (any DatabaseWriter)?
    ) {
        let shouldRemember: Bool
        if let stored = UserDefaults.standard.object(forKey: rememberDanmakuStateSettingKey) as? Bool {
            shouldRemember = stored
        } else {
            shouldRemember = defaultRememberDanmakuState
        }

        guard shouldRemember else { return }

        UserDefaults.standard.set(enabled, forKey: lastDanmakuEnabledSettingKey)
        if let database {
            Task {
                try? await setLastDanmakuEnabled(enabled, in: database)
            }
        }
    }

    nonisolated static func danmakuDisplayArea(
        in database: any DatabaseWriter
    ) async throws -> Double {
        let value = try await systemSettingValue(
            forKey: danmakuDisplayAreaSettingKey,
            in: database
        )
        guard let value, let area = Double(value), area >= 0.1, area <= 1.0 else {
            return defaultDanmakuDisplayArea
        }
        return area
    }

    nonisolated static func setDanmakuDisplayArea(
        _ area: Double,
        in database: any DatabaseWriter
    ) async throws {
        let clamped = min(max(area, 0.125), 1.0)
        UserDefaults.standard.set(clamped, forKey: danmakuDisplayAreaSettingKey)
        try await database.write { db in
            try upsertSystemSetting(
                key: danmakuDisplayAreaSettingKey,
                value: String(clamped),
                valueType: "double",
                in: db
            )
        }
    }

    nonisolated static func resolvedInitialDanmakuDisplayArea() -> CGFloat {
        if let stored = UserDefaults.standard.object(forKey: danmakuDisplayAreaSettingKey) as? Double,
           stored >= 0.1, stored <= 1.0 {
            return CGFloat(stored)
        }
        return CGFloat(defaultDanmakuDisplayArea)
    }

    nonisolated static func persistDanmakuDisplayArea(
        _ area: CGFloat,
        in database: (any DatabaseWriter)?
    ) {
        let clamped = min(max(Double(area), 0.125), 1.0)
        UserDefaults.standard.set(clamped, forKey: danmakuDisplayAreaSettingKey)
        if let database {
            Task {
                try? await setDanmakuDisplayArea(clamped, in: database)
            }
        }
    }

    nonisolated static func syncDanmakuSettingsToUserDefaults(
        in database: any DatabaseWriter
    ) async {
        do {
            let remember = try await isRememberDanmakuStateEnabled(in: database)
            let lastEnabled = try await isLastDanmakuEnabled(in: database)
            let displayArea = try await danmakuDisplayArea(in: database)
            let baseURL = try await danmuApiBaseURL(in: database)
            let token = try await danmuApiToken(in: database)
            UserDefaults.standard.set(remember, forKey: rememberDanmakuStateSettingKey)
            UserDefaults.standard.set(lastEnabled, forKey: lastDanmakuEnabledSettingKey)
            UserDefaults.standard.set(displayArea, forKey: danmakuDisplayAreaSettingKey)
            UserDefaults.standard.set(baseURL, forKey: danmuApiBaseURLSettingKey)
            UserDefaults.standard.set(token, forKey: danmuApiTokenSettingKey)
        } catch {
            print("[SystemSettingsTable] Failed to sync danmaku settings to UserDefaults: \(error)")
        }
    }

    nonisolated static func danmuApiBaseURL(
        in database: any DatabaseWriter
    ) async throws -> String {
        let value = try await systemSettingValue(
            forKey: danmuApiBaseURLSettingKey,
            in: database
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty {
            return value
        }
        return defaultDanmuApiBaseURL
    }

    nonisolated static func setDanmuApiBaseURL(
        _ baseURL: String,
        in database: any DatabaseWriter
    ) async throws {
        let normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(normalized, forKey: danmuApiBaseURLSettingKey)
        try await database.write { db in
            try upsertSystemSetting(
                key: danmuApiBaseURLSettingKey,
                value: normalized,
                valueType: "string",
                in: db
            )
        }
    }

    nonisolated static func danmuApiToken(
        in database: any DatabaseWriter
    ) async throws -> String {
        let value = try await systemSettingValue(
            forKey: danmuApiTokenSettingKey,
            in: database
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return value ?? defaultDanmuApiToken
    }

    nonisolated static func setDanmuApiToken(
        _ token: String,
        in database: any DatabaseWriter
    ) async throws {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(normalized, forKey: danmuApiTokenSettingKey)
        try await database.write { db in
            try upsertSystemSetting(
                key: danmuApiTokenSettingKey,
                value: normalized,
                valueType: "string",
                in: db
            )
        }
    }

    nonisolated static func resolvedDanmuApiBaseURL() -> String {
        let stored = UserDefaults.standard.string(forKey: danmuApiBaseURLSettingKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty {
            return stored
        }
        return defaultDanmuApiBaseURL
    }

    nonisolated static func resolvedDanmuApiToken() -> String {
        if let stored = UserDefaults.standard.string(forKey: danmuApiTokenSettingKey) {
            return stored.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return defaultDanmuApiToken
    }

    nonisolated static func defaultMediaSourceName(
        in database: any DatabaseWriter
    ) async throws -> String? {
        let value = try await systemSettingValue(
            forKey: defaultMediaSourceNameSettingKey,
            in: database
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let value, !value.isEmpty else { return nil }
        return value
    }

    nonisolated static func setDefaultMediaSourceName(
        _ name: String?,
        in database: any DatabaseWriter
    ) async throws {
        let normalized = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try await database.write { db in
            try upsertSystemSetting(
                key: defaultMediaSourceNameSettingKey,
                value: normalized,
                valueType: "string",
                in: db
            )
        }
    }

    nonisolated static func skipOPEDMode(
        in database: any DatabaseWriter
    ) async throws -> SkipOPEDMode {
        let value = try await systemSettingValue(
            forKey: skipOPEDModeSettingKey,
            in: database
        )
        guard let value, let mode = SkipOPEDMode(rawValue: value) else {
            return defaultSkipOPEDMode
        }
        return mode
    }

    nonisolated static func setSkipOPEDMode(
        _ mode: SkipOPEDMode,
        in database: any DatabaseWriter
    ) async throws {
        UserDefaults.standard.set(mode.rawValue, forKey: skipOPEDModeSettingKey)
        try await database.write { db in
            try upsertSystemSetting(
                key: skipOPEDModeSettingKey,
                value: mode.rawValue,
                valueType: "string",
                in: db
            )
        }
    }

    nonisolated static func fallbackOPSkipSeconds(
        in database: any DatabaseWriter
    ) async throws -> Int {
        let value = try await systemSettingValue(
            forKey: fallbackOPSkipSecondsSettingKey,
            in: database
        )
        guard let value, let seconds = Int(value), seconds >= 30, seconds <= 240 else {
            return defaultFallbackOPSkipSeconds
        }
        return seconds
    }

    nonisolated static func setFallbackOPSkipSeconds(
        _ seconds: Int,
        in database: any DatabaseWriter
    ) async throws {
        let clamped = min(max(seconds, 30), 240)
        UserDefaults.standard.set(clamped, forKey: fallbackOPSkipSecondsSettingKey)
        try await database.write { db in
            try upsertSystemSetting(
                key: fallbackOPSkipSecondsSettingKey,
                value: String(clamped),
                valueType: "integer",
                in: db
            )
        }
    }

    nonisolated static func bangumiOAuthRedirectURI(
        in database: any DatabaseWriter
    ) async throws -> String? {
        let value = try await systemSettingValue(
            forKey: bangumiOAuthRedirectURISettingKey,
            in: database
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let value, !value.isEmpty else { return nil }
        return value
    }

    nonisolated static func setBangumiOAuthRedirectURI(
        _ redirectURI: String,
        in database: any DatabaseWriter
    ) async throws {
        let normalizedRedirectURI = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRedirectURI.isEmpty else { return }

        try await database.write { db in
            try upsertSystemSetting(
                key: bangumiOAuthRedirectURISettingKey,
                value: normalizedRedirectURI,
                valueType: "string",
                in: db
            )
        }
    }

    nonisolated static func isBangumiOAuthRefreshBlocked(
        in database: any DatabaseWriter
    ) async throws -> Bool {
        let value = try await systemSettingValue(
            forKey: bangumiOAuthRefreshBlockedSettingKey,
            in: database
        )
        return value == "1"
    }

    nonisolated static func setBangumiOAuthRefreshBlocked(
        _ isBlocked: Bool,
        in database: any DatabaseWriter
    ) async throws {
        try await database.write { db in
            try upsertSystemSetting(
                key: bangumiOAuthRefreshBlockedSettingKey,
                value: isBlocked ? "1" : "0",
                valueType: "boolean",
                in: db
            )
        }
    }
}
