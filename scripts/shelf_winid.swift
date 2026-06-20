import CoreGraphics
import Foundation
let targetPID = CommandLine.arguments.count > 1 ? Int32(CommandLine.arguments[1]) ?? -1 : -1
guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { exit(1) }
var best: (id: Int, area: Int)? = nil
for w in infoList {
  guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owner == targetPID else { continue }
  guard let wid = w[kCGWindowNumber as String] as? Int else { continue }
  guard let bounds = w[kCGWindowBounds as String] as? [String: Any],
        let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { continue }
  let area = Int(width*height)
  if area < 90000 { continue }
  if best == nil || area > best!.area { best = (wid, area) }
}
if let best { print(best.id) } else { exit(2) }
