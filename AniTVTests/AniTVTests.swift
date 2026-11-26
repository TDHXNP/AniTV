//
//  AniTVTests.swift
//  AniTVTests
//
//  Created by Feiran Yang on 2026/2/10.
//

import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import AniTV

final class AniTVTests: XCTestCase {

    func testExample() async throws {
        // Write your test here
    }

    func testTimelineServiceDemo() async throws {
        let database = try AniTVDatabase.makeDefaultDatabase()

        if try await AniTVDatabase.isBangumiDataEmpty(in: database) {
            let release = try await AniTVDatabase.resolveBangumiDataRelease()
            let items = try await AniTVDatabase.downloadBangumiData(from: release.url)
            try await AniTVDatabase.replaceBangumiData(items, version: release.version, in: database)
        }

        let service = TimelineService()
        let timeline = try await service.fetchTimelineMap(
            database: database,
            now: Date(),
            daysBefore: 7,
            daysAfter: 7
        )

        let sortedKeys = timeline.keys.sorted()
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = .current
        timeFormatter.dateFormat = "HH:mm:ss"

        var orderedEntries: [[String: Any]] = []
        for key in sortedKeys {
            let entries = timeline[key, default: []]
            for entry in entries {
                let formattedTime: String
                if entry.airingTimestamp == .max {
                    formattedTime = "unknown"
                } else {
                    let date = Date(timeIntervalSince1970: TimeInterval(entry.airingTimestamp))
                    formattedTime = timeFormatter.string(from: date)
                }

                orderedEntries.append([
                    "date": key,
                    "time": formattedTime,
                    "airingTimestamp": entry.airingTimestamp,
                    "subjectTitle": entry.subjectTitle,
                    "subjectTitleCN": entry.subjectTitleCN as Any,
                    "episodeSort": entry.episodeSort as Any,
                    "episodeName": entry.episodeName as Any,
                    "episodeNameCN": entry.episodeNameCN as Any,
                    "bangumiID": entry.bangumiID as Any,
                    "anilistID": entry.anilistID as Any,
                    "isAniListMissing": entry.isAniListMissing,
                    "coverImageURL": entry.coverImageURL as Any
                ])
            }
        }

        let payload: [String: Any] = [
            "dayCount": timeline.count,
            "days": sortedKeys,
            "entries": orderedEntries
        ]

        let jsonData = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
        }

        XCTAssertFalse(timeline.isEmpty)
    }

    func testHlsManifestFilterAdDetection() throws {
        // Build simulated low-density playlist with sandwiched ad
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:5",
            "#EXT-X-MEDIA-SEQUENCE:0"
        ]
        
        // Group 0: 30 segments of 3s = 90s
        for i in 0..<30 {
            lines.append("#EXTINF:3.000000,")
            lines.append("main_seg_\(i).ts")
        }
        
        // Group 1 (Ad): 5 segments of 4s = 20s
        lines.append("#EXT-X-DISCONTINUITY")
        for i in 0..<5 {
            lines.append("#EXTINF:4.000000,")
            lines.append("ad_seg_\(i).ts")
        }
        
        // Group 2: 30 segments of 3s = 90s
        lines.append("#EXT-X-DISCONTINUITY")
        for i in 30..<60 {
            lines.append("#EXTINF:3.000000,")
            lines.append("main_seg_\(i).ts")
        }
        lines.append("#EXT-X-ENDLIST")
        
        let content = lines.joined(separator: "\n")
        let result = HlsManifestFilter.filter(content: content)
        
        XCTAssertEqual(result.status, .filtered)
        XCTAssertEqual(result.removedGroups.count, 1)
        XCTAssertEqual(result.removedGroups.first?.segmentCount, 5)
        XCTAssertFalse(result.content.contains("ad_seg_"))
        XCTAssertTrue(result.content.contains("main_seg_0.ts"))
        XCTAssertTrue(result.content.contains("main_seg_59.ts"))
    }

    func testHlsManifestFilterMasterPlaylistUnsupported() throws {
        let masterContent = """
        #EXTM3U
        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=800000,RESOLUTION=1080x608
        2000k/hls/index.m3u8
        """
        let result = HlsManifestFilter.filter(content: masterContent)
        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.reason, "master_playlist")
    }

    func testHlsManifestFilterLivePlaylistUnsupported() throws {
        let liveContent = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXTINF:4.0,
        seg1.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:4.0,
        seg2.ts
        """
        let result = HlsManifestFilter.filter(content: liveContent)
        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.reason, "live_or_incomplete_playlist")
    }

    func testHlsManifestFilterImplicitIvUnchanged() throws {
        let content = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:100.0,
        main1.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:10.0,
        ad1.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:100.0,
        main2.ts
        #EXT-X-ENDLIST
        """
        let result = HlsManifestFilter.filter(content: content)
        XCTAssertEqual(result.status, .unchanged)
        XCTAssertEqual(result.reason, "encrypted_implicit_iv")
    }

    func testRememberDanmakuStateLogic() async throws {
        // 1. When remember is true, resolve follows lastDanmakuEnabled
        AniTVDatabase.persistDanmakuStateIfRememberEnabled(false, in: nil)
        UserDefaults.standard.set(true, forKey: AniTVDatabase.rememberDanmakuStateSettingKey)
        XCTAssertFalse(AniTVDatabase.resolvedInitialDanmakuEnabled())

        AniTVDatabase.persistDanmakuStateIfRememberEnabled(true, in: nil)
        XCTAssertTrue(AniTVDatabase.resolvedInitialDanmakuEnabled())

        // 2. When remember is false, resolve is always true regardless of last saved state
        AniTVDatabase.persistDanmakuStateIfRememberEnabled(false, in: nil)
        UserDefaults.standard.set(false, forKey: AniTVDatabase.rememberDanmakuStateSettingKey)
        XCTAssertTrue(AniTVDatabase.resolvedInitialDanmakuEnabled())

        // Reset to default
        UserDefaults.standard.set(true, forKey: AniTVDatabase.rememberDanmakuStateSettingKey)
        UserDefaults.standard.set(true, forKey: AniTVDatabase.lastDanmakuEnabledSettingKey)
    }

    func testDanmakuDisplayAreaAndDefaultMediaSourcePersistence() async throws {
        let database = try AniTVDatabase.makeDefaultDatabase()
        let previousArea = try await AniTVDatabase.danmakuDisplayArea(in: database)
        let previousDefaultSource = try await AniTVDatabase.defaultMediaSourceName(in: database)

        defer {
            Task {
                try? await AniTVDatabase.setDanmakuDisplayArea(previousArea, in: database)
                try? await AniTVDatabase.setDefaultMediaSourceName(previousDefaultSource, in: database)
            }
        }

        // 1. Danmaku display area persistence to SQLite + UserDefaults
        try await AniTVDatabase.setDanmakuDisplayArea(0.5, in: database)
        let storedArea = try await AniTVDatabase.danmakuDisplayArea(in: database)
        XCTAssertEqual(storedArea, 0.5, accuracy: 0.001)
        XCTAssertEqual(Double(AniTVDatabase.resolvedInitialDanmakuDisplayArea()), 0.5, accuracy: 0.001)

        AniTVDatabase.persistDanmakuDisplayArea(0.25, in: nil)
        XCTAssertEqual(Double(AniTVDatabase.resolvedInitialDanmakuDisplayArea()), 0.25, accuracy: 0.001)

        await AniTVDatabase.syncDanmakuSettingsToUserDefaults(in: database)
        XCTAssertEqual(Double(AniTVDatabase.resolvedInitialDanmakuDisplayArea()), 0.5, accuracy: 0.001)

        // 2. Default media source persistence
        try await AniTVDatabase.setDefaultMediaSourceName("GiriGiri", in: database)
        let storedSource = try await AniTVDatabase.defaultMediaSourceName(in: database)
        XCTAssertEqual(storedSource, "GiriGiri")

        try await AniTVDatabase.setDefaultMediaSourceName(nil, in: database)
        let clearedSource = try await AniTVDatabase.defaultMediaSourceName(in: database)
        XCTAssertNil(clearedSource)
    }

    func testPrioritizedMediaSourceConfigsMovesDefaultToFront() throws {
        let makeConfig: (String) -> MediaSourceConfig = { name in
            let json = """
            {
              "name": "\(name)",
              "description": "",
              "iconUrl": "",
              "tier": 0,
              "searchConfig": {
                "searchUrl": "https://example.com/?q={keyword}",
                "searchUseOnlyFirstWord": false,
                "searchRemoveSpecial": false,
                "subjectFormatId": "a",
                "channelFormatId": "index-grouped",
                "matchVideo": {
                  "matchVideoUrl": ".*",
                  "cookies": "",
                  "addCookiesToHeader": false,
                  "enableNestedUrl": false
                },
                "filterByEpisodeSort": true,
                "filterBySubjectName": true
              }
            }
            """
            let data = Data(json.utf8)
            let args = try! JSONDecoder().decode(SelectorMediaSourceArguments.self, from: data)
            return MediaSourceConfig(serializedArguments: data, arguments: args)
        }

        let configs = [makeConfig("Alpha"), makeConfig("Beta"), makeConfig("Gamma")]
        let reordered = AnimePlayerContainerView.prioritizedMediaSourceConfigs(configs, defaultSourceName: "Gamma")
        XCTAssertEqual(reordered.compactMap { $0.arguments?.name }, ["Gamma", "Alpha", "Beta"])

        let unchanged = AnimePlayerContainerView.prioritizedMediaSourceConfigs(configs, defaultSourceName: "Missing")
        XCTAssertEqual(unchanged.compactMap { $0.arguments?.name }, ["Alpha", "Beta", "Gamma"])

        let langConfigs = [makeConfig("源A-繁中"), makeConfig("源B-默认"), makeConfig("源C-简中")]
        let langSorted = AnimePlayerContainerView.prioritizedMediaSourceConfigs(langConfigs, defaultSourceName: nil)
        XCTAssertEqual(langSorted.compactMap { $0.arguments?.name }, ["源C-简中", "源B-默认", "源A-繁中"])
    }

    func testSimplifiedChineseRoutesSortedAboveTraditional() throws {
        XCTAssertLessThan(
            AnimePlayerContainerView.subtitleLanguageSortPriority(text: "简中线路1"),
            AnimePlayerContainerView.subtitleLanguageSortPriority(text: "繁中线路1")
        )
        XCTAssertLessThan(
            AnimePlayerContainerView.subtitleLanguageSortPriority(text: "简日双语"),
            AnimePlayerContainerView.subtitleLanguageSortPriority(text: "繁日双语")
        )
        XCTAssertLessThan(
            AnimePlayerContainerView.subtitleLanguageSortPriority(text: "线路1", subtitleLanguageIds: ["CHS"]),
            AnimePlayerContainerView.subtitleLanguageSortPriority(text: "线路2", subtitleLanguageIds: ["CHT"])
        )
        XCTAssertLessThan(
            AnimePlayerContainerView.subtitleLanguageSortPriority(text: "普通线路"),
            AnimePlayerContainerView.subtitleLanguageSortPriority(text: "繁體路線")
        )
    }

    func testResumePositionPreservesInitialPlayheadBeforeItemReady() throws {
        let saved = CMTime(seconds: 612, preferredTimescale: 600)
        let zero = CMTime.zero

        // When player.currentItem is nil (fresh player), currentTime() is .zero and must NOT wipe saved resume time
        let initialResolved = AnimePlayerContainerView.resolveResumePosition(
            currentItemStatus: nil,
            currentPlayerTime: zero,
            lastPlaybackPosition: saved,
            isApplyingResumeSeek: false
        )
        XCTAssertEqual(initialResolved?.seconds ?? -1, 612, accuracy: 0.01)

        // When currentItem is still .unknown (buffering), saved resume time must still be preserved
        let bufferingResolved = AnimePlayerContainerView.resolveResumePosition(
            currentItemStatus: .unknown,
            currentPlayerTime: zero,
            lastPlaybackPosition: saved,
            isApplyingResumeSeek: false
        )
        XCTAssertEqual(bufferingResolved?.seconds ?? -1, 612, accuracy: 0.01)

        // Once readyToPlay and actively playing (not seeking), current player time takes over
        let livePosition = CMTime(seconds: 745, preferredTimescale: 600)
        let activeResolved = AnimePlayerContainerView.resolveResumePosition(
            currentItemStatus: .readyToPlay,
            currentPlayerTime: livePosition,
            lastPlaybackPosition: saved,
            isApplyingResumeSeek: false
        )
        XCTAssertEqual(activeResolved?.seconds ?? -1, 745, accuracy: 0.01)
    }

    func testSkipDecisionEngineAniSkipAndFallback() throws {
        let exactOP = SkipSegment(kind: .op, startTime: 60, endTime: 150, source: .aniSkip)
        let exactED = SkipSegment(kind: .ed, startTime: 1320, endTime: 1410, source: .aniSkip)
        let exactPlan = EpisodeSkipPlan(op: exactOP, ed: exactED)

        // 1. Prompt mode inside AniSkip OP shows exact prompt
        let opPrompt = SkipDecisionEngine.evaluate(
            currentTime: 70,
            duration: 1420,
            plan: exactPlan,
            mode: .prompt,
            fallbackOPSkipSeconds: 85,
            hasNextEpisode: true,
            skippedKinds: []
        )
        if case .showPrompt(let action) = opPrompt {
            XCTAssertEqual(action.kind, .op)
            XCTAssertEqual(action.source, .aniSkip)
            XCTAssertEqual(action.targetSeconds, 150)
        } else {
            XCTFail("Expected exact OP prompt, got \(opPrompt)")
        }

        // 2. Auto mode inside AniSkip OP auto-skips once, then suppresses
        let opAuto = SkipDecisionEngine.evaluate(
            currentTime: 70,
            duration: 1420,
            plan: exactPlan,
            mode: .auto,
            fallbackOPSkipSeconds: 85,
            hasNextEpisode: true,
            skippedKinds: []
        )
        XCTAssertEqual(opAuto, .autoSkip(exactOP))

        let opAlreadySkipped = SkipDecisionEngine.evaluate(
            currentTime: 70,
            duration: 1420,
            plan: exactPlan,
            mode: .auto,
            fallbackOPSkipSeconds: 85,
            hasNextEpisode: true,
            skippedKinds: [.op]
        )
        XCTAssertEqual(opAlreadySkipped, .none)

        // 3. Fallback OP shows manual prompt even when mode == .auto (never blindly auto-skips!)
        let fallbackOP = SkipDecisionEngine.evaluate(
            currentTime: 25,
            duration: 1420,
            plan: .empty,
            mode: .auto,
            fallbackOPSkipSeconds: 85,
            hasNextEpisode: true,
            skippedKinds: []
        )
        if case .showPrompt(let action) = fallbackOP {
            XCTAssertEqual(action.kind, .op)
            XCTAssertEqual(action.source, .fallback)
            XCTAssertNil(action.targetSeconds)
        } else {
            XCTFail("Expected fallback OP prompt without auto-skip, got \(fallbackOP)")
        }

        // 4. Fallback ED offers next-episode prompt near end of episode
        let fallbackED = SkipDecisionEngine.evaluate(
            currentTime: 1350,
            duration: 1420,
            plan: .empty,
            mode: .prompt,
            fallbackOPSkipSeconds: 85,
            hasNextEpisode: true,
            skippedKinds: []
        )
        if case .showPrompt(let action) = fallbackED {
            XCTAssertEqual(action.kind, .ed)
            XCTAssertEqual(action.source, .fallback)
            XCTAssertTrue(action.switchesToNextEpisode)
        } else {
            XCTFail("Expected fallback ED next-episode prompt, got \(fallbackED)")
        }

        // 5. Off mode returns .none
        let offDecision = SkipDecisionEngine.evaluate(
            currentTime: 70,
            duration: 1420,
            plan: exactPlan,
            mode: .off,
            fallbackOPSkipSeconds: 85,
            hasNextEpisode: true,
            skippedKinds: []
        )
        XCTAssertEqual(offDecision, .none)
    }

    func testLocalMediaSourceCRUDAndEpisodeMatching() async throws {
        let database = try AniTVDatabase.makeDefaultDatabase()
        let created = try await AniTVDatabase.insertLocalMediaSource(
            name: "测试 NAS",
            kind: .webdav,
            baseURL: "http://192.168.1.99:5244/dav/Anime",
            username: "admin",
            password: "secret",
            in: database
        )
        defer {
            Task {
                try? await AniTVDatabase.deleteLocalMediaSource(id: created.id, in: database)
            }
        }

        let fetched = try await AniTVDatabase.fetchLocalMediaSources(enabledOnly: true, in: database)
        XCTAssertTrue(fetched.contains(where: { $0.id == created.id && $0.name == "测试 NAS" && $0.kind == .webdav }))

        try await AniTVDatabase.setLocalMediaSourceEnabled(id: created.id, isEnabled: false, in: database)
        let enabledOnly = try await AniTVDatabase.fetchLocalMediaSources(enabledOnly: true, in: database)
        XCTAssertFalse(enabledOnly.contains(where: { $0.id == created.id }))

        XCTAssertTrue(LocalMediaServerClient.matchesSubjectTitle("葬送的芙莉莲 (2023)", candidates: ["葬送的芙莉莲"]))
        XCTAssertTrue(LocalMediaServerClient.matchesEpisodeNumber("[Lilith-Raws] Frieren - S01E05 [1080p].mp4", episodeNumber: 5))
        XCTAssertTrue(LocalMediaServerClient.matchesEpisodeNumber("葬送的芙莉莲 第05集.mkv", episodeNumber: 5))
        XCTAssertFalse(LocalMediaServerClient.matchesEpisodeNumber("[Lilith-Raws] Frieren - S01E15 [1080p].mp4", episodeNumber: 5))
    }

    @MainActor
    func testTopShelfEntryAndDeepLinkParsing() throws {
        let entry = TopShelfEntry(
            subjectID: 400602,
            title: "葬送的芙莉莲",
            posterURL: "https://lain.bgm.tv/pic/cover/l/test.jpg",
            epStatus: 14,
            totalEpisodes: 28
        )
        XCTAssertEqual(entry.continueWatchingDisplayTitle, "葬送的芙莉莲 · 第 14 集")
        XCTAssertEqual(entry.effectivePlaybackProgress, 0.5, accuracy: 0.001)

        let coordinator = DeepLinkCoordinator.shared
        coordinator.handle(url: TopShelfSharedStore.detailURL(subjectID: 400602))
        XCTAssertEqual(coordinator.consumePendingAction(), .animeDetail(400602))

        coordinator.handle(url: TopShelfSharedStore.playURL(subjectID: 400602))
        XCTAssertEqual(coordinator.consumePendingAction(), .playAnime(400602))

        coordinator.handle(url: URL(string: "anitv://oauth/bangumi?code=abc")!)
        XCTAssertNil(coordinator.consumePendingAction())

        // Verify TopShelfEntry HTTPS normalization
        let httpEntry = TopShelfEntry(
            subjectID: 123,
            title: "Test",
            posterURL: "http://lain.bgm.tv/pic/cover/l/test.jpg"
        )
        XCTAssertEqual(httpEntry.resolvedPosterURL?.absoluteString, "https://lain.bgm.tv/pic/cover/l/test.jpg")

        // Verify Ranking filter query construction
        var rankingFilter = RankingFilterState()
        rankingFilter.time = .y2025
        rankingFilter.category = "TV"
        rankingFilter.source = "漫画改"
        rankingFilter.genre = "奇幻"
        rankingFilter.region = "日本"
        rankingFilter.audience = "少年向"
        XCTAssertEqual(rankingFilter.airDateConditions, [">=2025-01-01", "<2026-01-01"])
        XCTAssertEqual(rankingFilter.metaTags, ["TV", "漫画改", "奇幻", "日本", "少年向"])
        XCTAssertTrue(rankingFilter.hasActiveFilters)
        rankingFilter.resetFilters()
        XCTAssertFalse(rankingFilter.hasActiveFilters)
        XCTAssertTrue(rankingFilter.metaTags.isEmpty)
        XCTAssertTrue(rankingFilter.airDateConditions.isEmpty)
    }

    func testDanmuAPIURLBuildingAndCommentParsing() throws {
        // 1. Base URL without path + separate token
        let url1 = DanDanPlayAPI.buildEndpointURL(
            baseURL: "https://danmu.example.com",
            token: "87654321",
            apiPath: "/search/episodes",
            queryItems: [URLQueryItem(name: "anime", value: "Frieren")]
        )
        XCTAssertEqual(url1?.absoluteString, "https://danmu.example.com/87654321/api/v2/search/episodes?anime=Frieren")

        // 2. Base URL already containing token path (e.g. /APTX4869) must NOT append default token again
        let urlWithPathToken = DanDanPlayAPI.buildEndpointURL(
            baseURL: "https://danmu.tdhxnp.com/APTX4869",
            token: "87654321",
            apiPath: "/comment/10009",
            queryItems: [URLQueryItem(name: "format", value: "json")]
        )
        XCTAssertEqual(urlWithPathToken?.absoluteString, "https://danmu.tdhxnp.com/APTX4869/api/v2/comment/10009?format=json")

        // 3. Token already embedded in base URL + trailing /api/v2
        let url2 = DanDanPlayAPI.buildEndpointURL(
            baseURL: "http://192.168.1.7:9321/87654321/api/v2/",
            token: "87654321",
            apiPath: "/comment/10001",
            queryItems: [URLQueryItem(name: "format", value: "json")]
        )
        XCTAssertEqual(url2?.absoluteString, "http://192.168.1.7:9321/87654321/api/v2/comment/10001?format=json")

        // 4. Empty token omits token path segment
        let url3 = DanDanPlayAPI.buildEndpointURL(
            baseURL: "192.168.1.7:9321",
            token: "",
            apiPath: "/match"
        )
        XCTAssertEqual(url3?.absoluteString, "http://192.168.1.7:9321/api/v2/match")

        // 5. Title suffix stripping and season disambiguation
        XCTAssertEqual(
            DanDanPlayAPI.stripDanmuAPITitleSuffix("葬送的芙莉莲(2023)【TV动画】from dandan"),
            "葬送的芙莉莲"
        )
        let season1 = DanmuAPISearchAnimeItem(
            animeId: 17617,
            animeTitle: "葬送的芙莉莲(2023)【TV动画】from dandan",
            aliases: ["葬送的芙莉莲"],
            type: "tvseries",
            startDate: "2023-09-29T00:00:00",
            episodeCount: 58,
            source: "dandan"
        )
        let season2 = DanmuAPISearchAnimeItem(
            animeId: 18886,
            animeTitle: "葬送的芙莉莲 第二季(2026)【TV动画】from dandan",
            aliases: ["葬送的芙莉莲 第二季"],
            type: "tvseries",
            startDate: "2026-01-16T00:00:00",
            episodeCount: 19,
            source: "dandan"
        )
        XCTAssertGreaterThan(
            DanDanPlayAPI.scoreAnime(season1, query: "葬送的芙莉莲", targetStrings: ["1"], targetYear: 2023),
            DanDanPlayAPI.scoreAnime(season2, query: "葬送的芙莉莲", targetStrings: ["1"], targetYear: 2023)
        )

        // 6. Parse real comment/10009 format + 3-field + 8-field formats
        let parsedReal = DanDanPlayDanmuProvider.parseComment(
            DanDanPlayComment(cid: 1, p: "5.00,2,14463824,[renren]", m: "怎么感觉演的乱七八糟的")
        )
        XCTAssertEqual(parsedReal, ParsedDanDanPlayDanmu(time: 5.0, mode: 2, color: 14463824, userId: "[renren]", text: "怎么感觉演的乱七八糟的"))

        let parsed3 = DanDanPlayDanmuProvider.parseComment(DanDanPlayComment(p: "12.5,1,16777215", m: "hello"))
        XCTAssertEqual(parsed3, ParsedDanDanPlayDanmu(time: 12.5, mode: 1, color: 16777215, userId: "", text: "hello"))

        let parsed8 = DanDanPlayDanmuProvider.parseComment(DanDanPlayComment(p: "45.0,4,25,65280,1700000000,0,abc123,9999", m: "bottom"))
        XCTAssertEqual(parsed8, ParsedDanDanPlayDanmu(time: 45.0, mode: 4, color: 65280, userId: "abc123", text: "bottom"))

        // 7. Flexible JSON decoding when cid/episodeId are string or omitted
        let json = """
        {
          "count": 2,
          "comments": [
            { "p": "1.0,1,16777215", "m": "no cid" },
            { "cid": "42", "p": "2.0,1,16777215,u1", "m": "string cid", "t": 2, "like": 0 }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(DanDanPlayCommentResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.comments.count, 2)
        XCTAssertEqual(decoded.comments[0].cid, 0)
        XCTAssertEqual(decoded.comments[1].cid, 42)
    }
}
