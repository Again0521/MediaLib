import Foundation
import MediaLibCore

/// Catalog-backed administration reads extracted from the main HTTP router.
///
/// The outer router still owns authentication and the independent API rate-limit bucket. This
/// handler owns each endpoint's precise permission, strict query contract, redacted catalog call
/// and HTTP mapping so a new management page cannot accidentally inherit another page's policy.
struct ServerAdministrationReadHandler {
    private let catalog: ServerAdministrationCatalog?

    init(catalog: ServerAdministrationCatalog?) {
        self.catalog = catalog
    }

    func response(
        path: String,
        target: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse? {
        switch path {
        case "/api/v1/admin/users":
            guard principal.permissions.contains(.manageUsers) else { return .forbidden() }
            guard let query = ServerAdministrationQueryParser.users(from: target) else {
                return .badRequest()
            }
            guard let catalog,
                  let value = try? catalog.users(limit: query.limit, offset: query.offset),
                  let data = ServerCommandOutput.jsonData(value)
            else { return .serviceUnavailable() }
            return .ok(body: data, omitBody: omitBody)

        case "/api/v1/admin/sessions":
            guard principal.permissions.contains(.manageSessions) else { return .forbidden() }
            guard let query = ServerAdministrationQueryParser.sessions(from: target) else {
                return .badRequest()
            }
            guard let catalog,
                  let value = try? catalog.activeSessions(
                    limit: query.limit,
                    offset: query.offset,
                    searchText: query.searchText
                  ),
                  let data = ServerCommandOutput.jsonData(value)
            else { return .serviceUnavailable() }
            return .ok(body: data, omitBody: omitBody)

        case "/api/v1/admin/security-events", "/api/v1/admin/logs":
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard let query = ServerAdministrationQueryParser.securityEvents(from: target, path: path) else {
                return .badRequest()
            }
            guard let catalog,
                  let value = try? catalog.securityEvents(
                    limit: query.limit,
                    offset: query.offset,
                    category: query.category,
                    outcome: query.outcome,
                    searchText: query.searchText
                  ),
                  let data = ServerCommandOutput.jsonData(value)
            else { return .serviceUnavailable() }
            return .ok(body: data, omitBody: omitBody)

        case "/api/v1/admin/sources":
            guard principal.permissions.contains(.manageLibraries) ||
                    principal.permissions.contains(.manageServer)
            else { return .forbidden() }
            guard let query = ServerAdministrationQueryParser.sources(from: target) else {
                return .badRequest()
            }
            guard let catalog,
                  let value = try? catalog.sources(
                    limit: query.limit,
                    offset: query.offset,
                    searchText: query.searchText
                  ),
                  let data = ServerCommandOutput.jsonData(value)
            else { return .serviceUnavailable() }
            return .ok(body: data, omitBody: omitBody)

        case "/api/v1/admin/libraries":
            guard principal.permissions.contains(.manageLibraries) else { return .forbidden() }
            guard ServerAdministrationQueryParser.libraries(from: target) else {
                return .badRequest()
            }
            guard let catalog,
                  let value = try? catalog.libraries(),
                  let data = ServerCommandOutput.jsonData(value)
            else { return .serviceUnavailable() }
            return .ok(body: data, omitBody: omitBody)

        default:
            return nil
        }
    }
}
