import Foundation
import MediaLibCore

// LRCLib 歌词搜索响应（原 AppState.swift 的 private struct，随歌词获取搬来）。
private struct LRCLibLyricsSearchResult: Decodable {
    var plainLyrics: String?
    var syncedLyrics: String?
}

// 音乐元数据批量获取 + 缺口补全 + 标签/侧车写回 + 歌词获取从 AppState.swift 拆到本文件，
// 直接缩小那个超大文件（R1-ARCH-001 头号债务）。纯文件搬运，逐字不变。本组不直接动 cached* 派生缓存
// （经 updateMetadataInMemory / rebuildDerivedItemCaches 间接刷新）。放宽到 internal 的主体成员：
// beginBackgroundTask / updateBackgroundTask / finishBackgroundTask / bestTMDBVideoMatch /
// rebuildDerivedItemCaches / updateMetadata；组内有组外调用者的 bestSupplementalVideoUpdate /
// updateMetadataInMemory 去 private，其余 helper 保留 private。
extension AppState {
    func fetchAllMusicMetadata() async {
        guard !isFetchingMusicMetadata else { return }
        // 一键获取只做增量补充：已有完整标签/封面的曲目不再进入匹配队列。
        let tracks = musicTracks
            .filter(metadataFetchEnabled(for:))
            .filter(needsMusicMetadataSupplement)
        guard !tracks.isEmpty else {
            alert = AppAlert(title: "没有需要补充的音乐", message: "当前参与元数据拉取的音乐已具备主要标签和封面。")
            return
        }
        guard settings.musicMetadataProvider != .disabled else {
            alert = AppAlert(title: "音乐数据源未启用", message: "请先在设置中选择 MusicBrainz 或 iTunes Search。")
            return
        }

        let service = MetadataSearchService()
        isFetchingMusicMetadata = true
        musicMetadataFetchProgress = "准备补充 \(tracks.count) 首"
        defer { isFetchingMusicMetadata = false }

        var updatedCount = 0
        var lowConfidence = 0
        for (index, track) in tracks.enumerated() {
            if Task.isCancelled { break }
            musicMetadataFetchProgress = "\(index + 1)/\(tracks.count) \(track.title)"
            let query = [track.artist, track.title]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " ")
            if let results = try? await service.searchMusic(
                query: query.isEmpty ? track.title : query,
                provider: settings.musicMetadataProvider,
                lastfmAPIKey: settings.lastfmAPIKey
            ),
               let best = MetadataMatchScorer.bestMusicMatch(for: track, in: results) {
                // 置信度复核：标题+艺人相似度低于阈值（按用户选择的宽容度档位）则跳过，留待手动复核，不盲取首条。
                if best.confidence >= settings.musicMetadataMatchTolerance.musicThreshold {
                    // 一键获取只补充缺失数据，绝不覆盖已有：先判断各字段是否缺失。
                    let needsArtist = (track.artist?.isEmpty ?? true)
                    let needsAlbum = (track.album?.isEmpty ?? true)
                    let needsYear = (track.year == nil)
                    let needsOverview = (track.overview?.isEmpty ?? true)
                    let needsTrackNumber = (track.trackNumber == nil)
                    let needsCover = (track.posterPath?.isEmpty ?? true)

                    if needsArtist || needsAlbum || needsYear || needsOverview || needsTrackNumber || needsCover {
                        var update: MediaMetadataUpdate
                        if needsCover {
                            // 仅缺封面时才下载封面，避免浪费与覆盖现有封面。
                            update = await service.materializedMetadataUpdate(
                                for: best.result,
                                itemID: track.id,
                                artworkDirectory: directories?.thumbnails,
                                preserveEmbeddedPoster: track.hasEmbeddedArtwork
                            )
                        } else {
                            update = best.result.metadataUpdate
                            update.posterPath = nil
                            update.backdropPath = nil
                        }
                        // 已有字段一律置 nil（DB 端 COALESCE 保留原值），只补缺失项；标题永不覆盖。
                        update.title = nil
                        update.originalTitle = nil
                        if !needsArtist { update.artist = nil }
                        if !needsAlbum { update.album = nil }
                        if !needsYear { update.year = nil }
                        if !needsOverview { update.overview = nil }
                        if !needsTrackNumber { update.trackNumber = nil }
                        do {
                            if source(for: track)?.preferMetadataWriteToSource == true {
                                await writeMusicTagsToSourceIfPossible(update: update, item: track)
                            }
                            try updateMetadata(id: track.id, metadata: update, source: "music-metadata-fetch")
                            updatedCount += 1
                        } catch {
                            showError("音乐信息写入失败", error)
                        }
                    }
                } else {
                    lowConfidence += 1
                }
            }
            if source(for: track)?.preferMetadataWriteToSource == true {
                await fetchLyricsIfPossible(for: track)
            }
        }

        reload()
        musicMetadataFetchProgress = lowConfidence > 0
            ? "完成 \(updatedCount)/\(tracks.count) 首（\(lowConfidence) 首置信度偏低已跳过）"
            : "完成 \(updatedCount)/\(tracks.count) 首"
    }

    private func needsMusicMetadataSupplement(_ track: MediaItem) -> Bool {
        (track.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
            (track.album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
            track.year == nil ||
            track.trackNumber == nil ||
            (track.posterPath?.isEmpty ?? true)
    }

    func supplementMissingMetadataFromHealth() {
        guard !isSupplementingMetadata else { return }
        let videoCandidates = missingMetadataItems
            .filter { $0.type != .music && metadataFetchEnabled(for: $0) }
        let musicCandidates = musicTracks
            .filter(metadataFetchEnabled(for:))
            .filter(needsMusicMetadataSupplement)
        guard !videoCandidates.isEmpty || !musicCandidates.isEmpty else {
            alert = AppAlert(title: "没有可补充项目", message: "当前参与元数据拉取的来源中没有发现需要补充的信息。")
            return
        }

        let taskID = beginBackgroundTask(
            kind: .metadataSupplement,
            title: "一键补充元数据",
            detail: "准备补充 \(videoCandidates.count) 个视频项目、\(musicCandidates.count) 首音乐",
            progress: 0,
            isCancellable: false
        )
        Task { [weak self] in
            await self?.performMetadataSupplement(
                videoCandidates: videoCandidates,
                musicCandidates: musicCandidates,
                taskID: taskID
            )
        }
    }

    private func performMetadataSupplement(
        videoCandidates: [MediaItem],
        musicCandidates: [MediaItem],
        taskID: UUID
    ) async {
        guard !isSupplementingMetadata else { return }
        isSupplementingMetadata = true
        defer { isSupplementingMetadata = false }

        let total = max(videoCandidates.count + musicCandidates.count, 1)
        let service = MetadataSearchService()
        var processed = 0
        var updated = 0
        var skipped = 0
        var errors: [String] = []

        for item in videoCandidates {
            if Task.isCancelled { break }
            updateBackgroundTask(id: taskID, progress: Double(processed) / Double(total), detail: "补充 \(item.title)")
            guard let update = await bestSupplementalVideoUpdate(for: item, service: service) else {
                skipped += 1
                processed += 1
                continue
            }
            do {
                if source(for: item)?.preferMetadataWriteToSource == true {
                    do {
                        try writeVideoMetadataSidecarIfPossible(item: item, update: update)
                    } catch {
                        logger?.log("写入视频元数据 sidecar 失败(\(item.id))：\(error.localizedDescription)", level: .warning)
                    }
                }
                try updateMetadata(id: item.id, metadata: update, source: "metadata-supplement")
                updated += 1
            } catch {
                errors.append(error.localizedDescription)
            }
            processed += 1
        }

        if settings.musicMetadataProvider != .disabled {
            for track in musicCandidates {
                if Task.isCancelled { break }
                updateBackgroundTask(id: taskID, progress: Double(processed) / Double(total), detail: "补充 \(track.title)")
                guard let update = await bestSupplementalMusicUpdate(for: track, service: service) else {
                    skipped += 1
                    processed += 1
                    continue
                }
                do {
                    if source(for: track)?.preferMetadataWriteToSource == true {
                        await writeMusicTagsToSourceIfPossible(update: update, item: track)
                    }
                    try updateMetadata(id: track.id, metadata: update, source: "metadata-supplement")
                    updated += 1
                } catch {
                    errors.append(error.localizedDescription)
                }
                processed += 1
            }
        } else if !musicCandidates.isEmpty {
            skipped += musicCandidates.count
        }

        reload()
        let detail = skipped > 0
            ? "已补充 \(updated) 项，\(skipped) 项因未匹配或数据源未配置跳过"
            : "已补充 \(updated) 项"
        updateBackgroundTask(id: taskID, progress: 1, detail: detail)
        finishBackgroundTask(id: taskID, errors: errors)
        if errors.isEmpty {
            alert = AppAlert(title: "补充完成", message: detail)
        }
    }

    func bestSupplementalVideoUpdate(for item: MediaItem, service: MetadataSearchService) async -> MediaMetadataUpdate? {
        let apiKey = settings.tmdbAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else { return nil }
        let language = settings.tmdbLanguage.isEmpty ? "zh-CN" : settings.tmdbLanguage
        let threshold = settings.metadataMatchTolerance.videoThreshold
        guard let best = await bestTMDBVideoMatch(for: item, service: service, apiKey: apiKey, language: language),
              best.confidence >= threshold else { return nil }
        let result = await service.fetchTMDBDetailResult(for: best.result, apiKey: apiKey, language: language) ?? best.result
        return await supplementalVideoUpdate(from: result, item: item, service: service)
    }

    private func supplementalVideoUpdate(from result: MetadataSearchResult, item: MediaItem, service: MetadataSearchService) async -> MediaMetadataUpdate {
        let needsPoster = item.posterPath?.isEmpty ?? true
        let alreadyMatchedToSameLocalizedResult = item.externalID == result.id && item.metadataProvider == result.provider
        var update = await service.materializedMetadataUpdate(
            for: result,
            itemID: item.id,
            artworkDirectory: needsPoster ? directories?.thumbnails : nil
        )
        if alreadyMatchedToSameLocalizedResult {
            update.title = nil
            update.originalTitle = nil
        }
        if item.year != nil { update.year = nil }
        if item.overview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { update.overview = nil }
        if !needsPoster { update.posterPath = nil }
        if item.backdropPath?.isEmpty == false { update.backdropPath = nil }
        if item.rating != nil { update.rating = nil }
        if item.runtime != nil { update.runtime = nil }
        if item.externalID?.hasPrefix("tmdb:") == true, item.externalID == result.id { update.externalID = nil }
        if item.metadataProvider == result.provider { update.metadataProvider = nil }
        if item.genre?.isEmpty == false { update.genre = nil }
        return update
    }

    private func bestSupplementalMusicUpdate(for track: MediaItem, service: MetadataSearchService) async -> MediaMetadataUpdate? {
        let query = [track.artist, track.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let results = try? await service.searchMusic(
            query: query.isEmpty ? track.title : query,
            provider: settings.musicMetadataProvider,
            lastfmAPIKey: settings.lastfmAPIKey
        ),
              let best = MetadataMatchScorer.bestMusicMatch(for: track, in: results),
              best.confidence >= settings.musicMetadataMatchTolerance.musicThreshold else {
            return nil
        }
        let needsCover = track.posterPath?.isEmpty ?? true
        var update = needsCover
            ? await service.materializedMetadataUpdate(
                for: best.result,
                itemID: track.id,
                artworkDirectory: directories?.thumbnails,
                preserveEmbeddedPoster: track.hasEmbeddedArtwork
            )
            : best.result.metadataUpdate
        update.title = nil
        update.originalTitle = nil
        if track.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { update.artist = nil }
        if track.album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { update.album = nil }
        if track.trackNumber != nil { update.trackNumber = nil }
        if track.year != nil { update.year = nil }
        if !needsCover { update.posterPath = nil }
        update.backdropPath = nil
        return update
    }

    private func writeMusicTagsToSourceIfPossible(update: MediaMetadataUpdate, item: MediaItem) async {
        guard canWriteMusicFileTags(for: item) else { return }
        let draft = MusicTagDraft(
            artist: update.artist,
            album: update.album,
            trackNumber: update.trackNumber,
            year: update.year,
            artworkPath: update.posterPath,
            externalID: update.externalID,
            metadataProvider: update.metadataProvider
        )
        guard draft.hasWritableMetadata else { return }
        do {
            _ = try await MusicTagEditingService(logger: logger).write(draft, to: item)
        } catch {
            logger?.log("音乐标签写入源文件失败，已回落到 MediaLIB 索引：\(error.localizedDescription)", level: .warning)
        }
    }

    private func writeVideoMetadataSidecarIfPossible(item: MediaItem, update: MediaMetadataUpdate) throws {
        guard let source = source(for: item), source.sourceKind == .local else { return }
        let targetURL: URL?
        if item.type == .movie, let filePath = item.filePath {
            targetURL = URL(fileURLWithPath: filePath).deletingLastPathComponent().appendingPathComponent("movie.nfo")
        } else if item.type == .tvShow || item.type == .anime {
            let firstEpisodeURL = children(for: item).first?.filePath.map { URL(fileURLWithPath: $0) }
            targetURL = firstEpisodeURL?.deletingLastPathComponent().appendingPathComponent("tvshow.nfo")
        } else {
            targetURL = nil
        }
        guard let targetURL else { return }
        let directory = targetURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: directory.path) else { return }
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <\(item.type == .movie ? "movie" : "tvshow")>
          <title>\(xmlEscaped(update.title ?? item.title))</title>
          \(update.originalTitle.map { "<originaltitle>\(xmlEscaped($0))</originaltitle>" } ?? "")
          \(update.year.map { "<year>\($0)</year>" } ?? "")
          \(update.overview.map { "<plot>\(xmlEscaped($0))</plot>" } ?? "")
          \(update.rating.map { "<rating>\($0)</rating>" } ?? "")
          \(update.genre.map { "<genre>\(xmlEscaped($0))</genre>" } ?? "")
          \(update.externalID.map { "<uniqueid type=\"tmdb\">\(xmlEscaped($0))</uniqueid>" } ?? "")
        </\(item.type == .movie ? "movie" : "tvshow")>
        """
        try xml.write(to: targetURL, atomically: true, encoding: .utf8)
    }

    private func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    func updateMetadataInMemory(id: String, metadata: MediaMetadataUpdate) {
        let now = Date()

        func updated(_ item: MediaItem) -> MediaItem {
            guard item.id == id else { return item }
            var copy = item
            copy.title = metadata.title ?? copy.title
            copy.originalTitle = metadata.originalTitle ?? copy.originalTitle
            copy.artist = metadata.artist ?? copy.artist
            copy.album = metadata.album ?? copy.album
            copy.trackNumber = metadata.trackNumber ?? copy.trackNumber
            copy.year = metadata.year ?? copy.year
            copy.overview = metadata.overview ?? copy.overview
            copy.posterPath = metadata.posterPath ?? copy.posterPath
            copy.backdropPath = metadata.backdropPath ?? copy.backdropPath
            copy.rating = metadata.rating ?? copy.rating
            copy.runtime = metadata.runtime ?? copy.runtime
            copy.externalID = metadata.externalID ?? copy.externalID
            copy.metadataProvider = metadata.metadataProvider ?? copy.metadataProvider
            copy.collectionTitle = metadata.collectionTitle ?? copy.collectionTitle
            copy.genre = metadata.genre ?? copy.genre
            copy.updatedAt = now
            return copy
        }

        items = items.map(updated)
        musicQueue = musicQueue.map(updated)
        if let activePlayerItem {
            self.activePlayerItem = updated(activePlayerItem)
        }
        if let selectedItem {
            self.selectedItem = updated(selectedItem)
        }
        if let quickPreviewItem {
            self.quickPreviewItem = updated(quickPreviewItem)
        }
        rebuildDerivedItemCaches()
        bumpLibraryRevision()
    }

    private func fetchLyricsIfPossible(for track: MediaItem) async {
        guard let filePath = track.filePath else { return }
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album)
        ].filter { $0.value?.isEmpty == false }
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("MediaLIB/1.0 local macOS media library", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let results = try? JSONDecoder().decode([LRCLibLyricsSearchResult].self, from: data),
              let text = results.first.flatMap({ $0.syncedLyrics ?? $0.plainLyrics }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let mediaURL = URL(fileURLWithPath: filePath)
        let outputURL = mediaURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(mediaURL.deletingPathExtension().lastPathComponent).lrc")
        do {
            try text.write(to: outputURL, atomically: true, encoding: .utf8)
        } catch {
            logger?.log("写入歌词 .lrc 失败(\(outputURL.lastPathComponent))：\(error.localizedDescription)", level: .warning)
        }
    }

}
