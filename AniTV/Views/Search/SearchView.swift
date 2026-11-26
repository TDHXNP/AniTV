//
//  SearchView.swift
//  AniTV
//
//  Created by Codex on 2026/11/25.
//

import SwiftUI
import Combine
import Kingfisher

enum AnimeSearchSort: String, CaseIterable, Identifiable {
    case match = "match"
    case heat = "heat"
    case rank = "rank"
    case score = "score"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .match: return "相关度"
        case .heat: return "热度"
        case .rank: return "排名"
        case .score: return "评分"
        }
    }
}

@MainActor
final class AnimeSearchStore: ObservableObject {
    @Published var results: [BgmSearchSubjectDTO] = []
    @Published var isSearching = false
    @Published var isLoadingMore = false
    @Published var hasSearched = false
    @Published var errorMessage: String?
    @Published var totalCount = 0
    @Published var recentQueries: [String] = []

    private let repository = BangumiRepository()
    private let pageSize = 24
    private let historyKey = "search.recent_queries"
    private var currentKeyword = ""
    private var currentSort: AnimeSearchSort = .match
    private var currentOffset = 0
    private var canLoadMore = false
    private var searchTask: Task<Void, Never>?

    init() {
        recentQueries = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    func search(keyword: String, sort: AnimeSearchSort) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reset()
            return
        }

        searchTask?.cancel()
        currentKeyword = trimmed
        currentSort = sort
        currentOffset = 0
        canLoadMore = false
        errorMessage = nil
        isSearching = true
        hasSearched = true
        recordHistory(trimmed)

        searchTask = Task {
            do {
                let response = try await repository.searchSubjects(
                    keyword: trimmed,
                    sort: sort.rawValue,
                    subjectTypes: [2],
                    limit: pageSize,
                    offset: 0
                )
                guard !Task.isCancelled else { return }
                results = response.data
                totalCount = response.total
                currentOffset = response.data.count
                canLoadMore = response.data.count < response.total && !response.data.isEmpty
                isSearching = false
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                totalCount = 0
                errorMessage = "搜索失败：\(error.localizedDescription)"
                isSearching = false
            }
        }
    }

    func loadMoreIfNeeded(currentItem: BgmSearchSubjectDTO) {
        guard currentItem.id == results.last?.id,
              canLoadMore,
              !isSearching,
              !isLoadingMore,
              !currentKeyword.isEmpty else {
            return
        }

        isLoadingMore = true
        let keyword = currentKeyword
        let sort = currentSort
        let offset = currentOffset

        Task {
            do {
                let response = try await repository.searchSubjects(
                    keyword: keyword,
                    sort: sort.rawValue,
                    subjectTypes: [2],
                    limit: pageSize,
                    offset: offset
                )
                guard keyword == currentKeyword else {
                    isLoadingMore = false
                    return
                }
                var existing = Set(results.map(\.id))
                for item in response.data where existing.insert(item.id).inserted {
                    results.append(item)
                }
                currentOffset += response.data.count
                canLoadMore = currentOffset < response.total && !response.data.isEmpty
                isLoadingMore = false
            } catch {
                isLoadingMore = false
            }
        }
    }

    func reset() {
        searchTask?.cancel()
        currentKeyword = ""
        results = []
        totalCount = 0
        hasSearched = false
        isSearching = false
        isLoadingMore = false
        errorMessage = nil
        canLoadMore = false
    }

    func clearHistory() {
        recentQueries = []
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    private func recordHistory(_ query: String) {
        var updated = recentQueries.filter { $0 != query }
        updated.insert(query, at: 0)
        if updated.count > 10 {
            updated = Array(updated.prefix(10))
        }
        recentQueries = updated
        UserDefaults.standard.set(updated, forKey: historyKey)
    }
}

struct SearchView: View {
    @Binding var columnVisibility: NavigationSplitViewVisibility
    let openAnimeDetail: (Int) -> Void

    @StateObject private var store = AnimeSearchStore()
    @State private var queryText = ""
    @State private var selectedSort: AnimeSearchSort = .match

    private let columns = [
        GridItem(.fixed(258), spacing: 36),
        GridItem(.fixed(258), spacing: 36),
        GridItem(.fixed(258), spacing: 36),
        GridItem(.fixed(258), spacing: 36),
        GridItem(.fixed(258), spacing: 36),
        GridItem(.fixed(258), spacing: 36)
    ]

    private var parsedBgmID: Int? {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0 else { return nil }
        return value
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                headerAndSearchBar
                sortAndQuickJumpBar
                contentSection
            }
            .padding(.horizontal, 80)
            .padding(.top, 52)
            .padding(.bottom, 80)
        }
        .background(Color.black.ignoresSafeArea())
        .onExitCommand {
            withAnimation(.easeInOut(duration: 0.25)) {
                columnVisibility = .all
            }
        }
    }

    private var headerAndSearchBar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text("搜索")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                if store.hasSearched && !store.isSearching && store.errorMessage == nil {
                    Text("共找到 \(store.totalCount) 部动画")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()
            }

            HStack(spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.65))

                    TextField("输入番剧名、关键词或 BGM ID…", text: $queryText)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .onSubmit {
                            triggerSearch()
                        }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .frame(maxWidth: 760)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )

                Button {
                    triggerSearch()
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                        .font(.headline.weight(.semibold))
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.borderedProminent)

                if !queryText.isEmpty {
                    Button {
                        queryText = ""
                        store.reset()
                    } label: {
                        Label("清空", systemImage: "xmark.circle")
                            .font(.headline)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var sortAndQuickJumpBar: some View {
        HStack(spacing: 16) {
            Text("排序")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))

            ForEach(AnimeSearchSort.allCases) { sort in
                Button {
                    selectedSort = sort
                    if !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        triggerSearch()
                    }
                } label: {
                    Text(sort.title)
                        .font(.subheadline.weight(selectedSort == sort ? .bold : .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(selectedSort == sort ? .white : .gray)
            }

            if let bgmID = parsedBgmID {
                Spacer(minLength: 12)

                Button {
                    openAnimeDetail(bgmID)
                } label: {
                    Label("直达 BGM #\(bgmID)", systemImage: "arrow.right.circle.fill")
                        .font(.subheadline.weight(.bold))
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        if store.isSearching {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 36) {
                ForEach(0..<12, id: \.self) { _ in
                    SearchPosterSkeletonCard()
                }
            }
        } else if let errorMessage = store.errorMessage {
            VStack(spacing: 18) {
                ContentUnavailableView(
                    "搜索出错",
                    systemImage: "wifi.exclamationmark",
                    description: Text(errorMessage)
                )
                Button("重试") {
                    triggerSearch()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        } else if !store.hasSearched {
            recentSearchesSection
        } else if store.results.isEmpty {
            ContentUnavailableView(
                "未找到相关番剧",
                systemImage: "magnifyingglass",
                description: Text("换个关键词试试，或直接输入 Bangumi 条目 ID。")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 100)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 36) {
                ForEach(store.results) { item in
                    SearchPosterCard(item: item) {
                        openAnimeDetail(item.id)
                    }
                    .onAppear {
                        store.loadMoreIfNeeded(currentItem: item)
                    }
                }

                if store.isLoadingMore {
                    SearchPosterSkeletonCard()
                }
            }
        }
    }

    @ViewBuilder
    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !store.recentQueries.isEmpty {
                HStack {
                    Text("最近搜索")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white.opacity(0.85))

                    Spacer()

                    Button("清空记录") {
                        store.clearHistory()
                    }
                    .buttonStyle(.bordered)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(store.recentQueries, id: \.self) { query in
                            Button {
                                queryText = query
                                triggerSearch()
                            } label: {
                                Label(query, systemImage: "clock.arrow.circlepath")
                                    .font(.headline.weight(.medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 8)
                }
            } else {
                ContentUnavailableView(
                    "搜索 Bangumi 番剧",
                    systemImage: "sparkles.tv",
                    description: Text("输入中文名、日文原名或 Bangumi 条目 ID 即可查找并播放。")
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 90)
            }
        }
    }

    private func triggerSearch() {
        store.search(keyword: queryText, sort: selectedSort)
    }
}

private struct SearchPosterCard: View {
    let item: BgmSearchSubjectDTO
    let action: () -> Void

    private var subtitleText: String {
        var parts: [String] = []
        if item.score > 0 {
            parts.append("★ \(String(format: "%.1f", item.score))")
        }
        if let date = item.date, date.count >= 4 {
            parts.append(String(date.prefix(4)))
        }
        if let eps = item.totalEpisodes, eps > 0 {
            parts.append("\(eps) 集")
        }
        return parts.isEmpty ? item.name : parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                KFImage(item.posterURL)
                    .resizable()
                    .placeholder {
                        ZStack {
                            Color.white.opacity(0.1)
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.white.opacity(0.24))
                        }
                    }
                    .fade(duration: 0.2)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 258, height: 366)
                    .clipped()

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.displayTitle)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(subtitleText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(width: 258, alignment: .leading)
                .background(Color.white.opacity(0.08))
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.card)
        .frame(width: 258)
    }
}

private struct SearchPosterSkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.white.opacity(0.12)
                .frame(width: 258, height: 366)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.22))
                    .frame(width: 180, height: 18)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.14))
                    .frame(width: 110, height: 14)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(width: 258, alignment: .leading)
            .background(Color.white.opacity(0.08))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .redacted(reason: .placeholder)
    }
}
