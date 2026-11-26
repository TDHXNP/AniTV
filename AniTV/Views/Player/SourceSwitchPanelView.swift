//
//  SourceSwitchPanelView.swift
//  AniTV
//
//  Created by Feiran Yang on 2026/3/28.
//

import SwiftUI
import Combine

private let sourcePanelWidth: CGFloat = 1180
private let sourcePanelHeight: CGFloat = 476
private let sourcePanelRowHeight: CGFloat = 60

fileprivate enum SourcePanelFocusTarget: Hashable {
    case source(Int)
    case defaultToggle
    case resource(Int)
}

fileprivate struct SourcePanelResourceKey: Hashable {
    let sourceIndex: Int
    let resourceIndex: Int
}

@MainActor
final class SourceSwitchPanelModel: ObservableObject {
    @Published var sources: [VideoSource] = []
    @Published var sessionTitle: String = ""
    @Published var episodeLabel: String = ""
    @Published var defaultSourceName: String?
    @Published var focusedSourceIndex: Int = 0
    @Published var committedSourceIndex: Int?
    @Published var committedResourceIndex: Int?
    @Published var pendingSourceIndex: Int?
    @Published var pendingResourceIndex: Int?
    @Published var loadingSourceIndices: Set<Int> = []
    @Published fileprivate var failedResourceKeys: Set<SourcePanelResourceKey> = []

    var onSourceSelected: ((Int, Int, VideoResource) -> Void)?
    var onSetDefaultSource: ((String?) -> Void)?

    func update(
        sources: [VideoSource],
        sessionTitle: String? = nil,
        episodeLabel: String? = nil,
        defaultSourceName: String?? = nil,
        onSourceSelected: ((Int, Int, VideoResource) -> Void)?,
        onSetDefaultSource: ((String?) -> Void)? = nil
    ) {
        self.sources = sources
        if let sessionTitle {
            self.sessionTitle = sessionTitle
        }
        if let episodeLabel {
            self.episodeLabel = episodeLabel
        }
        if let defaultSourceName {
            self.defaultSourceName = defaultSourceName
        }
        self.onSourceSelected = onSourceSelected
        if let onSetDefaultSource {
            self.onSetDefaultSource = onSetDefaultSource
        }

        if sources.isEmpty {
            focusedSourceIndex = 0
            committedSourceIndex = nil
            committedResourceIndex = nil
            pendingSourceIndex = nil
            pendingResourceIndex = nil
            return
        }

        focusedSourceIndex = min(focusedSourceIndex, sources.count - 1)
        committedSourceIndex = clampedSourceIndex(committedSourceIndex)
        pendingSourceIndex = clampedSourceIndex(pendingSourceIndex)
        committedResourceIndex = clampedResourceIndex(committedResourceIndex, in: committedSourceIndex)
        pendingResourceIndex = clampedResourceIndex(pendingResourceIndex, in: pendingSourceIndex)
    }

    var focusedSource: VideoSource? {
        guard sources.indices.contains(focusedSourceIndex) else { return nil }
        return sources[focusedSourceIndex]
    }

    var focusedResources: [VideoResource] {
        focusedSource?.resources ?? []
    }

    var totalSourceCount: Int {
        sources.count
    }

    var loadedSourceCount: Int {
        max(0, sources.count - loadingSourceIndices.count)
    }

    var isLoadingAnySource: Bool {
        !loadingSourceIndices.isEmpty
    }

    var isPendingAnyPlayback: Bool {
        pendingSourceIndex != nil && pendingResourceIndex != nil
    }

    var currentlyPlayingSummary: String? {
        guard let sourceIdx = committedSourceIndex,
              let resourceIdx = committedResourceIndex,
              sources.indices.contains(sourceIdx),
              sources[sourceIdx].resources.indices.contains(resourceIdx) else {
            return nil
        }
        return "\(sources[sourceIdx].sourceName) · \(sources[sourceIdx].resources[resourceIdx].resourceName)"
    }

    func focusSource(at index: Int) {
        guard sources.indices.contains(index) else { return }
        focusedSourceIndex = index
    }

    func isDefaultSource(_ index: Int) -> Bool {
        guard let defaultSourceName,
              !defaultSourceName.isEmpty,
              sources.indices.contains(index) else {
            return false
        }
        return sources[index].sourceName == defaultSourceName
    }

    var isFocusedSourceDefault: Bool {
        isDefaultSource(focusedSourceIndex)
    }

    func toggleDefaultSource(at index: Int) {
        guard sources.indices.contains(index) else { return }
        let sourceName = sources[index].sourceName
        let nextDefault: String? = (defaultSourceName == sourceName) ? nil : sourceName
        defaultSourceName = nextDefault
        onSetDefaultSource?(nextDefault)
    }

    func isSourceLoading(_ index: Int) -> Bool {
        loadingSourceIndices.contains(index)
    }

    func isPlayingSource(_ index: Int) -> Bool {
        if let pendingSourceIndex {
            return index == pendingSourceIndex
        }
        return index == committedSourceIndex
    }

    func isPlayingResource(_ index: Int) -> Bool {
        guard pendingSourceIndex == nil else { return false }
        return index == committedResourceIndex && focusedSourceIndex == committedSourceIndex
    }

    func isPendingResource(_ index: Int) -> Bool {
        index == pendingResourceIndex && focusedSourceIndex == pendingSourceIndex
    }

    func isFailedResource(_ index: Int) -> Bool {
        failedResourceKeys.contains(
            SourcePanelResourceKey(
                sourceIndex: focusedSourceIndex,
                resourceIndex: index
            )
        )
    }

    func selectResource(at index: Int) {
        guard focusedResources.indices.contains(index) else { return }
        beginSelectionAttempt(sourceIndex: focusedSourceIndex, resourceIndex: index)
        onSourceSelected?(focusedSourceIndex, index, focusedResources[index])
    }

    func beginSelectionAttempt(sourceIndex: Int, resourceIndex: Int) {
        guard sources.indices.contains(sourceIndex),
              sources[sourceIndex].resources.indices.contains(resourceIndex) else { return }
        focusedSourceIndex = sourceIndex
        pendingSourceIndex = sourceIndex
        pendingResourceIndex = resourceIndex
        failedResourceKeys.remove(
            SourcePanelResourceKey(
                sourceIndex: sourceIndex,
                resourceIndex: resourceIndex
            )
        )
    }

    func confirmPendingSelection() {
        if let pendingSourceIndex, let pendingResourceIndex {
            failedResourceKeys.remove(
                SourcePanelResourceKey(
                    sourceIndex: pendingSourceIndex,
                    resourceIndex: pendingResourceIndex
                )
            )
        }
        committedSourceIndex = pendingSourceIndex
        committedResourceIndex = pendingResourceIndex
        pendingSourceIndex = nil
        pendingResourceIndex = nil
    }

    func markPendingSelectionResolveFailed() {
        if let pendingSourceIndex, let pendingResourceIndex {
            failedResourceKeys.insert(
                SourcePanelResourceKey(
                    sourceIndex: pendingSourceIndex,
                    resourceIndex: pendingResourceIndex
                )
            )
        }
        clearPendingSelection()
    }

    func markPendingSelectionPlaybackFailed() {
        if let pendingSourceIndex, let pendingResourceIndex {
            failedResourceKeys.insert(
                SourcePanelResourceKey(
                    sourceIndex: pendingSourceIndex,
                    resourceIndex: pendingResourceIndex
                )
            )
        }
        committedSourceIndex = nil
        committedResourceIndex = nil
        clearPendingSelection()
    }

    func clearPendingSelection() {
        pendingSourceIndex = nil
        pendingResourceIndex = nil
    }

    var isFocusedSourceLoading: Bool {
        loadingSourceIndices.contains(focusedSourceIndex)
    }

    func setLoadingSources(_ indices: Set<Int>) {
        loadingSourceIndices = indices
    }

    func markSourceLoaded(_ index: Int) {
        loadingSourceIndices.remove(index)
    }

    private func clampedSourceIndex(_ index: Int?) -> Int? {
        guard let index, sources.indices.contains(index) else { return nil }
        return index
    }

    private func clampedResourceIndex(_ index: Int?, in sourceIndex: Int?) -> Int? {
        guard let sourceIndex,
              sources.indices.contains(sourceIndex),
              let index else { return nil }

        let resources = sources[sourceIndex].resources
        guard resources.indices.contains(index) else { return nil }
        return index
    }
}

struct SourceSwitchPanelView: View {
    @ObservedObject var model: SourceSwitchPanelModel
    @Namespace private var sourcePanelFocusScope
    @FocusState private var focusedTarget: SourcePanelFocusTarget?
    @State private var focusRestoreID = UUID()
    private let panelShape = RoundedRectangle(cornerRadius: 36, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.horizontal, 36)
                .padding(.top, 24)
                .padding(.bottom, 18)

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)
                .padding(.horizontal, 28)

            HStack(spacing: 0) {
                sourceColumn
                    .frame(width: 460)

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1)
                    .padding(.vertical, 18)

                resourceColumn
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 10)

            footerHintBar
                .padding(.horizontal, 36)
                .padding(.bottom, 16)
        }
        .frame(width: sourcePanelWidth, height: sourcePanelHeight)
        .background {
            panelShape
                .fill(.ultraThinMaterial)
                .overlay {
                    panelShape
                        .fill(Color.black.opacity(0.42))
                }
        }
        .glassEffect(.clear.tint(Color.black.opacity(0.24)), in: panelShape)
        .overlay {
            panelShape
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.28),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: Color.black.opacity(0.45), radius: 34, y: 16)
        .environment(\.colorScheme, .dark)
        .focusScope(sourcePanelFocusScope)
        .focusSection()
        .onAppear {
            focusedTarget = nil
            focusRestoreID = UUID()
            restoreInitialFocus()
        }
        .onChange(of: model.sources.count) { _, _ in
            guard focusedTarget == nil else { return }
            focusRestoreID = UUID()
            restoreInitialFocus()
        }
        .onChange(of: focusedTarget) { _, newValue in
            guard let newValue else { return }
            switch newValue {
            case .source(let index):
                model.focusSource(at: index)
            case .resource, .defaultToggle:
                break
            }
        }
    }

    // MARK: - Header & Footer

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle.on.rectangle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))

                Text("切换视频源")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                if !model.sessionTitle.isEmpty || !model.episodeLabel.isEmpty {
                    let contextText = [model.sessionTitle, model.episodeLabel]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    Text(contextText)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.58))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 420, alignment: .leading)
                }
            }

            Spacer(minLength: 16)

            headerStatusPill
        }
    }

    @ViewBuilder
    private var headerStatusPill: some View {
        if model.isPendingAnyPlayback {
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(0.75)

                Text("正在解析播放线路…")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(0.14)))
        } else if let playingSummary = model.currentlyPlayingSummary {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)

                Text(playingSummary)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(0.14)))
        } else if model.isLoadingAnySource {
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(0.75)

                Text("已加载 \(model.loadedSourceCount)/\(model.totalSourceCount) 个源")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(0.10)))
        } else if model.totalSourceCount > 0 {
            Text("共 \(model.totalSourceCount) 个视频源")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
    }

    private var footerHintBar: some View {
        HStack(spacing: 14) {
            Text("左右键切换视频源与线路 · 长按视频源或点击右上角设为默认 · 返回键关闭")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45))

            Spacer()

            if let defaultSourceName = model.defaultSourceName, !defaultSourceName.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.yellow.opacity(0.9))
                    Text("默认：\(defaultSourceName)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Focus & Scrolling

    private func restoreInitialFocus() {
        guard let target = preferredInitialFocusTarget else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            focusedTarget = nil
            switch target {
            case .source(let index):
                model.focusSource(at: index)
            case .resource:
                if let sourceIndex = preferredSelectedSourceIndex {
                    model.focusSource(at: sourceIndex)
                }
            case .defaultToggle:
                break
            }
            focusedTarget = target
        }
    }

    private func scrollSourceListIfNeeded(with proxy: ScrollViewProxy, anchor: UnitPoint = .center) {
        let targetIndex = preferredSourceScrollIndex ?? model.focusedSourceIndex
        guard model.sources.indices.contains(targetIndex) else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(targetIndex, anchor: anchor)
        }
    }

    private func scrollResourceListIfNeeded(with proxy: ScrollViewProxy, anchor: UnitPoint = .center) {
        let targetIndex = preferredResourceScrollIndex
        guard let targetIndex, model.focusedResources.indices.contains(targetIndex) else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(targetIndex, anchor: anchor)
        }
    }

    private var preferredInitialFocusTarget: SourcePanelFocusTarget? {
        if let _ = preferredSelectedSourceIndex,
           let resourceIndex = preferredSelectedResourceIndex {
            return .resource(resourceIndex)
        }

        if let sourceIndex = firstSourceWithResourcesIndex {
            return .source(sourceIndex)
        }

        guard !model.sources.isEmpty else { return nil }
        return .source(0)
    }

    private var preferredSelectedSourceIndex: Int? {
        if let pendingSourceIndex = model.pendingSourceIndex {
            return pendingSourceIndex
        }
        return model.committedSourceIndex
    }

    private var preferredSelectedResourceIndex: Int? {
        if let pendingResourceIndex = model.pendingResourceIndex {
            return pendingResourceIndex
        }
        return model.committedResourceIndex
    }

    private var firstSourceWithResourcesIndex: Int? {
        model.sources.firstIndex { !$0.resources.isEmpty }
    }

    private var preferredSourceScrollIndex: Int? {
        switch preferredInitialFocusTarget {
        case .source(let index):
            return index
        case .resource:
            return preferredSelectedSourceIndex
        case .defaultToggle, nil:
            return nil
        }
    }

    private var preferredResourceScrollIndex: Int? {
        switch preferredInitialFocusTarget {
        case .resource(let index):
            return index
        default:
            return nil
        }
    }

    private var preferredResourceFocusTarget: SourcePanelFocusTarget {
        if let pendingResourceIndex = model.pendingResourceIndex,
           model.focusedSourceIndex == model.pendingSourceIndex,
           model.focusedResources.indices.contains(pendingResourceIndex) {
            return .resource(pendingResourceIndex)
        }

        if let committedResourceIndex = model.committedResourceIndex,
           model.focusedSourceIndex == model.committedSourceIndex,
           model.focusedResources.indices.contains(committedResourceIndex) {
            return .resource(committedResourceIndex)
        }

        if model.focusedResources.indices.contains(0) {
            return .resource(0)
        }

        return .defaultToggle
    }

    private var isRightColumnFocused: Bool {
        switch focusedTarget {
        case .resource, .defaultToggle:
            return true
        case .source, nil:
            return false
        }
    }

    private var selectedBackgroundSourceIndex: Int? {
        guard isRightColumnFocused,
              model.sources.indices.contains(model.focusedSourceIndex) else { return nil }
        return model.focusedSourceIndex
    }

    private func resourceIndicator(for index: Int) -> ResourceRowView.StateStyle {
        if model.isPendingResource(index) {
            return .loading
        }
        if model.isPlayingResource(index) {
            return .playing
        }
        if model.isFailedResource(index) {
            return .failed
        }
        return .idle
    }

    // MARK: - Left Column (Sources)

    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("视频源")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))

                Spacer()

                let availableCount = model.sources.filter { !$0.resources.isEmpty }.count
                if availableCount > 0 {
                    Text("\(availableCount) 个可用")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 14)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(model.sources.enumerated()), id: \.offset) { index, source in
                            let isLoading = model.isSourceLoading(index)
                            let isDefault = model.isDefaultSource(index)
                            let isPlaying = model.isPlayingSource(index)
                            let showsSelectedBackground = selectedBackgroundSourceIndex == index

                            SourceRowView(
                                title: source.sourceName,
                                routeCount: source.resources.count,
                                isLoading: isLoading,
                                isPlaying: isPlaying,
                                isDefault: isDefault,
                                isFocused: focusedTarget == .source(index),
                                showsSelectedBackground: showsSelectedBackground,
                                isInitiallyFocused: preferredInitialFocusTarget == .source(index),
                                focusScope: sourcePanelFocusScope,
                                focusTarget: .source(index),
                                focusedTarget: $focusedTarget
                            ) {
                                model.focusSource(at: index)
                                if !source.resources.isEmpty {
                                    focusedTarget = preferredResourceFocusTarget
                                }
                            }
                            .contextMenu {
                                Button {
                                    model.toggleDefaultSource(at: index)
                                } label: {
                                    Label(
                                        isDefault ? "取消默认视频源" : "设为默认视频源",
                                        systemImage: isDefault ? "star.slash" : "star.fill"
                                    )
                                }
                            }
                            .onMoveCommand { direction in
                                guard focusedTarget == .source(index) else { return }
                                if direction == .right {
                                    focusedTarget = preferredResourceFocusTarget
                                }
                            }
                            .id(index)
                        }

                        if model.sources.isEmpty {
                            statusContent {
                                Text("暂无视频源")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.5))
                            }
                            .frame(height: 240)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onAppear {
                    scrollSourceListIfNeeded(with: proxy)
                }
                .onChange(of: focusRestoreID) { _, _ in
                    scrollSourceListIfNeeded(with: proxy)
                }
                .onChange(of: model.focusedSourceIndex) { _, newValue in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .padding(.trailing, 18)
    }

    // MARK: - Right Column (Routes)

    private var resourceColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("播放线路")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))

                if let source = model.focusedSource {
                    Text("· \(source.sourceName)")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.42))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if model.focusedSource != nil {
                    defaultSourceToggleButton
                }
            }
            .padding(.horizontal, 14)

            if model.isFocusedSourceLoading {
                statusContent {
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(1.25)

                        Text("正在搜索可用线路…")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.65))
                    }
                }
            } else if model.focusedResources.isEmpty {
                statusContent {
                    VStack(spacing: 12) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.35))

                        Text("该视频源暂无匹配线路")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.62))

                        Text("请尝试选择左侧其他视频源")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(model.focusedResources.enumerated()), id: \.offset) { index, resource in
                                ResourceRowView(
                                    title: resource.resourceName,
                                    state: resourceIndicator(for: index),
                                    isFocused: focusedTarget == .resource(index),
                                    isInitiallyFocused: preferredInitialFocusTarget == .resource(index),
                                    focusScope: sourcePanelFocusScope,
                                    focusTarget: .resource(index),
                                    focusedTarget: $focusedTarget
                                ) {
                                    model.selectResource(at: index)
                                }
                                .onMoveCommand { direction in
                                    guard focusedTarget == .resource(index) else { return }
                                    if direction == .left {
                                        focusedTarget = .source(model.focusedSourceIndex)
                                    } else if direction == .up && index == 0 {
                                        focusedTarget = .defaultToggle
                                    }
                                }
                                .id(index)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .onAppear {
                        scrollResourceListIfNeeded(with: proxy)
                    }
                    .onChange(of: focusRestoreID) { _, _ in
                        scrollResourceListIfNeeded(with: proxy)
                    }
                    .onChange(of: model.focusedSourceIndex) { _, _ in
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(0, anchor: .top)
                        }
                        scrollResourceListIfNeeded(with: proxy)
                    }
                    .onChange(of: model.committedResourceIndex) { _, newValue in
                        guard let newValue else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                    .onChange(of: model.pendingResourceIndex) { _, newValue in
                        guard let newValue,
                              model.focusedSourceIndex == model.pendingSourceIndex else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(.leading, 18)
    }

    private var defaultSourceToggleButton: some View {
        let isFocused = focusedTarget == .defaultToggle
        let isDefault = model.isFocusedSourceDefault

        return Button {
            model.toggleDefaultSource(at: model.focusedSourceIndex)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isDefault ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isFocused ? Color.black : (isDefault ? Color.yellow : Color.white.opacity(0.8)))

                Text(isDefault ? "已设为默认" : "设为默认")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isFocused ? Color.black : Color.white.opacity(0.9))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(
                        isFocused
                            ? Color.white
                            : (isDefault ? Color.yellow.opacity(0.20) : Color.white.opacity(0.12))
                    )
            )
            .scaleEffect(isFocused ? 1.04 : 1.0)
            .animation(.easeOut(duration: 0.14), value: isFocused)
        }
        .buttonStyle(CleanButtonStyle())
        .focused($focusedTarget, equals: .defaultToggle)
        .onMoveCommand { direction in
            guard focusedTarget == .defaultToggle else { return }
            switch direction {
            case .left:
                focusedTarget = .source(model.focusedSourceIndex)
            case .down:
                if !model.focusedResources.isEmpty {
                    focusedTarget = .resource(0)
                }
            default:
                break
            }
        }
    }

    private func statusContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - Source Row

private struct SourceRowView: View {
    let title: String
    let routeCount: Int
    let isLoading: Bool
    let isPlaying: Bool
    let isDefault: Bool
    let isFocused: Bool
    let showsSelectedBackground: Bool
    let isInitiallyFocused: Bool
    let focusScope: Namespace.ID
    let focusTarget: SourcePanelFocusTarget
    let focusedTarget: FocusState<SourcePanelFocusTarget?>.Binding
    let action: () -> Void

    private var isEmptyAndLoaded: Bool {
        !isLoading && routeCount == 0
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leadingIcon
                    .frame(width: 24, height: 24)

                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if isDefault {
                    Text("默认")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isFocused ? Color.black.opacity(0.85) : Color.yellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(isFocused ? Color.black.opacity(0.12) : Color.yellow.opacity(0.18))
                        )
                }

                Spacer(minLength: 8)

                trailingBadge
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: sourcePanelRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(rowBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        showsSelectedBackground && !isFocused
                            ? Color.white.opacity(0.28)
                            : Color.clear,
                        lineWidth: 1
                    )
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .shadow(color: isFocused ? Color.black.opacity(0.28) : .clear, radius: 12, y: 4)
            .animation(.easeOut(duration: 0.14), value: isFocused)
        }
        .buttonStyle(CleanButtonStyle())
        .prefersDefaultFocus(isInitiallyFocused, in: focusScope)
        .focused(focusedTarget, equals: focusTarget)
    }

    private var primaryTextColor: Color {
        if isFocused {
            return .black
        }
        return isEmptyAndLoaded ? Color.white.opacity(0.45) : Color.white.opacity(0.94)
    }

    private var rowBackgroundColor: Color {
        if isFocused {
            return Color.white
        }
        if showsSelectedBackground {
            return Color.white.opacity(0.16)
        }
        return Color.white.opacity(0.05)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if isPlaying {
            Image(systemName: "waveform")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(isFocused ? Color.black : Color.cyan)
        } else if isDefault {
            Image(systemName: "star.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isFocused ? Color.black : Color.yellow.opacity(0.9))
        } else {
            Circle()
                .fill(
                    isFocused
                        ? Color.black.opacity(0.35)
                        : (routeCount > 0 ? Color.green.opacity(0.85) : Color.white.opacity(0.22))
                )
                .frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private var trailingBadge: some View {
        if isLoading {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(isFocused ? .black : .white)
                .scaleEffect(0.75)
        } else if routeCount > 0 {
            Text("\(routeCount) 条")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isFocused ? Color.black.opacity(0.7) : Color.white.opacity(0.68))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isFocused ? Color.black.opacity(0.10) : Color.white.opacity(0.10))
                )
        } else {
            Text("无线路")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isFocused ? Color.black.opacity(0.45) : Color.white.opacity(0.32))
        }
    }
}

// MARK: - Resource Row

private struct ResourceRowView: View {
    enum StateStyle {
        case idle
        case playing
        case loading
        case failed
    }

    let title: String
    let state: StateStyle
    let isFocused: Bool
    let isInitiallyFocused: Bool
    let focusScope: Namespace.ID
    let focusTarget: SourcePanelFocusTarget
    let focusedTarget: FocusState<SourcePanelFocusTarget?>.Binding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                leadingIndicator
                    .frame(width: 24, height: 24)

                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isFocused ? Color.black : Color.white.opacity(state == .failed ? 0.65 : 0.94))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 10)

                trailingStatus
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .frame(height: sourcePanelRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(rowBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        state == .playing && !isFocused ? Color.cyan.opacity(0.55) : Color.clear,
                        lineWidth: 1.2
                    )
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .shadow(color: isFocused ? Color.black.opacity(0.28) : .clear, radius: 12, y: 4)
            .animation(.easeOut(duration: 0.14), value: isFocused)
        }
        .buttonStyle(CleanButtonStyle())
        .prefersDefaultFocus(isInitiallyFocused, in: focusScope)
        .focused(focusedTarget, equals: focusTarget)
    }

    private var rowBackgroundColor: Color {
        if isFocused {
            return Color.white
        }
        if state == .playing {
            return Color.cyan.opacity(0.14)
        }
        return Color.white.opacity(0.06)
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        switch state {
        case .idle:
            Image(systemName: "play.circle")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(isFocused ? Color.black.opacity(0.75) : Color.white.opacity(0.48))
        case .playing:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(isFocused ? Color.black : Color.cyan)
        case .loading:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(isFocused ? .black : .white)
                .scaleEffect(0.85)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(isFocused ? Color.red : Color.orange)
        }
    }

    @ViewBuilder
    private var trailingStatus: some View {
        switch state {
        case .loading:
            Text("解析中…")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isFocused ? Color.black.opacity(0.7) : Color.white.opacity(0.72))
        case .playing:
            Text("播放中")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isFocused ? Color.black.opacity(0.8) : Color.cyan)
        case .failed:
            Text(isFocused ? "点击重试" : "不可用")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isFocused ? Color.red : Color.orange.opacity(0.9))
        case .idle:
            if isFocused {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.75))
            }
        }
    }
}
