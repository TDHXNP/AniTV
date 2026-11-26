//
//  DanDanPlayModels.swift
//  AniTV
//
//  Compatible with open-source huangxd-/danmu_api (DanDanPlay v2 API specification).
//

import Foundation

// MARK: - Lossy Primitive Decoding Helpers

private enum LossyDecoders {
    nonisolated static func decodeInt<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> Int? {
        if let intValue = try? container.decode(Int.self, forKey: key) {
            return intValue
        }
        if let strValue = try? container.decode(String.self, forKey: key),
           let intValue = Int(strValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return intValue
        }
        if let doubleValue = try? container.decode(Double.self, forKey: key) {
            return Int(doubleValue)
        }
        return nil
    }

    nonisolated static func decodeString<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> String? {
        if let strValue = try? container.decode(String.self, forKey: key) {
            return strValue
        }
        if let intValue = try? container.decode(Int.self, forKey: key) {
            return String(intValue)
        }
        if let doubleValue = try? container.decode(Double.self, forKey: key) {
            if abs(doubleValue.rounded() - doubleValue) < 0.0001 {
                return String(Int(doubleValue.rounded()))
            }
            return String(doubleValue)
        }
        return nil
    }
}

// MARK: - Bangumi & Episode Models

nonisolated struct DanDanPlayBangumiDetailsResponse: Codable, Sendable {
    let errorCode: Int?
    let success: Bool?
    let errorMessage: String?
    let bangumi: DanDanPlayBangumi?
}

nonisolated struct DanDanPlayBangumi: Codable, Sendable {
    let bangumiId: String?
    let animeId: Int?
    let animeTitle: String
    let episodes: [DanDanPlayEpisode]

    enum CodingKeys: String, CodingKey {
        case bangumiId
        case animeId
        case animeTitle
        case episodes
    }

    init(
        bangumiId: String? = nil,
        animeId: Int? = nil,
        animeTitle: String,
        episodes: [DanDanPlayEpisode]
    ) {
        self.bangumiId = bangumiId
        self.animeId = animeId
        self.animeTitle = animeTitle
        self.episodes = episodes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bangumiId = LossyDecoders.decodeString(from: container, forKey: .bangumiId)
        self.animeId = LossyDecoders.decodeInt(from: container, forKey: .animeId)
        self.animeTitle = (try? container.decode(String.self, forKey: .animeTitle)) ?? ""
        self.episodes = (try? container.decode([DanDanPlayEpisode].self, forKey: .episodes)) ?? []
    }
}

nonisolated struct DanDanPlayEpisode: Codable, Sendable {
    let episodeId: Int
    let episodeTitle: String
    let episodeNumber: String?
    let airDate: String?

    enum CodingKeys: String, CodingKey {
        case episodeId
        case episodeTitle
        case episodeNumber
        case airDate
    }

    init(
        episodeId: Int,
        episodeTitle: String,
        episodeNumber: String? = nil,
        airDate: String? = nil
    ) {
        self.episodeId = episodeId
        self.episodeTitle = episodeTitle
        self.episodeNumber = episodeNumber
        self.airDate = airDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let episodeId = LossyDecoders.decodeInt(from: container, forKey: .episodeId) else {
            throw DecodingError.keyNotFound(
                CodingKeys.episodeId,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing episodeId")
            )
        }
        self.episodeId = episodeId
        self.episodeTitle = (try? container.decode(String.self, forKey: .episodeTitle)) ?? ""
        self.episodeNumber = LossyDecoders.decodeString(from: container, forKey: .episodeNumber)
        self.airDate = try? container.decodeIfPresent(String.self, forKey: .airDate)
    }
}

// MARK: - Search & Match Models (huangxd-/danmu_api)

nonisolated struct DanmuAPISearchAnimeItem: Codable, Sendable {
    let animeId: Int
    let animeTitle: String
    let aliases: [String]
    let type: String?
    let typeDescription: String?
    let startDate: String?
    let episodeCount: Int?
    let source: String?
    let episodes: [DanDanPlayEpisode]

    enum CodingKeys: String, CodingKey {
        case animeId
        case animeTitle
        case aliases
        case type
        case typeDescription
        case startDate
        case episodeCount
        case source
        case episodes
    }

    init(
        animeId: Int,
        animeTitle: String,
        aliases: [String] = [],
        type: String? = nil,
        typeDescription: String? = nil,
        startDate: String? = nil,
        episodeCount: Int? = nil,
        source: String? = nil,
        episodes: [DanDanPlayEpisode] = []
    ) {
        self.animeId = animeId
        self.animeTitle = animeTitle
        self.aliases = aliases
        self.type = type
        self.typeDescription = typeDescription
        self.startDate = startDate
        self.episodeCount = episodeCount
        self.source = source
        self.episodes = episodes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.animeId = LossyDecoders.decodeInt(from: container, forKey: .animeId) ?? 0
        self.animeTitle = (try? container.decode(String.self, forKey: .animeTitle)) ?? ""
        self.aliases = (try? container.decode([String].self, forKey: .aliases)) ?? []
        self.type = try? container.decodeIfPresent(String.self, forKey: .type)
        self.typeDescription = try? container.decodeIfPresent(String.self, forKey: .typeDescription)
        self.startDate = try? container.decodeIfPresent(String.self, forKey: .startDate)
        self.episodeCount = LossyDecoders.decodeInt(from: container, forKey: .episodeCount)
        self.source = try? container.decodeIfPresent(String.self, forKey: .source)
        self.episodes = (try? container.decode([DanDanPlayEpisode].self, forKey: .episodes)) ?? []
    }
}

nonisolated struct DanmuAPISearchResponse: Codable, Sendable {
    let hasMore: Bool?
    let errorCode: Int?
    let success: Bool?
    let errorMessage: String?
    let animes: [DanmuAPISearchAnimeItem]

    enum CodingKeys: String, CodingKey {
        case hasMore
        case errorCode
        case success
        case errorMessage
        case animes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hasMore = try? container.decodeIfPresent(Bool.self, forKey: .hasMore)
        self.errorCode = try? container.decodeIfPresent(Int.self, forKey: .errorCode)
        self.success = try? container.decodeIfPresent(Bool.self, forKey: .success)
        self.errorMessage = try? container.decodeIfPresent(String.self, forKey: .errorMessage)
        self.animes = (try? container.decode([DanmuAPISearchAnimeItem].self, forKey: .animes)) ?? []
    }
}

nonisolated struct DanmuAPIMatchItem: Codable, Sendable {
    let episodeId: Int
    let animeId: Int?
    let animeTitle: String?
    let episodeTitle: String?

    enum CodingKeys: String, CodingKey {
        case episodeId
        case animeId
        case animeTitle
        case episodeTitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let episodeId = LossyDecoders.decodeInt(from: container, forKey: .episodeId) else {
            throw DecodingError.keyNotFound(
                CodingKeys.episodeId,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing episodeId")
            )
        }
        self.episodeId = episodeId
        self.animeId = LossyDecoders.decodeInt(from: container, forKey: .animeId)
        self.animeTitle = try? container.decodeIfPresent(String.self, forKey: .animeTitle)
        self.episodeTitle = try? container.decodeIfPresent(String.self, forKey: .episodeTitle)
    }
}

nonisolated struct DanmuAPIMatchResponse: Codable, Sendable {
    let isMatched: Bool?
    let errorCode: Int?
    let success: Bool?
    let errorMessage: String?
    let matches: [DanmuAPIMatchItem]

    enum CodingKeys: String, CodingKey {
        case isMatched
        case errorCode
        case success
        case errorMessage
        case matches
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isMatched = try? container.decodeIfPresent(Bool.self, forKey: .isMatched)
        self.errorCode = try? container.decodeIfPresent(Int.self, forKey: .errorCode)
        self.success = try? container.decodeIfPresent(Bool.self, forKey: .success)
        self.errorMessage = try? container.decodeIfPresent(String.self, forKey: .errorMessage)
        self.matches = (try? container.decode([DanmuAPIMatchItem].self, forKey: .matches)) ?? []
    }
}

// MARK: - Comment Models

nonisolated struct DanDanPlayCommentResponse: Codable, Sendable {
    let count: Int?
    let comments: [DanDanPlayComment]

    enum CodingKeys: String, CodingKey {
        case count
        case comments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.count = LossyDecoders.decodeInt(from: container, forKey: .count)
        self.comments = (try? container.decode([DanDanPlayComment].self, forKey: .comments)) ?? []
    }
}

nonisolated struct DanDanPlayComment: Codable, Sendable {
    let cid: Int
    let p: String
    let m: String

    enum CodingKeys: String, CodingKey {
        case cid
        case p
        case m
    }

    init(cid: Int = 0, p: String, m: String) {
        self.cid = cid
        self.p = p
        self.m = m
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cid = LossyDecoders.decodeInt(from: container, forKey: .cid) ?? 0
        self.p = (try? container.decode(String.self, forKey: .p)) ?? ""
        self.m = (try? container.decode(String.self, forKey: .m)) ?? ""
    }
}
