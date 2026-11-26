//
//  AnimePlayerContainerView.swift
//  AniTV
//
//  Created by Feiran Yang on 2026/3/15.
//


import SwiftUI
import AVKit
import SQLiteData

private let sourceFetchConcurrency = 5

private struct QueuedVideoResource {
    let sourceIndex: Int
    let resourceIndex: Int
    let resource: VideoResource
}

private struct QueuedVideoResourceKey: Hashable {
    let sourceIndex: Int
    let resourceIndex: Int
}

private struct PlaybackProgressSnapshot {
    let playheadSeconds: Int
    let isCompleted: Bool
}

private struct SourcePanelOverlayContainer: UIViewControllerRepresentable {
    @ObservedObject var model: SourceSwitchPanelModel

    func makeUIViewController(context: Context) -> SourcePanelOverlayViewController {
        SourcePanelOverlayViewController(model: model)
    }

    func updateUIViewController(_ uiViewController: SourcePanelOverlayViewController, context: Context) {
        uiViewController.update(model: model)
    }
}

private final class SourcePanelOverlayViewController: UIViewController {
    private let hostingController: UIHostingController<SourceSwitchPanelView>

    init(model: SourceSwitchPanelModel) {
        hostingController = UIHostingController(rootView: SourceSwitchPanelView(model: model))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear
        setupHostingController()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestPanelFocus()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        return [hostingController.view]
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        guard let previouslyFocusedView = context.previouslyFocusedView,
              isDescendant(previouslyFocusedView, of: hostingController.view) else {
            return true
        }

        guard let nextFocusedView = context.nextFocusedView else {
            return false
        }

        if isDescendant(nextFocusedView, of: hostingController.view) {
            return true
        }

        let heading = context.focusHeading
        if heading.contains(.up) || heading.contains(.down) {
            return false
        }

        return false
    }

    func update(model: SourceSwitchPanelModel) {
    }

    private func setupHostingController() {
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .clear
        view.addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        hostingController.didMove(toParent: self)
    }
    private func requestPanelFocus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.hostingController.view.setNeedsLayout()
            self.hostingController.view.layoutIfNeeded()
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
            self.hostingController.view.setNeedsFocusUpdate()
            self.hostingController.view.updateFocusIfNeeded()
        }
    }

    private func isDescendant(_ view: UIView, of ancestor: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate === ancestor {
                return true
            }
            current = candidate.superview
        }
        return false
    }
}

struct AnimePlayerContainerView: View {
    @Dependency(\.defaultDatabase) private var database
    @State private var player = AVPlayer()
    @State private var videoSources: [VideoSource] = []
    @State private var isLoading = true
    @State private var isSourcePanelPresented = true
    @State private var sourcePanelPresentationID = 0
    @State private var hasUserSelectedSource = false
    @State private var hasResolvedAutoPlayback = false
    @State private var queuedVideoResources: [QueuedVideoResource] = []
    @State private var queuedVideoResourceKeys: Set<QueuedVideoResourceKey> = []
    @State private var attemptedAutoResourceKeys: Set<QueuedVideoResourceKey> = []
    @State private var isAttemptingPlayback = false
    @State private var fetchSourcesTask: Task<Void, Never>?
    @State private var playbackTask: Task<Void, Never>?
    @State private var lastPlaybackPosition: CMTime?
    @State private var isApplyingResumeSeek = false
    @State private var mediaResolver = TVOSMediaResolver.shared
    @StateObject private var sourcePanelModel = SourceSwitchPanelModel()
    @State private var currentBgmUserID: Int?
    @State private var periodicTimeObserver: Any?
    @State private var timeControlStatusObservation: NSKeyValueObservation?
    @State private var lastSavedPlayheadSeconds: Int?
    @State private var playbackCompletionThreshold = AniTVDatabase.defaultPlaybackCompletionThreshold
    @State private var didFinishPlayback = false
    @State private var didSyncCompletionToBangumi = false
    
    // 💥 1. 新增一个 State 来强引用监听器，防止它被销毁
    @State private var statusObservation: NSKeyValueObservation?
    @State private var danmuManager: DanmuViewManager?
    @State private var isDanmakuAvailable = true
    @State private var defaultMediaSourceName: String?
    @State private var isWaitingForDefaultSource = false
    @State private var skipOPEDMode: SkipOPEDMode = AniTVDatabase.defaultSkipOPEDMode
    @State private var fallbackOPSkipSeconds: Int = AniTVDatabase.defaultFallbackOPSkipSeconds
    @State private var episodeSkipPlan: EpisodeSkipPlan = .empty
    @State private var activeSkipAction: PlayerSkipContextualAction?
    @State private var skippedSegmentKinds: Set<SkipSegmentKind> = []
    @State private var skipTimeObserver: Any?
    @State private var skipPlanTask: Task<Void, Never>?
    @State private var skipToastMessage: String?
    @State private var skipToastTask: Task<Void, Never>?

    let episodeInfo: BgmEpisodeInfo
    let episodes: [BgmEpisodeInfo]
    let sessionTitle: String
    let initialPlaybackPositionSeconds: Int?
    var onSelectEpisode: ((BgmEpisodeInfo) -> Void)? = nil
    var onPlaybackCompleted: (() -> Void)? = nil
    var onExitRequest: (() -> Void)? = nil
    @State private var text = "正在解析番剧源..."

    init(
        episodeInfo: BgmEpisodeInfo,
        episodes: [BgmEpisodeInfo] = [],
        sessionTitle: String,
        initialPlaybackPositionSeconds: Int? = nil,
        onSelectEpisode: ((BgmEpisodeInfo) -> Void)? = nil,
        onPlaybackCompleted: (() -> Void)? = nil,
        onExitRequest: (() -> Void)? = nil
    ) {
        self.episodeInfo = episodeInfo
        self.episodes = episodes
        self.sessionTitle = sessionTitle
        self.initialPlaybackPositionSeconds = initialPlaybackPositionSeconds
        self.onSelectEpisode = onSelectEpisode
        self.onPlaybackCompleted = onPlaybackCompleted
        self.onExitRequest = onExitRequest
    }

    private var episodeLabel: String {
        let value = episodeInfo.ep > 0 ? episodeInfo.ep : episodeInfo.sort
        if value.rounded() == value {
            return "第 \(Int(value)) 集"
        }
        return "第 \(value) 集"
    }

    private var hasNextEpisode: Bool {
        guard let currentIndex = episodes.firstIndex(where: { $0.id == episodeInfo.id }) else {
            return false
        }
        return episodes.indices.contains(currentIndex + 1)
    }

    private var nextEpisode: BgmEpisodeInfo? {
        guard let currentIndex = episodes.firstIndex(where: { $0.id == episodeInfo.id }) else {
            return nil
        }
        let nextIndex = currentIndex + 1
        return episodes.indices.contains(nextIndex) ? episodes[nextIndex] : nil
    }

    private var resolvedEpisodeNumberForAniSkip: Int {
        let value = episodeInfo.ep > 0 ? episodeInfo.ep : episodeInfo.sort
        return max(0, Int(value.rounded()))
    }

    nonisolated static func resolveResumePosition(
        currentItemStatus: AVPlayerItem.Status?,
        currentPlayerTime: CMTime?,
        lastPlaybackPosition: CMTime?,
        isApplyingResumeSeek: Bool
    ) -> CMTime? {
        if !isApplyingResumeSeek,
           currentItemStatus == .readyToPlay,
           let currentPlayerTime {
            return currentPlayerTime
        }
        return lastPlaybackPosition
    }

    nonisolated static func subtitleLanguageSortPriority(
        text: String,
        subtitleLanguageIds: [String] = []
    ) -> Int {
        let lower = text.lowercased()
        let tokens = Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted))
        let upperIDs = Set(subtitleLanguageIds.map { $0.uppercased() })

        let simplifiedMarkers = ["简中", "簡中", "简体", "簡體", "简日", "簡日", "简字", "簡字", "中简", "中簡", "zh-hans", "zh_hans"]
        let traditionalMarkers = ["繁中", "繁体", "繁體", "繁日", "繁字", "中繁", "zh-hant", "zh_hant", "big5"]

        let hasSimplified = upperIDs.contains("CHS")
            || simplifiedMarkers.contains { lower.contains($0) }
            || tokens.contains("chs")
        let hasTraditional = upperIDs.contains("CHT")
            || traditionalMarkers.contains { lower.contains($0) }
            || tokens.contains("cht")

        if hasSimplified && !hasTraditional {
            return 0 // 纯简中优先
        }
        if hasSimplified && hasTraditional {
            return 1 // 简繁双语其次
        }
        if hasTraditional {
            return 3 // 繁中排在简中与未标注线路之后
        }
        return 2 // 未标注语言保持原有相对顺序
    }

    nonisolated static func prioritizedMediaSourceConfigs(
        _ configs: [MediaSourceConfig],
        defaultSourceName: String?
    ) -> [MediaSourceConfig] {
        let normalizedDefault = defaultSourceName?.trimmingCharacters(in: .whitespacesAndNewlines)

        var pinned: MediaSourceConfig?
        var remaining: [(offset: Int, config: MediaSourceConfig)] = []

        for (index, config) in configs.enumerated() {
            if pinned == nil,
               let normalizedDefault,
               !normalizedDefault.isEmpty,
               config.arguments?.name == normalizedDefault {
                pinned = config
            } else {
                remaining.append((index, config))
            }
        }

        let sortedRemaining = remaining.sorted { lhs, rhs in
            let lhsPriority = subtitleLanguageSortPriority(text: lhs.config.arguments?.name ?? "")
            let rhsPriority = subtitleLanguageSortPriority(text: rhs.config.arguments?.name ?? "")
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.offset < rhs.offset
        }.map(\.config)

        if let pinned {
            return [pinned] + sortedRemaining
        }
        return sortedRemaining
    }

    nonisolated static func prioritizedMediaMatches(_ matches: [MediaMatch]) -> [MediaMatch] {
        matches.enumerated().sorted { lhs, rhs in
            let lhsText = "\(lhs.element.media.properties.alliance) \(lhs.element.media.originalTitle)"
            let rhsText = "\(rhs.element.media.properties.alliance) \(rhs.element.media.originalTitle)"
            let lhsPriority = subtitleLanguageSortPriority(
                text: lhsText,
                subtitleLanguageIds: lhs.element.media.properties.subtitleLanguageIds
            )
            let rhsPriority = subtitleLanguageSortPriority(
                text: rhsText,
                subtitleLanguageIds: rhs.element.media.properties.subtitleLanguageIds
            )
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    var body: some View {
        ZStack {
            AdvancedVideoPlayer(
                player: player,
                title: sessionTitle,
                episodes: episodes.isEmpty ? [episodeInfo] : episodes,
                currentEpisode: episodeInfo,
                availableSources: videoSources,
                isSourcePanelPresented: $isSourcePanelPresented,
                danmuManager: danmuManager,
                isDanmakuAvailable: isDanmakuAvailable,
                activeSkipAction: activeSkipAction,
                skipOPEDMode: skipOPEDMode,
                skipPlanSourceDescription: episodeSkipPlan.sourceDescription,
                hasCustomSkipPreference: episodeSkipPlan.hasCustomPreference,
                fallbackOPSkipSeconds: fallbackOPSkipSeconds,
                onExitRequest: onExitRequest,
                onSelectEpisode: onSelectEpisode,
                onDanmakuToggled: { newEnabled in
                    AniTVDatabase.persistDanmakuStateIfRememberEnabled(newEnabled, in: database)
                },
                onDanmakuDisplayAreaChanged: { newArea in
                    AniTVDatabase.persistDanmakuDisplayArea(newArea, in: database)
                },
                onPerformSkipAction: handlePerformSkipAction,
                onChangeSkipMode: handleChangeSkipOPEDMode,
                onManualFallbackSkipOP: handleManualFallbackSkipOP,
                onRememberCurrentAsOPEnd: handleRememberCurrentAsOPEnd,
                onClearCustomSkipPreference: handleClearCustomSkipPreference,
                onSourceSelected: handleUserSelectedResource
            )
                .ignoresSafeArea()

            if let skipToastMessage {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 10) {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(Color.cyan)

                            Text(skipToastMessage)
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .overlay(Capsule().fill(Color.black.opacity(0.45)))
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                        .padding(.top, 52)
                        .padding(.trailing, 64)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(2)
            }

            if isSourcePanelPresented {
                ZStack(alignment: .top) {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.68),
                            Color.black.opacity(0.32),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 640)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                    SourcePanelOverlayContainer(model: sourcePanelModel)
                        .id(sourcePanelPresentationID)
                        .frame(width: 1180, height: 476)
                        .padding(.top, 44)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
                .onExitCommand {
                    isSourcePanelPresented = false
                }
            }
            
//            if isLoading {
//                VStack(spacing: 20) {
//                    ProgressView()
//                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
//                        .scaleEffect(1.5)
//                    Text(text)
//                        .foregroundColor(.gray)
//                }
//                .frame(maxWidth: .infinity, maxHeight: .infinity)
//                .background(Color.black)
//            }
        }
        .animation(.easeOut(duration: 0.2), value: isSourcePanelPresented)
        .onChange(of: isSourcePanelPresented) { _, isPresented in
            guard isPresented else { return }
            sourcePanelPresentationID += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let finishedItem = notification.object as? AVPlayerItem,
                  finishedItem === player.currentItem else { return }
            didFinishPlayback = true
            finalizePlaybackProgress(trigger: "completed", shouldSyncCompletionToBangumi: true)
            onPlaybackCompleted?()
        }
        .onAppear {
            setupDanmaku(episodeInfo: episodeInfo)
            hasResolvedAutoPlayback = false
            hasUserSelectedSource = false
            queuedVideoResources = []
            queuedVideoResourceKeys = []
            attemptedAutoResourceKeys = []
            isAttemptingPlayback = false
            didFinishPlayback = false
            didSyncCompletionToBangumi = false
            skippedSegmentKinds = []
            activeSkipAction = nil
            episodeSkipPlan = .empty
            isApplyingResumeSeek = false
            if let initialPlaybackPositionSeconds, initialPlaybackPositionSeconds > 0 {
                lastPlaybackPosition = CMTime(
                    seconds: Double(initialPlaybackPositionSeconds),
                    preferredTimescale: 600
                )
            } else {
                lastPlaybackPosition = nil
            }
            lastSavedPlayheadSeconds = initialPlaybackPositionSeconds
            configurePlaybackProgressTracking()
            sourcePanelModel.update(
                sources: videoSources,
                sessionTitle: sessionTitle,
                episodeLabel: episodeLabel,
                defaultSourceName: defaultMediaSourceName,
                onSourceSelected: handleUserSelectedResource,
                onSetDefaultSource: handleSetDefaultMediaSource
            )
            Task {
                await loadPlaybackPersistenceContext()
                loadSkipPlan()
            }
            fetchSourcesTask?.cancel()
            fetchSourcesTask = Task { @MainActor in
                await doFetch()
            }
        }
        .onDisappear {
            // 退出时清理资源和监听器
            finalizePlaybackProgress(trigger: "exit", shouldSyncCompletionToBangumi: true)
            fetchSourcesTask?.cancel()
            fetchSourcesTask = nil
            playbackTask?.cancel()
            playbackTask = nil
            skipPlanTask?.cancel()
            skipPlanTask = nil
            skipToastTask?.cancel()
            skipToastTask = nil
            Task { @MainActor in
                mediaResolver.cancelResolve()
            }
            LocalHlsPlaybackPreparer.shared.stopCurrentSession()
            lastPlaybackPosition = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
            statusObservation?.invalidate()
            statusObservation = nil
            removePlaybackProgressTracking()
            cleanup()
        }
    }

    private func handleSetDefaultMediaSource(_ name: String?) {
        defaultMediaSourceName = name
        Task {
            try? await AniTVDatabase.setDefaultMediaSourceName(name, in: database)
        }
    }

    private func handleUserSelectedResource(sourceIndex: Int, resourceIndex: Int, resource: VideoResource) {
        hasUserSelectedSource = true
        hasResolvedAutoPlayback = true
        startPlaybackAttempt(
            sourceIndex: sourceIndex,
            resourceIndex: resourceIndex,
            resource: resource,
            isUserInitiated: true
        )
    }

    private func startPlaybackAttempt(
        sourceIndex: Int,
        resourceIndex: Int,
        resource: VideoResource,
        isUserInitiated: Bool
    ) {
        isAttemptingPlayback = true
        playbackTask?.cancel()
        playbackTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        sourcePanelModel.beginSelectionAttempt(sourceIndex: sourceIndex, resourceIndex: resourceIndex)
        onSwitch(resource: resource, isUserInitiated: isUserInitiated)
    }

    private func attemptNextQueuedResourceIfNeeded() {
        guard !hasUserSelectedSource, !hasResolvedAutoPlayback, !isAttemptingPlayback else { return }
        if isWaitingForDefaultSource {
            return
        }

        while !queuedVideoResources.isEmpty {
            let next = queuedVideoResources.removeFirst()
            let key = QueuedVideoResourceKey(sourceIndex: next.sourceIndex, resourceIndex: next.resourceIndex)
            queuedVideoResourceKeys.remove(key)
            guard !attemptedAutoResourceKeys.contains(key) else { continue }
            attemptedAutoResourceKeys.insert(key)
            startPlaybackAttempt(
                sourceIndex: next.sourceIndex,
                resourceIndex: next.resourceIndex,
                resource: next.resource,
                isUserInitiated: false
            )
            return
        }
    }

    private func enqueueResources(_ resources: [VideoResource], forSourceIndex sourceIndex: Int) {
        for (resourceIndex, resource) in resources.enumerated() {
            let key = QueuedVideoResourceKey(sourceIndex: sourceIndex, resourceIndex: resourceIndex)
            guard !queuedVideoResourceKeys.contains(key), !attemptedAutoResourceKeys.contains(key) else { continue }
            queuedVideoResources.append(
                QueuedVideoResource(
                    sourceIndex: sourceIndex,
                    resourceIndex: resourceIndex,
                    resource: resource
                )
            )
            queuedVideoResourceKeys.insert(key)
        }
        queuedVideoResources.sort { lhs, rhs in
            if lhs.sourceIndex != rhs.sourceIndex {
                return lhs.sourceIndex < rhs.sourceIndex
            }
            return lhs.resourceIndex < rhs.resourceIndex
        }
    }

    private func onSwitch(resource: VideoResource, isUserInitiated: Bool){
        playbackTask = Task { @MainActor in
            let validCurrentTime = validatedPlaybackPosition(from: player.currentTime())
            let resumeTime = Self.resolveResumePosition(
                currentItemStatus: player.currentItem?.status,
                currentPlayerTime: validCurrentTime,
                lastPlaybackPosition: lastPlaybackPosition,
                isApplyingResumeSeek: isApplyingResumeSeek
            )
            if let resumeTime {
                lastPlaybackPosition = resumeTime
            }
            mediaResolver.cancelResolve()
            print("解析地址: \(resource.url)")
            let playerItem: AVPlayerItem
            if let directURL = resource.directPlayURL {
                print("🎬 本地媒体源直连播放 URL: \(directURL)")
                if resource.directHeaders.isEmpty {
                    playerItem = AVPlayerItem(url: directURL)
                } else {
                    let asset = AVURLAsset(
                        url: directURL,
                        options: ["AVURLAssetHTTPHeaderFieldsKey": resource.directHeaders]
                    )
                    playerItem = AVPlayerItem(asset: asset)
                }
            } else {
                guard let matchConfig = resource.matchConfig else {
                    isAttemptingPlayback = false
                    sourcePanelModel.markPendingSelectionResolveFailed()
                    if !isUserInitiated {
                        attemptNextQueuedResourceIfNeeded()
                    }
                    return
                }
                var link: ExtractionResult
                do {
                    link = try await mediaResolver.resolve(pageUrl: resource.url, config: matchConfig)
                    print("🎉 最终 m3u8 直链: \(link.m3u8Url)")
                    print("📋 请求头: \(link.headers)")
                    print("🍪 Cookies: \(link.cookieString)")
                } catch {
                    if error is CancellationError {
                        return
                    }
                    print("❌ 解析失败或超时: \(error.localizedDescription)")
                    isAttemptingPlayback = false
                    sourcePanelModel.markPendingSelectionResolveFailed()
                    if !isUserInitiated {
                        attemptNextQueuedResourceIfNeeded()
                    }
                    return
                }

                let prepared = await LocalHlsPlaybackPreparer.shared.prepare(url: link.m3u8Url, headers: link.headers)
                print("🎬 播放目标 URL: \(prepared.playUrl)")
                playerItem = AVPlayerItem(url: prepared.playUrl)
            }
            playerItem.externalMetadata = createMetadata()
            var didHandleReadyToPlay = false
            
            // 💥 2. 把返回的监听器赋值给 State 变量
            statusObservation = playerItem.observe(\.status, options: [.new, .initial]) { item, _ in
                // 因为是异步回调，确保在主线程打印和处理
                DispatchQueue.main.async {
                    if item.status == .failed {
                        print("❌ 播放失败: \(String(describing: item.error?.localizedDescription))")
                        if let error = item.error as NSError? {
                            print("❌ 详细错误信息: \(error.userInfo)")
                        }
                        text = "播放失败"
                        isAttemptingPlayback = false
                        isApplyingResumeSeek = false
                        sourcePanelModel.markPendingSelectionPlaybackFailed()
                        if !isUserInitiated {
                            attemptNextQueuedResourceIfNeeded()
                        }
                    } else if item.status == .readyToPlay {
                        guard !didHandleReadyToPlay else { return }
                        didHandleReadyToPlay = true
                        print("✅ 准备就绪，可以播放")
                        isLoading = false
                        isAttemptingPlayback = false
                        hasResolvedAutoPlayback = true
                        sourcePanelModel.confirmPendingSelection()
                        isSourcePanelPresented = false
                        if let resumeTime, resumeTime.seconds > 0 {
                            let targetResumeTime: CMTime
                            if let itemDuration = validatedPlaybackPosition(from: item.duration),
                               itemDuration.seconds > 2 {
                                let clampedSeconds = min(resumeTime.seconds, itemDuration.seconds - 1)
                                targetResumeTime = CMTime(seconds: max(0, clampedSeconds), preferredTimescale: 600)
                            } else {
                                targetResumeTime = resumeTime
                            }
                            lastPlaybackPosition = targetResumeTime
                            isApplyingResumeSeek = true
                            print("⏩ 续播定位至 \(Int(targetResumeTime.seconds)) 秒")
                            player.seek(to: targetResumeTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                                DispatchQueue.main.async {
                                    isApplyingResumeSeek = false
                                    player.play()
                                }
                            }
                        } else {
                            isApplyingResumeSeek = false
                            player.play()
                        }
                    } else if item.status == .unknown {
                        print("⏳ 状态未知，正在缓冲...")
                    }
                }
            }
            
            player.replaceCurrentItem(with: playerItem)
        }
    }

    private enum UnifiedFetchSource {
        case local(LocalMediaSourceConfig)
        case remote(MediaSourceConfig)

        var displayName: String {
            switch self {
            case .local(let config):
                return config.name
            case .remote(let config):
                return config.arguments?.name ?? "Unknown Source"
            }
        }
    }

    private func doFetch() async -> URL? {
        guard !Task.isCancelled else { return nil }
        let localSources = (try? await AniTVDatabase.fetchLocalMediaSources(enabledOnly: true, in: database)) ?? []
        let rawConfigs: [MediaSourceConfig]
        do {
            rawConfigs = try await AniTVDatabase.fetchMediaSourceConfigs(in: database)
        } catch {
            print("[AnimePlayer] Failed to load media sources from database: \(error)")
            rawConfigs = []
        }

        guard !localSources.isEmpty || !rawConfigs.isEmpty else {
            print("[AnimePlayer] No media sources available in database")
            videoSources = []
            sourcePanelModel.update(
                sources: videoSources,
                sessionTitle: sessionTitle,
                episodeLabel: episodeLabel,
                defaultSourceName: defaultMediaSourceName,
                onSourceSelected: handleUserSelectedResource,
                onSetDefaultSource: handleSetDefaultMediaSource
            )
            sourcePanelModel.setLoadingSources(Set<Int>())
            return nil
        }

        let configuredConcurrency = (try? await AniTVDatabase.playbackSearchConcurrency(in: database)) ?? sourceFetchConcurrency
        let effectiveConcurrency = max(1, configuredConcurrency)
        let savedDefaultSourceName = try? await AniTVDatabase.defaultMediaSourceName(in: database)
        defaultMediaSourceName = savedDefaultSourceName

        let orderedRemoteConfigs = Self.prioritizedMediaSourceConfigs(rawConfigs, defaultSourceName: savedDefaultSourceName)
        var unifiedSources: [UnifiedFetchSource] =
            localSources.map { .local($0) } + orderedRemoteConfigs.map { .remote($0) }

        if let savedDefaultSourceName, !savedDefaultSourceName.isEmpty,
           let preferredIndex = unifiedSources.firstIndex(where: { $0.displayName == savedDefaultSourceName }),
           preferredIndex > 0 {
            let preferred = unifiedSources.remove(at: preferredIndex)
            unifiedSources.insert(preferred, at: 0)
        }

        let hasPinnedDefaultSourceAtZero: Bool = {
            guard let savedDefaultSourceName, !savedDefaultSourceName.isEmpty else { return false }
            return unifiedSources.first?.displayName == savedDefaultSourceName
        }()
        isWaitingForDefaultSource = hasPinnedDefaultSourceAtZero

        let indexedSources = Array(unifiedSources.enumerated())

        videoSources = unifiedSources.enumerated().map { index, source in
            let fallbackName = "Source \(index)"
            let name = source.displayName.isEmpty ? fallbackName : source.displayName
            return VideoSource(sourceName: name, resources: [])
        }
        sourcePanelModel.update(
            sources: videoSources,
            sessionTitle: sessionTitle,
            episodeLabel: episodeLabel,
            defaultSourceName: savedDefaultSourceName,
            onSourceSelected: handleUserSelectedResource,
            onSetDefaultSource: handleSetDefaultMediaSource
        )
        sourcePanelModel.setLoadingSources(Set(indexedSources.map(\.0)))

        let localSearchEpisodeNumber = max(1, resolvedEpisodeNumberForAniSkip)
        let bangumiInfo = try? await AniTVDatabase.bangumiMalLookupInfo(
            forBangumiID: String(episodeInfo.subjectId),
            in: database
        )
        let localSearchTitles = [sessionTitle, bangumiInfo?.originalTitle ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for batchStart in stride(from: 0, to: indexedSources.count, by: effectiveConcurrency) {
            guard !Task.isCancelled else { return nil }
            let batchEnd = min(batchStart + effectiveConcurrency, indexedSources.count)
            let batch = Array(indexedSources[batchStart..<batchEnd])

            await withTaskGroup(of: (Int, [VideoResource]).self) { group in
                for (index, unifiedSource) in batch {
                    group.addTask {
                        guard !Task.isCancelled else { return (index, []) }
                        switch unifiedSource {
                        case .local(let localConfig):
                            let matches = await LocalMediaServerClient.shared.searchEpisode(
                                source: localConfig,
                                subjectTitles: localSearchTitles,
                                episodeNumber: localSearchEpisodeNumber
                            )
                            let resources = matches.map { match in
                                VideoResource(
                                    resourceName: match.displayName,
                                    url: match.streamURL.absoluteString,
                                    matchConfig: nil,
                                    directPlayURL: match.streamURL,
                                    directHeaders: match.headers
                                )
                            }
                            return (index, resources)

                        case .remote(let config):
                            print("get lines: \(config.arguments?.name ?? "UNKNOWN SOURCE \(index)")")
                            let mediaSource = SelectorMediaSource(
                                mediaSourceId: "1",
                                config: config,
                                repository: SelectorMediaSourceEpisodeCacheRepository(),
                                client: URLSessionHTTPClient()
                            )
                            print(episodeInfo.name)
                            let result = await mediaSource.fetch(query: MediaFetchRequest(
                                subjectId: "\(episodeInfo.subjectId)",
                                episodeId: "\(episodeInfo.id)",
                                subjectNameCN: sessionTitle,
                                subjectNames: [sessionTitle],
                                episodeSort: .normal(number: Float(Int(episodeInfo.sort))),
                                episodeName: "\(episodeInfo.nameCN)",
                                episodeEp: .normal(number: Float(Int(episodeInfo.ep)))
                            ))

                            // 线路选择面板优先选择 session title exact match 的项目，并将简中线路排在繁中上面
                            let exactMatchedItems = result.filter {
                                $0.media.properties.subjectName == sessionTitle
                            }
                            let baseItems = exactMatchedItems.isEmpty ? result : exactMatchedItems
                            let displayedItems = Self.prioritizedMediaMatches(baseItems)

                            guard let matchConfig = config.arguments?.searchConfig.matchVideo else {
                                return (index, [])
                            }

                            let resources = displayedItems.map {
                                VideoResource(
                                    resourceName: $0.media.properties.alliance,
                                    url: $0.media.originalUrl,
                                    matchConfig: matchConfig
                                )
                            }
                            return (index, resources)
                        }
                    }
                }

                for await (index, resources) in group {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    guard videoSources.indices.contains(index) else { continue }
                    videoSources[index] = VideoSource(
                        sourceName: videoSources[index].sourceName,
                        resources: resources
                    )
                    sourcePanelModel.markSourceLoaded(index)
                    enqueueResources(resources, forSourceIndex: index)
                    if index == 0 && isWaitingForDefaultSource {
                        isWaitingForDefaultSource = false
                    }
                    sourcePanelModel.update(
                        sources: videoSources,
                        onSourceSelected: handleUserSelectedResource
                    )
                    attemptNextQueuedResourceIfNeeded()
                }
            }
        }

        if isWaitingForDefaultSource {
            isWaitingForDefaultSource = false
            attemptNextQueuedResourceIfNeeded()
        }
        return nil
    }
    
    private func createMetadata() -> [AVMetadataItem] {
        var metadata: [AVMetadataItem] = []
        let episodeTitle = resolvedEpisodeTitle()
        
        // 1. 设置主标题 (例如："葬送的芙莉莲")
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = episodeTitle as NSString // 使用你传入的 title
        titleItem.extendedLanguageTag = "und" // "und" 表示 undefined，通用语言标签
        metadata.append(titleItem)
        
        // 2. 设置副标题或简介 (例如："第 1 集")
        let subtitle = AVMutableMetadataItem()
        subtitle.identifier = .commonIdentifierCreationDate
        subtitle.value =  "\(sessionTitle) 第 \(Int(episodeInfo.ep)) 集" as NSString // 结合你传入的 sort 变量
        subtitle.extendedLanguageTag = "und"
        metadata.append(subtitle)
        
        // 2. 设置副标题或简介 (例如："第 1 集")
        let descItem = AVMutableMetadataItem()
        descItem.identifier = .commonIdentifierDescription
        descItem.value =  episodeInfo.desc as NSString // 结合你传入的 sort 变量
        descItem.extendedLanguageTag = "und"
        metadata.append(descItem)
        
        // 3. 设置流派/分类 (显示在标题上方的小字，例如："AniTV 播放器")
        let genreItem = AVMutableMetadataItem()
        genreItem.identifier = .quickTimeMetadataAlbum
        genreItem.value = sessionTitle as NSString
        genreItem.extendedLanguageTag = "und"
        metadata.append(genreItem)
        
        return metadata
    }

    private func resolvedEpisodeTitle() -> String {
        let chineseTitle = episodeInfo.nameCN.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chineseTitle.isEmpty {
            return chineseTitle
        }

        let originalTitle = episodeInfo.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !originalTitle.isEmpty {
            return originalTitle
        }

        return "第 \(Int(episodeInfo.ep)) 集"
    }

    @MainActor
    private func loadPlaybackPersistenceContext() async {
        do {
            let profile = try await AniTVDatabase.currentUserProfile(in: database)
            currentBgmUserID = profile?.effectiveBgmUserID
            playbackCompletionThreshold = try await AniTVDatabase.playbackCompletionThreshold(in: database)
            skipOPEDMode = try await AniTVDatabase.skipOPEDMode(in: database)
            fallbackOPSkipSeconds = try await AniTVDatabase.fallbackOPSkipSeconds(in: database)
        } catch {
            currentBgmUserID = nil
            playbackCompletionThreshold = AniTVDatabase.defaultPlaybackCompletionThreshold
            skipOPEDMode = AniTVDatabase.defaultSkipOPEDMode
            fallbackOPSkipSeconds = AniTVDatabase.defaultFallbackOPSkipSeconds
            print("Failed to load playback persistence context: \(error)")
        }
    }

    private func loadSkipPlan() {
        skipPlanTask?.cancel()
        let subjectID = episodeInfo.subjectId
        let epNumber = resolvedEpisodeNumberForAniSkip
        let title = sessionTitle
        let durationSeconds = resolvedDurationSeconds()
        let db = database

        skipPlanTask = Task {
            let plan = await AniSkipService.shared.resolveSkipPlan(
                subjectID: subjectID,
                episodeNumber: epNumber,
                sessionTitle: title,
                episodeDurationSeconds: durationSeconds,
                database: db
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                episodeSkipPlan = plan
                evaluateSkipDecisionNow()
            }
        }
    }

    private func evaluateSkipDecisionNow() {
        guard !isSourcePanelPresented,
              player.currentItem?.status == .readyToPlay,
              let validTime = validatedPlaybackPosition(from: player.currentTime()) else {
            if activeSkipAction != nil {
                activeSkipAction = nil
            }
            return
        }

        let currentSeconds = validTime.seconds
        let durationSeconds = Double(resolvedDurationSeconds())

        let decision = SkipDecisionEngine.evaluate(
            currentTime: currentSeconds,
            duration: durationSeconds,
            plan: episodeSkipPlan,
            mode: skipOPEDMode,
            fallbackOPSkipSeconds: fallbackOPSkipSeconds,
            hasNextEpisode: hasNextEpisode,
            skippedKinds: skippedSegmentKinds
        )

        switch decision {
        case .none:
            if activeSkipAction != nil {
                activeSkipAction = nil
            }
        case .showPrompt(let action):
            if activeSkipAction != action {
                activeSkipAction = action
            }
        case .autoSkip(let segment):
            performAutoSkip(segment: segment, durationSeconds: durationSeconds)
        }
    }

    private func performAutoSkip(segment: SkipSegment, durationSeconds: Double) {
        skippedSegmentKinds.insert(segment.kind)
        activeSkipAction = nil

        if segment.kind == .ed,
           durationSeconds > 0,
           segment.endTime >= durationSeconds - 10,
           let nextEpisode {
            showSkipToast("已自动跳过片尾，即将播放下一集")
            finalizePlaybackProgress(trigger: "skip_ed_auto", shouldSyncCompletionToBangumi: true)
            onSelectEpisode?(nextEpisode)
            return
        }

        let clampedTarget = durationSeconds > 0
            ? min(segment.endTime, max(0, durationSeconds - 1))
            : segment.endTime
        seekToSeconds(clampedTarget)
        showSkipToast(segment.kind == .op ? "已自动跳过片头" : "已自动跳过片尾")
    }

    private func handlePerformSkipAction(_ action: PlayerSkipContextualAction) {
        skippedSegmentKinds.insert(action.kind)
        activeSkipAction = nil

        if action.switchesToNextEpisode, let nextEpisode {
            finalizePlaybackProgress(trigger: "skip_ed_prompt", shouldSyncCompletionToBangumi: true)
            onSelectEpisode?(nextEpisode)
            return
        }

        let durationSeconds = Double(resolvedDurationSeconds())
        if let targetSeconds = action.targetSeconds {
            let clamped = durationSeconds > 0
                ? min(targetSeconds, max(0, durationSeconds - 1))
                : targetSeconds
            seekToSeconds(clamped)
            showSkipToast(action.kind == .op ? "已跳过片头" : "已跳过片尾")
        } else if action.kind == .op {
            handleManualFallbackSkipOP()
        }
    }

    private func handleManualFallbackSkipOP() {
        guard let currentTime = validatedPlaybackPosition(from: player.currentTime()) else { return }
        let durationSeconds = Double(resolvedDurationSeconds())
        let rawTarget = currentTime.seconds + Double(fallbackOPSkipSeconds)
        let target = durationSeconds > 0
            ? min(rawTarget, max(currentTime.seconds, durationSeconds - 5))
            : rawTarget
        skippedSegmentKinds.insert(.op)
        activeSkipAction = nil
        seekToSeconds(target)
        showSkipToast("已跳过片头 (+\(fallbackOPSkipSeconds)秒)")
    }

    private func handleRememberCurrentAsOPEnd() {
        guard let currentTime = validatedPlaybackPosition(from: player.currentTime()) else { return }
        let opEnd = currentTime.seconds
        guard opEnd >= 10 else {
            showSkipToast("当前位置过短，无法记录为片头结束")
            return
        }

        let subjectID = episodeInfo.subjectId
        let existingED = episodeSkipPlan.ed
        let pref = SubjectSkipPreference(
            subjectID: subjectID,
            opStart: 0,
            opEnd: opEnd,
            edStart: existingED?.source == .custom ? existingED?.startTime : nil,
            edEnd: existingED?.source == .custom ? existingED?.endTime : nil
        )
        Task {
            try? await AniTVDatabase.upsertSubjectSkipPreference(pref, in: database)
            await MainActor.run {
                episodeSkipPlan = EpisodeSkipPlan(
                    op: SkipSegment(kind: .op, startTime: 0, endTime: opEnd, source: .custom),
                    ed: episodeSkipPlan.ed
                )
                skippedSegmentKinds.insert(.op)
                activeSkipAction = nil
                showSkipToast("已记住本番片头结束：\(formattedTimestamp(opEnd))")
            }
        }
    }

    private func handleClearCustomSkipPreference() {
        let subjectID = episodeInfo.subjectId
        Task {
            try? await AniTVDatabase.deleteSubjectSkipPreference(forSubjectID: subjectID, in: database)
            await MainActor.run {
                skippedSegmentKinds.remove(.op)
                showSkipToast("已清除本番片头记忆")
                loadSkipPlan()
            }
        }
    }

    private func handleChangeSkipOPEDMode(_ mode: SkipOPEDMode) {
        skipOPEDMode = mode
        if mode == .off {
            activeSkipAction = nil
        }
        Task {
            try? await AniTVDatabase.setSkipOPEDMode(mode, in: database)
        }
        evaluateSkipDecisionNow()
        showSkipToast("跳过 OP/ED：\(mode.displayTitle)")
    }

    private func seekToSeconds(_ seconds: Double) {
        let targetTime = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        lastPlaybackPosition = targetTime
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player.play()
        }
    }

    private func showSkipToast(_ message: String) {
        skipToastTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            skipToastMessage = message
        }
        skipToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) {
                skipToastMessage = nil
            }
        }
    }

    private func formattedTimestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func configurePlaybackProgressTracking() {
        removePlaybackProgressTracking()

        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 10, preferredTimescale: 600),
            queue: .main
        ) { [weak player] _ in
            guard player != nil else { return }
            persistPlaybackProgress(trigger: "periodic")
        }

        skipTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak player] _ in
            guard player != nil else { return }
            evaluateSkipDecisionNow()
        }

        timeControlStatusObservation = player.observe(
            \.timeControlStatus,
            options: [.old, .new]
        ) { _, change in
            DispatchQueue.main.async {
                if change.newValue == .playing {
                    danmuManager?.play()
                } else if change.newValue == .paused {
                    danmuManager?.pause()
                    if change.oldValue == .playing {
                        persistPlaybackProgress(trigger: "pause")
                    }
                }
            }
        }
    }

    private func removePlaybackProgressTracking() {
        if let periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
            self.periodicTimeObserver = nil
        }
        if let skipTimeObserver {
            player.removeTimeObserver(skipTimeObserver)
            self.skipTimeObserver = nil
        }
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
    }

    private func cleanup() {
        print("🧹 Cleaning up AnimePlayerContainerView...")
        LocalHlsPlaybackPreparer.shared.stopCurrentSession()
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil

        if let periodicTimeObserver = periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
            self.periodicTimeObserver = nil
        }
        if let skipTimeObserver = skipTimeObserver {
            player.removeTimeObserver(skipTimeObserver)
            self.skipTimeObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        danmuManager = nil
    }

    private func setupDanmaku(episodeInfo: BgmEpisodeInfo) {
        Task {
            do {
                var candidateSorts: [Double] = []
                if episodeInfo.ep > 0 {
                    candidateSorts.append(episodeInfo.ep)
                }
                if !candidateSorts.contains(episodeInfo.sort) {
                    candidateSorts.append(episodeInfo.sort)
                }

                let bangumi = try await DanDanPlayAPI.shared.getBangumiDetails(
                    bgmId: episodeInfo.subjectId,
                    animeTitle: sessionTitle,
                    targetSorts: candidateSorts,
                    targetAirDate: episodeInfo.airdate
                )
                let candidateStrings = candidateSorts.map { String(Int($0)) }
                var matchedEpisode: DanDanPlayEpisode? = nil

                // 1. Exact match on episodeNumber or common title formats
                for targetString in candidateStrings {
                    let padded = targetString.count == 1 ? "0\(targetString)" : targetString
                    for ep in bangumi.episodes {
                        if ep.episodeNumber == targetString ||
                           ep.episodeTitle == targetString ||
                           ep.episodeTitle == padded ||
                           ep.episodeTitle.contains("第\(targetString)话") ||
                           ep.episodeTitle.contains("第\(targetString)集") ||
                           ep.episodeTitle.contains("第\(padded)话") ||
                           ep.episodeTitle.contains("第\(padded)集") ||
                           ep.episodeTitle.localizedCaseInsensitiveContains("E\(padded)") ||
                           ep.episodeTitle.localizedCaseInsensitiveContains("EP\(targetString)") ||
                           ep.episodeTitle.localizedCaseInsensitiveContains("EP \(targetString)") {
                            matchedEpisode = ep
                            break
                        }
                    }
                    if matchedEpisode != nil { break }
                }

                // 2. Match digit token in episodeTitle
                if matchedEpisode == nil {
                    for targetString in candidateStrings {
                        let targetInt = Int(targetString)
                        for ep in bangumi.episodes {
                            let numbers = ep.episodeTitle
                                .components(separatedBy: CharacterSet.decimalDigits.inverted)
                                .compactMap(Int.init)
                            if let targetInt, numbers.contains(targetInt) {
                                matchedEpisode = ep
                                break
                            }
                        }
                        if matchedEpisode != nil { break }
                    }
                }

                // 3. Match airdate prefix if available
                if matchedEpisode == nil, !episodeInfo.airdate.isEmpty {
                    matchedEpisode = bangumi.episodes.first(where: { ep in
                        ep.airDate?.hasPrefix(episodeInfo.airdate) == true
                    })
                }

                // 4. Sequential 1-based index fallback for ordered episode lists
                if matchedEpisode == nil,
                   let firstSort = candidateSorts.first,
                   firstSort >= 1 {
                    let index = Int(firstSort) - 1
                    if bangumi.episodes.indices.contains(index) {
                        matchedEpisode = bangumi.episodes[index]
                    }
                }

                // 5. Substring fallback
                if matchedEpisode == nil {
                    for targetString in candidateStrings {
                        if let first = bangumi.episodes.first(where: { $0.episodeTitle.contains(targetString) }) {
                            matchedEpisode = first
                            break
                        }
                    }
                }
                
                if let ep = matchedEpisode {
                    print("[DanDanPlay] Found episode \(ep.episodeId) for \(candidateStrings) in bgmId \(episodeInfo.subjectId)")
                    let provider = DanDanPlayDanmuProvider(episodeId: ep.episodeId, airDateString: ep.airDate) { success in
                        DispatchQueue.main.async {
                            if !success {
                                self.isDanmakuAvailable = false
                            }
                        }
                    }
                    let manager = DanmuViewManager(provider: provider)
                    await MainActor.run {
                        self.danmuManager = manager
                        if player.timeControlStatus == .playing || player.rate > 0 {
                            manager.play()
                        }
                    }
                } else {
                    print("[DanDanPlay] Could not find episode matching \(candidateStrings) in bgmId \(episodeInfo.subjectId)")
                    await MainActor.run {
                        self.isDanmakuAvailable = false
                    }
                }
            } catch {
                print("[DanDanPlay] Failed to get bangumi details for bgmId \(episodeInfo.subjectId): \(error)")
                await MainActor.run {
                    self.isDanmakuAvailable = false
                }
            }
        }
    }

    private func persistPlaybackProgress(trigger: String) {
        guard let snapshot = currentPlaybackProgressSnapshot(includeCompletionThreshold: false) else { return }
        saveLocalPlaybackProgress(
            snapshot.isCompleted ? 0 : snapshot.playheadSeconds,
            trigger: trigger
        )
    }

    private func finalizePlaybackProgress(
        trigger: String,
        shouldSyncCompletionToBangumi: Bool
    ) {
        guard let snapshot = currentPlaybackProgressSnapshot(includeCompletionThreshold: true) else { return }

        let persistedSeconds = snapshot.isCompleted ? 0 : snapshot.playheadSeconds
        saveLocalPlaybackProgress(persistedSeconds, trigger: trigger)

        guard shouldSyncCompletionToBangumi,
              snapshot.isCompleted,
              !didSyncCompletionToBangumi,
              currentBgmUserID != nil else { return }

        didSyncCompletionToBangumi = true

        Task {
            let repository = BangumiRepository()
            do {
                try await repository.ensureSubjectCollectionWatchingIfNeeded(
                    subjectID: episodeInfo.subjectId
                )
                try await repository.markEpisodesWatched(
                    subjectID: episodeInfo.subjectId,
                    episodeIDs: [episodeInfo.id]
                )
                print("Synced watched episode to Bangumi (\(trigger)): subject=\(episodeInfo.subjectId), episode=\(episodeInfo.id)")
            } catch {
                didSyncCompletionToBangumi = false
                print("Failed to sync watched episode to Bangumi (\(trigger)): \(error)")
            }
        }
    }

    private func currentPlaybackProgressSnapshot(
        includeCompletionThreshold: Bool
    ) -> PlaybackProgressSnapshot? {
        let validCurrentTime = validatedPlaybackPosition(from: player.currentTime())
        let resolvedTime = Self.resolveResumePosition(
            currentItemStatus: player.currentItem?.status,
            currentPlayerTime: validCurrentTime,
            lastPlaybackPosition: lastPlaybackPosition,
            isApplyingResumeSeek: isApplyingResumeSeek
        )
        guard let resolvedTime else { return nil }

        lastPlaybackPosition = resolvedTime
        let playheadSeconds = max(0, Int(resolvedTime.seconds.rounded(.down)))
        let isCompleted =
            didFinishPlayback
            || (includeCompletionThreshold && completionRatio(for: playheadSeconds) >= playbackCompletionThreshold)

        return PlaybackProgressSnapshot(
            playheadSeconds: playheadSeconds,
            isCompleted: isCompleted
        )
    }

    private func saveLocalPlaybackProgress(_ playheadSeconds: Int, trigger: String) {
        guard let bgmUserID = currentBgmUserID else { return }
        guard lastSavedPlayheadSeconds != playheadSeconds else { return }

        lastSavedPlayheadSeconds = playheadSeconds

        Task {
            do {
                try await AniTVDatabase.upsertLocalEpisodeWatchState(
                    bgmUserID: bgmUserID,
                    episodeID: episodeInfo.id,
                    type: LocalEpisodeWatchState.watchingType,
                    updatedAt: 0,
                    playheadSeconds: playheadSeconds,
                    in: database
                )
                print("Saved playback progress (\(trigger)): episode=\(episodeInfo.id), seconds=\(playheadSeconds)")
            } catch {
                print("Failed to save playback progress (\(trigger)): \(error)")
            }
        }
    }

    private func completionRatio(for playheadSeconds: Int) -> Double {
        let durationSeconds = resolvedDurationSeconds()
        guard durationSeconds > 0 else { return 0 }
        return min(1, Double(playheadSeconds) / Double(durationSeconds))
    }

    private func resolvedDurationSeconds() -> Int {
        if episodeInfo.durationSeconds > 0 {
            return episodeInfo.durationSeconds
        }

        if let duration = validatedPlaybackPosition(from: player.currentItem?.duration ?? .invalid) {
            return max(0, Int(duration.seconds.rounded(.down)))
        }

        return 0
    }

    private func validatedPlaybackPosition(from time: CMTime) -> CMTime? {
        guard time.isValid,
              !time.isIndefinite,
              !time.isNegativeInfinity,
              !time.isPositiveInfinity,
              time.seconds.isFinite,
              time.seconds >= 0 else {
            return nil
        }
        return time
    }

}

#Preview {
    AnimePlayerContainerView(
        episodeInfo: BgmEpisodeInfo(
            id: 1,
            subjectId: 1,
            type: 1,
            ep: 1.0,
            sort: 1.0,
            name: "test",
            nameCN: "test",
            duration: "test",
            durationSeconds: 0,
            airdate: "test",
            comment: 0,
            desc: "test",
            disc: 0
        ),
        sessionTitle: "test"
    )
    .zIndex(0)
}
