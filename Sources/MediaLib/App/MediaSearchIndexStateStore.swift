import Combine
import Foundation

/// 媒体搜索索引的详情补充状态容器。
///
/// 只保存详情完整度缺口、额外搜索词和搜索 revision；索引构建、字段拼装、
/// 查询匹配、repository 读取/写入和界面列表刷新仍由 AppState 原有流程编排。
@MainActor
final class MediaSearchIndexStateStore: ObservableObject {
    @Published private(set) var detailMetadataGapsByMediaID: [String: Set<String>] = [:]
    @Published private(set) var detailSearchTermsByMediaID: [String: [String]] = [:]
    @Published private(set) var revision = 0

    func replaceDetailMetadataGaps(_ gapsByMediaID: [String: Set<String>]) {
        detailMetadataGapsByMediaID = gapsByMediaID
    }

    func setDetailMetadataGaps(_ gaps: Set<String>?, forMediaID mediaID: String) {
        if let gaps {
            detailMetadataGapsByMediaID[mediaID] = gaps
        } else {
            detailMetadataGapsByMediaID.removeValue(forKey: mediaID)
        }
    }

    func replaceDetailSearchTerms(_ termsByMediaID: [String: [String]]) {
        detailSearchTermsByMediaID = termsByMediaID
    }

    func setRevision(_ revision: Int) {
        self.revision = revision
    }

    func bumpRevision() {
        revision += 1
    }
}
