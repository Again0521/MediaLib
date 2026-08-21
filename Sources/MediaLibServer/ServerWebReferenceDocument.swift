import Foundation

/// The approved visual source is a self-contained document rather than a
/// stylesheet library: component geometry, colors and responsive rules live in
/// the document template's inline styles.  Keeping one read-only copy available
/// to the local server lets visual regression checks render the exact same
/// source in a fixed browser viewport.
enum ServerWebReferenceDocument {
    static func data() -> Data? {
        let fileName = "MediaLIB 系统页面"
        if let bundled = Bundle.main.url(forResource: fileName, withExtension: "html"),
           let data = try? Data(contentsOf: bundled) {
            return data
        }

        // SwiftPM tests and local debug builds do not have the final app bundle.
        // This fallback is deliberately limited to the checked-in visual source;
        // it never reads media paths or user data.
        let checkout = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("doc", isDirectory: true)
            .appendingPathComponent("\(fileName).html")
        return try? Data(contentsOf: checkout)
    }
}
