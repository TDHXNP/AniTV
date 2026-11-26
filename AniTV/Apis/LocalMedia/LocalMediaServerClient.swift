//
//  LocalMediaServerClient.swift
//  AniTV
//
//  Created by Codex on 2026/11/25.
//

import Foundation

struct LocalMatchedVideo: Sendable, Equatable {
    let displayName: String
    let streamURL: URL
    let headers: [String: String]
}

enum LocalMediaServerError: LocalizedError {
    case invalidURL
    case authenticationFailed
    case serverError(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "服务器地址格式无效"
        case .authenticationFailed: return "认证失败，请检查账号密码或 API Key"
        case .serverError(let code): return "服务器返回错误（HTTP \(code)）"
        case .emptyResponse: return "服务器未返回有效数据"
        }
    }
}

actor LocalMediaServerClient {
    static let shared = LocalMediaServerClient()

    private static let supportedVideoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "m3u8", "mkv", "ts", "webm"
    ]

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    // MARK: - Connection Test

    func testConnection(source: LocalMediaSourceConfig) async -> Result<String, Error> {
        switch source.kind {
        case .webdav:
            do {
                let items = try await listWebDAVDirectory(urlString: source.baseURL, source: source)
                return .success("连接成功，发现 \(items.count) 个目录/文件")
            } catch {
                return .failure(error)
            }
        case .emby, .jellyfin:
            do {
                let serverName = try await pingEmbyLikeServer(source: source)
                return .success("连接成功：\(serverName)")
            } catch {
                return .failure(error)
            }
        }
    }

    // MARK: - Episode Search

    func searchEpisode(
        source: LocalMediaSourceConfig,
        subjectTitles: [String],
        episodeNumber: Int
    ) async -> [LocalMatchedVideo] {
        let cleanedTitles = subjectTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanedTitles.isEmpty, episodeNumber > 0 else { return [] }

        switch source.kind {
        case .webdav:
            return await searchWebDAVEpisode(source: source, subjectTitles: cleanedTitles, episodeNumber: episodeNumber)
        case .emby, .jellyfin:
            return await searchEmbyLikeEpisode(source: source, subjectTitles: cleanedTitles, episodeNumber: episodeNumber)
        }
    }

    // MARK: - WebDAV

    fileprivate struct WebDAVEntry: Sendable {
        let href: String
        let displayName: String
        let isDirectory: Bool
    }

    private func webDAVAuthHeaders(for source: LocalMediaSourceConfig) -> [String: String] {
        guard !source.username.isEmpty || !source.password.isEmpty else { return [:] }
        let raw = "\(source.username):\(source.password)"
        let encoded = Data(raw.utf8).base64EncodedString()
        return ["Authorization": "Basic \(encoded)"]
    }

    private func listWebDAVDirectory(urlString: String, source: LocalMediaSourceConfig) async throws -> [WebDAVEntry] {
        guard let url = URL(string: urlString) else {
            throw LocalMediaServerError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (key, value) in webDAVAuthHeaders(for: source) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8" ?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:displayname/>
            <D:resourcetype/>
          </D:prop>
        </D:propfind>
        """.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalMediaServerError.emptyResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw LocalMediaServerError.authenticationFailed
        }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 207 else {
            throw LocalMediaServerError.serverError(http.statusCode)
        }

        let parser = WebDAVPropfindXMLParser()
        let parsed = parser.parse(data: data)

        let requestedPath = normalizedWebDAVPath(url.path)
        return parsed.filter { entry in
            guard let resolved = resolvedWebDAVURL(href: entry.href, relativeTo: url) else {
                return false
            }
            return normalizedWebDAVPath(resolved.path) != requestedPath
        }
    }

    private func searchWebDAVEpisode(
        source: LocalMediaSourceConfig,
        subjectTitles: [String],
        episodeNumber: Int
    ) async -> [LocalMatchedVideo] {
        guard let baseURL = URL(string: source.baseURL) else { return [] }
        let headers = webDAVAuthHeaders(for: source)

        do {
            let rootEntries = try await listWebDAVDirectory(urlString: source.baseURL, source: source)
            var matchedVideos: [LocalMatchedVideo] = []

            // 1. Check direct video files in root matching both title and episode
            for entry in rootEntries where !entry.isDirectory {
                guard isSupportedVideoFile(entry.displayName),
                      Self.matchesSubjectTitle(entry.displayName, candidates: subjectTitles),
                      Self.matchesEpisodeNumber(entry.displayName, episodeNumber: episodeNumber),
                      let fileURL = resolvedWebDAVURL(href: entry.href, relativeTo: baseURL) else {
                    continue
                }
                matchedVideos.append(LocalMatchedVideo(
                    displayName: entry.displayName,
                    streamURL: fileURL,
                    headers: headers
                ))
            }

            // 2. Match directories corresponding to the anime title
            let matchingDirs = rootEntries
                .filter { $0.isDirectory && Self.matchesSubjectTitle($0.displayName, candidates: subjectTitles) }
                .prefix(3)

            for dir in matchingDirs {
                guard let dirURL = resolvedWebDAVURL(href: dir.href, relativeTo: baseURL) else { continue }
                let childEntries = (try? await listWebDAVDirectory(urlString: dirURL.absoluteString, source: source)) ?? []

                for child in childEntries where !child.isDirectory {
                    guard isSupportedVideoFile(child.displayName),
                          Self.matchesEpisodeNumber(child.displayName, episodeNumber: episodeNumber),
                          let fileURL = resolvedWebDAVURL(href: child.href, relativeTo: dirURL) else {
                        continue
                    }
                    matchedVideos.append(LocalMatchedVideo(
                        displayName: child.displayName,
                        streamURL: fileURL,
                        headers: headers
                    ))
                }

                // Traverse one nested Season level if no match in top folder
                if matchedVideos.isEmpty {
                    for subDir in childEntries.filter(\.isDirectory).prefix(3) {
                        guard let subURL = resolvedWebDAVURL(href: subDir.href, relativeTo: dirURL) else { continue }
                        let nested = (try? await listWebDAVDirectory(urlString: subURL.absoluteString, source: source)) ?? []
                        for file in nested where !file.isDirectory {
                            guard isSupportedVideoFile(file.displayName),
                                  Self.matchesEpisodeNumber(file.displayName, episodeNumber: episodeNumber),
                                  let fileURL = resolvedWebDAVURL(href: file.href, relativeTo: subURL) else {
                                continue
                            }
                            matchedVideos.append(LocalMatchedVideo(
                                displayName: file.displayName,
                                streamURL: fileURL,
                                headers: headers
                            ))
                        }
                    }
                }
            }

            return matchedVideos
        } catch {
            print("[LocalMediaServer] WebDAV search failed for \(source.name): \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Emby / Jellyfin

    private func embyBaseURL(from raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func embyHeaders(for source: LocalMediaSourceConfig) -> [String: String] {
        let token = source.apiKey.isEmpty ? source.password : source.apiKey
        var headers = ["Accept": "application/json"]
        if !token.isEmpty {
            headers["X-Emby-Token"] = token
        }
        return headers
    }

    private func pingEmbyLikeServer(source: LocalMediaSourceConfig) async throws -> String {
        let base = embyBaseURL(from: source.baseURL)
        guard let url = URL(string: "\(base)/System/Info") else {
            throw LocalMediaServerError.invalidURL
        }
        var request = URLRequest(url: url)
        for (k, v) in embyHeaders(for: source) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalMediaServerError.emptyResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw LocalMediaServerError.authenticationFailed
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalMediaServerError.serverError(http.statusCode)
        }

        struct SystemInfo: Decodable {
            let ServerName: String?
            let Version: String?
        }
        if let info = try? JSONDecoder().decode(SystemInfo.self, from: data) {
            return [info.ServerName, info.Version].compactMap { $0 }.joined(separator: " ")
        }
        return source.kind.displayName
    }

    private func searchEmbyLikeEpisode(
        source: LocalMediaSourceConfig,
        subjectTitles: [String],
        episodeNumber: Int
    ) async -> [LocalMatchedVideo] {
        let base = embyBaseURL(from: source.baseURL)
        let token = source.apiKey.isEmpty ? source.password : source.apiKey
        let headers = embyHeaders(for: source)

        struct ItemsResponse: Decodable {
            struct Item: Decodable {
                let Id: String
                let Name: String
                let IndexNumber: Int?
                let SeriesName: String?
            }
            let Items: [Item]
        }

        for title in subjectTitles {
            guard var components = URLComponents(string: "\(base)/Items") else { continue }
            components.queryItems = [
                URLQueryItem(name: "SearchTerm", value: title),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Series"),
                URLQueryItem(name: "Limit", value: "5")
            ]
            guard let searchURL = components.url else { continue }

            var searchReq = URLRequest(url: searchURL)
            for (k, v) in headers { searchReq.setValue(v, forHTTPHeaderField: k) }

            guard let (data, response) = try? await session.data(for: searchReq),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let seriesRes = try? JSONDecoder().decode(ItemsResponse.self, from: data),
                  let series = seriesRes.Items.first else {
                continue
            }

            guard var epComponents = URLComponents(string: "\(base)/Shows/\(series.Id)/Episodes") else { continue }
            epComponents.queryItems = [URLQueryItem(name: "Fields", value: "Path,MediaSources")]
            guard let epURL = epComponents.url else { continue }

            var epReq = URLRequest(url: epURL)
            for (k, v) in headers { epReq.setValue(v, forHTTPHeaderField: k) }

            guard let (epData, epResp) = try? await session.data(for: epReq),
                  let epHTTP = epResp as? HTTPURLResponse, (200..<300).contains(epHTTP.statusCode),
                  let episodesRes = try? JSONDecoder().decode(ItemsResponse.self, from: epData) else {
                continue
            }

            let matchingEpisodes = episodesRes.Items.filter { item in
                item.IndexNumber == episodeNumber || Self.matchesEpisodeNumber(item.Name, episodeNumber: episodeNumber)
            }
            if !matchingEpisodes.isEmpty {
                return matchingEpisodes.compactMap { ep in
                    var streamComponents = URLComponents(string: "\(base)/Videos/\(ep.Id)/stream")
                    var queryItems = [URLQueryItem(name: "static", value: "true")]
                    if !token.isEmpty {
                        queryItems.append(URLQueryItem(name: "api_key", value: token))
                    }
                    streamComponents?.queryItems = queryItems
                    guard let streamURL = streamComponents?.url else { return nil }
                    return LocalMatchedVideo(
                        displayName: "\(source.kind.displayName) · \(ep.Name)",
                        streamURL: streamURL,
                        headers: headers
                    )
                }
            }
        }
        return []
    }

    // MARK: - Filename & Title Matching Helpers

    nonisolated static func matchesSubjectTitle(_ candidate: String, candidates: [String]) -> Bool {
        let normalizedCandidate = MediaListFilters.removeSpecials(
            candidate,
            removeWhitespace: true,
            replaceNumbers: true
        ).lowercased()
        guard !normalizedCandidate.isEmpty else { return false }

        for title in candidates {
            let normalizedTitle = MediaListFilters.removeSpecials(
                title,
                removeWhitespace: true,
                replaceNumbers: true
            ).lowercased()
            guard !normalizedTitle.isEmpty else { continue }
            if normalizedCandidate.contains(normalizedTitle) || normalizedTitle.contains(normalizedCandidate) {
                return true
            }
            if StringMatcher.calculateMatchRate(normalizedCandidate, normalizedTitle) >= 75 {
                return true
            }
        }
        return false
    }

    nonisolated static func matchesEpisodeNumber(_ fileName: String, episodeNumber: Int) -> Bool {
        let patterns = [
            "(?i)(?:s\\d{1,2})?e0*\(episodeNumber)(?:\\b|[^0-9])",
            "(?i)ep\\.?\\s*0*\(episodeNumber)(?:\\b|[^0-9])",
            "第\\s*0*\(episodeNumber)\\s*[话話集回]",
            "[\\[\\(【\\s._-]0*\(episodeNumber)[\\]\\)】\\s._-]"
        ]
        for pattern in patterns {
            if fileName.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    private func isSupportedVideoFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return Self.supportedVideoExtensions.contains(ext)
    }

    private func resolvedWebDAVURL(href: String, relativeTo baseURL: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        if let relative = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
            return relative
        }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            return URL(string: encoded, relativeTo: baseURL)?.absoluteURL
        }
        return nil
    }

    private func normalizedWebDAVPath(_ path: String) -> String {
        let decoded = path.removingPercentEncoding ?? path
        return decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

// MARK: - Lightweight WebDAV XML Parser

private final class WebDAVPropfindXMLParser: NSObject, XMLParserDelegate {
    private var entries: [LocalMediaServerClient.WebDAVEntry] = []
    private var inResponse = false
    private var currentHref = ""
    private var currentDisplayName = ""
    private var isDirectory = false
    private var currentElement = ""
    private var textBuffer = ""

    func parse(data: Data) -> [LocalMediaServerClient.WebDAVEntry] {
        entries = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return entries
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        currentElement = localName
        textBuffer = ""

        if localName == "response" {
            inResponse = true
            currentHref = ""
            currentDisplayName = ""
            isDirectory = false
        } else if inResponse && localName == "collection" {
            isDirectory = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inResponse {
            textBuffer += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        if inResponse {
            switch localName {
            case "href":
                currentHref = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            case "displayname":
                currentDisplayName = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            case "response":
                inResponse = false
                guard !currentHref.isEmpty else { return }
                let fallbackName = URL(string: currentHref)?.lastPathComponent.removingPercentEncoding
                    ?? (currentHref as NSString).lastPathComponent.removingPercentEncoding
                    ?? currentHref
                let finalName = currentDisplayName.isEmpty ? fallbackName : currentDisplayName
                entries.append(
                    LocalMediaServerClient.WebDAVEntry(
                        href: currentHref,
                        displayName: finalName,
                        isDirectory: isDirectory || currentHref.hasSuffix("/")
                    )
                )
            default:
                break
            }
        }
        textBuffer = ""
    }
}
