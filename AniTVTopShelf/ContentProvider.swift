//
//  ContentProvider.swift
//  AniTVTopShelf
//
//  Provides Apple TV Top Shelf sectioned content:
//  1. 继续播放 (Continue Watching)
//  2. 推荐的项目 (Recommended Anime)
//

import Foundation
import TVServices

@objc(AniTVTopShelfContentProvider)
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let snapshot = TopShelfSharedStore.loadSnapshot()
        let continueEntries = snapshot?.continueWatching ?? []

        var recommendedEntries = snapshot?.recommended ?? []
        if recommendedEntries.isEmpty {
            recommendedEntries = await TopShelfFallbackClient.fetchRecommendedAnime(limit: 12)
        }

        let continueIDs = Set(continueEntries.map(\.subjectID))
        let filteredRecommended = recommendedEntries.filter { !continueIDs.contains($0.subjectID) }
        let effectiveRecommended = filteredRecommended.isEmpty ? recommendedEntries : filteredRecommended

        let allEntries = Array(continueEntries.prefix(10)) + Array(effectiveRecommended.prefix(12))
        guard !allEntries.isEmpty else {
            return nil
        }

        // Resolve local file:// poster JPEGs inside the extension's Caches directory
        // (copied from shared App Group cache or downloaded in parallel with proper
        // Bangumi headers) so PineBoard renders posters instantaneously without blanks.
        let localPosterURLs = await TopShelfPosterCache.resolveLocalPosterURLs(for: allEntries)

        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []

        if !continueEntries.isEmpty {
            let continueItems = continueEntries.prefix(10).compactMap { entry in
                makeSectionedItem(
                    identifier: "continue-\(entry.subjectID)",
                    entry: entry,
                    imageURL: localPosterURLs[entry.subjectID] ?? entry.resolvedPosterURL,
                    isContinueWatching: true
                )
            }
            if !continueItems.isEmpty {
                let section = TVTopShelfItemCollection(items: continueItems)
                section.title = "继续播放"
                sections.append(section)
            }
        }

        if !effectiveRecommended.isEmpty {
            let recommendedItems = effectiveRecommended.prefix(12).compactMap { entry in
                makeSectionedItem(
                    identifier: "recommended-\(entry.subjectID)",
                    entry: entry,
                    imageURL: localPosterURLs[entry.subjectID] ?? entry.resolvedPosterURL,
                    isContinueWatching: false
                )
            }
            if !recommendedItems.isEmpty {
                let section = TVTopShelfItemCollection(items: recommendedItems)
                section.title = "推荐的项目"
                sections.append(section)
            }
        }

        // If we could not cache any local posters AND have no valid sections, return nil
        // so tvOS displays the static Top Shelf banner instead of a blank screen.
        guard !sections.isEmpty, !localPosterURLs.isEmpty else {
            return nil
        }

        return TVTopShelfSectionedContent(sections: sections)
    }

    private func makeSectionedItem(
        identifier: String,
        entry: TopShelfEntry,
        imageURL: URL?,
        isContinueWatching: Bool
    ) -> TVTopShelfSectionedItem? {
        guard let imageURL else { return nil }

        let item = TVTopShelfSectionedItem(identifier: identifier)
        item.title = isContinueWatching ? entry.continueWatchingDisplayTitle : entry.title
        item.imageShape = .poster
        item.playbackProgress = isContinueWatching ? entry.effectivePlaybackProgress : 0

        item.setImageURL(imageURL, for: .screenScale1x)
        item.setImageURL(imageURL, for: .screenScale2x)

        item.displayAction = TVTopShelfAction(url: TopShelfSharedStore.detailURL(subjectID: entry.subjectID))
        item.playAction = TVTopShelfAction(url: TopShelfSharedStore.playURL(subjectID: entry.subjectID))
        return item
    }
}

private enum TopShelfFallbackClient {
    private struct TrendingResponse: Decodable {
        let data: [TrendingItem]
    }

    private struct TrendingItem: Decodable {
        let subject: TrendingSubject
    }

    private struct TrendingSubject: Decodable {
        let id: Int
        let name: String
        let nameCN: String?
        let images: TrendingImages?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case nameCN = "name_cn"
            case images
        }
    }

    private struct TrendingImages: Decodable {
        let large: String?
        let common: String?
        let medium: String?
    }

    private struct CalendarDay: Decodable {
        let items: [TrendingSubject]
    }

    static func fetchRecommendedAnime(limit: Int) async -> [TopShelfEntry] {
        let primary = await fetchFromNextTrending(limit: limit)
        if !primary.isEmpty {
            return primary
        }
        return await fetchFromPublicCalendar(limit: limit)
    }

    private static func fetchFromNextTrending(limit: Int) async -> [TopShelfEntry] {
        guard let url = URL(string: "https://next.bgm.tv/p1/trending/subjects?type=2&limit=\(limit)&offset=0") else {
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8.0
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(TopShelfSharedStore.bangumiUserAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return []
            }
            let decoded = try JSONDecoder().decode(TrendingResponse.self, from: data)
            return decoded.data.compactMap { mapSubject($0.subject) }
        } catch {
            return []
        }
    }

    private static func fetchFromPublicCalendar(limit: Int) async -> [TopShelfEntry] {
        guard let url = URL(string: "https://api.bgm.tv/calendar") else {
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8.0
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(TopShelfSharedStore.bangumiUserAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return []
            }
            let days = try JSONDecoder().decode([CalendarDay].self, from: data)
            var entries: [TopShelfEntry] = []
            var seenIDs: Set<Int> = []
            for day in days {
                for subject in day.items {
                    guard seenIDs.insert(subject.id).inserted,
                          let entry = mapSubject(subject) else { continue }
                    entries.append(entry)
                    if entries.count >= limit {
                        return entries
                    }
                }
            }
            return entries
        } catch {
            return []
        }
    }

    private static func mapSubject(_ subject: TrendingSubject) -> TopShelfEntry? {
        let cn = subject.nameCN?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = cn.isEmpty ? subject.name : cn
        let poster = [subject.images?.large, subject.images?.common, subject.images?.medium]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        guard let poster else { return nil }
        return TopShelfEntry(
            subjectID: subject.id,
            title: title,
            posterURL: poster
        )
    }
}
