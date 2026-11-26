//
//  SettingsView.swift
//  AniTV
//
//  Created by Codex on 2026/8/8.
//

import SwiftUI
import CoreImage.CIFilterBuiltins
import SQLiteData

enum SettingsSubpage: String, CaseIterable, Identifiable {
    case profile = "个人资料"
    case playerAndDanmaku = "播放器与弹幕"
    case dataSource = "数据源"
    case developerOptions = "开发者选项"
    case about = "关于"

    var id: String { rawValue }
}

struct SettingsView: View {
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @EnvironmentObject private var bangumiOAuthManager: BangumiOAuthManager
    @Dependency(\.defaultDatabase) private var database
    @Namespace private var rightListFocusScope
    @FocusState private var focusedMainMenuSubpage: SettingsSubpage?
    @FocusState private var focusedSubpageItem: String?

    // Left panel illustration opacity constant (75%)
    private static let leftIllustrationOpacity: Double = 0.75

    init(columnVisibility: Binding<NavigationSplitViewVisibility> = .constant(.detailOnly)) {
        self._columnVisibility = columnVisibility
    }

    @State private var selectedSubpage: SettingsSubpage? = nil
    @State private var lastSelectedSubpage: SettingsSubpage? = nil
    @State private var showingLoginSheet: Bool = false
    @State private var showingLogoutConfirmation: Bool = false
    @State private var currentProfile: UserProfile? = nil
    @State private var isDebugRenderEnabled: Bool = TVOSMediaResolver.isDebugRenderEnabled

    // Setting values
    @State private var searchConcurrency: Int = 5
    @State private var completionThreshold: Double = 0.9
    @State private var isAutoPlayNext: Bool = true
    @State private var skipOPEDMode: SkipOPEDMode = AniTVDatabase.defaultSkipOPEDMode
    @State private var fallbackOPSkipSeconds: Int = AniTVDatabase.defaultFallbackOPSkipSeconds
    @State private var isRememberDanmakuState: Bool = true
    @State private var danmakuDisplayArea: Double = AniTVDatabase.defaultDanmakuDisplayArea
    @State private var danmuApiBaseURL: String = AniTVDatabase.defaultDanmuApiBaseURL
    @State private var danmuApiToken: String = AniTVDatabase.defaultDanmuApiToken
    @State private var showingDanmuApiSettingsSheet: Bool = false
    @State private var isHlsAdFilterEnabled: Bool = LocalHlsPlaybackPreparer.isEnabled
    @State private var subscriptionURLString: String = MediaSourceConfigLoader.defaultSubscriptionURL.absoluteString
    @State private var defaultMediaSourceName: String? = nil
    @State private var availableMediaSourceNames: [String] = []
    @State private var isSelectingDefaultSource: Bool = false
    @State private var isManagingLocalSources: Bool = false
    @State private var localMediaSources: [LocalMediaSourceConfig] = []
    @State private var showingAddLocalSourceSheet: Bool = false
    @State private var selectedLocalSourceForAction: LocalMediaSourceConfig? = nil
    @State private var localSourceStatusMessage: String? = nil
    @State private var isRefreshingSubscription: Bool = false
    @State private var subscriptionRefreshStatus: String? = nil

    private static let danmakuAreaOptions: [(title: String, value: Double)] = [
        ("全屏", 1.0),
        ("3/4", 0.75),
        ("1/2", 0.5),
        ("1/4", 0.25),
        ("1/8", 0.125)
    ]

    private enum BangumiOAuthConfig {
        static let clientID = AppConfig.bangumiOAuthClientID
        static let appCallbackURL = BangumiOAuthManager.defaultRedirectURI
        static let secret = AppConfig.bangumiOAuthClientSecret
    }

    private var currentTitle: String {
        if isSelectingDefaultSource {
            return "默认视频源"
        }
        if isManagingLocalSources {
            return "本地媒体源"
        }
        return selectedSubpage?.rawValue ?? "设置"
    }

    private func defaultFocusItem(for subpage: SettingsSubpage) -> String {
        switch subpage {
        case .profile:
            return currentProfile?.isAuthenticated == true ? "profile_logout" : "profile_login"
        case .playerAndDanmaku:
            return "player_threshold"
        case .dataSource:
            return "datasource_default_source"
        case .developerOptions:
            return "developer_debug"
        case .about:
            return "about_repo"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header Title
            headerView

            HStack(alignment: .top, spacing: 60) {
                // Left Panel
                leftPanelView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Right Panel
                rightPanelView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 60)
            .padding(.top, 20)
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
//        .background(
//            Color.black.opacity(0.2)
//        )
        .ignoresSafeArea()
        .task {
            await loadSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .userProfileDidChange)) { _ in
            Task {
                await loadSettings()
                if currentProfile?.isAuthenticated == true, showingLoginSheet {
                    showingLoginSheet = false
                }
                if selectedSubpage == .profile {
                    focusedSubpageItem = defaultFocusItem(for: .profile)
                }
            }
        }
        .onExitCommand {
            if isSelectingDefaultSource {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isSelectingDefaultSource = false
                }
                focusedSubpageItem = "datasource_default_source"
            } else if isManagingLocalSources {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isManagingLocalSources = false
                }
                focusedSubpageItem = "datasource_local_sources"
            } else if selectedSubpage != nil {
                let target = lastSelectedSubpage ?? .profile
                focusedSubpageItem = nil
                withAnimation(.easeInOut(duration: 0.28)) {
                    selectedSubpage = nil
                }
                focusedMainMenuSubpage = target
            } else {
                withAnimation(.easeInOut(duration: 0.28)) {
                    columnVisibility = .all
                }
            }
        }
        .onChange(of: selectedSubpage) { _, newSubpage in
            isSelectingDefaultSource = false
            isManagingLocalSources = false
            if let newSubpage {
                focusedMainMenuSubpage = nil
                focusedSubpageItem = defaultFocusItem(for: newSubpage)
            }
        }
        .sheet(isPresented: $showingAddLocalSourceSheet) {
            AddLocalMediaSourceSheet { newSource in
                Task {
                    _ = try? await AniTVDatabase.insertLocalMediaSource(
                        name: newSource.name,
                        kind: newSource.kind,
                        baseURL: newSource.baseURL,
                        username: newSource.username,
                        password: newSource.password,
                        apiKey: newSource.apiKey,
                        isEnabled: true,
                        in: database
                    )
                    await loadSettings()
                    showingAddLocalSourceSheet = false
                }
            } onCancel: {
                showingAddLocalSourceSheet = false
            }
        }
        .sheet(isPresented: $showingDanmuApiSettingsSheet) {
            DanmuAPISettingsSheet(
                initialBaseURL: danmuApiBaseURL,
                initialToken: danmuApiToken,
                onSave: { newBaseURL, newToken in
                    Task {
                        let changed = newBaseURL != danmuApiBaseURL || newToken != danmuApiToken
                        try? await AniTVDatabase.setDanmuApiBaseURL(newBaseURL, in: database)
                        try? await AniTVDatabase.setDanmuApiToken(newToken, in: database)
                        if changed {
                            DanDanPlayCacheManager.shared.clearAllCache()
                        }
                        await loadSettings()
                        showingDanmuApiSettingsSheet = false
                    }
                },
                onCancel: {
                    showingDanmuApiSettingsSheet = false
                }
            )
        }
        .confirmationDialog(
            selectedLocalSourceForAction?.name ?? "本地媒体源",
            isPresented: Binding(
                get: { selectedLocalSourceForAction != nil },
                set: { if !$0 { selectedLocalSourceForAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let source = selectedLocalSourceForAction {
                Button("测试连接") {
                    Task {
                        localSourceStatusMessage = "正在测试「\(source.name)」…"
                        let result = await LocalMediaServerClient.shared.testConnection(source: source)
                        switch result {
                        case .success(let info):
                            localSourceStatusMessage = "\(source.name)：\(info)"
                        case .failure(let error):
                            localSourceStatusMessage = "\(source.name)：\(error.localizedDescription)"
                        }
                    }
                }
                Button(source.isEnabled ? "停用此源" : "启用此源") {
                    Task {
                        try? await AniTVDatabase.setLocalMediaSourceEnabled(
                            id: source.id,
                            isEnabled: !source.isEnabled,
                            in: database
                        )
                        await loadSettings()
                    }
                }
                Button("删除", role: .destructive) {
                    Task {
                        try? await AniTVDatabase.deleteLocalMediaSource(id: source.id, in: database)
                        await loadSettings()
                    }
                }
                Button("取消", role: .cancel) {}
            }
        } message: {
            if let source = selectedLocalSourceForAction {
                Text("\(source.kind.displayName) · \(source.baseURL)")
            }
        }
        .fullScreenCover(isPresented: $showingLoginSheet) {
            OOBEProfileSetupView(
                isAuthenticating: bangumiOAuthManager.isAuthenticating,
                statusMessage: bangumiOAuthManager.statusMessage,
                lanEntryURL: bangumiOAuthManager.lanEntryURL,
                lanServiceStatus: bangumiOAuthManager.lanServiceStatus,
                createGuestAction: {
                    Task {
                        if currentProfile == nil {
                            _ = try? await AniTVDatabase.insertGuestUserProfile(in: database)
                        }
                        await loadSettings()
                        showingLoginSheet = false
                    }
                },
                connectBangumiAction: {
                    bangumiOAuthManager.startLogin(
                        clientID: BangumiOAuthConfig.clientID,
                        clientSecret: BangumiOAuthConfig.secret,
                        redirectURI: BangumiOAuthConfig.appCallbackURL
                    )
                },
                onAppearAction: {
                    bangumiOAuthManager.ensureLANServerRunning()
                },
                onDismiss: {
                    showingLoginSheet = false
                }
            )
        }
        .onChange(of: showingLoginSheet) { _, isShowing in
            if !isShowing {
                Task {
                    await loadSettings()
                    if selectedSubpage == .profile {
                        focusedSubpageItem = defaultFocusItem(for: .profile)
                    }
                }
            }
        }
        .onChange(of: bangumiOAuthManager.authenticatedSession) { _, session in
            if session != nil {
                Task {
                    await loadSettings()
                    if currentProfile?.isAuthenticated == true {
                        showingLoginSheet = false
                    }
                }
            }
        }
        .alert("退出登录", isPresented: $showingLogoutConfirmation) {
            Button("退出登录", role: .destructive) {
                Task {
                    try? await AniTVDatabase.logoutCurrentUser(in: database)
                    await loadSettings()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要退出当前账号吗？")
        }
    }

    // MARK: - Header
    private var headerView: some View {
        HStack {
            Spacer()
            Text(currentTitle)
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
        }
        .padding(.horizontal, 60)
        .padding(.top, 60)
        .padding(.bottom, 30)
    }

    // MARK: - Left Panel Views (Consistent illustration size & position with crossfade)
    @ViewBuilder
    private var leftPanelView: some View {
        VStack(spacing: 24) {
            // Fixed-size illustration container
            ZStack {
                currentLeftIllustration
                    .opacity(Self.leftIllustrationOpacity)
                    .id(selectedSubpage?.rawValue ?? "home_illustration")
                    .transition(.opacity)
            }
            .frame(width: 540, height: 380)

            // Fixed-size hint container so the icon above never jumps
            ZStack(alignment: .top) {
                if let hint = currentLeftHint {
                    Text(hint)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                        .id(hint)
                        .transition(.opacity)
                }
            }
            .frame(width: 540, height: 80, alignment: .top)
            .animation(.easeInOut(duration: 0.2), value: currentLeftHint)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    @ViewBuilder
    private var currentLeftIllustration: some View {
        if let subpage = selectedSubpage {
            switch subpage {
            case .profile:
                profileLeftIllustration
            case .playerAndDanmaku:
                playerAndDanmakuLeftIllustration
            case .dataSource:
                dataSourceLeftIllustration
            case .developerOptions:
                developerOptionsLeftIllustration
            case .about:
                aboutLeftIllustration
            }
        } else {
            homeLeftIllustration
        }
    }

    private var currentLeftHint: String? {
        if isSelectingDefaultSource {
            return "播放时将优先使用默认视频源进行解析；未匹配或播放失败时自动回退到其他源"
        }
        if isManagingLocalSources {
            return localSourceStatusMessage ?? "支持连接局域网 WebDAV（如 Alist / NAS）、Emby 与 Jellyfin，播放时直连局域网文件"
        }
        if let item = focusedSubpageItem {
            switch item {
            case "developer_debug":
                return "开启后，解析 m3u8 时会将后台的 WKWebView 全屏渲染在屏幕上"
            case "player_ad_filter":
                return "自动识别并跳过 m3u8 视频源中插入的切片广告"
            case "player_skip_oped":
                return "优先匹配 AniSkip 精准 OP/ED 区间；未命中时使用兜底跳过提示（兜底不会盲目自动跳过）"
            case "player_fallback_op_seconds":
                return "当 AniSkip 未收录当前集片头时，兜底「跳过片头」按钮单次快进的秒数"
            case "danmaku_remember_state":
                return "开启后，播放器将记住弹幕开关状态并在下次播放时恢复"
            case "danmaku_display_area":
                return "设置弹幕在屏幕中的最大显示区域，在播放器内调整也会自动保存"
            case "danmaku_api_config":
                return "使用开源弹幕服务 huangxd-/danmu_api 获取多平台弹幕，无需弹弹 play 商业密钥"
            case "datasource_default_source":
                return "优先使用选定的视频源进行解析与播放，未匹配或失败时自动回退到其他源"
            case "datasource_local_sources":
                return "添加局域网 WebDAV / Emby / Jellyfin 媒体服务器，播放时直接匹配并直连播放"
            case "datasource_subscription":
                return subscriptionRefreshStatus ?? "点击立即从远端拉取最新在线数据源配置"
            default:
                return nil
            }
        }
        if selectedSubpage == .developerOptions {
            return "开启后，解析 m3u8 时会将后台的 WKWebView 全屏渲染在屏幕上"
        }
        return nil
    }

    // Home Left Illustration (Gear)
    private var homeLeftIllustration: some View {
        Image(systemName: "gear")
            .resizable()
            .scaledToFit()
            .frame(width: 360, height: 360)
            .foregroundStyle(.white)
    }

    // Profile Left Illustration (Person)
    private var profileLeftIllustration: some View {
        Image(systemName: "person")
            .resizable()
            .scaledToFit()
            .frame(width: 360, height: 360)
            .foregroundStyle(.white)
    }

    // Subpage Left Illustrations
    private var playerAndDanmakuLeftIllustration: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 48, style: .continuous)
                    .stroke(.white, lineWidth: 20)
                    .frame(width: 460, height: 300)

                Image(systemName: "play.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .foregroundStyle(.white)
                    .offset(x: 8)
            }

            Capsule()
                .fill(.white)
                .frame(width: 220, height: 24)
        }
        .frame(width: 540, height: 380)
    }

    private var dataSourceLeftIllustration: some View {
        HStack(spacing: 32) {
            VStack(spacing: 24) {
                Capsule()
                    .fill(.white)
                    .frame(width: 200, height: 32)
                Capsule()
                    .fill(.white)
                    .frame(width: 150, height: 32)
                Capsule()
                    .fill(.white)
                    .frame(width: 150, height: 32)
                Capsule()
                    .fill(.white)
                    .frame(width: 150, height: 32)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .stroke(.white, lineWidth: 18)
                    .frame(width: 240, height: 260)

                VStack(spacing: 20) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.8))
                        .frame(width: 140, height: 80)

                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.8))
                        .frame(width: 140, height: 80)
                }

                // Sprocket holes along left and right
                VStack(spacing: 12) {
                    ForEach(0..<4) { _ in
                        HStack(spacing: 196) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.white)
                                .frame(width: 20, height: 20)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.white)
                                .frame(width: 20, height: 20)
                        }
                    }
                }
            }
        }
        .frame(width: 540, height: 380)
    }

    private var developerOptionsLeftIllustration: some View {
        Text("{ }")
            .font(.system(size: 320, weight: .light, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 360, height: 360)
    }

    private var aboutLeftIllustration: some View {
        Image(systemName: "info.circle")
            .resizable()
            .scaledToFit()
            .frame(width: 360, height: 360)
            .foregroundStyle(.white)
    }

    // MARK: - Right Panel Views (FocusGuide enabled)
    @ViewBuilder
    private var rightPanelView: some View {
        ZStack(alignment: .topLeading) {
            mainSettingsNavigationMenu
                .offset(x: selectedSubpage == nil ? 0 : -100)
                .opacity(selectedSubpage == nil ? 1 : 0)
                .allowsHitTesting(selectedSubpage == nil)
                .disabled(selectedSubpage != nil)

            if let subpage = selectedSubpage {
                subpageView(for: subpage)
                    .defaultFocus($focusedSubpageItem, defaultFocusItem(for: subpage), priority: .userInitiated)
                    .transition(
                        .asymmetric(
                            insertion: .offset(x: 100).combined(with: .opacity),
                            removal: .offset(x: 100).combined(with: .opacity)
                        )
                    )
                    .id("subpage_\(subpage.rawValue)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusScope(rightListFocusScope)
        .focusSection()
    }

    @ViewBuilder
    private func subpageView(for subpage: SettingsSubpage) -> some View {
        switch subpage {
        case .profile:
            profileSettingsOptions
        case .playerAndDanmaku:
            playerAndDanmakuSettingsOptions
        case .dataSource:
            dataSourceSettingsOptions
        case .developerOptions:
            developerOptionsSettingsOptions
        case .about:
            aboutSettingsOptions
        }
    }

    // Main Navigation Menu (5 categories)
    private var mainSettingsNavigationMenu: some View {
        VStack(spacing: 16) {
            ForEach(SettingsSubpage.allCases) { subpage in
                Button {
                    lastSelectedSubpage = subpage
                    focusedMainMenuSubpage = nil
                    focusedSubpageItem = defaultFocusItem(for: subpage)
                    withAnimation(.easeInOut(duration: 0.28)) {
                        selectedSubpage = subpage
                    }
                } label: {
                    SettingsRowContent {
                        HStack {
                            Text(subpage.rawValue)
                                .font(.headline.weight(.medium))

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .padding(.horizontal, 28)
                        .frame(height: 76)
                    }
                }
                .buttonStyle(CleanButtonStyle())
                .focused($focusedMainMenuSubpage, equals: subpage)
            }
        }
        .defaultFocus($focusedMainMenuSubpage, lastSelectedSubpage ?? .profile, priority: selectedSubpage == nil ? .userInitiated : .automatic)
    }

    // Subpage: Profile
    @ViewBuilder
    private var profileSettingsOptions: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let profile = currentProfile, profile.isAuthenticated {
                Text("账号信息")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))

                if let nickname = profile.nickname, !nickname.isEmpty {
                    SettingsRowButton {
                    } label: {
                        HStack {
                            Text("用户名")
                                .font(.headline.weight(.medium))

                            Spacer()

                            Text(nickname)
                                .font(.headline.weight(.semibold))
                        }
                        .padding(.horizontal, 28)
                        .frame(height: 76)
                    }
                    .focused($focusedSubpageItem, equals: "profile_username")
                }

                SettingsRowButton {
                    showingLogoutConfirmation = true
                } label: {
                    HStack {
                        Text("退出登录")
                            .font(.headline.weight(.medium))

                        Spacer()
                    }
                    .padding(.horizontal, 28)
                    .frame(height: 76)
                }
                .focused($focusedSubpageItem, equals: "profile_logout")
            } else {
                Text("账号状态")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))

                SettingsRowButton {
                    showingLoginSheet = true
                } label: {
                    HStack {
                        Text("登录")
                            .font(.headline.weight(.medium))

                        Spacer()
                    }
                    .padding(.horizontal, 28)
                    .frame(height: 76)
                }
                .focused($focusedSubpageItem, equals: "profile_login")
            }
        }
    }

    // Subpage: Player & Danmaku
    private var playerAndDanmakuSettingsOptions: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
            Text("播放器")
                .font(.body)
                .foregroundStyle(.white.opacity(0.6))

            SettingsRowButton {
                cycleCompletionThreshold()
            } label: {
                HStack {
                    Text("自动标记为看过")
                        .font(.headline.weight(.medium))

                    Spacer()

                    Text("\(Int(completionThreshold * 100))%")
                        .font(.headline.weight(.semibold))
                }
                .padding(.horizontal, 28)
                .frame(height: 76)
            }
            .focused($focusedSubpageItem, equals: "player_threshold")

            SettingsRowButton {
                isAutoPlayNext.toggle()
                Task {
                    try? await AniTVDatabase.setAutoPlayNextEnabled(isAutoPlayNext, in: database)
                }
            } label: {
                HStack {
                    Text("自动连播")
                        .font(.headline.weight(.medium))

                    Spacer()

                    Text(isAutoPlayNext ? "是" : "否")
                        .font(.headline.weight(.semibold))
                }
                .padding(.horizontal, 28)
                .frame(height: 76)
            }
            .focused($focusedSubpageItem, equals: "player_autoplay")

            SettingsRowButton {
                isHlsAdFilterEnabled.toggle()
                LocalHlsPlaybackPreparer.isEnabled = isHlsAdFilterEnabled
            } label: {
                HStack {
                    Text("过滤切片广告 (实验性)")
                        .font(.headline.weight(.medium))

                    Spacer()

                    Text(isHlsAdFilterEnabled ? "是" : "否")
                        .font(.headline.weight(.semibold))
                }
                .padding(.horizontal, 28)
                .frame(height: 76)
            }
            .focused($focusedSubpageItem, equals: "player_ad_filter")

            SettingsRowButton {
                cycleSkipOPEDMode()
            } label: {
                HStack {
                    Text("跳过片头片尾")
                        .font(.headline.weight(.medium))

                    Spacer()

                    Text(skipOPEDMode.displayTitle)
                        .font(.headline.weight(.semibold))
                }
                .padding(.horizontal, 28)
                .frame(height: 76)
            }
            .focused($focusedSubpageItem, equals: "player_skip_oped")

            SettingsRowButton {
                cycleFallbackOPSkipSeconds()
            } label: {
                HStack {
                    Text("片头兜底跳过时长")
                        .font(.headline.weight(.medium))

                    Spacer()

                    Text("\(fallbackOPSkipSeconds) 秒")
                        .font(.headline.weight(.semibold))
                }
                .padding(.horizontal, 28)
                .frame(height: 76)
            }
            .focused($focusedSubpageItem, equals: "player_fallback_op_seconds")

            Text("弹幕")
                .font(.body)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 10)

            SettingsRowButton {
                isRememberDanmakuState.toggle()
                Task {
                    try? await AniTVDatabase.setRememberDanmakuStateEnabled(isRememberDanmakuState, in: database)
                }
            } label: {
                HStack {
                    Text("记住弹幕开关状态")
                        .font(.headline.weight(.medium))

                    Spacer()

                    Text(isRememberDanmakuState ? "是" : "否")
                        .font(.headline.weight(.semibold))
                }
                .padding(.horizontal, 28)
                .frame(height: 76)
            }
            .focused($focusedSubpageItem, equals: "danmaku_remember_state")

            SettingsRowButton {
                cycleDanmakuDisplayArea()
            } label: {
                HStack {
                    Text("默认弹幕区域")
                        .font(.headline.weight(.medium))

                    Spacer()

                    Text(danmakuDisplayAreaLabel)
                        .font(.headline.weight(.semibold))
                }
                .padding(.horizontal, 28)
                .frame(height: 76)
            }
            .focused($focusedSubpageItem, equals: "danmaku_display_area")

            SettingsRowButton {
                showingDanmuApiSettingsSheet = true
            } label: {
                HStack {
                    Text("弹幕服务 (danmu_api)")
                        .font(.headline.weight(.medium))

                    Spacer()

                    HStack(spacing: 10) {
                        Text(danmuApiSummaryLabel)
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .padding(.horizontal, 28)
                .frame(height: 76)
            }
            .focused($focusedSubpageItem, equals: "danmaku_api_config")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        }
    }

    // Subpage: Data Source
    @ViewBuilder
    private var dataSourceSettingsOptions: some View {
        if isSelectingDefaultSource {
            defaultSourcePickerOptions
        } else if isManagingLocalSources {
            localMediaSourcesOptions
        } else {
            VStack(alignment: .leading, spacing: 20) {
                SettingsRowButton {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isSelectingDefaultSource = true
                    }
                    focusedSubpageItem = defaultSourceOptionFocusID(for: defaultMediaSourceName)
                } label: {
                    HStack {
                        Text("默认视频源")
                            .font(.headline.weight(.medium))

                        Spacer()

                        HStack(spacing: 10) {
                            Text(defaultMediaSourceName ?? "自动")
                                .font(.headline.weight(.semibold))
                                .lineLimit(1)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 28)
                    .frame(height: 76)
                }
                .focused($focusedSubpageItem, equals: "datasource_default_source")

                SettingsRowButton {
                    localSourceStatusMessage = nil
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isManagingLocalSources = true
                    }
                    focusedSubpageItem = "local_source_add"
                } label: {
                    HStack {
                        Text("本地媒体源")
                            .font(.headline.weight(.medium))

                        Spacer()

                        HStack(spacing: 10) {
                            let enabledCount = localMediaSources.filter(\.isEnabled).count
                            Text(enabledCount > 0 ? "\(enabledCount) 个已启用" : "未配置")
                                .font(.headline.weight(.semibold))

                            Image(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 28)
                    .frame(height: 76)
                }
                .focused($focusedSubpageItem, equals: "datasource_local_sources")

                SettingsRowButton {
                    cycleSearchConcurrency()
                } label: {
                    HStack {
                        Text("播放查询并发数")
                            .font(.headline.weight(.medium))

                        Spacer()

                        Text("\(searchConcurrency)")
                            .font(.headline.weight(.semibold))
                    }
                    .padding(.horizontal, 28)
                    .frame(height: 76)
                }
                .focused($focusedSubpageItem, equals: "datasource_concurrency")

                Text("订阅")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 12)

                SettingsRowButton {
                    refreshSubscriptionNow()
                } label: {
                    HStack(spacing: 12) {
                        Text(subscriptionURLString)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        if isRefreshingSubscription {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("刷新")
                                .font(.callout.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 28)
                    .frame(height: 76)
                }
                .focused($focusedSubpageItem, equals: "datasource_subscription")
            }
        }
    }

    private var localMediaSourcesOptions: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsRowButton {
                    showingAddLocalSourceSheet = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .font(.headline)
                        Text("添加本地媒体源（WebDAV / Emby / Jellyfin）")
                            .font(.headline.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 28)
                    .frame(height: 74)
                }
                .focused($focusedSubpageItem, equals: "local_source_add")

                ForEach(localMediaSources) { source in
                    SettingsRowButton {
                        selectedLocalSourceForAction = source
                    } label: {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 10) {
                                    Text(source.name)
                                        .font(.headline.weight(.semibold))
                                        .lineLimit(1)
                                    Text(source.kind.displayName)
                                        .font(.caption.weight(.bold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(Color.gray.opacity(0.3)))
                                }
                                Text(source.baseURL)
                                    .font(.caption)
                                    .opacity(0.7)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            Text(source.isEnabled ? "已启用" : "已停用")
                                .font(.callout.weight(.semibold))
                                .opacity(source.isEnabled ? 1.0 : 0.55)
                        }
                        .padding(.horizontal, 28)
                        .frame(height: 82)
                    }
                    .focused($focusedSubpageItem, equals: "local_source_\(source.id)")
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
    }

    private var defaultSourcePickerOptions: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsRowButton {
                    selectDefaultMediaSource(nil)
                } label: {
                    HStack {
                        Text("自动（按默认顺序）")
                            .font(.headline.weight(.medium))

                        Spacer()

                        if defaultMediaSourceName == nil {
                            Image(systemName: "checkmark")
                                .font(.headline.weight(.bold))
                        }
                    }
                    .padding(.horizontal, 28)
                    .frame(height: 72)
                }
                .focused($focusedSubpageItem, equals: defaultSourceOptionFocusID(for: nil))

                ForEach(availableMediaSourceNames, id: \.self) { sourceName in
                    SettingsRowButton {
                        selectDefaultMediaSource(sourceName)
                    } label: {
                        HStack {
                            Text(sourceName)
                                .font(.headline.weight(.medium))
                                .lineLimit(1)

                            Spacer()

                            if defaultMediaSourceName == sourceName {
                                Image(systemName: "checkmark")
                                    .font(.headline.weight(.bold))
                            }
                        }
                        .padding(.horizontal, 28)
                        .frame(height: 72)
                    }
                    .focused($focusedSubpageItem, equals: defaultSourceOptionFocusID(for: sourceName))
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
    }

    private func defaultSourceOptionFocusID(for name: String?) -> String {
        if let name, !name.isEmpty {
            return "default_source_option_\(name)"
        }
        return "default_source_option_auto"
    }

    private var danmakuDisplayAreaLabel: String {
        Self.danmakuAreaOptions.first(where: { abs($0.value - danmakuDisplayArea) < 0.01 })?.title ?? "全屏"
    }

    private var danmuApiSummaryLabel: String {
        let trimmed = danmuApiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "未配置" }
        if let url = URL(string: trimmed.contains("://") ? trimmed : "http://\(trimmed)"),
           let host = url.host, !host.isEmpty {
            if let port = url.port {
                return "\(host):\(port)"
            }
            return host
        }
        return trimmed
    }

    // Subpage: Developer Options
    private var developerOptionsSettingsOptions: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsRowButton {
                isDebugRenderEnabled.toggle()
                TVOSMediaResolver.isDebugRenderEnabled = isDebugRenderEnabled
            } label: {
                HStack {
                    Text("CSS解析Debug模式")
                        .font(.headline.weight(.medium))

                    Spacer()

                    Text(isDebugRenderEnabled ? "开" : "关")
                        .font(.headline.weight(.semibold))
                }
                .padding(.horizontal, 28)
                .frame(height: 76)
            }
            .focused($focusedSubpageItem, equals: "developer_debug")
        }
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        return "AniTV V\(version)"
    }

    // Subpage: About
    private var aboutSettingsOptions: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsRowButton {
                // Repository link
            } label: {
                HStack {
                    Text("https://github.com/moyuwangP/AniTV")
                        .font(.callout)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 28)
                .frame(height: 76)
            }
            .focused($focusedSubpageItem, equals: "about_repo")

            SettingsRowButton {
                // Version info
            } label: {
                HStack {
                    Text("版本号")
                        .font(.callout)

                    Spacer()

                    Text(appVersionString)
                        .font(.callout)
                }
                .padding(.horizontal, 28)
                .frame(height: 76)
            }
            .focused($focusedSubpageItem, equals: "about_version")
        }
    }

    // MARK: - Actions
    private func loadSettings() async {
        do {
            currentProfile = try await AniTVDatabase.currentUserProfile(in: database)
            searchConcurrency = try await AniTVDatabase.playbackSearchConcurrency(in: database)
            completionThreshold = try await AniTVDatabase.playbackCompletionThreshold(in: database)
            isAutoPlayNext = try await AniTVDatabase.isAutoPlayNextEnabled(in: database)
            skipOPEDMode = try await AniTVDatabase.skipOPEDMode(in: database)
            fallbackOPSkipSeconds = try await AniTVDatabase.fallbackOPSkipSeconds(in: database)
            isRememberDanmakuState = try await AniTVDatabase.isRememberDanmakuStateEnabled(in: database)
            danmakuDisplayArea = try await AniTVDatabase.danmakuDisplayArea(in: database)
            danmuApiBaseURL = try await AniTVDatabase.danmuApiBaseURL(in: database)
            danmuApiToken = try await AniTVDatabase.danmuApiToken(in: database)
            await AniTVDatabase.syncDanmakuSettingsToUserDefaults(in: database)
            defaultMediaSourceName = try await AniTVDatabase.defaultMediaSourceName(in: database)
            localMediaSources = try await AniTVDatabase.fetchLocalMediaSources(enabledOnly: false, in: database)
            let remoteNames = try await AniTVDatabase.fetchMediaSourceNames(in: database)
            let localNames = localMediaSources.filter(\.isEnabled).map(\.name)
            var combinedNames: [String] = []
            var seenNames = Set<String>()
            for name in localNames + remoteNames where seenNames.insert(name).inserted {
                combinedNames.append(name)
            }
            availableMediaSourceNames = combinedNames
            isHlsAdFilterEnabled = LocalHlsPlaybackPreparer.isEnabled
        } catch {
            print("[SettingsView] Failed to load settings: \(error)")
        }
    }

    private func refreshSubscriptionNow() {
        guard !isRefreshingSubscription else { return }
        isRefreshingSubscription = true
        subscriptionRefreshStatus = "正在刷新在线数据源订阅…"
        Task {
            do {
                _ = try await AniTVDatabase.refreshMediaSourcesIfNeeded(in: database)
                await loadSettings()
                subscriptionRefreshStatus = "订阅刷新成功，当前共 \(availableMediaSourceNames.count) 个可用源"
            } catch {
                subscriptionRefreshStatus = "订阅刷新失败：\(error.localizedDescription)"
            }
            isRefreshingSubscription = false
        }
    }

    private func selectDefaultMediaSource(_ name: String?) {
        defaultMediaSourceName = name
        Task {
            try? await AniTVDatabase.setDefaultMediaSourceName(name, in: database)
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            isSelectingDefaultSource = false
        }
        focusedSubpageItem = "datasource_default_source"
    }

    private func cycleDanmakuDisplayArea() {
        let options = Self.danmakuAreaOptions
        if let idx = options.firstIndex(where: { abs($0.value - danmakuDisplayArea) < 0.01 }) {
            danmakuDisplayArea = options[(idx + 1) % options.count].value
        } else {
            danmakuDisplayArea = AniTVDatabase.defaultDanmakuDisplayArea
        }
        Task {
            try? await AniTVDatabase.setDanmakuDisplayArea(danmakuDisplayArea, in: database)
        }
    }

    private func cycleSkipOPEDMode() {
        let modes = SkipOPEDMode.allCases
        if let idx = modes.firstIndex(of: skipOPEDMode) {
            skipOPEDMode = modes[(idx + 1) % modes.count]
        } else {
            skipOPEDMode = AniTVDatabase.defaultSkipOPEDMode
        }
        Task {
            try? await AniTVDatabase.setSkipOPEDMode(skipOPEDMode, in: database)
        }
    }

    private func cycleFallbackOPSkipSeconds() {
        let values = [60, 85, 90, 105, 120]
        if let idx = values.firstIndex(of: fallbackOPSkipSeconds) {
            fallbackOPSkipSeconds = values[(idx + 1) % values.count]
        } else {
            fallbackOPSkipSeconds = AniTVDatabase.defaultFallbackOPSkipSeconds
        }
        Task {
            try? await AniTVDatabase.setFallbackOPSkipSeconds(fallbackOPSkipSeconds, in: database)
        }
    }

    private func cycleSearchConcurrency() {
        let values = [1, 3, 5, 8, 10]
        if let idx = values.firstIndex(of: searchConcurrency) {
            searchConcurrency = values[(idx + 1) % values.count]
        } else {
            searchConcurrency = 5
        }
        Task {
            try? await AniTVDatabase.setPlaybackSearchConcurrency(searchConcurrency, in: database)
        }
    }

    private func cycleCompletionThreshold() {
        let values = [0.8, 0.85, 0.9, 0.95]
        if let idx = values.firstIndex(where: { abs($0 - completionThreshold) < 0.01 }) {
            completionThreshold = values[(idx + 1) % values.count]
        } else {
            completionThreshold = 0.9
        }
        Task {
            try? await AniTVDatabase.setPlaybackCompletionThreshold(completionThreshold, in: database)
        }
    }
}

// MARK: - Focus-aware Buttons for tvOS (Pill shape Capsule)
struct SettingsRowButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Content

    var body: some View {
        Button(action: action) {
            SettingsRowContent(label: label)
        }
        .buttonStyle(CleanButtonStyle())
    }
}

struct SettingsRowContent<Content: View>: View {
    @ViewBuilder let label: () -> Content
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        label()
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .background(
                Capsule()
                    .fill(isFocused ? Color.white : Color.white.opacity(0.18))
            )
            .scaleEffect(isFocused ? 1.03 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

private struct AddLocalMediaSourceSheet: View {
    let onSave: (LocalMediaSourceConfig) -> Void
    let onCancel: () -> Void

    @State private var kind: LocalMediaSourceKind = .webdav
    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var apiKey: String = ""
    @State private var testStatus: String? = nil
    @State private var isTesting: Bool = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var draftConfig: LocalMediaSourceConfig {
        LocalMediaSourceConfig(
            id: 0,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            isEnabled: true
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器类型") {
                    Picker("类型", selection: $kind) {
                        ForEach(LocalMediaSourceKind.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("连接信息") {
                    TextField("名称（如：客厅 NAS）", text: $name)
                    TextField("地址（如：\(kind.urlPlaceholder)）", text: $baseURL)
                        .autocorrectionDisabled()
                    if kind == .webdav {
                        TextField("用户名（可选）", text: $username)
                            .autocorrectionDisabled()
                        SecureField("密码（可选）", text: $password)
                    } else {
                        TextField("API Key / Token", text: $apiKey)
                            .autocorrectionDisabled()
                    }
                }

                if let testStatus {
                    Section("连接状态") {
                        Text(testStatus)
                    }
                }

                Section {
                    Button {
                        Task {
                            isTesting = true
                            testStatus = "正在测试连接…"
                            let result = await LocalMediaServerClient.shared.testConnection(source: draftConfig)
                            switch result {
                            case .success(let message):
                                testStatus = message
                            case .failure(let error):
                                testStatus = "连接失败：\(error.localizedDescription)"
                            }
                            isTesting = false
                        }
                    } label: {
                        if isTesting {
                            ProgressView()
                        } else {
                            Label("测试连接", systemImage: "network")
                        }
                    }
                    .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)

                    Button {
                        onSave(draftConfig)
                    } label: {
                        Label("保存", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(!canSave)

                    Button("取消", role: .cancel, action: onCancel)
                }
            }
            .navigationTitle("添加本地媒体源")
        }
    }
}

private struct DanmuAPISettingsSheet: View {
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var baseURL: String
    @State private var token: String
    @State private var testStatus: String? = nil
    @State private var isTesting: Bool = false

    init(
        initialBaseURL: String,
        initialToken: String,
        onSave: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._baseURL = State(initialValue: initialBaseURL)
        self._token = State(initialValue: initialToken)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var resolvedPreviewURL: String {
        DanDanPlayAPI.buildEndpointURL(
            baseURL: baseURL,
            token: token,
            apiPath: "/search/episodes"
        )?.absoluteString ?? "请输入有效的 danmu_api 服务器地址"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("开源弹幕服务（huangxd-/danmu_api）") {
                    TextField("服务器地址（如：https://danmu.tdhxnp.com/APTX4869）", text: $baseURL)
                        .autocorrectionDisabled()
                    TextField("访问 Token（若地址已包含 Token 请留空）", text: $token)
                        .autocorrectionDisabled()
                }

                Section("接口预览") {
                    Text(resolvedPreviewURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let testStatus {
                    Section("连接状态") {
                        Text(testStatus)
                    }
                }

                Section {
                    Button {
                        Task {
                            isTesting = true
                            testStatus = "正在测试连接…"
                            let result = await DanDanPlayAPI.shared.testConnection(
                                baseURL: baseURL,
                                token: token
                            )
                            switch result {
                            case .success(let message):
                                testStatus = message
                            case .failure(let error):
                                testStatus = "连接失败：\(error.localizedDescription)"
                            }
                            isTesting = false
                        }
                    } label: {
                        if isTesting {
                            ProgressView()
                        } else {
                            Label("测试连接", systemImage: "network")
                        }
                    }
                    .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)

                    Button {
                        DanDanPlayCacheManager.shared.clearAllCache()
                        testStatus = "已清空本地弹幕缓存"
                    } label: {
                        Label("清空弹幕缓存", systemImage: "trash")
                    }

                    Button {
                        onSave(
                            baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                            token.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    } label: {
                        Label("保存", systemImage: "checkmark.circle.fill")
                    }

                    Button("取消", role: .cancel, action: onCancel)
                }
            }
            .navigationTitle("弹幕服务设置")
        }
    }
}

