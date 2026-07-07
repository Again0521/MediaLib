import Foundation

public final class MediaDetailRepository {
    private let database: DatabaseManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum DetailPresenceTable: CaseIterable {
        case externalIDs
        case credits
        case artwork
        case relatedTitles

        var selectDistinctMediaIDsSQL: String {
            switch self {
            case .externalIDs:
                return "SELECT DISTINCT media_id FROM media_external_ids"
            case .credits:
                return "SELECT DISTINCT media_id FROM media_credits"
            case .artwork:
                return "SELECT DISTINCT media_id FROM media_artwork"
            case .relatedTitles:
                return "SELECT DISTINCT media_id FROM media_related_titles"
            }
        }

        var missingLabel: String {
            switch self {
            case .externalIDs: return "外部 ID"
            case .credits: return "人物"
            case .artwork: return "艺术照"
            case .relatedTitles: return "推荐"
            }
        }
    }

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func save(_ snapshot: MediaDetailSnapshot) throws {
        try database.transaction {
            try saveMetadata(snapshot.metadata)
            try replaceExternalIDs(mediaID: snapshot.metadata.mediaID, values: snapshot.externalIDs)
            for person in snapshot.people {
                try savePerson(person)
            }
            try replaceCredits(mediaID: snapshot.metadata.mediaID, values: snapshot.credits)
            try replaceArtwork(mediaID: snapshot.metadata.mediaID, values: snapshot.artwork)
            try replaceRelatedTitles(mediaID: snapshot.metadata.mediaID, values: snapshot.relatedTitles)
            try cleanupOrphanedPeople()
        }
    }

    public func fetch(mediaID: String) throws -> MediaDetailSnapshot? {
        guard let metadata = try fetchMetadata(mediaID: mediaID) else { return nil }
        let externalIDs = try database.query(
            "SELECT provider, external_value FROM media_external_ids WHERE media_id = ? ORDER BY provider",
            bindings: [.text(mediaID)]
        ) { MediaExternalID(provider: $0.string(0) ?? "", value: $0.string(1) ?? "") }
        let credits = try fetchCredits(mediaID: mediaID)
        let people = try credits.compactMap { try fetchPerson(id: $0.personID) }
        let artwork = try database.query(
            """
            SELECT id, kind, thumb_url, full_url, language, aspect_ratio, sort_order, local_path
            FROM media_artwork WHERE media_id = ? ORDER BY sort_order, id
            """,
            bindings: [.text(mediaID)]
        ) {
            MediaArtwork(
                id: $0.string(0) ?? UUID().uuidString,
                mediaID: mediaID,
                kind: $0.string(1) ?? "backdrop",
                thumbURL: $0.string(2) ?? "",
                fullURL: $0.string(3) ?? "",
                language: $0.string(4),
                aspectRatio: Self.normalizedArtworkAspectRatio($0.double(5)),
                order: $0.int(6) ?? 0,
                localPath: $0.string(7)
            )
        }
        let related = try database.query(
            """
            SELECT id, relation, external_id, title, year, poster_url, overview, rating, popularity, local_media_id, sort_order
            FROM media_related_titles WHERE media_id = ? ORDER BY relation, sort_order, id
            """,
            bindings: [.text(mediaID)]
        ) {
            MediaRelatedTitle(
                id: $0.string(0) ?? UUID().uuidString,
                mediaID: mediaID,
                relation: $0.string(1) ?? "similar",
                externalID: $0.string(2) ?? "",
                title: $0.string(3) ?? "未命名作品",
                year: $0.int(4),
                posterURL: $0.string(5),
                overview: $0.string(6),
                rating: Self.normalizedRelatedRating($0.double(7)),
                popularity: Self.normalizedPopularity($0.double(8)),
                localMediaID: $0.string(9),
                order: $0.int(10) ?? 0
            )
        }
        return MediaDetailSnapshot(
            metadata: metadata,
            externalIDs: externalIDs,
            people: people,
            credits: credits,
            artwork: artwork,
            relatedTitles: related
        )
    }

    public func fetchPerson(id: String) throws -> MediaPerson? {
        let rows = try database.query(
            """
            SELECT id, name, profile_url, biography, birthday, deathday, place_of_birth,
                   known_for_department, known_for_json, filmography_json, updated_at
            FROM media_people WHERE id = ? LIMIT 1
            """,
            bindings: [.text(id)]
        ) { row -> MediaPerson in
            MediaPerson(
                id: row.string(0) ?? id,
                name: row.string(1) ?? "未知人物",
                profileURL: row.string(2),
                biography: row.string(3),
                birthday: row.string(4),
                deathday: row.string(5),
                placeOfBirth: row.string(6),
                knownForDepartment: row.string(7),
                knownFor: self.decodeWorks(row.string(8)),
                filmography: self.decodeWorks(row.string(9)),
                updatedAt: row.date(10) ?? Date()
            )
        }
        guard var person = rows.first else { return nil }
        person.externalIDs = try database.query(
            "SELECT provider, external_value FROM media_person_external_ids WHERE person_id = ? ORDER BY provider",
            bindings: [.text(id)]
        ) { MediaExternalID(provider: $0.string(0) ?? "", value: $0.string(1) ?? "") }
        return person
    }

    public func savePerson(_ person: MediaPerson) throws {
        try database.execute(
            """
            INSERT INTO media_people (
              id, name, profile_url, biography, birthday, deathday, place_of_birth,
              known_for_department, known_for_json, filmography_json, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              profile_url = COALESCE(excluded.profile_url, media_people.profile_url),
              biography = COALESCE(NULLIF(excluded.biography, ''), media_people.biography),
              birthday = COALESCE(excluded.birthday, media_people.birthday),
              deathday = COALESCE(excluded.deathday, media_people.deathday),
              place_of_birth = COALESCE(excluded.place_of_birth, media_people.place_of_birth),
              known_for_department = COALESCE(excluded.known_for_department, media_people.known_for_department),
              known_for_json = CASE WHEN excluded.known_for_json != '[]' THEN excluded.known_for_json ELSE media_people.known_for_json END,
              filmography_json = CASE WHEN excluded.filmography_json != '[]' THEN excluded.filmography_json ELSE media_people.filmography_json END,
              updated_at = excluded.updated_at
            """,
            bindings: [
                .text(person.id),
                .text(person.name),
                .optionalText(person.profileURL),
                .optionalText(person.biography),
                .optionalText(person.birthday),
                .optionalText(person.deathday),
                .optionalText(person.placeOfBirth),
                .optionalText(person.knownForDepartment),
                .text(encodeWorks(person.knownFor)),
                .text(encodeWorks(person.filmography)),
                .optionalDate(person.updatedAt)
            ]
        )
        try database.execute("DELETE FROM media_person_external_ids WHERE person_id = ?", bindings: [.text(person.id)])
        for value in person.externalIDs where !value.provider.isEmpty && !value.value.isEmpty {
            try database.execute(
                "INSERT OR REPLACE INTO media_person_external_ids (person_id, provider, external_value) VALUES (?, ?, ?)",
                bindings: [.text(person.id), .text(value.provider), .text(value.value)]
            )
        }
    }

    public func libraryCredits(personID: String) throws -> [MediaPersonLibraryCredit] {
        let mediaRepository = MediaRepository(database: database)
        let credits = try database.query(
            """
            SELECT id, media_id, category, role, department, sort_order
            FROM media_credits WHERE person_id = ? ORDER BY sort_order, id
            """,
            bindings: [.text(personID)]
        ) {
            MediaCredit(
                id: $0.string(0) ?? UUID().uuidString,
                mediaID: $0.string(1) ?? "",
                personID: personID,
                category: $0.string(2) ?? "cast",
                role: $0.string(3) ?? "",
                department: $0.string(4),
                order: $0.int(5) ?? 0
            )
        }
        return try credits.compactMap { credit in
            guard let item = try mediaRepository.fetch(id: credit.mediaID) else { return nil }
            return MediaPersonLibraryCredit(media: item, credit: credit)
        }
    }

    public func searchTermsByMediaID() throws -> [String: [String]] {
        var values: [String: Set<String>] = [:]

        let metadataRows = try database.query(
            """
            SELECT media_id, status, first_air_date, end_date, content_rating, original_language,
                   countries_json, production_companies_json, networks_json, provider
            FROM media_detail_metadata
            """
        ) { row in
            (
                mediaID: row.string(0) ?? "",
                scalarValues: [
                    row.string(1), row.string(2), row.string(3), row.string(4),
                    row.string(5), row.string(9)
                ].compactMap { $0 },
                countries: self.decodeStrings(row.string(6)),
                companies: self.decodeStrings(row.string(7)),
                networks: self.decodeStrings(row.string(8))
            )
        }
        for row in metadataRows where !row.mediaID.isEmpty {
            values[row.mediaID, default: []].formUnion(row.scalarValues)
            values[row.mediaID, default: []].formUnion(row.countries)
            values[row.mediaID, default: []].formUnion(row.companies)
            values[row.mediaID, default: []].formUnion(row.networks)
        }

        let externalRows = try database.query(
            "SELECT media_id, provider, external_value FROM media_external_ids"
        ) {
            (
                mediaID: $0.string(0) ?? "",
                provider: $0.string(1) ?? "",
                externalValue: $0.string(2) ?? ""
            )
        }
        for row in externalRows where !row.mediaID.isEmpty {
            values[row.mediaID, default: []].insert(row.provider)
            values[row.mediaID, default: []].insert(row.externalValue)
        }

        let creditRows = try database.query(
            """
            SELECT c.media_id, p.name, c.role, c.department
            FROM media_credits c
            JOIN media_people p ON p.id = c.person_id
            """
        ) {
            (
                mediaID: $0.string(0) ?? "",
                name: $0.string(1) ?? "",
                role: $0.string(2) ?? "",
                department: $0.string(3) ?? ""
            )
        }
        for row in creditRows where !row.mediaID.isEmpty {
            values[row.mediaID, default: []].insert(row.name)
            values[row.mediaID, default: []].insert(row.role)
            values[row.mediaID, default: []].insert(row.department)
        }

        return values.mapValues {
            $0.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted()
        }
    }

    public func externalMediaIDIndex() throws -> [String: String] {
        let rows = try database.query(
            "SELECT media_id, provider, external_value FROM media_external_ids"
        ) {
            (
                mediaID: $0.string(0) ?? "",
                provider: $0.string(1) ?? "",
                externalValue: $0.string(2) ?? ""
            )
        }
        var result: [String: String] = [:]
        for row in rows where !row.mediaID.isEmpty && !row.externalValue.isEmpty {
            let provider = row.provider.lowercased()
            result[row.externalValue.lowercased()] = row.mediaID
            if !provider.isEmpty {
                result["\(provider):\(row.externalValue.lowercased())"] = row.mediaID
            }
        }
        return result
    }

    public func mediaIDsByPersonID() throws -> [String: Set<String>] {
        let rows = try database.query(
            "SELECT person_id, media_id FROM media_credits"
        ) {
            (personID: $0.string(0) ?? "", mediaID: $0.string(1) ?? "")
        }
        var result: [String: Set<String>] = [:]
        for row in rows where !row.personID.isEmpty && !row.mediaID.isEmpty {
            result[row.personID, default: []].insert(row.mediaID)
        }
        return result
    }

    public func firstBackdropPathsByMediaID() throws -> [String: String] {
        let rows = try database.query(
            """
            SELECT media_id, kind, full_url, local_path, aspect_ratio, sort_order
            FROM media_artwork
            WHERE kind = 'backdrop' OR aspect_ratio >= 1.3
            ORDER BY media_id, sort_order ASC, id ASC
            """
        ) {
            (
                mediaID: $0.string(0) ?? "",
                kind: $0.string(1) ?? "backdrop",
                fullURL: $0.string(2) ?? "",
                localPath: $0.string(3),
                aspectRatio: Self.normalizedArtworkAspectRatio($0.double(4)),
                order: $0.int(5) ?? 0
            )
        }
        let grouped = Dictionary(grouping: rows.filter { !$0.mediaID.isEmpty }, by: \.mediaID)
        return grouped.compactMapValues { candidates in
            candidates
                .filter { ($0.kind == "backdrop" || $0.aspectRatio >= 1.45) && $0.aspectRatio >= 1.3 }
                .sorted { lhs, rhs in
                    if (lhs.kind == "backdrop") != (rhs.kind == "backdrop") {
                        return lhs.kind == "backdrop"
                    }
                    if lhs.localPath != rhs.localPath {
                        return lhs.localPath != nil
                    }
                    if abs(lhs.aspectRatio - rhs.aspectRatio) > 0.08 {
                        return lhs.aspectRatio > rhs.aspectRatio
                    }
                    return lhs.order < rhs.order
                }
                .first
                .flatMap { $0.localPath ?? ($0.fullURL.isEmpty ? nil : $0.fullURL) }
        }
    }

    public func staleMediaIDs(olderThan date: Date) throws -> Set<String> {
        Set(try database.query(
            "SELECT media_id FROM media_detail_metadata WHERE fetched_at < ?",
            bindings: [.optionalDate(date)]
        ) { $0.string(0) ?? "" }.filter { !$0.isEmpty })
    }

    public func detailCompleteness(mediaIDs: [String]) throws -> [String: Set<String>] {
        guard !mediaIDs.isEmpty else { return [:] }
        let candidates = Set(mediaIDs)
        func mediaIDsWithRows(in table: DetailPresenceTable) throws -> Set<String> {
            Set(try database.query(
                table.selectDistinctMediaIDsSQL
            ) { $0.string(0) ?? "" }.filter { candidates.contains($0) })
        }
        var mediaIDsByTable: [DetailPresenceTable: Set<String>] = [:]
        for table in DetailPresenceTable.allCases {
            mediaIDsByTable[table] = try mediaIDsWithRows(in: table)
        }
        var result: [String: Set<String>] = [:]
        for mediaID in mediaIDs {
            var missing = Set<String>()
            for table in DetailPresenceTable.allCases {
                if mediaIDsByTable[table]?.contains(mediaID) != true {
                    missing.insert(table.missingLabel)
                }
            }
            if !missing.isEmpty { result[mediaID] = missing }
        }
        return result
    }

    public func prepareBackfill(mediaIDs: [String]) throws {
        let now = Date()
        try database.transaction {
            for mediaID in mediaIDs {
                try database.execute(
                    """
                    INSERT OR IGNORE INTO media_detail_backfill_jobs
                      (media_id, status, attempt_count, next_retry_at, last_error, updated_at)
                    VALUES (?, 'pending', 0, NULL, NULL, ?)
                    """,
                    bindings: [.text(mediaID), .optionalDate(now)]
                )
                try database.execute(
                    """
                    UPDATE media_detail_backfill_jobs
                    SET status = 'pending', next_retry_at = NULL, updated_at = ?
                    WHERE media_id = ?
                      AND status = 'completed'
                      AND (
                        NOT EXISTS (
                          SELECT 1 FROM media_detail_metadata
                          WHERE media_detail_metadata.media_id = media_detail_backfill_jobs.media_id
                        )
                        OR EXISTS (
                          SELECT 1 FROM media_detail_metadata
                          WHERE media_detail_metadata.media_id = media_detail_backfill_jobs.media_id
                            AND fetched_at < ?
                        )
                      )
                    """,
                    bindings: [
                        .optionalDate(now),
                        .text(mediaID),
                        .optionalDate(now.addingTimeInterval(-30 * 24 * 60 * 60))
                    ]
                )
            }
        }
    }

    public func pendingBackfillMediaIDs(limit: Int = 200) throws -> [String] {
        try database.query(
            """
            SELECT media_id
            FROM media_detail_backfill_jobs
            WHERE status IN ('pending', 'failed', 'waitingConfiguration')
              AND (next_retry_at IS NULL OR next_retry_at <= ?)
            ORDER BY
              CASE status WHEN 'pending' THEN 0 WHEN 'waitingConfiguration' THEN 1 ELSE 2 END,
              updated_at
            LIMIT ?
            """,
            bindings: [.optionalDate(Date()), .int(Int64(max(limit, 1)))]
        ) { $0.string(0) ?? "" }.filter { !$0.isEmpty }
    }

    public func markBackfillRunning(mediaID: String) throws {
        try database.execute(
            """
            UPDATE media_detail_backfill_jobs
            SET status = 'running', attempt_count = attempt_count + 1, updated_at = ?
            WHERE media_id = ?
            """,
            bindings: [.optionalDate(Date()), .text(mediaID)]
        )
    }

    public func markBackfillCompleted(mediaID: String) throws {
        try database.execute(
            """
            UPDATE media_detail_backfill_jobs
            SET status = 'completed', next_retry_at = NULL, last_error = NULL, updated_at = ?
            WHERE media_id = ?
            """,
            bindings: [.optionalDate(Date()), .text(mediaID)]
        )
    }

    public func markBackfillWaitingForConfiguration(mediaID: String) throws {
        try database.execute(
            """
            UPDATE media_detail_backfill_jobs
            SET status = 'waitingConfiguration', next_retry_at = ?, last_error = ?, updated_at = ?
            WHERE media_id = ?
            """,
            bindings: [
                .optionalDate(Date().addingTimeInterval(24 * 60 * 60)),
                .text("等待配置 TMDB"),
                .optionalDate(Date()),
                .text(mediaID)
            ]
        )
    }

    public func markBackfillFailed(mediaID: String, error: String) throws {
        let attempts = try database.query(
            "SELECT attempt_count FROM media_detail_backfill_jobs WHERE media_id = ? LIMIT 1",
            bindings: [.text(mediaID)]
        ) { $0.int(0) ?? 1 }.first ?? 1
        let retryMinutes = min(max(attempts, 1) * 15, 360)
        try database.execute(
            """
            UPDATE media_detail_backfill_jobs
            SET status = 'failed',
                next_retry_at = ?,
                last_error = ?,
                updated_at = ?
            WHERE media_id = ?
            """,
            bindings: [
                .optionalDate(Date().addingTimeInterval(Double(retryMinutes) * 60)),
                .text(error),
                .optionalDate(Date()),
                .text(mediaID)
            ]
        )
    }

    private func saveMetadata(_ value: MediaDetailMetadata) throws {
        try database.execute(
            """
            INSERT INTO media_detail_metadata (
              media_id, status, first_air_date, end_date, season_count, episode_count,
              content_rating, original_language, countries_json, production_companies_json,
              networks_json, trailer_url, provider, language, fetched_at, fetch_version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(media_id) DO UPDATE SET
              status = excluded.status,
              first_air_date = excluded.first_air_date,
              end_date = excluded.end_date,
              season_count = excluded.season_count,
              episode_count = excluded.episode_count,
              content_rating = excluded.content_rating,
              original_language = excluded.original_language,
              countries_json = excluded.countries_json,
              production_companies_json = excluded.production_companies_json,
              networks_json = excluded.networks_json,
              trailer_url = excluded.trailer_url,
              provider = excluded.provider,
              language = excluded.language,
              fetched_at = excluded.fetched_at,
              fetch_version = excluded.fetch_version
            """,
            bindings: [
                .text(value.mediaID),
                .optionalText(value.status),
                .optionalText(value.firstAirDate),
                .optionalText(value.endDate),
                .optionalInt(Self.normalizedCount(value.seasonCount)),
                .optionalInt(Self.normalizedCount(value.episodeCount)),
                .optionalText(value.contentRating),
                .optionalText(value.originalLanguage),
                .text(encodeStrings(value.countries)),
                .text(encodeStrings(value.productionCompanies)),
                .text(encodeStrings(value.networks)),
                .optionalText(value.trailerURL),
                .text(value.provider),
                .text(value.language),
                .optionalDate(value.fetchedAt),
                .int(Int64(value.fetchVersion))
            ]
        )
    }

    private func fetchMetadata(mediaID: String) throws -> MediaDetailMetadata? {
        try database.query(
            """
            SELECT status, first_air_date, end_date, season_count, episode_count, content_rating,
                   original_language, countries_json, production_companies_json, networks_json,
                   trailer_url, provider, language, fetched_at, fetch_version
            FROM media_detail_metadata WHERE media_id = ? LIMIT 1
            """,
            bindings: [.text(mediaID)]
        ) {
            MediaDetailMetadata(
                mediaID: mediaID,
                status: $0.string(0),
                firstAirDate: $0.string(1),
                endDate: $0.string(2),
                seasonCount: Self.normalizedCount($0.int(3)),
                episodeCount: Self.normalizedCount($0.int(4)),
                contentRating: $0.string(5),
                originalLanguage: $0.string(6),
                countries: self.decodeStrings($0.string(7)),
                productionCompanies: self.decodeStrings($0.string(8)),
                networks: self.decodeStrings($0.string(9)),
                trailerURL: $0.string(10),
                provider: $0.string(11) ?? "unknown",
                language: $0.string(12) ?? "zh-CN",
                fetchedAt: $0.date(13) ?? .distantPast,
                fetchVersion: $0.int(14) ?? 1
            )
        }.first
    }

    private func fetchCredits(mediaID: String) throws -> [MediaCredit] {
        try database.query(
            """
            SELECT id, person_id, category, role, department, sort_order
            FROM media_credits WHERE media_id = ? ORDER BY category, sort_order, id
            """,
            bindings: [.text(mediaID)]
        ) {
            MediaCredit(
                id: $0.string(0) ?? UUID().uuidString,
                mediaID: mediaID,
                personID: $0.string(1) ?? "",
                category: $0.string(2) ?? "cast",
                role: $0.string(3) ?? "",
                department: $0.string(4),
                order: $0.int(5) ?? 0
            )
        }
    }

    private func replaceExternalIDs(mediaID: String, values: [MediaExternalID]) throws {
        try database.execute("DELETE FROM media_external_ids WHERE media_id = ?", bindings: [.text(mediaID)])
        for value in values where !value.provider.isEmpty && !value.value.isEmpty {
            try database.execute(
                "INSERT OR REPLACE INTO media_external_ids (media_id, provider, external_value) VALUES (?, ?, ?)",
                bindings: [.text(mediaID), .text(value.provider), .text(value.value)]
            )
        }
    }

    private func replaceCredits(mediaID: String, values: [MediaCredit]) throws {
        try database.execute("DELETE FROM media_credits WHERE media_id = ?", bindings: [.text(mediaID)])
        for value in values {
            try database.execute(
                """
                INSERT OR REPLACE INTO media_credits
                  (id, media_id, person_id, category, role, department, sort_order)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(value.id), .text(mediaID), .text(value.personID), .text(value.category),
                    .text(value.role), .optionalText(value.department), .int(Int64(value.order))
                ]
            )
        }
    }

    private func replaceArtwork(mediaID: String, values: [MediaArtwork]) throws {
        try database.execute("DELETE FROM media_artwork WHERE media_id = ?", bindings: [.text(mediaID)])
        for value in values {
            try database.execute(
                """
                INSERT OR REPLACE INTO media_artwork
                  (id, media_id, kind, thumb_url, full_url, language, aspect_ratio, sort_order, local_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(value.id), .text(mediaID), .text(value.kind), .text(value.thumbURL),
                    .text(value.fullURL), .optionalText(value.language), .double(Self.normalizedArtworkAspectRatio(value.aspectRatio)),
                    .int(Int64(value.order)), .optionalText(value.localPath)
                ]
            )
        }
    }

    private func replaceRelatedTitles(mediaID: String, values: [MediaRelatedTitle]) throws {
        try database.execute("DELETE FROM media_related_titles WHERE media_id = ?", bindings: [.text(mediaID)])
        for value in values {
            try database.execute(
                """
                INSERT OR REPLACE INTO media_related_titles
                  (id, media_id, relation, external_id, title, year, poster_url, overview,
                   rating, popularity, local_media_id, sort_order)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(value.id), .text(mediaID), .text(value.relation), .text(value.externalID),
                    .text(value.title), .optionalInt(value.year), .optionalText(value.posterURL),
                    .optionalText(value.overview), .optionalDouble(Self.normalizedRelatedRating(value.rating)),
                    .optionalDouble(Self.normalizedPopularity(value.popularity)), .optionalText(value.localMediaID),
                    .int(Int64(value.order))
                ]
            )
        }
    }

    private func cleanupOrphanedPeople() throws {
        try database.execute(
            """
            DELETE FROM media_people
            WHERE NOT EXISTS (
              SELECT 1 FROM media_credits WHERE media_credits.person_id = media_people.id
            )
            """
        )
    }

    private static func normalizedCount(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func normalizedArtworkAspectRatio(_ value: Double?) -> Double {
        guard let value, value.isFinite, value > 0, value <= 10 else { return 1.78 }
        return value
    }

    private static func normalizedRelatedRating(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...10).contains(value) else { return nil }
        return value
    }

    private static func normalizedPopularity(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func normalizedWorks(_ values: [MediaPersonWork]) -> [MediaPersonWork] {
        values.map { value in
            var normalized = value
            normalized.popularity = normalizedPopularity(value.popularity)
            return normalized
        }
    }

    private func encodeStrings(_ values: [String]) -> String {
        guard let data = try? encoder.encode(values) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func decodeStrings(_ value: String?) -> [String] {
        guard let value, let data = value.data(using: .utf8) else { return [] }
        return (try? decoder.decode([String].self, from: data)) ?? []
    }

    private func encodeWorks(_ values: [MediaPersonWork]) -> String {
        guard let data = try? encoder.encode(Self.normalizedWorks(values)) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func decodeWorks(_ value: String?) -> [MediaPersonWork] {
        guard let value, let data = value.data(using: .utf8) else { return [] }
        return Self.normalizedWorks((try? decoder.decode([MediaPersonWork].self, from: data)) ?? [])
    }
}
