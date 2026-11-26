//
//  AniSkipTable.swift
//  AniTV
//
//  Created by Codex on 2026/11/25.
//

import Foundation
import GRDB
import SQLiteData

struct CachedAniSkipEntry: Equatable, Sendable {
    let subjectID: Int
    let episodeNumber: Int
    let opStart: Double?
    let opEnd: Double?
    let edStart: Double?
    let edEnd: Double?
    let found: Bool
    let fetchedAt: TimeInterval
}

struct SubjectSkipPreference: Equatable, Sendable {
    let subjectID: Int
    let opStart: Double?
    let opEnd: Double?
    let edStart: Double?
    let edEnd: Double?
}

extension AniTVDatabase {
    static func registerAniSkipMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create bangumi_mal_map table") { db in
            try #sql(
                """
                CREATE TABLE "bangumi_mal_map" (
                  "subject_id" INTEGER PRIMARY KEY NOT NULL,
                  "mal_id" INTEGER NOT NULL,
                  "updated_at" INTEGER NOT NULL
                ) STRICT
                """
            )
            .execute(db)
        }

        migrator.registerMigration("Create aniskip_episode_cache table") { db in
            try #sql(
                """
                CREATE TABLE "aniskip_episode_cache" (
                  "subject_id" INTEGER NOT NULL,
                  "episode_number" INTEGER NOT NULL,
                  "op_start" REAL,
                  "op_end" REAL,
                  "ed_start" REAL,
                  "ed_end" REAL,
                  "found" INTEGER NOT NULL DEFAULT 0,
                  "fetched_at" INTEGER NOT NULL,
                  PRIMARY KEY ("subject_id", "episode_number")
                ) STRICT
                """
            )
            .execute(db)
        }

        migrator.registerMigration("Create subject_skip_preferences table") { db in
            try #sql(
                """
                CREATE TABLE "subject_skip_preferences" (
                  "subject_id" INTEGER PRIMARY KEY NOT NULL,
                  "op_start" REAL,
                  "op_end" REAL,
                  "ed_start" REAL,
                  "ed_end" REAL,
                  "updated_at" INTEGER NOT NULL
                ) STRICT
                """
            )
            .execute(db)
        }
    }

    // MARK: - Bangumi -> MAL ID Cache

    nonisolated static func cachedMalID(
        forSubjectID subjectID: Int,
        in database: any DatabaseWriter
    ) async throws -> Int? {
        try await database.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT "mal_id"
                FROM "bangumi_mal_map"
                WHERE "subject_id" = ?
                LIMIT 1
                """,
                arguments: [subjectID]
            )
        }
    }

    nonisolated static func upsertMalID(
        _ malID: Int,
        forSubjectID subjectID: Int,
        in database: any DatabaseWriter
    ) async throws {
        let now = Int(Date().timeIntervalSince1970)
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO "bangumi_mal_map" ("subject_id", "mal_id", "updated_at")
                VALUES (?, ?, ?)
                ON CONFLICT("subject_id") DO UPDATE SET
                  "mal_id" = excluded."mal_id",
                  "updated_at" = excluded."updated_at"
                """,
                arguments: [subjectID, malID, now]
            )
        }
    }

    // MARK: - AniSkip Episode Cache

    nonisolated static func cachedAniSkipEntry(
        subjectID: Int,
        episodeNumber: Int,
        in database: any DatabaseWriter
    ) async throws -> CachedAniSkipEntry? {
        try await database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                  "subject_id",
                  "episode_number",
                  "op_start",
                  "op_end",
                  "ed_start",
                  "ed_end",
                  "found",
                  "fetched_at"
                FROM "aniskip_episode_cache"
                WHERE "subject_id" = ? AND "episode_number" = ?
                LIMIT 1
                """,
                arguments: [subjectID, episodeNumber]
            ) else {
                return nil
            }

            let foundInt: Int = row["found"]
            let fetchedAtInt: Int = row["fetched_at"]
            return CachedAniSkipEntry(
                subjectID: row["subject_id"],
                episodeNumber: row["episode_number"],
                opStart: row["op_start"],
                opEnd: row["op_end"],
                edStart: row["ed_start"],
                edEnd: row["ed_end"],
                found: foundInt != 0,
                fetchedAt: TimeInterval(fetchedAtInt)
            )
        }
    }

    nonisolated static func upsertAniSkipEntry(
        _ entry: CachedAniSkipEntry,
        in database: any DatabaseWriter
    ) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO "aniskip_episode_cache" (
                  "subject_id",
                  "episode_number",
                  "op_start",
                  "op_end",
                  "ed_start",
                  "ed_end",
                  "found",
                  "fetched_at"
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT("subject_id", "episode_number") DO UPDATE SET
                  "op_start" = excluded."op_start",
                  "op_end" = excluded."op_end",
                  "ed_start" = excluded."ed_start",
                  "ed_end" = excluded."ed_end",
                  "found" = excluded."found",
                  "fetched_at" = excluded."fetched_at"
                """,
                arguments: [
                    entry.subjectID,
                    entry.episodeNumber,
                    entry.opStart,
                    entry.opEnd,
                    entry.edStart,
                    entry.edEnd,
                    entry.found ? 1 : 0,
                    Int(entry.fetchedAt)
                ]
            )
        }
    }

    // MARK: - User Per-Subject Skip Preferences

    nonisolated static func subjectSkipPreference(
        forSubjectID subjectID: Int,
        in database: any DatabaseWriter
    ) async throws -> SubjectSkipPreference? {
        try await database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT "subject_id", "op_start", "op_end", "ed_start", "ed_end"
                FROM "subject_skip_preferences"
                WHERE "subject_id" = ?
                LIMIT 1
                """,
                arguments: [subjectID]
            ) else {
                return nil
            }

            return SubjectSkipPreference(
                subjectID: row["subject_id"],
                opStart: row["op_start"],
                opEnd: row["op_end"],
                edStart: row["ed_start"],
                edEnd: row["ed_end"]
            )
        }
    }

    nonisolated static func upsertSubjectSkipPreference(
        _ pref: SubjectSkipPreference,
        in database: any DatabaseWriter
    ) async throws {
        let now = Int(Date().timeIntervalSince1970)
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO "subject_skip_preferences" (
                  "subject_id",
                  "op_start",
                  "op_end",
                  "ed_start",
                  "ed_end",
                  "updated_at"
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT("subject_id") DO UPDATE SET
                  "op_start" = excluded."op_start",
                  "op_end" = excluded."op_end",
                  "ed_start" = excluded."ed_start",
                  "ed_end" = excluded."ed_end",
                  "updated_at" = excluded."updated_at"
                """,
                arguments: [
                    pref.subjectID,
                    pref.opStart,
                    pref.opEnd,
                    pref.edStart,
                    pref.edEnd,
                    now
                ]
            )
        }
    }

    nonisolated static func deleteSubjectSkipPreference(
        forSubjectID subjectID: Int,
        in database: any DatabaseWriter
    ) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                DELETE FROM "subject_skip_preferences"
                WHERE "subject_id" = ?
                """,
                arguments: [subjectID]
            )
        }
    }
}
