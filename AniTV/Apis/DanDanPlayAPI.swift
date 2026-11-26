//
//  DanDanPlayAPI.swift
//  AniTV
//
//  Open-source danmu_api client (https://github.com/huangxd-/danmu_api),
//  compatible with DanDanPlay v2 API without requiring commercial AppId/AppSecret.
//

import Foundation

enum DanDanPlayError: Error, LocalizedError {
    case notConfigured
    case invalidURL
    case invalidResponse(statusCode: Int?)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "未配置弹幕服务地址，请在「设置 → 播放器与弹幕」中填入 danmu_api 地址"
        case .invalidURL:
            return "无效的弹幕服务地址"
        case .invalidResponse(let code):
            if let code {
                return "弹幕服务响应异常 (HTTP \(code))"
            }
            return "弹幕服务响应异常"
        case .apiError(let message):
            return message
        }
    }
}

final class DanDanPlayAPI {
    static let shared = DanDanPlayAPI()

    private init() {}

    // MARK: - Endpoint Resolution

    /// Builds a `danmu_api` endpoint URL supporting:
    /// - `https://danmu.tdhxnp.com/APTX4869` (token already in path) -> `https://danmu.tdhxnp.com/APTX4869/api/v2/...`
    /// - `http://host:9321` + token `87654321` -> `http://host:9321/87654321/api/v2/...`
    /// - `http://host:9321` + empty token -> `http://host:9321/api/v2/...`
    /// - `https://xxx.vercel.app/APTX4869/api/v2` -> automatically strips duplicate `/api/v2`
    nonisolated static func buildEndpointURL(
        baseURL: String,
        token: String,
        apiPath: String,
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        var root = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }

        if !root.contains("://") {
            root = "http://" + root
        }

        while root.hasSuffix("/") {
            root.removeLast()
        }

        if root.lowercased().hasSuffix("/api/v2") {
            root = String(root.dropLast("/api/v2".count))
        } else if root.lowercased().hasSuffix("/api") {
            root = String(root.dropLast("/api".count))
        }

        while root.hasSuffix("/") {
            root.removeLast()
        }

        let trimmedToken = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let existingPath = URLComponents(string: root)?
            .path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""

        var fullRoot = root
        // Only append token when the base URL doesn't already carry a token/path prefix
        if !trimmedToken.isEmpty && existingPath.isEmpty {
            fullRoot += "/\(trimmedToken)"
        }

        let cleanPath = apiPath.hasPrefix("/") ? apiPath : "/\(apiPath)"
        let fullURLString = "\(fullRoot)/api/v2\(cleanPath)"

        guard var components = URLComponents(string: fullURLString) else {
            return nil
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url
    }

    private func currentServerConfig() throws -> (baseURL: String, token: String) {
        let baseURL = AniTVDatabase.resolvedDanmuApiBaseURL()
        let token = AniTVDatabase.resolvedDanmuApiToken()
        guard !baseURL.isEmpty else {
            throw DanDanPlayError.notConfigured
        }
        return (baseURL, token)
    }

    private func makeJSONRequest(
        url: URL,
        method: String = "GET",
        body: Data? = nil,
        timeout: TimeInterval = 45
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AniTV/0.2.1", forHTTPHeaderField: "User-Agent")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    // MARK: - Connection Test (Settings)

    func testConnection(baseURL: String, token: String) async -> Result<String, Error> {
        guard let url = Self.buildEndpointURL(
            baseURL: baseURL,
            token: token,
            apiPath: "/search/anime",
            queryItems: [URLQueryItem(name: "keyword", value: "葬送的芙莉莲")]
        ) else {
            return .failure(DanDanPlayError.invalidURL)
        }

        do {
            let request = makeJSONRequest(url: url, timeout: 30)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(DanDanPlayError.invalidResponse(statusCode: nil))
            }
            guard (200...299).contains(http.statusCode) else {
                return .failure(DanDanPlayError.invalidResponse(statusCode: http.statusCode))
            }
            let decoded = try JSONDecoder().decode(DanmuAPISearchResponse.self, from: data)
            if decoded.success == false, let msg = decoded.errorMessage, !msg.isEmpty {
                return .failure(DanDanPlayError.apiError(msg))
            }
            return .success("连接成功（示例搜索命中 \(decoded.animes.count) 条结果）")
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Bangumi / Episode Resolution via danmu_api

    func getBangumiDetails(bgmId: Int, targetSort: Double?) async throws -> DanDanPlayBangumi {
        try await getBangumiDetails(
            bgmId: bgmId,
            animeTitle: nil,
            targetSorts: targetSort.map { [$0] } ?? [],
            targetAirDate: nil
        )
    }

    func getBangumiDetails(
        bgmId: Int,
        animeTitle: String? = nil,
        targetSorts: [Double] = [],
        targetAirDate: String? = nil
    ) async throws -> DanDanPlayBangumi {
        let config = try currentServerConfig()
        let cache = DanDanPlayCacheManager.shared
        let sortStrings = targetSorts.map { String(Int($0)) }

        // 1. Check local cache first
        if let cachedBangumi = cache.getCachedBangumi(bgmId: bgmId), !cachedBangumi.episodes.isEmpty {
            if sortStrings.isEmpty || containsMatchingEpisode(in: cachedBangumi.episodes, targetStrings: sortStrings) {
                print("[DanmuAPI] Cache hit for bgmId \(bgmId)")
                return cachedBangumi
            }
        }

        // 2. Check short fetch throttling if previous request recently failed
        if cache.isBangumiFetchThrottled(bgmId: bgmId) {
            if let cachedBangumi = cache.getCachedBangumi(bgmId: bgmId) {
                return cachedBangumi
            }
            throw DanDanPlayError.apiError("弹幕检索冷却中，请稍后再试")
        }

        // 3. Resolve anime title (use caller's sessionTitle or fetch from Bangumi)
        var queryTitle = animeTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if queryTitle.isEmpty {
            if let subject = try? await BangumiRepository().getSubject(subjectID: bgmId) {
                let cn = subject.nameCN.trimmingCharacters(in: .whitespacesAndNewlines)
                queryTitle = cn.isEmpty ? subject.name : cn
            }
        }
        guard !queryTitle.isEmpty else {
            cache.recordBangumiFetchTime(bgmId: bgmId)
            throw DanDanPlayError.apiError("缺少番剧标题，无法向 danmu_api 检索弹幕")
        }

        let targetYear = Self.extractYear(from: targetAirDate)
        let candidateQueries = buildCandidateQueries(from: queryTitle)

        do {
            // Tier 1: GET /api/v2/search/anime -> GET /api/v2/bangumi/{animeId}
            // Preferred because /search/anime returns aliases + startDate + source,
            // and /bangumi/{animeId} returns exact episodeNumber + airDate.
            for query in candidateQueries {
                if let bangumi = try await searchViaAnimeAndBangumiEndpoints(
                    query: query,
                    targetStrings: sortStrings,
                    targetYear: targetYear,
                    bgmId: bgmId,
                    config: config
                ) {
                    cache.saveBangumi(bangumi, bgmId: bgmId)
                    return bangumi
                }
            }

            // Tier 2: GET /api/v2/search/episodes?anime=<title>
            for query in candidateQueries {
                if let bangumi = try await searchViaEpisodesEndpoint(
                    query: query,
                    targetStrings: sortStrings,
                    targetYear: targetYear,
                    bgmId: bgmId,
                    config: config
                ) {
                    cache.saveBangumi(bangumi, bgmId: bgmId)
                    return bangumi
                }
            }

            // Tier 3: POST /api/v2/match with fileName heuristic
            if let targetEp = sortStrings.first,
               let bangumi = try await matchViaFileNameEndpoint(
                   animeTitle: queryTitle,
                   episodeString: targetEp,
                   bgmId: bgmId,
                   config: config
               ) {
                cache.saveBangumi(bangumi, bgmId: bgmId)
                return bangumi
            }

            cache.recordBangumiFetchTime(bgmId: bgmId)
            throw DanDanPlayError.apiError("danmu_api 未检索到「\(queryTitle)」对应的剧集弹幕")
        } catch {
            cache.recordBangumiFetchTime(bgmId: bgmId)
            throw error
        }
    }

    // MARK: - Fetch Comments via danmu_api

    func getComments(episodeId: Int, airDateString: String? = nil) async throws -> [DanDanPlayComment] {
        let cache = DanDanPlayCacheManager.shared
        if let cachedComments = cache.getCachedComments(episodeId: episodeId, airDateString: airDateString) {
            return cachedComments
        }

        let config = try currentServerConfig()
        guard let url = Self.buildEndpointURL(
            baseURL: config.baseURL,
            token: config.token,
            apiPath: "/comment/\(episodeId)",
            queryItems: [
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "withRelated", value: "true"),
                URLQueryItem(name: "chConvert", value: "1")
            ]
        ) else {
            throw DanDanPlayError.invalidURL
        }

        // Cold comment scraping in danmu_api can take 30-50s across upstream sources
        let request = makeJSONRequest(url: url, timeout: 60)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DanDanPlayError.invalidResponse(statusCode: nil)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw DanDanPlayError.invalidResponse(statusCode: httpResponse.statusCode)
        }

        let result = try JSONDecoder().decode(DanDanPlayCommentResponse.self, from: data)
        cache.saveComments(result.comments, episodeId: episodeId, airDateString: airDateString)
        return result.comments
    }

    // MARK: - Internal Tier Helpers

    private func searchViaAnimeAndBangumiEndpoints(
        query: String,
        targetStrings: [String],
        targetYear: Int?,
        bgmId: Int,
        config: (baseURL: String, token: String)
    ) async throws -> DanDanPlayBangumi? {
        guard let searchURL = Self.buildEndpointURL(
            baseURL: config.baseURL,
            token: config.token,
            apiPath: "/search/anime",
            queryItems: [URLQueryItem(name: "keyword", value: query)]
        ) else {
            throw DanDanPlayError.invalidURL
        }

        let (searchData, searchResponse) = try await URLSession.shared.data(for: makeJSONRequest(url: searchURL, timeout: 45))
        guard let searchHTTP = searchResponse as? HTTPURLResponse, (200...299).contains(searchHTTP.statusCode) else {
            return nil
        }

        let decodedSearch = try JSONDecoder().decode(DanmuAPISearchResponse.self, from: searchData)
        guard !decodedSearch.animes.isEmpty else { return nil }

        let rankedCandidates = decodedSearch.animes
            .filter { $0.animeId > 0 }
            .sorted {
                Self.scoreAnime($0, query: query, targetStrings: targetStrings, targetYear: targetYear) >
                Self.scoreAnime($1, query: query, targetStrings: targetStrings, targetYear: targetYear)
            }

        for candidate in rankedCandidates.prefix(3) {
            guard let bangumiURL = Self.buildEndpointURL(
                baseURL: config.baseURL,
                token: config.token,
                apiPath: "/bangumi/\(candidate.animeId)"
            ) else {
                continue
            }

            let (detailData, detailResponse) = try await URLSession.shared.data(for: makeJSONRequest(url: bangumiURL, timeout: 45))
            guard let detailHTTP = detailResponse as? HTTPURLResponse, (200...299).contains(detailHTTP.statusCode) else {
                continue
            }

            if let detail = try? JSONDecoder().decode(DanDanPlayBangumiDetailsResponse.self, from: detailData),
               let bangumi = detail.bangumi,
               !bangumi.episodes.isEmpty {
                return bangumi
            }
        }

        return nil
    }

    private func searchViaEpisodesEndpoint(
        query: String,
        targetStrings: [String],
        targetYear: Int?,
        bgmId: Int,
        config: (baseURL: String, token: String)
    ) async throws -> DanDanPlayBangumi? {
        guard let url = Self.buildEndpointURL(
            baseURL: config.baseURL,
            token: config.token,
            apiPath: "/search/episodes",
            queryItems: [URLQueryItem(name: "anime", value: query)]
        ) else {
            throw DanDanPlayError.invalidURL
        }

        let request = makeJSONRequest(url: url, timeout: 45)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }

        let decoded = try JSONDecoder().decode(DanmuAPISearchResponse.self, from: data)
        let candidates = decoded.animes.filter { !$0.episodes.isEmpty }
        guard let best = candidates.max(by: {
            Self.scoreAnime($0, query: query, targetStrings: targetStrings, targetYear: targetYear) <
            Self.scoreAnime($1, query: query, targetStrings: targetStrings, targetYear: targetYear)
        }) else {
            return nil
        }

        return DanDanPlayBangumi(
            bangumiId: String(bgmId),
            animeId: best.animeId,
            animeTitle: best.animeTitle.isEmpty ? query : best.animeTitle,
            episodes: best.episodes
        )
    }

    private func matchViaFileNameEndpoint(
        animeTitle: String,
        episodeString: String,
        bgmId: Int,
        config: (baseURL: String, token: String)
    ) async throws -> DanDanPlayBangumi? {
        guard let url = Self.buildEndpointURL(
            baseURL: config.baseURL,
            token: config.token,
            apiPath: "/match"
        ) else {
            throw DanDanPlayError.invalidURL
        }

        let padded = episodeString.count == 1 ? "0\(episodeString)" : episodeString
        let payload = ["fileName": "\(animeTitle) S01E\(padded).mp4"]
        let body = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: makeJSONRequest(url: url, method: "POST", body: body, timeout: 45))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }

        let decoded = try JSONDecoder().decode(DanmuAPIMatchResponse.self, from: data)
        guard let first = decoded.matches.first else { return nil }

        let ep = DanDanPlayEpisode(
            episodeId: first.episodeId,
            episodeTitle: first.episodeTitle ?? "第\(episodeString)集",
            episodeNumber: episodeString,
            airDate: nil
        )
        return DanDanPlayBangumi(
            bangumiId: String(bgmId),
            animeId: first.animeId,
            animeTitle: first.animeTitle ?? animeTitle,
            episodes: [ep]
        )
    }

    // MARK: - Title & Episode Matching Heuristics

    private func buildCandidateQueries(from title: String) -> [String] {
        var queries: [String] = []
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            queries.append(trimmed)
        }

        let stripped = trimmed
            .replacingOccurrences(of: #"\s*[（(][^）)]*[）)]\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*第[一二三四五六七八九十0-9]+季\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stripped.isEmpty && !queries.contains(stripped) {
            queries.append(stripped)
        }
        return queries
    }

    /// Strips `danmu_api` display decorations like `(2023)【TV动画】from dandan`
    nonisolated static func stripDanmuAPITitleSuffix(_ rawTitle: String) -> String {
        rawTitle
            .replacingOccurrences(of: #"\s*from\s+\S+\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*【[^】]*】\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\((?:19|20)\d{2}|未知\)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\(((?:19|20)\d{2}|未知)\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func scoreAnime(
        _ item: DanmuAPISearchAnimeItem,
        query: String,
        targetStrings: [String],
        targetYear: Int? = nil
    ) -> Int {
        var score = 0
        let normalizedQuery = normalizeTitle(query)
        let cleanedTitle = stripDanmuAPITitleSuffix(item.animeTitle)
        let normalizedCandidate = normalizeTitle(cleanedTitle)
        let normalizedAliases = item.aliases.map { normalizeTitle($0) }

        if !normalizedQuery.isEmpty {
            if normalizedCandidate == normalizedQuery || normalizedAliases.contains(normalizedQuery) {
                score += 120
            } else if normalizedCandidate.contains(normalizedQuery) || normalizedQuery.contains(normalizedCandidate) {
                // Penalize extra length (e.g., "第二季" when searching Season 1)
                let lengthDiff = abs(normalizedCandidate.count - normalizedQuery.count)
                score += max(25, 65 - lengthDiff * 6)
            } else if normalizedAliases.contains(where: { $0.contains(normalizedQuery) || normalizedQuery.contains($0) }) {
                score += 50
            }
        }

        if let targetYear,
           let candidateYear = extractYear(from: item.startDate) {
            let diff = abs(candidateYear - targetYear)
            if diff == 0 {
                score += 45
            } else if diff == 1 {
                score += 15
            } else {
                score -= 20
            }
        }

        if let episodeCount = item.episodeCount, episodeCount > 0 {
            score += 10
        }

        if !item.episodes.isEmpty {
            score += 15
            if !targetStrings.isEmpty, containsMatchingEpisodeStatic(in: item.episodes, targetStrings: targetStrings) {
                score += 35
            }
        }

        let source = (item.source ?? "").lowercased()
        if source == "dandan" || item.animeTitle.localizedCaseInsensitiveContains("from dandan") {
            score += 15
        }

        let typeText = (item.type ?? "") + " " + (item.typeDescription ?? "")
        if typeText.localizedCaseInsensitiveContains("tv") || typeText.contains("动画") || typeText.contains("番剧") {
            score += 10
        }

        return score
    }

    private func containsMatchingEpisode(in episodes: [DanDanPlayEpisode], targetStrings: [String]) -> Bool {
        Self.containsMatchingEpisodeStatic(in: episodes, targetStrings: targetStrings)
    }

    private nonisolated static func containsMatchingEpisodeStatic(
        in episodes: [DanDanPlayEpisode],
        targetStrings: [String]
    ) -> Bool {
        episodes.contains { ep in
            targetStrings.contains { s in
                let padded = s.count == 1 ? "0\(s)" : s
                return ep.episodeNumber == s ||
                    ep.episodeTitle == s ||
                    ep.episodeTitle == padded ||
                    ep.episodeTitle.contains("第\(s)话") ||
                    ep.episodeTitle.contains("第\(s)集") ||
                    ep.episodeTitle.contains("第\(padded)话") ||
                    ep.episodeTitle.contains("第\(padded)集") ||
                    ep.episodeTitle.localizedCaseInsensitiveContains("E\(padded)")
            }
        }
    }

    private nonisolated static func extractYear(from dateString: String?) -> Int? {
        guard let raw = dateString?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.count >= 4,
              let year = Int(raw.prefix(4)),
              (1950...2100).contains(year) else {
            return nil
        }
        return year
    }

    private nonisolated static func normalizeTitle(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[\s\-_：:·・!！?？,，。]+"#, with: "", options: .regularExpression)
    }
}
