//
//  AniTVCustomDropdownView.swift
//  AniTV
//
//  Created by Feiran Yang on 2026/3/16.
//

import SwiftUI

struct AniTVCustomDropdownView: View {
    let title: String
    let episodes: [BgmEpisodeInfo]
    let currentEpisode: BgmEpisodeInfo
    var onSelectEpisode: ((BgmEpisodeInfo) -> Void)?

    @FocusState private var focusedEpisodeID: Int?

    private var displayEpisodes: [BgmEpisodeInfo] {
        episodes.isEmpty ? [currentEpisode] : episodes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(title)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("当前播放：第 \(formattedNumber(for: currentEpisode)) 集")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.68))

                if let currentTitle = resolvedEpisodeTitle(for: currentEpisode) {
                    Text("· \(currentTitle)")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 22) {
                        ForEach(displayEpisodes, id: \.id) { episode in
                            let isCurrent = episode.id == currentEpisode.id
                            UpNextEpisodeCardButton(
                                episodeNumberText: "第 \(formattedNumber(for: episode)) 集",
                                episodeTitle: resolvedEpisodeTitle(for: episode),
                                durationText: resolvedDurationText(for: episode),
                                isCurrent: isCurrent,
                                isFocused: focusedEpisodeID == episode.id
                            ) {
                                onSelectEpisode?(episode)
                            }
                            .id(episode.id)
                            .focused($focusedEpisodeID, equals: episode.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 10)
                }
                .onAppear {
                    focusedEpisodeID = currentEpisode.id
                    DispatchQueue.main.async {
                        proxy.scrollTo(currentEpisode.id, anchor: .center)
                    }
                }
                .onChange(of: currentEpisode.id) { _, newID in
                    focusedEpisodeID = newID
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formattedNumber(for episode: BgmEpisodeInfo) -> String {
        let value = episode.ep > 0 ? episode.ep : episode.sort
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }

    private func resolvedEpisodeTitle(for episode: BgmEpisodeInfo) -> String? {
        let cn = episode.nameCN.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cn.isEmpty { return cn }
        let raw = episode.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    private func resolvedDurationText(for episode: BgmEpisodeInfo) -> String? {
        let trimmed = episode.duration.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if episode.durationSeconds > 0 {
            let minutes = episode.durationSeconds / 60
            return "\(minutes) 分钟"
        }
        return nil
    }
}

private struct UpNextEpisodeCardButton: View {
    let episodeNumberText: String
    let episodeTitle: String?
    let durationText: String?
    let isCurrent: Bool
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(episodeNumberText)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(isFocused ? Color.black : Color.white)

                    Spacer(minLength: 8)

                    if isCurrent {
                        HStack(spacing: 5) {
                            Image(systemName: "waveform")
                                .font(.caption.weight(.bold))
                            Text("播放中")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(isFocused ? Color.black.opacity(0.8) : Color.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(isFocused ? Color.black.opacity(0.12) : Color.cyan.opacity(0.2))
                        )
                    } else if let durationText {
                        Text(durationText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isFocused ? Color.black.opacity(0.6) : Color.white.opacity(0.5))
                    }
                }

                Text(episodeTitle ?? episodeNumberText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isFocused ? Color.black.opacity(0.82) : Color.white.opacity(0.76))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(width: 284, height: 122, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        isFocused
                            ? Color.white
                            : (isCurrent ? Color.white.opacity(0.2) : Color.white.opacity(0.1))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        isFocused
                            ? Color.clear
                            : (isCurrent ? Color.cyan.opacity(0.65) : Color.white.opacity(0.14)),
                        lineWidth: isCurrent ? 1.5 : 1
                    )
            )
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .shadow(color: isFocused ? Color.black.opacity(0.35) : .clear, radius: 14, y: 6)
            .animation(.easeOut(duration: 0.16), value: isFocused)
        }
        .buttonStyle(CleanButtonStyle())
    }
}
