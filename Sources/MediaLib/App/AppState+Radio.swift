import Foundation
import MediaLibCore

// 电台（B5）从 AppState.swift 拆到本文件，直接缩小那个超大文件（R1-ARCH-001 头号债务）。
// 以本地曲库为种子按「同艺人 > 同风格 > 其它」加权采样生成连续播放队列。纯文件搬运，逐字不变。
// 依赖均为 internal（musicTracks / alert / replaceMusicQueueAndPlay）；genreSet / buildRadioQueue
// 是本特性私有，随之搬来仍保持 private（仅本文件可见）。
extension AppState {
    /// 以某首歌为种子开始电台：从本地曲库按「同艺人 > 同风格 > 其它」加权采样，生成一条连续播放队列。
    /// 同艺人=艺人电台，配合风格权重即得相似度电台。
    func startRadio(seed: MediaItem) {
        guard seed.type == .music else { return }
        let pool = musicTracks
        let radio = buildRadioQueue(seed: seed, pool: pool, limit: 60)
        guard radio.count > 1 else {
            alert = AppAlert(title: "曲库太小", message: "可播放的本地歌曲不足，无法生成电台。")
            return
        }
        replaceMusicQueueAndPlay(radio, startingAt: seed)
    }

    /// 以某个风格为主题开始电台：随机选一首该风格歌曲作种子。
    func startGenreRadio(_ genre: String) {
        let target = genre.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return }
        let matches = musicTracks.filter { Self.genreSet($0).contains(target) }
        guard let seed = matches.randomElement() else {
            alert = AppAlert(title: "暂无该风格歌曲", message: "本地曲库中没有标记为「\(genre)」的歌曲。")
            return
        }
        startRadio(seed: seed)
    }

    /// 以某位艺人为主题开始电台：随机选一首该艺人歌曲作种子。
    func startArtistRadio(artistName: String) {
        let target = artistName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return }
        let matches = musicTracks.filter {
            ($0.artist?.trimmingCharacters(in: .whitespaces).lowercased() == target) && $0.filePath != nil
        }
        guard let seed = matches.randomElement() else {
            alert = AppAlert(title: "暂无该艺人歌曲", message: "本地曲库中没有「\(artistName)」的可播放歌曲。")
            return
        }
        startRadio(seed: seed)
    }

    /// 本地曲库中是否有该艺人的可播放歌曲（用于决定是否展示艺人电台入口）。
    func hasPlayableTracks(forArtist artistName: String) -> Bool {
        let target = artistName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return false }
        return musicTracks.contains {
            ($0.artist?.trimmingCharacters(in: .whitespaces).lowercased() == target) && $0.filePath != nil
        }
    }

    private static func genreSet(_ item: MediaItem) -> Set<String> {
        guard let genre = item.genre else { return [] }
        return Set(
            genre.components(separatedBy: ", ")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    /// 加权无放回采样：同艺人 +6、同风格 +3、基础 1，从种子相关度高到低自然铺开，同权重内随机。
    private func buildRadioQueue(seed: MediaItem, pool: [MediaItem], limit: Int) -> [MediaItem] {
        let seedGenres = Self.genreSet(seed)
        let seedArtist = seed.artist?.trimmingCharacters(in: .whitespaces).lowercased()
        var weighted: [(item: MediaItem, weight: Double)] = pool.compactMap { track in
            guard track.id != seed.id, track.filePath != nil else { return nil }
            var weight = 1.0
            if let seedArtist, !seedArtist.isEmpty,
               let artist = track.artist?.trimmingCharacters(in: .whitespaces).lowercased(),
               artist == seedArtist {
                weight += 6
            }
            if !seedGenres.isEmpty, !seedGenres.isDisjoint(with: Self.genreSet(track)) {
                weight += 3
            }
            return (track, weight)
        }

        var result: [MediaItem] = [seed]
        var generator = SystemRandomNumberGenerator()
        while result.count < limit, !weighted.isEmpty {
            let total = weighted.reduce(0.0) { $0 + $1.weight }
            var threshold = Double.random(in: 0..<total, using: &generator)
            var pickIndex = weighted.count - 1
            for (index, entry) in weighted.enumerated() {
                threshold -= entry.weight
                if threshold < 0 {
                    pickIndex = index
                    break
                }
            }
            result.append(weighted[pickIndex].item)
            weighted.remove(at: pickIndex)
        }
        return result
    }
}
