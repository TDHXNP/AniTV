//
//  AniSkipService.swift
//  AniTV
//
//  Created by Codex on 2026/11/25.
//

import Foundation
import GRDB
import SQLiteData

enum SkipSegmentKind: String, Hashable, Sendable {
    case op
    case ed
}

enum SkipSegmentSource: String, Hashable, Sendable {
    case custom
    case aniSkip
    case fallback
}

struct SkipSegment: Equatable, Sendable {
    let kind: SkipSegmentKind
    let startTime: Double
    let endTime: Double
    let source: SkipSegmentSource

    var isValid: Bool {
        startTime.isFinite && endTime.isFinite && startTime >= 0 && endTime - startTime >= 5
    }
}

struct EpisodeSkipPlan: Equatable, Sendable {
    let op: SkipSegment?
    let ed: SkipSegment?

    static let empty = EpisodeSkipPlan(op: nil, ed: nil)

    var hasExactOP: Bool {
        op != nil
    }

    var hasExactED: Bool {
        ed != nil
    }

    var hasCustomPreference: Bool {
        op?.source == .custom || ed?.source == .custom
    }

    var sourceDescription: String {
        if hasCustomPreference {
            return "本番自定义片头"
        }
        if op?.source == .aniSkip || ed?.source == .aniSkip {
            return "AniSkip 精准区间"
        }
        return "默认兜底模式"
    }
}

struct PlayerSkipContextualAction: Equatable, Sendable {
    let id: String
    let kind: SkipSegmentKind
    let source: SkipSegmentSource
    let title: String
    let systemImage: String
    let targetSeconds: Double?
    let switchesToNextEpisode: Bool
}

enum SkipPlaybackDecision: Equatable, Sendable {
    case none
    case showPrompt(PlayerSkipContextualAction)
    case autoSkip(SkipSegment)
}

enum SkipDecisionEngine {
    static let minimumDurationForFallbackSeconds: Double = 600
    static let fallbackOPWindowEndSeconds: Double = 150
    static let fallbackEDLeadSeconds: Double = 105
    static let fallbackEDTailGuardSeconds: Double = 12

    nonisolated static func evaluate(
        currentTime: Double,
        duration: Double,
        plan: EpisodeSkipPlan,
        mode: SkipOPEDMode,
        fallbackOPSkipSeconds: Int,
        hasNextEpisode: Bool,
        skippedKinds: Set<SkipSegmentKind>
    ) -> SkipPlaybackDecision {
        guard mode != .off,
              currentTime.isFinite,
              currentTime >= 0 else {
            return .none
        }

        // 1. Exact OP (Custom or AniSkip)
        if let op = plan.op, op.isValid, !skippedKinds.contains(.op) {
            if currentTime >= op.startTime && currentTime < op.endTime - 1.5 {
                if mode == .auto {
                    return .autoSkip(op)
                }
                let action = PlayerSkipContextualAction(
                    id: "exact_op_\(Int(op.startTime))_\(Int(op.endTime))",
                    kind: .op,
                    source: op.source,
                    title: "跳过片头",
                    systemImage: "forward.end.fill",
                    targetSeconds: op.endTime,
                    switchesToNextEpisode: false
                )
                return .showPrompt(action)
            }
        }

        // 2. Exact ED (Custom or AniSkip)
        if let ed = plan.ed, ed.isValid, !skippedKinds.contains(.ed) {
            if currentTime >= ed.startTime && currentTime < ed.endTime - 1.5 {
                if mode == .auto {
                    return .autoSkip(ed)
                }
                let reachesEnd = duration > 0 && ed.endTime >= duration - 10
                let shouldSwitchNext = reachesEnd && hasNextEpisode
                let action = PlayerSkipContextualAction(
                    id: "exact_ed_\(Int(ed.startTime))_\(Int(ed.endTime))",
                    kind: .ed,
                    source: ed.source,
                    title: shouldSwitchNext ? "跳过片尾 · 下一集" : "跳过片尾",
                    systemImage: shouldSwitchNext ? "forward.frame.fill" : "forward.end.fill",
                    targetSeconds: shouldSwitchNext ? nil : ed.endTime,
                    switchesToNextEpisode: shouldSwitchNext
                )
                return .showPrompt(action)
            }
        }

        // 3. Fallback OP (NEVER auto-skip to avoid skipping actual episode content)
        if plan.op == nil,
           !skippedKinds.contains(.op),
           duration >= minimumDurationForFallbackSeconds,
           currentTime <= fallbackOPWindowEndSeconds {
            let skipDelta = Double(max(30, min(fallbackOPSkipSeconds, 240)))
            let target = min(currentTime + skipDelta, max(currentTime, duration - 30))
            if target - currentTime >= 15 {
                let action = PlayerSkipContextualAction(
                    id: "fallback_op_\(fallbackOPSkipSeconds)",
                    kind: .op,
                    source: .fallback,
                    title: "跳过片头 (+\(fallbackOPSkipSeconds)秒)",
                    systemImage: "goforward",
                    targetSeconds: nil, // computed dynamically on tap as currentTime + fallbackOPSkipSeconds
                    switchesToNextEpisode: false
                )
                return .showPrompt(action)
            }
        }

        // 4. Fallback ED -> Next Episode prompt near the end when AniSkip has no ED
        if plan.ed == nil,
           hasNextEpisode,
           !skippedKinds.contains(.ed),
           duration >= minimumDurationForFallbackSeconds {
            let edWindowStart = max(0, duration - fallbackEDLeadSeconds)
            let edWindowEnd = max(edWindowStart, duration - fallbackEDTailGuardSeconds)
            if currentTime >= edWindowStart && currentTime <= edWindowEnd {
                let action = PlayerSkipContextualAction(
                    id: "fallback_ed_next",
                    kind: .ed,
                    source: .fallback,
                    title: "跳过片尾 · 下一集",
                    systemImage: "forward.frame.fill",
                    targetSeconds: nil,
                    switchesToNextEpisode: true
                )
                return .showPrompt(action)
            }
        }

        return .none
    }
}

actor AniSkipService {
    static let shared = AniSkipService()

    private let foundCacheTTL: TimeInterval = 7 * 24 * 3600
    private let notFoundCacheTTL: TimeInterval = 12 * 3600

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    func resolveSkipPlan(
        subjectID: Int,
        episodeNumber: Int,
        sessionTitle: String,
        episodeDurationSeconds: Int,
        database: any DatabaseWriter
    ) async -> EpisodeSkipPlan {
        // 1. Load user custom per-subject preference (highest priority)
        let customPref = try? await AniTVDatabase.subjectSkipPreference(
            forSubjectID: subjectID,
            in: database
        )
        let customOP: SkipSegment? = {
            guard let start = customPref?.opStart, let end = customPref?.opEnd else { return nil }
            let seg = SkipSegment(kind: .op, startTime: start, endTime: end, source: .custom)
            return seg.isValid ? seg : nil
        }()
        let customED: SkipSegment? = {
            guard let start = customPref?.edStart, let end = customPref?.edEnd else { return nil }
            let seg = SkipSegment(kind: .ed, startTime: start, endTime: end, source: .custom)
            return seg.isValid ? seg : nil
        }()

        // If user set both custom OP and ED, no remote call needed
        if customOP != nil && customED != nil {
            return EpisodeSkipPlan(op: customOP, ed: customED)
        }

        // 2. Check AniSkip SQLite cache
        let now = Date().timeIntervalSince1970
        if episodeNumber > 0,
           let cached = try? await AniTVDatabase.cachedAniSkipEntry(
               subjectID: subjectID,
               episodeNumber: episodeNumber,
               in: database
           ) {
            let ttl = cached.found ? foundCacheTTL : notFoundCacheTTL
            if now - cached.fetchedAt < ttl {
                let cachedOP = makeSegment(kind: .op, start: cached.opStart, end: cached.opEnd, source: .aniSkip)
                let cachedED = makeSegment(kind: .ed, start: cached.edStart, end: cached.edEnd, source: .aniSkip)
                return EpisodeSkipPlan(
                    op: customOP ?? cachedOP,
                    ed: customED ?? cachedED
                )
            }
        }

        guard episodeNumber > 0 else {
            return EpisodeSkipPlan(op: customOP, ed: customED)
        }

        // 3. Resolve MAL ID for subjectID
        guard let malID = await resolveMalID(
            subjectID: subjectID,
            fallbackTitle: sessionTitle,
            database: database
        ) else {
            print("[AniSkip] Could not resolve MAL ID for bgm subject \(subjectID)")
            return EpisodeSkipPlan(op: customOP, ed: customED)
        }

        // 4. Query AniSkip v2 API
        let fetched = await fetchAniSkipTimes(
            malID: malID,
            episodeNumber: episodeNumber,
            episodeDurationSeconds: episodeDurationSeconds
        )

        let entry = CachedAniSkipEntry(
            subjectID: subjectID,
            episodeNumber: episodeNumber,
            opStart: fetched.op?.startTime,
            opEnd: fetched.op?.endTime,
            edStart: fetched.ed?.startTime,
            edEnd: fetched.ed?.endTime,
            found: fetched.op != nil || fetched.ed != nil,
            fetchedAt: now
        )
        try? await AniTVDatabase.upsertAniSkipEntry(entry, in: database)

        return EpisodeSkipPlan(
            op: customOP ?? fetched.op,
            ed: customED ?? fetched.ed
        )
    }

    // MARK: - MAL ID Resolution

    private func resolveMalID(
        subjectID: Int,
        fallbackTitle: String,
        database: any DatabaseWriter
    ) async -> Int? {
        if let cached = try? await AniTVDatabase.cachedMalID(forSubjectID: subjectID, in: database),
           cached > 0 {
            return cached
        }

        let localInfo = try? await AniTVDatabase.bangumiMalLookupInfo(
            forBangumiID: String(subjectID),
            in: database
        )
        if let directMalID = localInfo?.malID, directMalID > 0 {
            try? await AniTVDatabase.upsertMalID(directMalID, forSubjectID: subjectID, in: database)
            return directMalID
        }

        var originalTitle = localInfo?.originalTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var airYear = extractYear(from: localInfo?.beginDate)

        if originalTitle.isEmpty {
            if let subject = try? await BangumiRepository().getSubject(subjectID: subjectID) {
                originalTitle = subject.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if airYear == nil {
                    airYear = extractYear(from: subject.date)
                }
            }
        }

        let searchQuery = !originalTitle.isEmpty ? originalTitle : fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchQuery.isEmpty else { return nil }

        if let anilistMalID = await lookupMalIDViaAniList(query: searchQuery, expectedYear: airYear) {
            try? await AniTVDatabase.upsertMalID(anilistMalID, forSubjectID: subjectID, in: database)
            print("[AniSkip] Resolved bgm \(subjectID) -> mal \(anilistMalID) via AniList")
            return anilistMalID
        }

        if let jikanMalID = await lookupMalIDViaJikan(query: searchQuery, expectedYear: airYear) {
            try? await AniTVDatabase.upsertMalID(jikanMalID, forSubjectID: subjectID, in: database)
            print("[AniSkip] Resolved bgm \(subjectID) -> mal \(jikanMalID) via Jikan")
            return jikanMalID
        }

        return nil
    }

    private func lookupMalIDViaAniList(query: String, expectedYear: Int?) async -> Int? {
        guard let url = URL(string: "https://graphql.anilist.co") else { return nil }
        let graphQL = """
        query ($search: String) {
          Page(page: 1, perPage: 6) {
            media(search: $search, type: ANIME) {
              idMal
              startDate { year }
              title { native romaji english }
            }
          }
        }
        """

        struct RequestBody: Encodable {
            let query: String
            let variables: [String: String]
        }
        struct ResponseBody: Decodable {
            struct DataBox: Decodable {
                struct Page: Decodable {
                    struct Media: Decodable {
                        struct StartDate: Decodable { let year: Int? }
                        struct Title: Decodable {
                            let native: String?
                            let romaji: String?
                            let english: String?
                        }
                        let idMal: Int?
                        let startDate: StartDate?
                        let title: Title?
                    }
                    let media: [Media]
                }
                let Page: Page
            }
            let data: DataBox?
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(
            RequestBody(query: graphQL, variables: ["search": query])
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return nil
            }
            let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
            let candidates = decoded.data?.Page.media.filter { ($0.idMal ?? 0) > 0 } ?? []
            guard !candidates.isEmpty else { return nil }

            let normalizedQuery = normalizeTitle(query)

            // 1. Exact native title match (with year preference)
            let exactNative = candidates.filter { normalizeTitle($0.title?.native ?? "") == normalizedQuery }
            if let year = expectedYear,
               let match = exactNative.first(where: { $0.startDate?.year == year }) {
                return match.idMal
            }
            if let match = exactNative.first {
                return match.idMal
            }

            // 2. Year match among top search results
            if let year = expectedYear,
               let match = candidates.first(where: { $0.startDate?.year == year }) {
                return match.idMal
            }

            return candidates.first?.idMal
        } catch {
            print("[AniSkip] AniList lookup failed for '\(query)': \(error.localizedDescription)")
            return nil
        }
    }

    private func lookupMalIDViaJikan(query: String, expectedYear: Int?) async -> Int? {
        var components = URLComponents(string: "https://api.jikan.moe/v4/anime")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components?.url else { return nil }

        struct JikanResponse: Decodable {
            struct Item: Decodable {
                let mal_id: Int
                let title: String?
                let title_japanese: String?
                let year: Int?
            }
            let data: [Item]
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return nil
            }
            let decoded = try JSONDecoder().decode(JikanResponse.self, from: data)
            let normalizedQuery = normalizeTitle(query)

            if let exact = decoded.data.first(where: {
                normalizeTitle($0.title_japanese ?? "") == normalizedQuery
            }) {
                return exact.mal_id
            }
            if let year = expectedYear,
               let yearMatch = decoded.data.first(where: { $0.year == year }) {
                return yearMatch.mal_id
            }
            return decoded.data.first?.mal_id
        } catch {
            print("[AniSkip] Jikan lookup failed for '\(query)': \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - AniSkip API v2

    private func fetchAniSkipTimes(
        malID: Int,
        episodeNumber: Int,
        episodeDurationSeconds: Int
    ) async -> (op: SkipSegment?, ed: SkipSegment?) {
        var components = URLComponents(string: "https://api.aniskip.com/v2/skip-times/\(malID)/\(episodeNumber)")
        components?.queryItems = [
            URLQueryItem(name: "types", value: "op"),
            URLQueryItem(name: "types", value: "ed"),
            URLQueryItem(name: "types", value: "mixed-op"),
            URLQueryItem(name: "types", value: "mixed-ed"),
            URLQueryItem(name: "episodeLength", value: String(max(0, episodeDurationSeconds)))
        ]

        guard let url = components?.url else { return (nil, nil) }

        struct AniSkipResponse: Decodable {
            struct ResultItem: Decodable {
                struct Interval: Decodable {
                    let startTime: Double
                    let endTime: Double
                }
                let interval: Interval
                let skipType: String
            }
            let found: Bool
            let results: [ResultItem]?
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(APIConfig.userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return (nil, nil) }
            if http.statusCode == 404 {
                print("[AniSkip] No skip times found for mal=\(malID) ep=\(episodeNumber)")
                return (nil, nil)
            }
            guard 200..<300 ~= http.statusCode else { return (nil, nil) }

            let decoded = try JSONDecoder().decode(AniSkipResponse.self, from: data)
            guard decoded.found, let results = decoded.results else { return (nil, nil) }

            var opSegment: SkipSegment?
            var edSegment: SkipSegment?

            for item in results {
                let start = item.interval.startTime
                let end = item.interval.endTime
                switch item.skipType {
                case "op":
                    let seg = SkipSegment(kind: .op, startTime: start, endTime: end, source: .aniSkip)
                    if seg.isValid { opSegment = seg }
                case "mixed-op":
                    if opSegment == nil {
                        let seg = SkipSegment(kind: .op, startTime: start, endTime: end, source: .aniSkip)
                        if seg.isValid { opSegment = seg }
                    }
                case "ed":
                    let seg = SkipSegment(kind: .ed, startTime: start, endTime: end, source: .aniSkip)
                    if seg.isValid { edSegment = seg }
                case "mixed-ed":
                    if edSegment == nil {
                        let seg = SkipSegment(kind: .ed, startTime: start, endTime: end, source: .aniSkip)
                        if seg.isValid { edSegment = seg }
                    }
                default:
                    break
                }
            }

            print("[AniSkip] Loaded skip times for mal=\(malID) ep=\(episodeNumber): op=\(String(describing: opSegment)), ed=\(String(describing: edSegment))")
            return (opSegment, edSegment)
        } catch {
            print("[AniSkip] Failed to fetch skip times for mal=\(malID) ep=\(episodeNumber): \(error.localizedDescription)")
            return (nil, nil)
        }
    }

    private func makeSegment(
        kind: SkipSegmentKind,
        start: Double?,
        end: Double?,
        source: SkipSegmentSource
    ) -> SkipSegment? {
        guard let start, let end else { return nil }
        let segment = SkipSegment(kind: kind, startTime: start, endTime: end, source: source)
        return segment.isValid ? segment : nil
    }

    private func extractYear(from dateString: String?) -> Int? {
        guard let dateString else { return nil }
        let prefix = String(dateString.prefix(4))
        guard prefix.count == 4, let year = Int(prefix), year >= 1950, year <= 2100 else {
            return nil
        }
        return year
    }

    private func normalizeTitle(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .joined()
    }
}
