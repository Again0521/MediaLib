import Foundation

/// The approved visual source is a self-contained document rather than a
/// stylesheet library: component geometry, colors and responsive rules live in
/// the document template's inline styles.  Keeping one read-only copy available
/// to the local server lets visual regression checks render the exact same
/// source in a fixed browser viewport.
enum ServerWebReferenceDocument {
    private static let fileName = "MediaLIB 系统页面"

    static func data() -> Data? {
        if let bundled = Bundle.main.url(forResource: fileName, withExtension: "html"),
           let data = try? Data(contentsOf: bundled) {
            return data
        }

        // SwiftPM tests and local debug builds do not have the final app bundle.
        // XCTest does not promise that its process starts in the package root, so
        // derive the checked-in source from this file before trying the legacy
        // working-directory lookup. Both locations are repository-owned only;
        // neither can resolve media paths or user data.
        let sourceCheckout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for checkout in [sourceCheckout, workingDirectory] {
            let document = checkout
                .appendingPathComponent("doc", isDirectory: true)
                .appendingPathComponent("\(fileName).html")
            if let data = try? Data(contentsOf: document) {
                return data
            }
        }
        return nil
    }
}
