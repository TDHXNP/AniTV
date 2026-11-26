//
//  TimelineView.swift
//  AniTV
//
//  Created by Codex on 2026/4/9.
//

import Foundation
import Combine
import SwiftUI
import Kingfisher
import SQLiteData
import Dependencies

private struct TimelineCardModel: Identifiable, Equatable, Sendable {
    let id: String
    let bangumiID: Int?
    let displayTitle: String
    let episodeLine: String
    let displayTime: String
    let coverURL: URL?
    let airingTimestamp: Int
    let isUnknownTime: Bool
}

private struct TimelineDaySectionModel: Identifiable, Equatable, Sendable {
    let id: String
    let monthDayText: String
    let subtitleText: String
    let isToday: Bool
    let cards: [TimelineCardModel]
    let cardIDs: Set<String>
}

private struct TimelineInitialTarget: Equatable, Sendable {
    let dayKey: String
    let entryID: String
    let leadingDayKey: String
}

@MainActor
final class TimelineStore: ObservableObject {
    static let shared = TimelineStore()

    @Published fileprivate private(set) var sections: [TimelineDaySectionModel] = []
    @Published fileprivate private(set) var initialTarget: TimelineInitialTarget?
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage = ""

    private let service = TimelineService()
    private var hasLoaded = false
    private var lastLoadedDayKey = ""
    private var isCurrentlyFetching = false

    private init() {}

    func loadIfNeeded(database: any DatabaseWriter) async {
        let currentDayKey = TimelineBoardFormatter.todayKey
        if hasLoaded, !sections.isEmpty, lastLoadedDayKey == currentDayKey {
            isLoading = false
            return
        }
        await load(database: database)
    }

    func load(database: any DatabaseWriter) async {
        guard !isCurrentlyFetching else { return }
        isCurrentlyFetching = true
        defer { isCurrentlyFetching = false }

        if sections.isEmpty {
            isLoading = true
        }
        errorMessage = ""

        do {
            let map = try await service.fetchTimelineMap(database: database)
            let now = Date()
            let built = await Task.detached(priority: .userInitiated) {
                TimelineViewModelBuilder.build(from: map, now: now)
            }.value

            sections = built.sections
            initialTarget = built.initialTarget
            lastLoadedDayKey = built.todayKey
            isLoading = false
            hasLoaded = true
        } catch {
            if sections.isEmpty {
                errorMessage = error.localizedDescription
            }
            isLoading = false
            hasLoaded = !sections.isEmpty
        }
    }
}

private enum TimelineViewModelBuilder {
    nonisolated static func build(
        from map: TimelineDayMap,
        now: Date
    ) -> (sections: [TimelineDaySectionModel], initialTarget: TimelineInitialTarget?, todayKey: String) {
        let calendar = TimelineBoardFormatter.makeCalendar()
        let dayFormatter = TimelineBoardFormatter.makeDayKeyFormatter(calendar: calendar)
        let monthDayFormatter = TimelineBoardFormatter.makeMonthDayFormatter(calendar: calendar)
        let timeFormatter = TimelineBoardFormatter.makeTimeFormatter(calendar: calendar)

        let todayKey = dayFormatter.string(from: now)
        let todayWeekStart = TimelineBoardFormatter.startOfWeek(for: now, calendar: calendar)
        let orderedDays = map.keys.sorted()

        var sections: [TimelineDaySectionModel] = []
        sections.reserveCapacity(orderedDays.count)

        for dayKey in orderedDays {
            let entries = map[dayKey] ?? []
            let date = dayFormatter.date(from: dayKey)
            let monthDayText = date.map { monthDayFormatter.string(from: $0) } ?? dayKey
            let isToday = dayKey == todayKey
            let subtitleText: String
            if isToday {
                subtitleText = "Today"
            } else if let date {
                subtitleText = TimelineBoardFormatter.weekdayText(
                    for: date,
                    todayWeekStart: todayWeekStart,
                    calendar: calendar
                )
            } else {
                subtitleText = ""
            }

            var cards: [TimelineCardModel] = []
            cards.reserveCapacity(entries.count)
            var cardIDs: Set<String> = []
            cardIDs.reserveCapacity(entries.count)

            for entry in entries {
                let cnTitle = entry.subjectTitleCN?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let displayTitle = cnTitle.isEmpty ? entry.subjectTitle : cnTitle

                let cnEpisode = entry.episodeNameCN?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let episodeTitle = !cnEpisode.isEmpty
                    ? cnEpisode
                    : (entry.episodeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                let sortText = TimelineBoardFormatter.episodeText(for: entry.episodeSort)
                let episodeLine = episodeTitle.isEmpty
                    ? "第 \(sortText) 集"
                    : "第 \(sortText) 集 \(episodeTitle)"

                let isUnknownTime = entry.airingTimestamp == .max
                let displayTime = isUnknownTime
                    ? "unknown"
                    : timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(entry.airingTimestamp)))

                let card = TimelineCardModel(
                    id: entry.id,
                    bangumiID: entry.bangumiID.flatMap(Int.init),
                    displayTitle: displayTitle,
                    episodeLine: episodeLine,
                    displayTime: displayTime,
                    coverURL: entry.coverImageURL.flatMap(URL.init(string:)),
                    airingTimestamp: entry.airingTimestamp,
                    isUnknownTime: isUnknownTime
                )
                cards.append(card)
                cardIDs.insert(card.id)
            }

            sections.append(
                TimelineDaySectionModel(
                    id: dayKey,
                    monthDayText: monthDayText,
                    subtitleText: subtitleText,
                    isToday: isToday,
                    cards: cards,
                    cardIDs: cardIDs
                )
            )
        }

        let nowTimestamp = Int(now.timeIntervalSince1970)
        var initialTarget: TimelineInitialTarget?
        for index in sections.indices.reversed() {
            let section = sections[index]
            if let lastAired = section.cards.last(where: { $0.airingTimestamp <= nowTimestamp }) {
                let leadingIndex = max(index - 1, 0)
                initialTarget = TimelineInitialTarget(
                    dayKey: section.id,
                    entryID: lastAired.id,
                    leadingDayKey: sections[leadingIndex].id
                )
                break
            }
        }

        return (sections, initialTarget, todayKey)
    }
}

struct TimelineView: View {
    let openAnimeDetail: (Int) -> Void

    @ObservedObject private var store = TimelineStore.shared
    @Dependency(\.defaultDatabase) private var database

    var body: some View {
        Group {
            if store.isLoading {
                ProgressView()
                    .tint(.white)
                    .focusable()
            } else if !store.errorMessage.isEmpty {
                ContentUnavailableView {
                    Label("时间线加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(store.errorMessage)
                } actions: {
                    Button {
                        Task {
                            await store.load(database: database)
                        }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if store.sections.isEmpty {
                ContentUnavailableView(
                    "暂无时间线数据",
                    systemImage: "calendar"
                )
            } else {
                TimelineBoardView(
                    sections: store.sections,
                    initialTarget: store.initialTarget,
                    openAnimeDetail: openAnimeDetail
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.12),
                    Color(red: 0.02, green: 0.03, blue: 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .task {
            TimelinePosterCache.configureIfNeeded()
            await store.loadIfNeeded(database: database)
        }
    }
}

private enum TimelinePosterCache {
    private static var didConfigure = false

    static func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true

        ImageCache.default.memoryStorage.config.expiration = .days(7)
        ImageCache.default.memoryStorage.config.totalCostLimit = 120 * 1024 * 1024
        ImageCache.default.memoryStorage.config.countLimit = 160
        ImageCache.default.diskStorage.config.expiration = .days(7)
    }
}

private struct TimelineBoardView: View {
    let sections: [TimelineDaySectionModel]
    let initialTarget: TimelineInitialTarget?
    let openAnimeDetail: (Int) -> Void

    @Namespace private var timelineFocusScope
    @FocusState private var focusedEntryID: String?
    @State private var didScrollToInitialPosition = false

    var body: some View {
        let initialFocusDay = initialTarget?.dayKey ?? sections.first?.id

        ScrollViewReader { scrollProxy in
            GeometryReader { proxy in
                let columnHeight = max(proxy.size.height - 36, 320)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 28) {
                        ForEach(sections) { section in
                            TimelineDayColumnView(
                                section: section,
                                availableHeight: columnHeight,
                                shouldPreferInitialFocus: section.id == initialFocusDay,
                                initialPreferredEntryID: section.id == initialFocusDay ? initialTarget?.entryID : nil,
                                focusedEntryID: $focusedEntryID,
                                focusScope: timelineFocusScope,
                                openAnimeDetail: openAnimeDetail
                            )
                            .id(section.id)
                        }
                    }
                    .frame(height: max(proxy.size.height - 36, 0), alignment: .top)
                    .padding(.horizontal, 48)
                    .padding(.top, 36)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .focusScope(timelineFocusScope)
                .task {
                    guard !didScrollToInitialPosition else { return }
                    didScrollToInitialPosition = true
                    await focusInitialEntry(using: scrollProxy)
                }
            }
        }
    }

    private func focusInitialEntry(using scrollProxy: ScrollViewProxy) async {
        guard let target = initialTarget else { return }

        // Scroll immediately so LazyHStack materializes the target column right away.
        scrollProxy.scrollTo(target.leadingDayKey, anchor: .leading)

        try? await Task.sleep(for: .milliseconds(80))

        withAnimation(.easeInOut(duration: 0.25)) {
            scrollProxy.scrollTo(target.leadingDayKey, anchor: .leading)
        }

        try? await Task.sleep(for: .milliseconds(220))

        focusedEntryID = target.entryID
    }
}

private struct TimelineDayColumnView: View {
    let section: TimelineDaySectionModel
    let availableHeight: CGFloat
    let shouldPreferInitialFocus: Bool
    let initialPreferredEntryID: String?
    let focusedEntryID: FocusState<String?>.Binding
    let focusScope: Namespace.ID
    let openAnimeDetail: (Int) -> Void

    private let headerHeight: CGFloat = 72
    @State private var didScrollToPreferredEntry = false
    @State private var didInitialVerticalScroll = false
    @State private var todayNow = Date()

    private var splitterInsertionIndex: Int? {
        guard section.isToday else { return nil }
        let nowTimestamp = Int(todayNow.timeIntervalSince1970)
        return section.cards.firstIndex { $0.airingTimestamp > nowTimestamp }
    }

    private var preferredFocusIndex: Int {
        if let initialPreferredEntryID,
           let matchedIndex = section.cards.firstIndex(where: { $0.id == initialPreferredEntryID }) {
            return matchedIndex
        }
        if let splitterInsertionIndex {
            return max(splitterInsertionIndex - 1, 0)
        }
        return max(section.cards.count - 1, 0)
    }

    private var verticalScrollAnchorID: String? {
        let anchorIndex = max(preferredFocusIndex - 2, 0)
        guard section.cards.indices.contains(anchorIndex) else { return nil }
        return section.cards[anchorIndex].id
    }

    private var shouldShowSplitterAtEnd: Bool {
        section.isToday && !section.cards.isEmpty && splitterInsertionIndex == nil
    }

    var body: some View {
        let insertionIndex = splitterInsertionIndex
        let preferredIndex = preferredFocusIndex

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(section.monthDayText)
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(.white)

                Text(section.subtitleText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(section.isToday ? Color.cyan.opacity(0.9) : .secondary)
            }
            .padding(.horizontal, 6)
            .frame(height: headerHeight, alignment: .topLeading)
            .padding(.bottom, 18)

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(Array(section.cards.enumerated()), id: \.element.id) { index, card in
                            if let insertionIndex, index == insertionIndex {
                                TimelineNowSplitter(currentTime: todayNow)
                            }

                            TimelineEpisodeCard(
                                card: card,
                                shouldPreferFocus: shouldPreferInitialFocus && preferredIndex == index,
                                focusedEntryID: focusedEntryID,
                                focusScope: focusScope,
                                openAnimeDetail: openAnimeDetail
                            )
                            .id(card.id)
                        }

                        if shouldShowSplitterAtEnd {
                            TimelineNowSplitter(currentTime: todayNow)
                        }
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(height: max(availableHeight - headerHeight, 220))
                .task {
                    guard shouldPreferInitialFocus,
                          !didScrollToPreferredEntry,
                          let anchorID = verticalScrollAnchorID else { return }

                    didScrollToPreferredEntry = true
                    scrollProxy.scrollTo(anchorID, anchor: .top)

                    try? await Task.sleep(for: .milliseconds(350))
                    didInitialVerticalScroll = true
                }
                .task(id: section.isToday) {
                    guard section.isToday else { return }
                    todayNow = Date()
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        guard !Task.isCancelled else { break }
                        todayNow = Date()
                    }
                }
                .onChange(of: focusedEntryID.wrappedValue) { _, newValue in
                    guard let newValue,
                          section.cardIDs.contains(newValue) else { return }

                    if shouldPreferInitialFocus && !didInitialVerticalScroll {
                        return
                    }

                    withAnimation(.easeInOut(duration: 0.22)) {
                        scrollProxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 420, height: availableHeight, alignment: .topLeading)
    }
}

private struct TimelineEpisodeCard: View {
    let card: TimelineCardModel
    let shouldPreferFocus: Bool
    let focusedEntryID: FocusState<String?>.Binding
    let focusScope: Namespace.ID
    let openAnimeDetail: (Int) -> Void

    private static let cardBackgroundGradient = LinearGradient(
        colors: [
            Color.white.opacity(0.1),
            Color.white.opacity(0.04)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text(card.displayTitle)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text(card.displayTime)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(card.isUnknownTime ? .white.opacity(0.7) : .cyan.opacity(0.95))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            card.isUnknownTime ? Color.white.opacity(0.08) : Color.cyan.opacity(0.18),
                            in: Capsule()
                        )
                }

                Text(card.episodeLine)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(2)
            }
            .padding(.leading, 120)
            .padding(.top, 13)
            .padding(.trailing, 18)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
            .background(Self.cardBackgroundGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1.2)
            )

            TimelinePosterButton(
                imageURL: card.coverURL,
                shouldPreferFocus: shouldPreferFocus,
                focusID: card.id,
                focusedEntryID: focusedEntryID,
                focusScope: focusScope,
                onOpen: {
                    if let bangumiID = card.bangumiID {
                        openAnimeDetail(bangumiID)
                    }
                }
            )
            .padding(.leading, 18)
            .padding(.top, 13)
            .zIndex(1)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct TimelinePosterButton: View {
    let imageURL: URL?
    let shouldPreferFocus: Bool
    let focusID: String
    let focusedEntryID: FocusState<String?>.Binding
    let focusScope: Namespace.ID
    let onOpen: () -> Void

    @Environment(\.isFocused) private var isFocused

    private static let posterProcessor = DownsamplingImageProcessor(size: CGSize(width: 172, height: 244))
    private static let placeholderGradient = LinearGradient(
        colors: [Color.white.opacity(0.18), Color.white.opacity(0.05)],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        Button(action: {
            focusedEntryID.wrappedValue = focusID
            onOpen()
        }) {
            KFImage(imageURL)
                .placeholder {
                    Self.placeholderGradient
                }
                .setProcessor(Self.posterProcessor)
                .cacheOriginalImage()
                .cancelOnDisappear(true)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 86, height: 122)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.card)
        .focused(focusedEntryID, equals: focusID)
        .prefersDefaultFocus(shouldPreferFocus, in: focusScope)
        .offset(y: isFocused ? 12 : 0)
        .zIndex(isFocused ? 2 : 0)
        .animation(.easeInOut(duration: 0.16), value: isFocused)
    }
}

private struct TimelineNowSplitter: View {
    let currentTime: Date

    var body: some View {
        HStack(spacing: 12) {
            Capsule()
                .fill(Color.cyan.opacity(0.85))
                .frame(height: 3)

            Text(TimelineBoardFormatter.currentTimeText(for: currentTime))
                .font(.caption.weight(.heavy))
                .foregroundStyle(.cyan.opacity(0.95))

            Capsule()
                .fill(Color.cyan.opacity(0.85))
                .frame(height: 3)
        }
        .padding(.vertical, 4)
    }
}

private enum TimelineBoardFormatter {
    static let calendar: Calendar = makeCalendar()
    static let dayKeyFormatter: DateFormatter = makeDayKeyFormatter(calendar: calendar)
    static let timeFormatter: DateFormatter = makeTimeFormatter(calendar: calendar)

    nonisolated static let weekdaySymbols = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    nonisolated static func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    nonisolated static func makeDayKeyFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    nonisolated static func makeMonthDayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M/d"
        return formatter
    }

    nonisolated static func makeTimeFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    static var todayKey: String {
        dayKeyFormatter.string(from: Date())
    }

    nonisolated static func weekdayText(for date: Date, todayWeekStart: Date, calendar: Calendar) -> String {
        let weekdayIndex = calendar.component(.weekday, from: date) - 1
        let weekday = weekdaySymbols.indices.contains(weekdayIndex) ? weekdaySymbols[weekdayIndex] : ""
        guard !weekday.isEmpty else { return "" }

        let targetWeekStart = startOfWeek(for: date, calendar: calendar)
        let dayOffset = calendar.dateComponents([.day], from: todayWeekStart, to: targetWeekStart).day ?? 0

        if dayOffset <= -7 {
            return "上\(weekday)"
        }
        if dayOffset >= 7 {
            return "下\(weekday)"
        }
        return weekday
    }

    static func currentTimeText(for date: Date) -> String {
        timeFormatter.string(from: date)
    }

    nonisolated static func episodeText(for sort: Double?) -> String {
        guard let sort else { return "?" }
        if abs(sort.rounded() - sort) < 0.0001 {
            return String(Int(sort.rounded()))
        }
        return String(format: "%.1f", sort)
    }

    static func key(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    nonisolated static func startOfWeek(for date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }
}

#Preview("Timeline Board") {
    let calendar = TimelineBoardFormatter.calendar
    let now = Date()
    let todayKey = TimelineBoardFormatter.key(for: now)
    let yesterdayKey = TimelineBoardFormatter.key(for: calendar.date(byAdding: .day, value: -1, to: now) ?? now)
    let tomorrowKey = TimelineBoardFormatter.key(for: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
    let laterToday = Int((calendar.date(byAdding: .hour, value: 2, to: now) ?? now).timeIntervalSince1970)
    let tonight = Int((calendar.date(byAdding: .hour, value: 5, to: now) ?? now).timeIntervalSince1970)

    let sampleTimeline: TimelineDayMap = [
        yesterdayKey: [
            TimelineEpisodeEntry(
                dateKey: yesterdayKey,
                airingTimestamp: Int((calendar.date(byAdding: .hour, value: -20, to: now) ?? now).timeIntervalSince1970),
                anilistID: 101,
                bangumiID: "621358",
                subjectTitle: "魔物喰らいの冒険者～俺だけ魔物を喰らって強くなる～",
                subjectTitleCN: "吞噬魔物的冒险者",
                episodeID: 9001,
                episodeSort: 1,
                episodeName: "瘴気漁り",
                episodeNameCN: "",
                coverImageURL: "https://lain.bgm.tv/pic/cover/l/8f/47/621358_hVvMr.jpg",
                isAniListMissing: false
            )
        ],
        todayKey: [
            TimelineEpisodeEntry(
                dateKey: todayKey,
                airingTimestamp: Int((calendar.date(byAdding: .hour, value: -1, to: now) ?? now).timeIntervalSince1970),
                anilistID: 201,
                bangumiID: "620001",
                subjectTitle: "勇者之扉",
                subjectTitleCN: "勇者之扉",
                episodeID: 9101,
                episodeSort: 13,
                episodeName: "勇者的觉醒",
                episodeNameCN: "",
                coverImageURL: "https://lain.bgm.tv/pic/cover/l/0b/52/620001_example.jpg",
                isAniListMissing: false
            ),
            TimelineEpisodeEntry(
                dateKey: todayKey,
                airingTimestamp: laterToday,
                anilistID: 202,
                bangumiID: "620002",
                subjectTitle: "摩绪",
                subjectTitleCN: "",
                episodeID: 9102,
                episodeSort: 2,
                episodeName: "集结魔链女",
                episodeNameCN: "",
                coverImageURL: "https://lain.bgm.tv/pic/cover/l/1a/11/620002_example.jpg",
                isAniListMissing: false
            ),
            TimelineEpisodeEntry(
                dateKey: todayKey,
                airingTimestamp: tonight,
                anilistID: 203,
                bangumiID: "620003",
                subjectTitle: "主播女孩重度依赖",
                subjectTitleCN: "主播女孩重度依赖",
                episodeID: 9103,
                episodeSort: 2,
                episodeName: "Just the Two of Us",
                episodeNameCN: "",
                coverImageURL: "https://lain.bgm.tv/pic/cover/l/2b/22/620003_example.jpg",
                isAniListMissing: false
            )
        ],
        tomorrowKey: [
            TimelineEpisodeEntry(
                dateKey: tomorrowKey,
                airingTimestamp: Int.max,
                anilistID: nil,
                bangumiID: "620004",
                subjectTitle: "边缘大人的白给是恶魔级",
                subjectTitleCN: "边缘大人的白给是恶魔级",
                episodeID: 9104,
                episodeSort: 2,
                episodeName: "アニきちゃった",
                episodeNameCN: "",
                coverImageURL: "https://lain.bgm.tv/pic/cover/l/3c/33/620004_example.jpg",
                isAniListMissing: true
            )
        ]
    ]

    let built = TimelineViewModelBuilder.build(from: sampleTimeline, now: now)
    TimelineBoardView(
        sections: built.sections,
        initialTarget: built.initialTarget,
        openAnimeDetail: { _ in }
    )
}
