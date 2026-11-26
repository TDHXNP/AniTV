//
//  TopShelfSharedStore.swift
//  AniTV
//
//  Shared between the main AniTV app and the AniTVTopShelf extension.
//

import Foundation
import ImageIO
import TVServices
import UniformTypeIdentifiers

nonisolated struct TopShelfEntry: Codable, Equatable, Sendable {
    let subjectID: Int
    let title: String
    let posterURL: String?
    let epStatus: Int
    let totalEpisodes: Int
    let playbackProgress: Double

    init(
        subjectID: Int,
        title: String,
        posterURL: String?,
        epStatus: Int = 0,
        totalEpisodes: Int = 0,
        playbackProgress: Double = 0
    ) {
        self.subjectID = subjectID
        self.title = title
        self.posterURL = TopShelfSharedStore.normalizedHTTPSString(posterURL)
        self.epStatus = epStatus
        self.totalEpisodes = totalEpisodes
        self.playbackProgress = playbackProgress
    }

    var continueWatchingDisplayTitle: String {
        if epStatus > 0 {
            return "\(title) · 第 \(epStatus) 集"
        }
        return title
    }

    var effectivePlaybackProgress: Double {
        if playbackProgress > 0 {
            return min(max(playbackProgress, 0.02), 1.0)
        }
        if totalEpisodes > 0, epStatus > 0 {
            return min(max(Double(epStatus) / Double(totalEpisodes), 0.05), 0.99)
        }
        if epStatus > 0 {
            return 0.25
        }
        return 0
    }

    var resolvedPosterURL: URL? {
        guard let normalized = TopShelfSharedStore.normalizedHTTPSString(posterURL) else {
            return nil
        }
        return URL(string: normalized)
    }
}

nonisolated struct TopShelfSnapshot: Codable, Equatable, Sendable {
    let updatedAt: Date
    let continueWatching: [TopShelfEntry]
    let recommended: [TopShelfEntry]

    init(
        updatedAt: Date = Date(),
        continueWatching: [TopShelfEntry],
        recommended: [TopShelfEntry]
    ) {
        self.updatedAt = updatedAt
        self.continueWatching = continueWatching
        self.recommended = recommended
    }
}

nonisolated enum TopShelfSharedStore {
    static let defaultAppGroupID = "group.xyz.moyuwang.AniTV"
    static let bangumiUserAgent = "moyuwang/AniTV/0.2.1 (tvOS) (https://github.com/moyuwangP/AniTV)"
    private static let snapshotFileName = "top-shelf-snapshot.json"
    private static let postersFolderName = "TopShelfPosters"
    private static let defaultsSnapshotKey = "anitv.topShelf.snapshot.v1"

    static func normalizedHTTPSString(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("http://") {
            return "https://" + trimmed.dropFirst("http://".count)
        }
        return trimmed
    }

    /// Discovers provisioned App Group identifiers in priority order:
    /// 1. Actual `com.apple.security.application-groups` from `embedded.mobileprovision`
    /// 2. `group.<parentAppBundleID>` derived from the running bundle
    /// 3. Default `group.xyz.moyuwang.AniTV`
    static var candidateAppGroupIDs: [String] {
        var ids: [String] = []

        for provisionedID in provisionedAppGroupIDs() where !ids.contains(provisionedID) {
            ids.append(provisionedID)
        }

        if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            let baseID: String
            if Bundle.main.bundlePath.hasSuffix(".appex") {
                let parts = bundleID.split(separator: ".")
                baseID = parts.count > 1 ? parts.dropLast().joined(separator: ".") : bundleID
            } else if bundleID.hasSuffix(".TopShelf") {
                baseID = String(bundleID.dropLast(".TopShelf".count))
            } else {
                baseID = bundleID
            }
            let derived = "group.\(baseID)"
            if !ids.contains(derived) {
                ids.append(derived)
            }
        }

        if !ids.contains(defaultAppGroupID) {
            ids.append(defaultAppGroupID)
        }
        return ids
    }

    static func detailURL(subjectID: Int) -> URL {
        URL(string: "anitv://anime/\(subjectID)")!
    }

    static func playURL(subjectID: Int) -> URL {
        URL(string: "anitv://play/\(subjectID)")!
    }

    static func sharedPostersDirectories() -> [URL] {
        candidateAppGroupIDs.compactMap { groupID in
            FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
                .appendingPathComponent(postersFolderName, isDirectory: true)
        }
    }

    static func localCachesPostersDirectory() -> URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(postersFolderName, isDirectory: true)
    }

    static func loadSnapshot() -> TopShelfSnapshot? {
        let decoder = JSONDecoder()

        for groupID in candidateAppGroupIDs {
            if let fileURL = snapshotFileURL(for: groupID),
               let data = try? Data(contentsOf: fileURL),
               let snapshot = try? decoder.decode(TopShelfSnapshot.self, from: data) {
                return snapshot
            }

            if let defaults = UserDefaults(suiteName: groupID),
               let data = defaults.data(forKey: defaultsSnapshotKey),
               let snapshot = try? decoder.decode(TopShelfSnapshot.self, from: data) {
                return snapshot
            }
        }

        if let data = UserDefaults.standard.data(forKey: defaultsSnapshotKey),
           let snapshot = try? decoder.decode(TopShelfSnapshot.self, from: data) {
            return snapshot
        }

        return nil
    }

    static func saveSnapshot(
        continueWatching: [TopShelfEntry]? = nil,
        recommended: [TopShelfEntry]? = nil
    ) {
        let existing = loadSnapshot()
        let nextContinueWatching = Array((continueWatching ?? existing?.continueWatching ?? []).prefix(12))
        let nextRecommended = Array((recommended ?? existing?.recommended ?? []).prefix(12))

        let hasChanged = existing == nil
            || existing?.continueWatching != nextContinueWatching
            || existing?.recommended != nextRecommended

        if hasChanged {
            let snapshot = TopShelfSnapshot(
                updatedAt: Date(),
                continueWatching: nextContinueWatching,
                recommended: nextRecommended
            )

            if let data = try? JSONEncoder().encode(snapshot) {
                for groupID in candidateAppGroupIDs {
                    if let fileURL = snapshotFileURL(for: groupID) {
                        try? data.write(to: fileURL, options: [.atomic])
                    }
                    if let defaults = UserDefaults(suiteName: groupID) {
                        defaults.set(data, forKey: defaultsSnapshotKey)
                    }
                }
                UserDefaults.standard.set(data, forKey: defaultsSnapshotKey)
            }
            TVTopShelfContentProvider.topShelfContentDidChange()
        }

        // Pre-download poster JPEGs into the shared App Group directory so the
        // Top Shelf extension can serve local file:// images instantaneously.
        let allEntries = nextContinueWatching + nextRecommended
        if !allEntries.isEmpty {
            Task.detached(priority: .utility) {
                let didWriteNewFiles = await TopShelfPosterCache.prefetchIntoSharedContainers(entries: allEntries)
                if didWriteNewFiles {
                    TVTopShelfContentProvider.topShelfContentDidChange()
                }
            }
        }
    }

    private static func snapshotFileURL(for groupID: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(snapshotFileName)
    }

    private static func provisionedAppGroupIDs() -> [String] {
        guard let provisionURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let rawData = try? Data(contentsOf: provisionURL),
              let rawString = String(data: rawData, encoding: .isoLatin1),
              let plistStart = rawString.range(of: "<plist"),
              let plistEnd = rawString.range(of: "</plist>") else {
            return []
        }

        let xmlSlice = String(rawString[plistStart.lowerBound..<plistEnd.upperBound])
        guard let xmlData = xmlSlice.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: xmlData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else {
            return []
        }

        return groups.filter { !$0.isEmpty }
    }
}

nonisolated enum TopShelfPosterCache {
    static func posterFilename(for subjectID: Int) -> String {
        "poster-\(subjectID).jpg"
    }

    /// Downloads missing posters into shared App Group container directories (called from main app).
    static func prefetchIntoSharedContainers(entries: [TopShelfEntry]) async -> Bool {
        let sharedDirs = TopShelfSharedStore.sharedPostersDirectories()
        guard !sharedDirs.isEmpty else { return false }

        let fm = FileManager.default
        for dir in sharedDirs {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var uniqueEntries: [TopShelfEntry] = []
        var seen: Set<Int> = []
        for entry in entries where seen.insert(entry.subjectID).inserted {
            uniqueEntries.append(entry)
        }

        var wroteAny = false
        await withTaskGroup(of: Bool.self) { group in
            for entry in uniqueEntries {
                let filename = posterFilename(for: entry.subjectID)
                let primaryTarget = sharedDirs[0].appendingPathComponent(filename)
                if isValidCachedImage(at: primaryTarget) {
                    continue
                }
                guard let remoteURL = entry.resolvedPosterURL else { continue }

                group.addTask {
                    guard let jpegData = await downloadNormalizedJPEG(from: remoteURL, timeout: 10.0) else {
                        return false
                    }
                    var didWrite = false
                    for dir in sharedDirs {
                        let target = dir.appendingPathComponent(filename)
                        if (try? jpegData.write(to: target, options: [.atomic])) != nil {
                            didWrite = true
                        }
                    }
                    return didWrite
                }
            }

            for await result in group {
                if result {
                    wroteAny = true
                }
            }
        }

        return wroteAny
    }

    /// Resolves local `file://` JPEG poster URLs inside the extension's own Caches directory.
    /// Order:
    /// 1. Existing file in extension Caches
    /// 2. Copy from shared App Group container (pre-cached by main app)
    /// 3. Parallel download with Bangumi User-Agent & Referer, normalized to JPEG
    static func resolveLocalPosterURLs(for entries: [TopShelfEntry]) async -> [Int: URL] {
        guard let cachesDir = TopShelfSharedStore.localCachesPostersDirectory() else {
            return [:]
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: cachesDir, withIntermediateDirectories: true)
        let sharedDirs = TopShelfSharedStore.sharedPostersDirectories()

        var uniqueEntries: [TopShelfEntry] = []
        var seen: Set<Int> = []
        for entry in entries where seen.insert(entry.subjectID).inserted {
            uniqueEntries.append(entry)
        }

        var resolved: [Int: URL] = [:]
        var toDownload: [TopShelfEntry] = []

        for entry in uniqueEntries {
            let filename = posterFilename(for: entry.subjectID)
            let localURL = cachesDir.appendingPathComponent(filename)

            if isValidCachedImage(at: localURL) {
                resolved[entry.subjectID] = localURL
                continue
            }

            var copiedFromShared = false
            for sharedDir in sharedDirs {
                let sharedFile = sharedDir.appendingPathComponent(filename)
                if isValidCachedImage(at: sharedFile),
                   let data = try? Data(contentsOf: sharedFile),
                   (try? data.write(to: localURL, options: [.atomic])) != nil {
                    resolved[entry.subjectID] = localURL
                    copiedFromShared = true
                    break
                }
            }

            if !copiedFromShared, entry.resolvedPosterURL != nil {
                toDownload.append(entry)
            }
        }

        if !toDownload.isEmpty {
            await withTaskGroup(of: (Int, URL)?.self) { group in
                for entry in toDownload {
                    guard let remoteURL = entry.resolvedPosterURL else { continue }
                    let localURL = cachesDir.appendingPathComponent(posterFilename(for: entry.subjectID))
                    group.addTask {
                        guard let jpegData = await downloadNormalizedJPEG(from: remoteURL, timeout: 6.0) else {
                            return nil
                        }
                        do {
                            try jpegData.write(to: localURL, options: [.atomic])
                            return (entry.subjectID, localURL)
                        } catch {
                            return nil
                        }
                    }
                }

                for await item in group {
                    if let (subjectID, url) = item {
                        resolved[subjectID] = url
                    }
                }
            }
        }

        return resolved
    }

    private static func isValidCachedImage(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 1024
    }

    private static func downloadNormalizedJPEG(from url: URL, timeout: TimeInterval) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(TopShelfSharedStore.bangumiUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://bgm.tv/", forHTTPHeaderField: "Referer")
        request.setValue("image/jpeg,image/png,image/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  data.count > 1024 else {
                return nil
            }
            return normalizeToPosterJPEG(data: data, maxPixelSize: 800) ?? data
        } catch {
            return nil
        }
    }

    private static func normalizeToPosterJPEG(data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let destOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.86
        ]
        CGImageDestinationAddImage(destination, cgImage, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }
}
