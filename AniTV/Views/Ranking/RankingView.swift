//
//  RankingView.swift
//  AniTV
//
//  Bangumi 动画排行榜：支持 时间 / 分类 / 来源 / 类型 / 地区 / 受众 多维筛选与排序
//

import SwiftUI
import Combine
import Kingfisher

enum RankingSortOption: String, CaseIterable, Identifiable {
    case rank = "rank"
    case score = "score"
    case heat = "heat"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rank: return "排名"
        case .score: return "评分"
        case .heat: return "热度"
        }
    }
}

enum RankingTimeFilter: String, CaseIterable, Identifiable, Equatable {
    case all = "全部"
    case y2026 = "2026"
    case y2025 = "2025"
    case y2024 = "2024"
    case y2023 = "2023"
    case y2022 = "2022"
    case y2021 = "2021"
    case y2020 = "2020"
    case y2019 = "2019"
    case y2018 = "2018"
    case y2017 = "2017"
    case y2016 = "2016"
    case y2015 = "2015"
    case y2014 = "2014"
    case y2013 = "2013"
    case y2012 = "2012"
    case y2011 = "2011"
    case y2010 = "2010"
    case decade2000s = "2000-2009"
    case decade1990s = "1990-1999"
    case earlier = "1990 以前"

    var id: String { rawValue }

    var airDateConditions: [String] {
        switch self {
        case .all:
            return []
        case .decade2000s:
            return [">=2000-01-01", "<2010-01-01"]
        case .decade1990s:
            return [">=1990-01-01", "<2000-01-01"]
        case .earlier:
            return ["<1990-01-01"]
        default:
            guard let year = Int(rawValue) else { return [] }
            return [">=\(year)-01-01", "<\(year + 1)-01-01"]
        }
    }
}

struct RankingFilterState: Equatable {
    var time: RankingTimeFilter = .all
    var category: String? = nil      // 分类: TV / WEB / OVA / 剧场版 / 动态漫画 / 其他
    var source: String? = nil        // 来源: 原创 / 漫画改 / 游戏改 / 小说改
    var genre: String? = nil         // 类型: 科幻 / 喜剧 / 恋爱 / 奇幻 / ...
    var region: String? = nil        // 地区: 日本 / 中国 / 欧美 / ...
    var audience: String? = nil      // 受众: BL / GL / 少儿 / 女性向 / 少年向 / 青年向
    var sort: RankingSortOption = .rank

    static let categories = ["TV", "WEB", "OVA", "剧场版", "动态漫画", "其他"]
    static let sources = ["原创", "漫画改", "游戏改", "小说改"]
    static let genres = [
        "科幻", "喜剧", "同人", "百合", "校园", "惊悚", "后宫", "机战",
        "悬疑", "恋爱", "奇幻", "推理", "运动", "耽美", "音乐", "战斗",
        "冒险", "萌系", "穿越", "玄幻", "乙女", "恐怖", "历史", "日常",
        "剧情", "武侠", "美食", "职场"
    ]
    static let regions = [
        "日本", "中国", "欧美", "美国", "韩国", "法国",
        "中国香港", "中国台湾", "英国", "俄罗斯", "苏联", "捷克", "马来西亚"
    ]
    static let audiences = ["少年向", "青年向", "女性向", "少儿", "BL", "GL"]

    var metaTags: [String] {
        [category, source, genre, region, audience].compactMap { $0 }
    }

    var airDateConditions: [String] {
        time.airDateConditions
    }

    var hasActiveFilters: Bool {
        time != .all || category != nil || source != nil || genre != nil || region != nil || audience != nil
    }

    mutating func resetFilters() {
        time = .all
        category = nil
        source = nil
        genre = nil
        region = nil
        audience = nil
    }
}

@MainActor
final class RankingStore: ObservableObject {
    static let shared = RankingStore()

    @Published var filter = RankingFilterState()
    @Published private(set) var items: [BgmSearchSubjectDTO] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?

    private let repository = BangumiRepository()
    private let pageSize = 24
    private var currentOffset = 0
    private var canLoadMore = false
    private var hasLoadedOnce = false
    private var activeTask: Task<Void, Never>?

    private init() {}

    func loadIfNeeded() {
        guard !hasLoadedOnce, !isLoading else { return }
        reload()
    }

    func updateFilter(_ mutate: (inout RankingFilterState) -> Void) {
        var next = filter
        mutate(&next)
        guard next != filter else { return }
        filter = next
        reload()
    }

    func reload() {
        activeTask?.cancel()
        let snapshotFilter = filter
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        currentOffset = 0
        canLoadMore = false

        activeTask = Task {
            do {
                let response = try await repository.fetchRankingSubjects(
                    sort: snapshotFilter.sort.rawValue,
                    metaTags: snapshotFilter.metaTags,
                    airDateConditions: snapshotFilter.airDateConditions,
                    limit: pageSize,
                    offset: 0
                )
                guard !Task.isCancelled else { return }
                items = response.data
                totalCount = response.total
                currentOffset = response.data.count
                canLoadMore = response.data.count < response.total && !response.data.isEmpty
                hasLoadedOnce = true
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                items = []
                totalCount = 0
                errorMessage = "排行榜加载失败：\(error.localizedDescription)"
                isLoading = false
            }
        }
    }

    func loadMoreIfNeeded(currentItem: BgmSearchSubjectDTO) {
        guard currentItem.id == items.last?.id,
              canLoadMore,
              !isLoading,
              !isLoadingMore else {
            return
        }

        let snapshotFilter = filter
        let offset = currentOffset
        isLoadingMore = true

        Task {
            do {
                let response = try await repository.fetchRankingSubjects(
                    sort: snapshotFilter.sort.rawValue,
                    metaTags: snapshotFilter.metaTags,
                    airDateConditions: snapshotFilter.airDateConditions,
                    limit: pageSize,
                    offset: offset
                )
                guard snapshotFilter == filter else {
                    isLoadingMore = false
                    return
                }
                var existing = Set(items.map(\.id))
                for entry in response.data where existing.insert(entry.id).inserted {
                    items.append(entry)
                }
                currentOffset += response.data.count
                canLoadMore = currentOffset < response.total && !response.data.isEmpty
                isLoadingMore = false
            } catch {
                isLoadingMore = false
            }
        }
    }
}

struct RankingView: View {
    @Binding var columnVisibility: NavigationSplitViewVisibility
    let openAnimeDetail: (Int) -> Void

    @ObservedObject private var store = RankingStore.shared

    private let columns = [
        GridItem(.fixed(258), spacing: 36),
        GridItem(.fixed(258), spacing: 36),
        GridItem(.fixed(258), spacing: 36),
        GridItem(.fixed(258), spacing: 36),
        GridItem(.fixed(258), spacing: 36),
        GridItem(.fixed(258), spacing: 36)
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                headerRow
                filterBar
                contentSection
            }
            .padding(.horizontal, 80)
            .padding(.top, 52)
            .padding(.bottom, 80)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.05, blue: 0.10),
                    Color.black
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .onAppear {
            store.loadIfNeeded()
        }
        .onExitCommand {
            withAnimation(.easeInOut(duration: 0.25)) {
                columnVisibility = .all
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 20) {
            Text("排行榜")
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            if !store.isLoading && store.errorMessage == nil && store.totalCount > 0 {
                Text("共 \(store.totalCount) 部动画")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.58))
            }

            Spacer()

            HStack(spacing: 12) {
                ForEach(RankingSortOption.allCases) { option in
                    let selected = store.filter.sort == option
                    Button {
                        store.updateFilter { $0.sort = option }
                    } label: {
                        Text(option.title)
                            .font(.callout.weight(selected ? .bold : .medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(selected ? .cyan : Color.white.opacity(0.14))
                }
            }
        }
        .focusSection()
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                // 1. 时间
                Menu {
                    ForEach(RankingTimeFilter.allCases) { option in
                        Button {
                            store.updateFilter { $0.time = option }
                        } label: {
                            if store.filter.time == option {
                                Label(option.rawValue, systemImage: "checkmark")
                            } else {
                                Text(option.rawValue)
                            }
                        }
                    }
                } label: {
                    RankingFilterChipLabel(
                        title: "时间",
                        value: store.filter.time.rawValue,
                        isActive: store.filter.time != .all
                    )
                }

                // 2. 分类
                optionalFilterMenu(
                    title: "分类",
                    options: RankingFilterState.categories,
                    selection: store.filter.category
                ) { selected in
                    store.updateFilter { $0.category = selected }
                }

                // 3. 来源
                optionalFilterMenu(
                    title: "来源",
                    options: RankingFilterState.sources,
                    selection: store.filter.source
                ) { selected in
                    store.updateFilter { $0.source = selected }
                }

                // 4. 类型
                optionalFilterMenu(
                    title: "类型",
                    options: RankingFilterState.genres,
                    selection: store.filter.genre
                ) { selected in
                    store.updateFilter { $0.genre = selected }
                }

                // 5. 地区
                optionalFilterMenu(
                    title: "地区",
                    options: RankingFilterState.regions,
                    selection: store.filter.region
                ) { selected in
                    store.updateFilter { $0.region = selected }
                }

                // 6. 受众
                optionalFilterMenu(
                    title: "受众",
                    options: RankingFilterState.audiences,
                    selection: store.filter.audience
                ) { selected in
                    store.updateFilter { $0.audience = selected }
                }

                if store.filter.hasActiveFilters {
                    Button {
                        store.updateFilter { $0.resetFilters() }
                    } label: {
                        Label("重置", systemImage: "arrow.counterclockwise")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
        }
        .focusSection()
    }

    private func optionalFilterMenu(
        title: String,
        options: [String],
        selection: String?,
        onSelect: @escaping (String?) -> Void
    ) -> some View {
        Menu {
            Button {
                onSelect(nil)
            } label: {
                if selection == nil {
                    Label("全部", systemImage: "checkmark")
                } else {
                    Text("全部")
                }
            }

            Divider()

            ForEach(options, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    if selection == option {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            RankingFilterChipLabel(
                title: title,
                value: selection ?? "全部",
                isActive: selection != nil
            )
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        if store.isLoading && store.items.isEmpty {
            HStack(spacing: 16) {
                ProgressView()
                Text("正在加载排行榜…")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        } else if let errorMessage = store.errorMessage {
            ContentUnavailableView {
                Label("排行榜加载失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button {
                    store.reload()
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        } else if store.items.isEmpty {
            ContentUnavailableView {
                Label("没有符合条件的动画", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("尝试放宽时间、类型或地区等筛选条件")
            } actions: {
                if store.filter.hasActiveFilters {
                    Button {
                        store.updateFilter { $0.resetFilters() }
                    } label: {
                        Label("重置筛选", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 44) {
                ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                    RankingPosterCardView(
                        item: item,
                        displayRank: item.rank > 0 ? item.rank : (index + 1),
                        orderIndex: index + 1
                    ) {
                        openAnimeDetail(item.id)
                    }
                    .onAppear {
                        store.loadMoreIfNeeded(currentItem: item)
                    }
                }
            }
            .focusSection()

            if store.isLoadingMore {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("加载更多…")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
            }
        }
    }
}

private struct RankingFilterChipLabel: View {
    let title: String
    let value: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? Color.cyan : Color.white.opacity(0.62))

            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)

            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct RankingPosterCardView: View {
    let item: BgmSearchSubjectDTO
    let displayRank: Int
    let orderIndex: Int
    let onSelect: () -> Void

    private static let posterProcessor = DownsamplingImageProcessor(size: CGSize(width: 516, height: 732))

    private var rankBadgeColor: Color {
        switch orderIndex {
        case 1: return Color(red: 0.96, green: 0.76, blue: 0.22)
        case 2: return Color(red: 0.78, green: 0.82, blue: 0.88)
        case 3: return Color(red: 0.84, green: 0.54, blue: 0.34)
        default: return Color.black.opacity(0.74)
        }
    }

    private var rankTextColor: Color {
        orderIndex <= 3 ? .black : .white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onSelect) {
                ZStack(alignment: .topLeading) {
                    KFImage(item.posterURL)
                        .placeholder {
                            ZStack {
                                Color.white.opacity(0.1)
                                Image(systemName: "film")
                                    .font(.largeTitle)
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                        }
                        .setProcessor(Self.posterProcessor)
                        .cacheOriginalImage()
                        .cancelOnDisappear(true)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 258, height: 366)
                        .clipped()

                    HStack {
                        Text("#\(displayRank)")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(rankTextColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(rankBadgeColor, in: Capsule())

                        Spacer()

                        if item.score > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.yellow)
                                Text(String(format: "%.1f", item.score))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.74), in: Capsule())
                        }
                    }
                    .padding(12)
                }
                .frame(width: 258, height: 366)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.card)
            .frame(width: 258, height: 366)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let date = item.date, !date.isEmpty {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }
            }
            .frame(width: 258, alignment: .leading)
        }
        .frame(width: 258)
    }
}
