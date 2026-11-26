//
//  TimelineService.swift
//  AniTV
//
//  Created by Codex on 2026/4/9.
//

import Foundation
import SQLiteData

typealias TimelineDayMap = [String: [TimelineEpisodeEntry]]

struct TimelineEpisodeEntry: Identifiable, Codable, Sendable {
    let dateKey: String
    let airingTimestamp: Int
    let anilistID: Int?
    let bangumiID: String?
    let subjectTitle: String
    let subjectTitleCN: String?
    let episodeID: Int?
    let episodeSort: Double?
    let episodeName: String?
    let episodeNameCN: String?
    let coverImageURL: String?
    let isAniListMissing: Bool

    var id: String {
        let bangumiPart = bangumiID ?? "nil"
        let aniListPart = anilistID.map { String($0) } ?? "nil"
        let episodePart = episodeID.map { String($0) } ?? "nil"
        let sortPart = String(episodeSort ?? -1)
        let timestampPart = String(airingTimestamp)

        return [
            bangumiPart,
            aniListPart,
            episodePart,
            sortPart,
            dateKey,
            timestampPart
        ].joined(separator: ":")
    }
}

struct TimelineService: Sendable {
    private let bangumiRepository = BangumiRepository()
    private let anilistClient = AniListTimelineClient()

    func fetchTimelineMap(
        database: any DatabaseWriter,
        now: Date = Date(),
        daysBefore: Int = 7,
        daysAfter: Int = 7
    ) async throws -> TimelineDayMap {
        let calendar = TimelineCalendar.make()
        let window = TimelineWindow(calendar: calendar, now: now, daysBefore: daysBefore, daysAfter: daysAfter)
        let bangumiDataVersion = try await AniTVDatabase.storedBangumiDataVersion(in: database) ?? "unknown"
        let cacheKey = TimelineCacheKey.make(
            calendar: calendar,
            now: now,
            daysBefore: daysBefore,
            daysAfter: daysAfter,
            bangumiDataVersion: bangumiDataVersion
        )

        if let cachedMap = try await AniTVDatabase.cachedTimelineMap(
            cacheKey: cacheKey,
            maxAge: 3_600,
            in: database
        ) {
            return cachedMap
        }

        let fetchedAniListItems = try await anilistClient.fetchTimeline(window: window)
        let bangumiRows = try await AniTVDatabase.fetchAllBangumiDataRows(in: database)

        let prepared = await Task.detached(priority: .userInitiated) {
            let bangumiIndex = TimelineBangumiDataIndex(rows: bangumiRows, now: now)
            let resolvedAniListItems = bangumiIndex.resolveAniListItems(fetchedAniListItems)
            TimelineLogger.logDroppedAniListItems(resolvedAniListItems.droppedItems)

            let missingItems = bangumiIndex.findMissingItems(
                excluding: Set(resolvedAniListItems.items.map(\.titleYearKey)),
                withinLastDays: 365,
                excludingBangumiIDs: Set(resolvedAniListItems.items.compactMap(\.bangumiID))
            )

            let subjectNeeds = TimelineSubjectNeeds(
                aniListItems: resolvedAniListItems.items,
                missingItems: missingItems,
                bangumiIndex: bangumiIndex
            )
            let exactAiringHints = TimelineExactAiringHints(
                aniListItems: resolvedAniListItems.items,
                bangumiIndex: bangumiIndex
            )
            return (bangumiIndex, resolvedAniListItems, missingItems, subjectNeeds, exactAiringHints)
        }.value

        let (bangumiIndex, resolvedAniListItems, missingItems, subjectNeeds, exactAiringHints) = prepared

        let subjectCacheRows = try await AniTVDatabase.fetchAllTimelineBangumiSubjectCaches(in: database)
        let episodeCacheRows = try await AniTVDatabase.fetchAllTimelineBangumiEpisodeCaches(in: database)
        let cacheAnalysis = await Task.detached(priority: .userInitiated) {
            let cacheState = TimelineCacheState(
                subjectRows: subjectCacheRows,
                episodeRows: episodeCacheRows,
                now: now,
                window: window
            )
            let subjectIDsToFetch = cacheState.subjectIDsNeedingRefresh(for: subjectNeeds)
            return (cacheState.subjectByBangumiID, cacheState.episodesByBangumiID, subjectIDsToFetch)
        }.value

        var mergedSubjectCache = cacheAnalysis.0
        var mergedEpisodeCache = cacheAnalysis.1
        let subjectIDsToFetch = cacheAnalysis.2

        if !subjectIDsToFetch.isEmpty {
            let fetchedSubjects = try await bangumiRepository.fetchTimelineSubjectDetails(
                subjectIDs: subjectIDsToFetch.compactMap(Int.init)
            )
            let cachePayload = await Task.detached(priority: .userInitiated) {
                TimelineCachePayloadBuilder.build(
                    subjects: fetchedSubjects,
                    now: now,
                    exactAiringHints: exactAiringHints
                )
            }.value

            try await AniTVDatabase.upsertTimelineBangumiSubjectCaches(cachePayload.subjectRows, in: database)
            try await AniTVDatabase.upsertTimelineBangumiEpisodeCaches(cachePayload.episodeRows, in: database)

            mergedSubjectCache.merge(cachePayload.subjectMap, uniquingKeysWith: { _, new in new })
            for (bangumiID, rows) in cachePayload.episodeMap {
                mergedEpisodeCache[bangumiID] = rows
            }
        }

        let finalSubjects = mergedSubjectCache
        let finalEpisodes = mergedEpisodeCache
        let builtMap = await Task.detached(priority: .userInitiated) {
            TimelineMapBuilder.build(
                aniListItems: resolvedAniListItems.items,
                missingItems: missingItems,
                bangumiIndex: bangumiIndex,
                subjects: finalSubjects,
                episodesByBangumiID: finalEpisodes,
                window: window
            )
        }.value

        try await AniTVDatabase.upsertTimelineMapCache(
            cacheKey: cacheKey,
            map: builtMap,
            in: database
        )

        return builtMap
    }
}

private enum TimelineCalendar {
    nonisolated static func make() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}

private enum TimelineCacheKey {
    nonisolated static func make(
        calendar: Calendar,
        now: Date,
        daysBefore: Int,
        daysAfter: Int,
        bangumiDataVersion: String
    ) -> String {
        let dayKey = now.timelineDayKey(calendar: calendar)
        return "timeline:\(dayKey):\(daysBefore):\(daysAfter):\(bangumiDataVersion)"
    }
}

private struct TimelineWindow: Sendable {
    let calendar: Calendar
    let now: Date
    let start: Date
    let end: Date

    nonisolated init(calendar: Calendar, now: Date, daysBefore: Int, daysAfter: Int) {
        self.calendar = calendar
        self.now = now
        let startCandidate = calendar.date(byAdding: .day, value: -daysBefore, to: now) ?? now
        let endCandidate = calendar.date(byAdding: .day, value: daysAfter, to: now) ?? now
        let dayStart = calendar.startOfDay(for: startCandidate)
        let nextDayStart = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: endCandidate)
        ) ?? endCandidate

        self.start = dayStart
        self.end = nextDayStart.addingTimeInterval(-1)
    }

    nonisolated func contains(_ date: Date) -> Bool {
        start ... end ~= date
    }

    nonisolated func contains(dateString: String) -> Bool {
        guard let date = calendar.timelineDate(from: dateString) else { return false }
        return contains(date)
    }

    nonisolated func dayKey(for date: Date) -> String {
        date.timelineDayKey(calendar: calendar)
    }
}

private struct AniListTimelineClient: Sendable {
    func fetchTimeline(window: TimelineWindow) async throws -> [AniListTimelineItem] {
        let query = """
        query ($page: Int!, $perPage: Int!, $from: Int!, $to: Int!) {
          Page(page: $page, perPage: $perPage) {
            pageInfo {
              currentPage
              hasNextPage
            }
            airingSchedules(
              airingAt_greater: $from
              airingAt_lesser: $to
              sort: TIME
            ) {
              airingAt
              episode
              media {
                id
                seasonYear
                title {
                  native
                }
                coverImage {
                  large
                }
              }
            }
          }
        }
        """

        var page = 1
        var result: [AniListTimelineItem] = []

        while true {
            let body = AniListGraphQLBody(
                query: query,
                variables: [
                    "page": page,
                    "perPage": 100,
                    "from": Int(window.start.timeIntervalSince1970),
                    "to": Int(window.end.timeIntervalSince1970)
                ]
            )

            var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("https://anilist.co", forHTTPHeaderField: "Origin")
            request.setValue("https://anilist.co/", forHTTPHeaderField: "Referer")
            request.httpBody = try JSONEncoder().encode(body)

            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw NetworkError.badServerResponse(statusCode: httpResponse.statusCode)
            }

            let decoded = try JSONDecoder().decode(AniListGraphQLResponse.self, from: data)
            if let errors = decoded.errors, !errors.isEmpty {
                throw ChiiError(message: errors.map(\.message).joined(separator: "\n"))
            }

            guard let pageData = decoded.data?.page else { break }
            result.append(contentsOf: pageData.airingSchedules.compactMap {
                AniListTimelineItem(schedule: $0, calendar: window.calendar)
            })

            guard pageData.pageInfo.hasNextPage else { break }
            page += 1
        }

        return result
    }
}

private struct AniListGraphQLBody: Encodable {
    let query: String
    let variables: [String: Int]
}

private struct AniListGraphQLResponse: Decodable {
    let data: AniListPageContainer?
    let errors: [BangumiGraphQLError]?
}

private struct AniListPageContainer: Decodable {
    let page: AniListPage

    enum CodingKeys: String, CodingKey {
        case page = "Page"
    }
}

private struct AniListPage: Decodable {
    let pageInfo: AniListPageInfo
    let airingSchedules: [AniListAiringSchedule]
}

private struct AniListPageInfo: Decodable {
    let currentPage: Int
    let hasNextPage: Bool
}

private struct AniListAiringSchedule: Decodable {
    let airingAt: Int
    let episode: Int
    let media: AniListMedia
}

private struct AniListMedia: Decodable {
    let id: Int
    let seasonYear: Int?
    let title: AniListMediaTitle
    let coverImage: AniListCoverImage?
}

private struct AniListMediaTitle: Decodable {
    let native: String?
}

private struct AniListCoverImage: Decodable {
    let large: String?
}

private struct AniListTimelineItem: Sendable {
    let anilistID: Int
    let subjectTitle: String
    let seasonYear: Int
    let airingAt: Int
    let episode: Int
    let dateKey: String
    let coverImageURL: String?
    let bangumiID: String?

    init?(schedule: AniListAiringSchedule, calendar: Calendar) {
        let subjectTitle = schedule.media.title.native?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !subjectTitle.isEmpty else { return nil }

        let date = Date(timeIntervalSince1970: TimeInterval(schedule.airingAt))
        self.anilistID = schedule.media.id
        self.subjectTitle = subjectTitle
        self.seasonYear = schedule.media.seasonYear ?? calendar.component(.year, from: date)
        self.airingAt = schedule.airingAt
        self.episode = schedule.episode
        self.dateKey = date.timelineDayKey(calendar: calendar)
        self.coverImageURL = schedule.media.coverImage?.large
        self.bangumiID = nil
    }

    nonisolated var titleYearKey: String {
        "\(subjectTitle)#\(seasonYear)"
    }

    nonisolated func withBangumiID(_ bangumiID: String) -> AniListTimelineItem {
        AniListTimelineItem(
            anilistID: anilistID,
            subjectTitle: subjectTitle,
            seasonYear: seasonYear,
            airingAt: airingAt,
            episode: episode,
            dateKey: dateKey,
            coverImageURL: coverImageURL,
            bangumiID: bangumiID
        )
    }

    private nonisolated init(
        anilistID: Int,
        subjectTitle: String,
        seasonYear: Int,
        airingAt: Int,
        episode: Int,
        dateKey: String,
        coverImageURL: String?,
        bangumiID: String?
    ) {
        self.anilistID = anilistID
        self.subjectTitle = subjectTitle
        self.seasonYear = seasonYear
        self.airingAt = airingAt
        self.episode = episode
        self.dateKey = dateKey
        self.coverImageURL = coverImageURL
        self.bangumiID = bangumiID
    }
}

struct TimelineBangumiDataRow: Decodable, Sendable {
    let bangumiID: String
    let title: String
    let titleTranslate: String
    let type: String
    let lang: String
    let begin: String
    let broadcast: String
    let end: String
    let sites: String

    enum CodingKeys: String, CodingKey {
        case bangumiID = "bangumi_id"
        case title
        case titleTranslate = "title_translate"
        case type
        case lang
        case begin
        case broadcast
        case end
        case sites
    }
}

struct TimelineBangumiSubjectCacheRow: Decodable, Sendable {
    let bangumiID: String
    let name: String
    let nameCN: String
    let imagesJSON: String
    let isComplete: Bool
    let updatedAt: Int

    enum CodingKeys: String, CodingKey {
        case bangumiID = "bangumi_id"
        case name
        case nameCN = "name_cn"
        case imagesJSON = "images_json"
        case isComplete = "is_complete"
        case updatedAt = "updated_at"
    }
}

struct TimelineBangumiEpisodeCacheRow: Decodable, Sendable {
    let episodeID: Int
    let bangumiID: String
    let airdate: String
    let name: String
    let nameCN: String
    let sort: Double
    let expiresAt: Int?
    let cachedAt: Int

    enum CodingKeys: String, CodingKey {
        case episodeID = "episode_id"
        case bangumiID = "bangumi_id"
        case airdate
        case name
        case nameCN = "name_cn"
        case sort
        case expiresAt = "expires_at"
        case cachedAt = "cached_at"
    }
}

private struct TimelineBangumiItem: Sendable {
    let bangumiID: String?
    let aniListID: Int?
    let title: String
    let beginDate: Date?
    let beginYear: Int?
    let type: String
}

private struct TimelineMissingBangumiItem: Sendable {
    let bangumiID: String
    let title: String
    let beginDate: Date?
    let beginYear: Int
}

private struct TimelineBangumiDataIndex: Sendable {
    let aniListToBangumi: [Int: TimelineBangumiItem]
    let missingAniListItems: [TimelineBangumiItem]
    let itemsByNormalizedTitle: [String: [TimelineBangumiItem]]
    let now: Date

    nonisolated init(rows: [TimelineBangumiDataRow], now: Date) {
        var aniListToBangumi: [Int: TimelineBangumiItem] = [:]
        var missingAniListItems: [TimelineBangumiItem] = []
        var itemsByNormalizedTitle: [String: [TimelineBangumiItem]] = [:]
        let calendar = Calendar.current
        let decoder = JSONDecoder()

        for row in rows {
            let beginDate = TimelineParser.parseISO8601(row.begin)
            let beginYear = beginDate.map { calendar.component(.year, from: $0) }
            let item = TimelineBangumiItem(
                bangumiID: row.bangumiID.isEmpty ? nil : row.bangumiID,
                aniListID: TimelineParser.extractSiteID(named: "aniList", from: row.sites, decoder: decoder).flatMap(Int.init),
                title: row.title,
                beginDate: beginDate,
                beginYear: beginYear,
                type: row.type
            )
            let normalizedTitle = TimelineParser.normalizedTitle(item.title)
            if !normalizedTitle.isEmpty {
                itemsByNormalizedTitle[normalizedTitle, default: []].append(item)
            }

            if let aniListID = item.aniListID {
                aniListToBangumi[aniListID] = item
            } else {
                missingAniListItems.append(item)
            }
        }

        self.aniListToBangumi = aniListToBangumi
        self.missingAniListItems = missingAniListItems
        self.itemsByNormalizedTitle = itemsByNormalizedTitle
        self.now = now
    }

    nonisolated func bangumiItem(for aniListID: Int) -> TimelineBangumiItem? {
        aniListToBangumi[aniListID]
    }

    nonisolated func resolveAniListItems(_ items: [AniListTimelineItem]) -> TimelineResolvedAniListItems {
        let currentYear = Calendar.current.component(.year, from: now)
        let allowedYears = (currentYear - 1)...(currentYear + 1)

        var keptItems: [AniListTimelineItem] = []
        var droppedItems: [TimelineDroppedAniListItem] = []

        for item in items {
            if let mapped = bangumiItem(for: item.anilistID)?.bangumiID {
                keptItems.append(item.withBangumiID(mapped))
                continue
            }

            let normalizedTitle = TimelineParser.normalizedTitle(item.subjectTitle)
            let titleMatches = itemsByNormalizedTitle[normalizedTitle, default: []].filter { candidate in
                guard let bangumiID = candidate.bangumiID,
                      !bangumiID.isEmpty,
                      let beginYear = candidate.beginYear,
                      ["tv", "web"].contains(candidate.type.lowercased()) else {
                    return false
                }
                return allowedYears.contains(beginYear)
            }

            if let resolvedBangumiID = titleMatches
                .sorted(by: { lhs, rhs in
                    let lhsDistance = abs((lhs.beginYear ?? currentYear) - item.seasonYear)
                    let rhsDistance = abs((rhs.beginYear ?? currentYear) - item.seasonYear)
                    if lhsDistance == rhsDistance {
                        return (lhs.bangumiID ?? "") < (rhs.bangumiID ?? "")
                    }
                    return lhsDistance < rhsDistance
                })
                .first?.bangumiID {
                keptItems.append(item.withBangumiID(resolvedBangumiID))
            } else {
                droppedItems.append(
                    TimelineDroppedAniListItem(
                        title: item.subjectTitle,
                        seasonYear: item.seasonYear,
                        episode: item.episode,
                        airingAt: item.airingAt
                    )
                )
            }
        }

        return TimelineResolvedAniListItems(items: keptItems, droppedItems: droppedItems)
    }

    nonisolated func findMissingItems(
        excluding keys: Set<String>,
        withinLastDays days: Int,
        excludingBangumiIDs: Set<String>
    ) -> [TimelineMissingBangumiItem] {
        let cutoff = now.addingTimeInterval(-TimeInterval(days * 86_400))
        return missingAniListItems.compactMap { item in
            guard let bangumiID = item.bangumiID,
                  ["tv", "web"].contains(item.type.lowercased()),
                  let beginYear = item.beginYear else {
                return nil
            }
            guard !excludingBangumiIDs.contains(bangumiID) else {
                return nil
            }
            if let beginDate = item.beginDate, beginDate < cutoff {
                return nil
            }
            let key = "\(item.title)#\(beginYear)"
            guard !keys.contains(key) else { return nil }
            return TimelineMissingBangumiItem(
                bangumiID: bangumiID,
                title: item.title,
                beginDate: item.beginDate,
                beginYear: beginYear
            )
        }
    }
}

private struct TimelineResolvedAniListItems: Sendable {
    let items: [AniListTimelineItem]
    let droppedItems: [TimelineDroppedAniListItem]
}

private struct TimelineDroppedAniListItem: Sendable {
    let title: String
    let seasonYear: Int
    let episode: Int
    let airingAt: Int
}

private struct TimelineSubjectNeeds: Sendable {
    let mappedEpisodesByBangumiID: [String: Set<Int>]
    let missingBangumiItems: [TimelineMissingBangumiItem]

    nonisolated init(
        aniListItems: [AniListTimelineItem],
        missingItems: [TimelineMissingBangumiItem],
        bangumiIndex: TimelineBangumiDataIndex
    ) {
        var mapped: [String: Set<Int>] = [:]
        for item in aniListItems {
            guard let bangumiID = item.bangumiID else { continue }
            mapped[bangumiID, default: []].insert(item.episode)
        }
        self.mappedEpisodesByBangumiID = mapped
        self.missingBangumiItems = missingItems
    }
}

private struct TimelineExactAiringHints: Sendable {
    let timestampsByBangumiIDAndEpisode: [String: [Int: Int]]

    nonisolated init(aniListItems: [AniListTimelineItem], bangumiIndex: TimelineBangumiDataIndex) {
        var result: [String: [Int: Int]] = [:]
        for item in aniListItems {
            guard let bangumiID = item.bangumiID else { continue }
            result[bangumiID, default: [:]][item.episode] = item.airingAt
        }
        self.timestampsByBangumiIDAndEpisode = result
    }
}

private struct TimelineCacheState: Sendable {
    let subjectByBangumiID: [String: TimelineBangumiSubjectCacheRow]
    let episodesByBangumiID: [String: [TimelineBangumiEpisodeCacheRow]]
    let nowTimestamp: Int
    let window: TimelineWindow

    nonisolated init(
        subjectRows: [TimelineBangumiSubjectCacheRow],
        episodeRows: [TimelineBangumiEpisodeCacheRow],
        now: Date,
        window: TimelineWindow
    ) {
        self.subjectByBangumiID = Dictionary(uniqueKeysWithValues: subjectRows.map { ($0.bangumiID, $0) })
        self.episodesByBangumiID = Dictionary(grouping: episodeRows, by: \.bangumiID)
        self.nowTimestamp = Int(now.timeIntervalSince1970)
        self.window = window
    }

    nonisolated func subjectIDsNeedingRefresh(for needs: TimelineSubjectNeeds) -> [String] {
        var required: Set<String> = []

        for (bangumiID, episodes) in needs.mappedEpisodesByBangumiID {
            guard let subject = subjectByBangumiID[bangumiID], subject.isComplete else {
                required.insert(bangumiID)
                continue
            }

            let episodeRows = episodesByBangumiID[bangumiID] ?? []
            for episode in episodes {
                guard let row = episodeRows.first(where: { TimelineParser.matches(sort: $0.sort, episodeNumber: episode) }),
                      row.isValid(at: nowTimestamp) else {
                    required.insert(bangumiID)
                    break
                }
            }
        }

        for item in needs.missingBangumiItems {
            guard let subject = subjectByBangumiID[item.bangumiID], subject.isComplete else {
                required.insert(item.bangumiID)
                continue
            }

            let episodeRows = episodesByBangumiID[item.bangumiID] ?? []
            let hasWindowEpisode = episodeRows.contains { row in
                row.isValid(at: nowTimestamp) && window.contains(dateString: row.airdate)
            }
            if !hasWindowEpisode {
                required.insert(item.bangumiID)
            }
        }

        return Array(required).sorted()
    }
}

private struct TimelineCachePayloadBuilder {
    nonisolated static func build(
        subjects: [Int: BangumiGraphQLTimelineSubjectNode],
        now: Date,
        exactAiringHints: TimelineExactAiringHints
    ) -> (
        subjectRows: [TimelineBangumiSubjectCacheRow],
        episodeRows: [TimelineBangumiEpisodeCacheRow],
        subjectMap: [String: TimelineBangumiSubjectCacheRow],
        episodeMap: [String: [TimelineBangumiEpisodeCacheRow]]
    ) {
        let encoder = JSONEncoder()
        let nowTimestamp = Int(now.timeIntervalSince1970)
        let maxExpiryTimestamp = nowTimestamp + 2 * 86_400
        let calendar = TimelineCalendar.make()

        var subjectRows: [TimelineBangumiSubjectCacheRow] = []
        var episodeRows: [TimelineBangumiEpisodeCacheRow] = []
        var subjectMap: [String: TimelineBangumiSubjectCacheRow] = [:]
        var episodeMap: [String: [TimelineBangumiEpisodeCacheRow]] = [:]

        for subject in subjects.values {
            let bangumiID = String(subject.id)
            let imagesJSON = (try? encoder.encode(subject.images)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let isComplete = !subject.name.isEmpty
                && !subject.nameCN.isEmpty
                && !subject.images.large.isEmpty
                && !subject.images.common.isEmpty
                && !subject.images.medium.isEmpty
                && !subject.images.small.isEmpty
                && !subject.images.grid.isEmpty

            let subjectRow = TimelineBangumiSubjectCacheRow(
                bangumiID: bangumiID,
                name: subject.name,
                nameCN: subject.nameCN,
                imagesJSON: imagesJSON,
                isComplete: isComplete,
                updatedAt: nowTimestamp
            )
            subjectRows.append(subjectRow)
            subjectMap[bangumiID] = subjectRow

            let exactHints = exactAiringHints.timestampsByBangumiIDAndEpisode[bangumiID] ?? [:]
            let mappedEpisodes = subject.episodes.map { episode -> TimelineBangumiEpisodeCacheRow in
                let expiresAt = computeEpisodeExpiry(
                    episode: episode,
                    exactAiringAt: exactHints[Int(episode.sort.rounded())],
                    nowTimestamp: nowTimestamp,
                    maxExpiryTimestamp: maxExpiryTimestamp,
                    calendar: calendar
                )
                return TimelineBangumiEpisodeCacheRow(
                    episodeID: episode.id,
                    bangumiID: bangumiID,
                    airdate: episode.airdate,
                    name: episode.name,
                    nameCN: episode.nameCN,
                    sort: episode.sort,
                    expiresAt: expiresAt,
                    cachedAt: nowTimestamp
                )
            }
            episodeRows.append(contentsOf: mappedEpisodes)
            episodeMap[bangumiID] = mappedEpisodes
        }

        return (subjectRows, episodeRows, subjectMap, episodeMap)
    }

    private nonisolated static func computeEpisodeExpiry(
        episode: BangumiGraphQLTimelineEpisodeNode,
        exactAiringAt: Int?,
        nowTimestamp: Int,
        maxExpiryTimestamp: Int,
        calendar: Calendar
    ) -> Int? {
        if let exactAiringAt {
            if exactAiringAt <= nowTimestamp {
                return nil
            }
            return min(exactAiringAt + 12 * 3_600, maxExpiryTimestamp)
        }

        guard let airdate = calendar.timelineDate(from: episode.airdate) else {
            return maxExpiryTimestamp
        }

        let todayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(nowTimestamp)))
        if airdate < todayStart {
            return nil
        }

        let dayEnd = (calendar.date(byAdding: .day, value: 1, to: airdate) ?? airdate)
            .addingTimeInterval(-1)
        return min(Int(dayEnd.timeIntervalSince1970) + 12 * 3_600, maxExpiryTimestamp)
    }
}

private enum TimelineMapBuilder {
    nonisolated static func build(
        aniListItems: [AniListTimelineItem],
        missingItems: [TimelineMissingBangumiItem],
        bangumiIndex: TimelineBangumiDataIndex,
        subjects: [String: TimelineBangumiSubjectCacheRow],
        episodesByBangumiID: [String: [TimelineBangumiEpisodeCacheRow]],
        window: TimelineWindow
    ) -> TimelineDayMap {
        var map: TimelineDayMap = [:]
        let nowTimestamp = Int(window.now.timeIntervalSince1970)
        let decoder = JSONDecoder()
        var decodedImageURLBySubjectID: [String: String?] = [:]
        decodedImageURLBySubjectID.reserveCapacity(subjects.count)

        func resolvedImageURL(for bangumiID: String, subjectRow: TimelineBangumiSubjectCacheRow) -> String? {
            if let cached = decodedImageURLBySubjectID[bangumiID] {
                return cached
            }
            let url = subjectRow.decodedImageURL(using: decoder)
            decodedImageURLBySubjectID[bangumiID] = url
            return url
        }

        for item in aniListItems {
            let bangumiID = item.bangumiID
            let subjectRow = bangumiID.flatMap { subjects[$0] }
            let episodeRow = bangumiID.flatMap { bangumiID in
                episodesByBangumiID[bangumiID]?.first(where: {
                    $0.isValid(at: nowTimestamp) && TimelineParser.matches(sort: $0.sort, episodeNumber: item.episode)
                })
            }
            let subjectImageURL: String? = if let bangumiID, let subjectRow {
                resolvedImageURL(for: bangumiID, subjectRow: subjectRow)
            } else {
                nil
            }

            let entry = TimelineEpisodeEntry(
                dateKey: item.dateKey,
                airingTimestamp: item.airingAt,
                anilistID: item.anilistID,
                bangumiID: bangumiID,
                subjectTitle: subjectRow?.name.isEmpty == false ? subjectRow!.name : item.subjectTitle,
                subjectTitleCN: subjectRow?.nameCN,
                episodeID: episodeRow?.episodeID,
                episodeSort: episodeRow?.sort ?? Double(item.episode),
                episodeName: episodeRow?.name,
                episodeNameCN: episodeRow?.nameCN,
                coverImageURL: subjectImageURL ?? item.coverImageURL,
                isAniListMissing: false
            )
            map[item.dateKey, default: []].append(entry)
        }

        for item in missingItems {
            guard let subjectRow = subjects[item.bangumiID] else { continue }
            let episodeRows = episodesByBangumiID[item.bangumiID] ?? []
            let subjectImageURL = resolvedImageURL(for: item.bangumiID, subjectRow: subjectRow)

            for episodeRow in episodeRows
            where episodeRow.isValid(at: nowTimestamp) && window.contains(dateString: episodeRow.airdate) {
                let dateKey = TimelineParser.dayKey(for: episodeRow.airdate, calendar: window.calendar)
                let entry = TimelineEpisodeEntry(
                    dateKey: dateKey,
                    airingTimestamp: Int.max,
                    anilistID: nil,
                    bangumiID: item.bangumiID,
                    subjectTitle: subjectRow.name,
                    subjectTitleCN: subjectRow.nameCN,
                    episodeID: episodeRow.episodeID,
                    episodeSort: episodeRow.sort,
                    episodeName: episodeRow.name,
                    episodeNameCN: episodeRow.nameCN,
                    coverImageURL: subjectImageURL,
                    isAniListMissing: true
                )
                map[dateKey, default: []].append(entry)
            }
        }

        for key in map.keys {
            map[key]?.sort {
                if $0.airingTimestamp == $1.airingTimestamp {
                    return ($0.episodeSort ?? 0) < ($1.episodeSort ?? 0)
                }
                return $0.airingTimestamp < $1.airingTimestamp
            }
        }

        return map
    }
}

private enum TimelineLogger {
    nonisolated static func logDroppedAniListItems(_ items: [TimelineDroppedAniListItem]) {
        guard !items.isEmpty else { return }

        for item in items.sorted(by: {
            if $0.airingAt == $1.airingAt {
                if $0.title == $1.title {
                    return $0.episode < $1.episode
                }
                return $0.title < $1.title
            }
            return $0.airingAt < $1.airingAt
        }) {
            print(
                "[TimelineService] dropped AniList item: title=\(item.title), seasonYear=\(item.seasonYear), episode=\(item.episode), airingAt=\(item.airingAt)"
            )
        }
    }
}

private enum TimelineParser {
    nonisolated static func parseISO8601(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        return TimelineDateFormatterPool.parseISO8601(value)
    }

    nonisolated static func extractSiteID(
        named siteName: String,
        from rawSites: String,
        decoder: JSONDecoder = JSONDecoder()
    ) -> String? {
        guard rawSites.contains(siteName),
              let data = rawSites.data(using: .utf8),
              let sites = try? decoder.decode([BgmDataSite].self, from: data) else {
            return nil
        }
        return sites.first { $0.site == siteName }?.id
    }

    nonisolated static func matches(sort: Double, episodeNumber: Int) -> Bool {
        abs(sort - Double(episodeNumber)) < 0.0001
    }

    nonisolated static func dayKey(for airdate: String, calendar: Calendar) -> String {
        calendar.timelineDate(from: airdate)?.timelineDayKey(calendar: calendar) ?? airdate
    }

    nonisolated static func normalizedTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let filteredScalars = trimmed.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x30...0x39,      // 0-9
                 0x41...0x5A,      // A-Z
                 0x61...0x7A,      // a-z
                 0x3040...0x309F,  // Hiragana
                 0x30A0...0x30FF,  // Katakana
                 0x4E00...0x9FFF:  // CJK Unified Ideographs
                return true
            default:
                return false
            }
        }

        return String(String.UnicodeScalarView(filteredScalars)).lowercased()
    }
}

private extension TimelineBangumiSubjectCacheRow {
    nonisolated func decodedImageURL(using decoder: JSONDecoder) -> String? {
        guard let data = imagesJSON.data(using: .utf8),
              let images = try? decoder.decode(SubjectImages.self, from: data) else {
            return nil
        }
        return images.large.isEmpty ? nil : images.large
    }
}

private extension TimelineBangumiEpisodeCacheRow {
    nonisolated func isValid(at timestamp: Int) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt > timestamp
    }
}

private enum TimelineDateFormatterPool {
    private nonisolated(unsafe) static let lock = NSLock()
    private nonisolated(unsafe) static var dayFormattersByTimeZone: [String: DateFormatter] = [:]
    private nonisolated(unsafe) static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private nonisolated(unsafe) static let isoBasic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated static func parseISO8601(_ value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return isoWithFractional.date(from: value) ?? isoBasic.date(from: value)
    }

    nonisolated static func dayDate(from airdate: String, calendar: Calendar) -> Date? {
        guard !airdate.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return formatter(for: calendar).date(from: airdate)
    }

    nonisolated static func dayKey(for date: Date, calendar: Calendar) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter(for: calendar).string(from: date)
    }

    private nonisolated static func formatter(for calendar: Calendar) -> DateFormatter {
        let key = calendar.timeZone.identifier
        if let existing = dayFormattersByTimeZone[key] {
            return existing
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        dayFormattersByTimeZone[key] = formatter
        return formatter
    }
}

private extension Calendar {
    nonisolated func timelineDate(from airdate: String) -> Date? {
        TimelineDateFormatterPool.dayDate(from: airdate, calendar: self)
    }
}

private extension Date {
    nonisolated func timelineDayKey(calendar: Calendar) -> String {
        TimelineDateFormatterPool.dayKey(for: self, calendar: calendar)
    }
}
