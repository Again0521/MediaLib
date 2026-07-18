import XCTest
@testable import MediaLib
@testable import MediaLibCore

@MainActor
final class RemoteConnectorStoreTests: XCTestCase {
    func testAccountsAreOwnedByStoreAndCanBeReplacedOrUpserted() {
        let store = RemoteConnectorStore()
        let emby = makeAccount(id: "emby-1", provider: .emby)
        var updatedEmby = emby
        updatedEmby.accountLabel = "Emby Updated"
        let plex = makeAccount(id: "plex-1", provider: .plex)

        store.replaceAccounts([emby])
        store.upsert(updatedEmby)
        store.upsert(plex)

        XCTAssertEqual(store.accounts.map(\.id), ["emby-1", "plex-1"])
        XCTAssertEqual(store.accounts.first?.accountLabel, "Emby Updated")
    }

    func testRemoveAccountsKeepsPredicateInsideStoreBoundary() {
        let store = RemoteConnectorStore()
        store.replaceAccounts([
            makeAccount(id: "emby-1", provider: .emby),
            makeAccount(id: "trakt-1", provider: .trakt)
        ])

        store.removeAccounts { $0.provider == .trakt }

        XCTAssertEqual(store.accounts.map(\.provider), [.emby])
    }

    func testMediaServerConnectionFlagsAreOwnedByStore() {
        let store = RemoteConnectorStore()

        store.setConnecting(.emby, true)
        store.setConnecting(.jellyfin, true)
        store.setConnecting(.plex, true)
        store.setConnecting(.mlink, true)
        store.setConnecting(.trakt, true)

        XCTAssertTrue(store.isConnecting(.emby))
        XCTAssertTrue(store.isConnecting(.jellyfin))
        XCTAssertTrue(store.isConnecting(.plex))
        XCTAssertTrue(store.isConnecting(.mlink))
        XCTAssertFalse(store.isConnecting(.trakt))
    }

    private func makeAccount(id: String, provider: RemoteConnectorProvider) -> RemoteConnectorAccount {
        RemoteConnectorAccount(
            id: id,
            provider: provider,
            accountLabel: provider.displayName,
            serverURL: "https://example.com/\(id)",
            sourceID: "\(id)-source",
            connectionMode: provider == .trakt ? .syncOnly : .library,
            syncEnabled: true
        )
    }
}
