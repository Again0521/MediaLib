import Foundation

/// 首页组件布局的纯数据规则。
///
/// 视图只负责拖放手势和呈现；顺序补全、去重与移动统一在这里处理，避免旧版本
/// 缺少的新模块、损坏的 UserDefaults 字符串或重复 id 让首页布局进入不可恢复状态。
public enum HomeModuleLayoutPolicy {
    public static func normalizedOrder(storedIDs: [String], allowedIDs: [String]) -> [String] {
        let allowed = Set(allowedIDs)
        var seen = Set<String>()
        let retained = storedIDs.filter { allowed.contains($0) && seen.insert($0).inserted }
        return retained + allowedIDs.filter { seen.insert($0).inserted }
    }

    public static func normalizedHiddenIDs(storedIDs: [String], allowedIDs: [String]) -> Set<String> {
        let allowed = Set(allowedIDs)
        return Set(storedIDs.filter { allowed.contains($0) })
    }

    public static func moving(_ id: String, before destinationID: String, in order: [String]) -> [String] {
        guard id != destinationID,
              let sourceIndex = order.firstIndex(of: id),
              order.contains(destinationID) else {
            return order
        }
        var result = order
        result.remove(at: sourceIndex)
        guard let destinationIndex = result.firstIndex(of: destinationID) else { return order }
        result.insert(id, at: destinationIndex)
        return result
    }

    /// 将恢复显示的组件放到当前布局末尾，保证“添加”不会悄悄打断用户已有编排。
    public static func appending(_ id: String, to order: [String]) -> [String] {
        order.filter { $0 != id } + [id]
    }
}
