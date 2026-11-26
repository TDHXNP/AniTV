//
//  LocalMediaSourcesTable.swift
//  AniTV
//
//  Created by Codex on 2026/11/25.
//

import Foundation
import GRDB
import SQLiteData

enum LocalMediaSourceKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case webdav = "webdav"
    case emby = "emby"
    case jellyfin = "jellyfin"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .webdav: return "WebDAV"
        case .emby: return "Emby"
        case .jellyfin: return "Jellyfin"
        }
    }

    var urlPlaceholder: String {
        switch self {
        case .webdav: return "http://192.168.1.10:5244/dav/Anime"
        case .emby: return "http://192.168.1.10:8096"
        case .jellyfin: return "http://192.168.1.10:8096"
        }
    }
}

struct LocalMediaSourceConfig: Identifiable, Equatable, Hashable, Sendable {
    let id: Int
    var name: String
    var kind: LocalMediaSourceKind
    var baseURL: String
    var username: String
    var password: String
    var apiKey: String
    var isEnabled: Bool
}

extension AniTVDatabase {
    static func registerLocalMediaSourceMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create local_media_sources table") { db in
            try #sql(
                """
                CREATE TABLE "local_media_sources" (
                  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
                  "name" TEXT NOT NULL,
                  "kind" TEXT NOT NULL,
                  "base_url" TEXT NOT NULL,
                  "username" TEXT NOT NULL DEFAULT '',
                  "password" TEXT NOT NULL DEFAULT '',
                  "api_key" TEXT NOT NULL DEFAULT '',
                  "enabled" INTEGER NOT NULL DEFAULT 1,
                  "created_at" TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                  "updated_at" TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                ) STRICT
                """
            )
            .execute(db)
        }
    }

    nonisolated static func fetchLocalMediaSources(
        enabledOnly: Bool = false,
        in database: any DatabaseWriter
    ) async throws -> [LocalMediaSourceConfig] {
        try await database.read { db in
            let sql = enabledOnly
                ? """
                SELECT "id", "name", "kind", "base_url", "username", "password", "api_key", "enabled"
                FROM "local_media_sources"
                WHERE "enabled" = 1
                ORDER BY "id" ASC
                """
                : """
                SELECT "id", "name", "kind", "base_url", "username", "password", "api_key", "enabled"
                FROM "local_media_sources"
                ORDER BY "id" ASC
                """

            return try Row.fetchAll(db, sql: sql).map { row in
                let kindRaw: String = row["kind"]
                let enabledInt: Int = row["enabled"]
                return LocalMediaSourceConfig(
                    id: row["id"],
                    name: row["name"],
                    kind: LocalMediaSourceKind(rawValue: kindRaw) ?? .webdav,
                    baseURL: row["base_url"],
                    username: row["username"],
                    password: row["password"],
                    apiKey: row["api_key"],
                    isEnabled: enabledInt != 0
                )
            }
        }
    }

    nonisolated static func insertLocalMediaSource(
        name: String,
        kind: LocalMediaSourceKind,
        baseURL: String,
        username: String = "",
        password: String = "",
        apiKey: String = "",
        isEnabled: Bool = true,
        in database: any DatabaseWriter
    ) async throws -> LocalMediaSourceConfig {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        return try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO "local_media_sources" (
                  "name", "kind", "base_url", "username", "password", "api_key", "enabled",
                  "created_at", "updated_at"
                ) VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                """,
                arguments: [
                    normalizedName,
                    kind.rawValue,
                    normalizedURL,
                    normalizedUser,
                    password,
                    normalizedKey,
                    isEnabled ? 1 : 0
                ]
            )
            let insertedID = Int(db.lastInsertedRowID)
            return LocalMediaSourceConfig(
                id: insertedID,
                name: normalizedName,
                kind: kind,
                baseURL: normalizedURL,
                username: normalizedUser,
                password: password,
                apiKey: normalizedKey,
                isEnabled: isEnabled
            )
        }
    }

    nonisolated static func setLocalMediaSourceEnabled(
        id: Int,
        isEnabled: Bool,
        in database: any DatabaseWriter
    ) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                UPDATE "local_media_sources"
                SET "enabled" = ?, "updated_at" = CURRENT_TIMESTAMP
                WHERE "id" = ?
                """,
                arguments: [isEnabled ? 1 : 0, id]
            )
        }
    }

    nonisolated static func deleteLocalMediaSource(
        id: Int,
        in database: any DatabaseWriter
    ) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                DELETE FROM "local_media_sources"
                WHERE "id" = ?
                """,
                arguments: [id]
            )
        }
    }
}
