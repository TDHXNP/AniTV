//
//  DanDanPlayDanmuProvider.swift
//  AniTV
//
//  Danmaku provider backed by huangxd-/danmu_api (DanDanPlay v2 compatible).
//

import Foundation
import Combine
import UIKit

struct ParsedDanDanPlayDanmu: Equatable {
    let time: TimeInterval
    let mode: Int
    let color: UInt32
    let userId: String
    let text: String
}

class DanDanPlayDanmuProvider: DanmuProviderProtocol {
    let onSendTextModel = PassthroughSubject<DanmakuTextCellModel, Never>()
    private var allDanmus = [ParsedDanDanPlayDanmu]()

    private var lastTime: TimeInterval = 0
    private var danmuIdx: Int = 0

    var onCompletion: ((_ success: Bool) -> Void)?

    init(episodeId: Int, airDateString: String? = nil, onCompletion: ((_ success: Bool) -> Void)? = nil) {
        self.onCompletion = onCompletion
        Task {
            await fetchComments(episodeId: episodeId, airDateString: airDateString)
        }
    }

    /// Parses DanDanPlay / `huangxd-/danmu_api` `p` attribute strings:
    /// - 3 fields: `time,mode,color`
    /// - 4 fields (DanDanPlay standard): `time,mode,color,userId`
    /// - 8 fields (Bilibili standard): `time,mode,fontSize,color,timestamp,pool,userHash,rowId`
    static func parseComment(_ comment: DanDanPlayComment) -> ParsedDanDanPlayDanmu? {
        let text = comment.m.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return nil }

        let parts = comment.p.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count >= 3,
              let time = TimeInterval(parts[0]),
              let mode = Int(parts[1]) else {
            return nil
        }

        let color: UInt32
        let userId: String

        if parts.count >= 8,
           let maybeFontSize = Int(parts[2]),
           (10...64).contains(maybeFontSize),
           let biliColor = UInt32(parts[3]) {
            color = biliColor
            userId = parts[6]
        } else if let standardColor = UInt32(parts[2]) {
            color = standardColor
            userId = parts.count > 3 ? parts[3] : ""
        } else {
            color = 0xFFFFFF
            userId = parts.count > 3 ? parts[3] : ""
        }

        return ParsedDanDanPlayDanmu(time: time, mode: mode, color: color, userId: userId, text: text)
    }

    private func fetchComments(episodeId: Int, airDateString: String?) async {
        do {
            let comments = try await DanDanPlayAPI.shared.getComments(episodeId: episodeId, airDateString: airDateString)
            let parsed = comments.compactMap(Self.parseComment)

            self.allDanmus = parsed.sorted(by: { $0.time < $1.time })
            self.danmuIdx = 0
            self.lastTime = 0
            print("[DanmuAPI] Loaded \(self.allDanmus.count) danmus for episode \(episodeId)")
            onCompletion?(true)
        } catch {
            print("[DanmuAPI] Failed to fetch comments for episode \(episodeId): \(error)")
            onCompletion?(false)
        }
    }

    func playerTimeChange(time: TimeInterval) {
        let diff = time - lastTime

        // If seek happened, reset the index
        if diff > 5 || diff < 0 {
            danmuIdx = allDanmus.firstIndex(where: { $0.time > time }) ?? allDanmus.count
        }

        lastTime = time

        while danmuIdx < allDanmus.count {
            let dm = allDanmus[danmuIdx]
            guard dm.time < time else { break }
            danmuIdx += 1

            let model = DanmakuTextCellModel(str: dm.text)

            let r = CGFloat((dm.color >> 16) & 0xFF) / 255.0
            let g = CGFloat((dm.color >> 8) & 0xFF) / 255.0
            let b = CGFloat(dm.color & 0xFF) / 255.0
            model.color = UIColor(red: r, green: g, blue: b, alpha: 1.0)

            switch dm.mode {
            case 4:
                model.type = .bottom
            case 5:
                model.type = .top
            default:
                model.type = .floating
            }

            onSendTextModel.send(model)
        }
    }
}
