import Foundation

/// 单范围 HTTP `Range` 请求的严格解析结果。多范围响应会大幅增加媒体服务复杂度，
/// 当前实现明确拒绝它们，浏览器和原生播放器的首个请求仍可正常使用单范围直放。
enum HTTPByteRangeRequest: Equatable {
    case closed(Int64, Int64)
    case from(Int64)
    case suffix(Int64)

    init?(headerValue: String) {
        let value = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let specification = String(value.dropFirst("bytes=".count))
        guard !specification.contains(","),
              let dash = specification.firstIndex(of: "-")
        else {
            return nil
        }

        let lowerText = specification[..<dash].trimmingCharacters(in: .whitespaces)
        let upperText = specification[specification.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if lowerText.isEmpty {
            guard let suffixLength = Int64(upperText), suffixLength > 0 else { return nil }
            self = .suffix(suffixLength)
        } else if upperText.isEmpty {
            guard let lower = Int64(lowerText), lower >= 0 else { return nil }
            self = .from(lower)
        } else {
            guard let lower = Int64(lowerText),
                  let upper = Int64(upperText),
                  lower >= 0,
                  upper >= lower
            else {
                return nil
            }
            self = .closed(lower, upper)
        }
    }

    func resolve(totalLength: Int64) -> ResolvedHTTPByteRange? {
        guard totalLength > 0 else { return nil }
        switch self {
        case let .closed(lower, upper):
            guard lower < totalLength else { return nil }
            return ResolvedHTTPByteRange(
                lowerBound: lower,
                upperBound: min(upper, totalLength - 1),
                totalLength: totalLength
            )
        case let .from(lower):
            guard lower < totalLength else { return nil }
            return ResolvedHTTPByteRange(
                lowerBound: lower,
                upperBound: totalLength - 1,
                totalLength: totalLength
            )
        case let .suffix(length):
            let lower = max(totalLength - length, 0)
            return ResolvedHTTPByteRange(
                lowerBound: lower,
                upperBound: totalLength - 1,
                totalLength: totalLength
            )
        }
    }
}

struct ResolvedHTTPByteRange: Equatable {
    let lowerBound: Int64
    let upperBound: Int64
    let totalLength: Int64

    var length: Int64 { upperBound - lowerBound + 1 }
    var contentRangeHeader: String { "bytes \(lowerBound)-\(upperBound)/\(totalLength)" }
}

func httpHeader(named name: String, in requestHead: String) -> String? {
    let prefix = name.lowercased() + ":"
    for line in requestHead.split(separator: "\r\n", omittingEmptySubsequences: false).dropFirst() {
        let text = String(line)
        guard text.lowercased().hasPrefix(prefix) else { continue }
        return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
}
