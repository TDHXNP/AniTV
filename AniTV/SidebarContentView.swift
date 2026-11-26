//
//  SidebarContentView.swift
//  AniTV
//
//  Created by Codex on 2426/4/4.
//

import SwiftUI
import SQLiteData

enum NavigationCategory: String, Hashable {
    case search
    case home
    case ranking
    case animeList
    case timeline
    case settings
}

struct SidebarContentView: View {
    @Environment(\.resetFocus) private var resetFocus
    @StateObject private var router = AppRouter()
    @ObservedObject private var deepLinkCoordinator = DeepLinkCoordinator.shared
    @State private var showingProfileSelection = false
    @State private var currentProfile: UserProfile?
    @State private var homeContinueWatchingRefreshToken = 0
    @Dependency(\.defaultDatabase) private var database
    @FocusState private var focusedCategory: NavigationCategory?
    @FocusState private var isSidebarFocused: Bool
    @FocusState private var isProfileButtonFocused: Bool
    @Namespace private var sidebarFocusScope

    private var currentUserName: String {
        currentProfile?.effectiveNickname ?? "Guest"
    }

    private var currentUserAvatarURL: URL? {
        guard let avatar = currentProfile?.effectiveAvatar else { return nil }
        return URL(string: avatar)
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            NavigationSplitView(columnVisibility: sidebarColumnVisibility) {
                List(selection: selectedCategory) {
                    Section {
                        Button {
                            showingProfileSelection = true
                        } label: {
                            HStack(spacing: 12) {
                                SidebarUserAvatarView(url: currentUserAvatarURL)

                                VStack(alignment: .leading, spacing: 2) {
                                    ZStack(alignment: .leading) {
                                        Text(currentUserName)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .opacity(isProfileButtonFocused ? 0 : 1)

                                        Text(currentUserName)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .opacity(isProfileButtonFocused ? 1 : 0)
                                    }
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    if isProfileButtonFocused {
                                        Text("切换账户")
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.72))
                                            .transition(
                                                .opacity.combined(with: .move(edge: .top))
                                            )
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 60)
                            .padding(.vertical, 6)
                            .animation(.easeInOut(duration: 0.22), value: isProfileButtonFocused)
                        }
                        .buttonStyle(.plain)
                        .focused($isProfileButtonFocused)
                    }

                    Section {
                        NavigationLink(value: NavigationCategory.search) {
                            Label("搜索", systemImage: "magnifyingglass")
                        }
                        .prefersDefaultFocus(shouldPreferSidebarFocus && router.selectedCategory == .search, in: sidebarFocusScope)
                        .focused($focusedCategory, equals: .search)

                        NavigationLink(value: NavigationCategory.home) {
                            Label("首页", systemImage: "house")
                        }
                        .prefersDefaultFocus(shouldPreferSidebarFocus && router.selectedCategory == .home, in: sidebarFocusScope)
                        .focused($focusedCategory, equals: .home)

                        NavigationLink(value: NavigationCategory.ranking) {
                            Label("排行榜", systemImage: "trophy")
                        }
                        .prefersDefaultFocus(shouldPreferSidebarFocus && router.selectedCategory == .ranking, in: sidebarFocusScope)
                        .focused($focusedCategory, equals: .ranking)

                        NavigationLink(value: NavigationCategory.animeList) {
                            Label("收藏", systemImage: "play.tv")
                        }
                        .prefersDefaultFocus(shouldPreferSidebarFocus && router.selectedCategory == .animeList, in: sidebarFocusScope)
                        .focused($focusedCategory, equals: .animeList)

                        NavigationLink(value: NavigationCategory.timeline) {
                            Label("时间线", systemImage: "calendar")
                        }
                        .prefersDefaultFocus(shouldPreferSidebarFocus && router.selectedCategory == .timeline, in: sidebarFocusScope)
                        .focused($focusedCategory, equals: .timeline)

                        NavigationLink(value: NavigationCategory.settings) {
                            Label("设置", systemImage: "gear")
                        }
                        .prefersDefaultFocus(shouldPreferSidebarFocus && router.selectedCategory == .settings, in: sidebarFocusScope)
                        .focused($focusedCategory, equals: .settings)
                    } header: {
                        Spacer()
                            .frame(height: 8)
                    }
                }
                .sidebarRowSpacing(12)
                .focused($isSidebarFocused)
                .focusScope(sidebarFocusScope)
            } detail: {
                SidebarDetailView(
                    selectedCategory: selectedCategory,
                    columnVisibility: sidebarColumnVisibility,
                    homeContinueWatchingRefreshToken: homeContinueWatchingRefreshToken,
                    openAnimeDetail: router.showAnimeDetail,
                    openEpisodePlayer: { episodes, episodeInfo, sessionTitle, initialPlaybackPositionSeconds in
                        router.showEpisodePlayer(
                            episodes: episodes,
                            episodeID: episodeInfo.id,
                            sessionTitle: sessionTitle,
                            initialPlaybackPositionSeconds: initialPlaybackPositionSeconds
                        )
                    }
                )
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .animeDetail(let bgmId):
                    AnimeDetailScreen(
                        bgmId: bgmId,
                        onClose: {
                            if router.selectedCategory == .home {
                                homeContinueWatchingRefreshToken += 1
                            }
                        }
                    )
                    .environmentObject(router)
                case .episodePlayer(let route):
                    AnimeEpisodePlayerScreen(
                        episodes: route.episodes,
                        initialEpisodeID: route.initialEpisodeID,
                        sessionTitle: route.sessionTitle,
                        initialPlaybackPositionSeconds: route.initialPlaybackPositionSeconds,
                        onScreenDisappear: {
                            router.notifyPlayerDismissed()
                        },
                        onExitRequest: {
                            router.pop()
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationBarBackButtonHidden(true)
                }
            }
        }
        .sheet(isPresented: $showingProfileSelection) {
            ProfileSwitcherView(currentUser: currentUserName)
        }
        .onAppear {
            router.selectedCategory = .home
            if let action = deepLinkCoordinator.consumePendingAction() {
                handleDeepLink(action)
            } else {
                requestSidebarFocus()
            }
        }
        .onChange(of: deepLinkCoordinator.pendingAction) { _, newValue in
            guard newValue != nil, let action = deepLinkCoordinator.consumePendingAction() else { return }
            handleDeepLink(action)
        }
        .task {
            await loadCurrentProfile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .userProfileDidChange)) { _ in
            Task {
                await loadCurrentProfile()
            }
        }
        .onChange(of: router.selectedCategory) { _, newValue in
            if router.columnVisibility != .detailOnly {
                focusedCategory = newValue
            }
        }
        .onChange(of: isSidebarFocused) { oldValue, newValue in
            if !oldValue, newValue {
                requestSidebarFocus()
            }
        }
        .onChange(of: router.columnVisibility) { oldValue, newValue in
            if oldValue == .detailOnly, newValue != .detailOnly {
                requestSidebarFocus()
            }
        }
    }

    private var selectedCategory: Binding<NavigationCategory?> {
        Binding(
            get: { router.selectedCategory },
            set: { newValue in
                router.selectedCategory = newValue ?? .home
            }
        )
    }

    private var sidebarColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { router.columnVisibility },
            set: { newValue in
                router.columnVisibility = newValue
            }
        )
    }

    private var shouldPreferSidebarFocus: Bool {
        router.columnVisibility != .detailOnly && router.path.isEmpty
    }

    private func requestSidebarFocus() {
        Task { @MainActor in
            focusedCategory = nil
            isProfileButtonFocused = false
            try? await Task.sleep(for: .milliseconds(150))
            guard router.columnVisibility != .detailOnly, router.path.isEmpty else { return }
            focusedCategory = router.selectedCategory
            resetFocus(in: sidebarFocusScope)
        }
    }

    private func loadCurrentProfile() async {
        do {
            currentProfile = try await AniTVDatabase.currentUserProfile(in: database)
        } catch {
            print("[SidebarContentView] Failed to load current user profile: \(error)")
            currentProfile = nil
        }
    }

    private func handleDeepLink(_ action: DeepLinkAction) {
        router.columnVisibility = .detailOnly
        router.selectedCategory = .home
        router.path = []

        switch action {
        case .animeDetail(let bgmID):
            router.showAnimeDetail(bgmID)
        case .playAnime(let bgmID):
            Task { @MainActor in
                await openDirectPlaybackFromDeepLink(bgmID: bgmID)
            }
        }
    }

    private func openDirectPlaybackFromDeepLink(bgmID: Int) async {
        let repository = BangumiRepository()
        do {
            async let subjectTask = repository.getSubject(subjectID: bgmID)
            async let episodesTask = repository.getEpisodes(id: bgmID)
            let (subject, episodesResponse) = try await (subjectTask, episodesTask)
            let episodes = episodesResponse.data
            guard !episodes.isEmpty else {
                router.showAnimeDetail(bgmID)
                return
            }

            let profile = try? await AniTVDatabase.currentUserProfile(in: database)
            var epStatus = 0
            if let profile, profile.isAuthenticated, let bgmUserID = profile.effectiveBgmUserID {
                if let remoteCollection = try? await repository.currentUserCollection(
                    subjectID: bgmID,
                    userID: bgmUserID
                ) {
                    epStatus = remoteCollection.epStatus
                }
            }

            let targetEpisode: BgmEpisodeInfo
            if epStatus > 0 {
                let nextSort = Double(epStatus + 1)
                targetEpisode = episodes.first(where: {
                    ($0.ep > 0 ? $0.ep : $0.sort) == nextSort
                }) ?? (episodes.indices.contains(epStatus) ? episodes[epStatus] : episodes.last!)
            } else {
                targetEpisode = episodes.first!
            }

            var resumeSeconds: Int? = nil
            if let profile, profile.isAuthenticated, let bgmUserID = profile.effectiveBgmUserID {
                if let watchState = try? await AniTVDatabase.localEpisodeWatchState(
                    bgmUserID: bgmUserID,
                    episodeID: targetEpisode.id,
                    in: database
                ), watchState.playheadSeconds > 0 {
                    resumeSeconds = watchState.playheadSeconds
                }
            }

            let title = subject.nameCN.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? subject.name
                : subject.nameCN

            router.showAnimeDetail(bgmID)
            router.showEpisodePlayer(
                episodes: episodes,
                episodeID: targetEpisode.id,
                sessionTitle: title,
                initialPlaybackPositionSeconds: resumeSeconds
            )
        } catch {
            print("[SidebarContentView] Failed to open direct playback for subject \(bgmID): \(error)")
            router.showAnimeDetail(bgmID)
        }
    }
}

private struct SidebarUserAvatarView: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        defaultAvatar
                    }
                }
                .id(url)
            } else {
                defaultAvatar
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(Circle())
    }

    private var defaultAvatar: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
    }
}

private struct AnimeEpisodePlayerScreen: View {
    let episodes: [BgmEpisodeInfo]
    let initialEpisodeID: Int
    let sessionTitle: String
    let initialPlaybackPositionSeconds: Int?
    let onScreenDisappear: () -> Void
    let onExitRequest: () -> Void

    @Dependency(\.defaultDatabase) private var database
    @State private var currentEpisodeIndex: Int

    init(
        episodes: [BgmEpisodeInfo],
        initialEpisodeID: Int,
        sessionTitle: String,
        initialPlaybackPositionSeconds: Int?,
        onScreenDisappear: @escaping () -> Void,
        onExitRequest: @escaping () -> Void
    ) {
        self.episodes = episodes
        self.initialEpisodeID = initialEpisodeID
        self.sessionTitle = sessionTitle
        self.initialPlaybackPositionSeconds = initialPlaybackPositionSeconds
        self.onScreenDisappear = onScreenDisappear
        self.onExitRequest = onExitRequest
        let initialIndex = episodes.firstIndex(where: { $0.id == initialEpisodeID }) ?? 0
        self._currentEpisodeIndex = State(initialValue: initialIndex)
    }

    private var currentEpisode: BgmEpisodeInfo? {
        guard episodes.indices.contains(currentEpisodeIndex) else { return nil }
        return episodes[currentEpisodeIndex]
    }

    var body: some View {
        Group {
            if let currentEpisode {
                AnimePlayerContainerView(
                    episodeInfo: currentEpisode,
                    episodes: episodes,
                    sessionTitle: sessionTitle,
                    initialPlaybackPositionSeconds: currentEpisode.id == initialEpisodeID ? initialPlaybackPositionSeconds : nil,
                    onSelectEpisode: selectEpisode,
                    onPlaybackCompleted: playNextEpisodeIfPossible,
                    onExitRequest: onExitRequest
                )
                .id(currentEpisode.id)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .onDisappear {
            onScreenDisappear()
        }
    }

    private func selectEpisode(_ episode: BgmEpisodeInfo) {
        guard let targetIndex = episodes.firstIndex(where: { $0.id == episode.id }) else { return }
        guard targetIndex != currentEpisodeIndex else { return }
        currentEpisodeIndex = targetIndex
    }

    private func playNextEpisodeIfPossible() {
        let nextIndex = currentEpisodeIndex + 1
        guard episodes.indices.contains(nextIndex) else { return }
        Task { @MainActor in
            let autoPlayNext = (try? await AniTVDatabase.isAutoPlayNextEnabled(in: database)) ?? AniTVDatabase.defaultAutoPlayNext
            guard autoPlayNext, episodes.indices.contains(nextIndex) else { return }
            currentEpisodeIndex = nextIndex
        }
    }

}

private struct AnimeDetailScreen: View {
    @EnvironmentObject private var router: AppRouter
    let bgmId: Int
    let onClose: () -> Void
    @Namespace private var detailFocusScope

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            AnimeDetailView(
                bgmId: bgmId,
                playerDismissRefreshToken: router.playerDismissRefreshToken,
                openEpisodePlayer: { episodes, episodeInfo, sessionTitle, initialPlaybackPositionSeconds in
                    router.showEpisodePlayer(
                        episodes: episodes,
                        episodeID: episodeInfo.id,
                        sessionTitle: sessionTitle,
                        initialPlaybackPositionSeconds: initialPlaybackPositionSeconds
                    )
                }
            )
        }
        .focusScope(detailFocusScope)
        .focusSection()
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onExitCommand {
            onClose()
            router.pop()
        }
    }
}

private struct SidebarDetailView: View {
    @Binding var selectedCategory: NavigationCategory?
    @Binding var columnVisibility: NavigationSplitViewVisibility
    let homeContinueWatchingRefreshToken: Int
    let openAnimeDetail: (Int) -> Void
    let openEpisodePlayer: ([BgmEpisodeInfo], BgmEpisodeInfo, String, Int?) -> Void

    var body: some View {
        Group {
            switch selectedCategory ?? .home {
            case .search:
                SearchView(
                    columnVisibility: $columnVisibility,
                    openAnimeDetail: openAnimeDetail
                )
            case .home:
                HomeView(
                    openAnimeDetail: openAnimeDetail,
                    continueWatchingRefreshToken: homeContinueWatchingRefreshToken,
                    openEpisodePlayer: openEpisodePlayer
                )
            case .ranking:
                RankingView(
                    columnVisibility: $columnVisibility,
                    openAnimeDetail: openAnimeDetail
                )
            case .animeList:
                CollectionView(
                    openAnimeDetail: openAnimeDetail
                )
            case .timeline:
                TimelineView(
                    openAnimeDetail: openAnimeDetail
                )
            case .settings:
                SettingsView(columnVisibility: $columnVisibility)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProfileSwitcherView: View {
    @Environment(\.dismiss) private var dismiss
    let currentUser: String

    private let users = ["User", "追番狂魔", "游客模式"]

    var body: some View {
        NavigationStack {
            List(users, id: \.self) { user in
                Button {
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle")
                        Text(user)
                        Spacer()
                        if user == currentUser {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .navigationTitle("选择你的 Profile")
        }
    }
}

#Preview {
    SidebarContentView()
}

private extension View {
    @ViewBuilder
    func sidebarRowSpacing(_ spacing: CGFloat) -> some View {
        if #available(tvOS 27.0, *) {
            self.listRowSpacing(spacing)
        } else {
            self
        }
    }
}

