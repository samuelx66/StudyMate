import Foundation
import SQLite3

public enum VocabularyNotebookError: LocalizedError {
    case notebookUnavailable
    case invalidNotebook
    case database(String)
    case invalidName
    case notebookAlreadyExists
    case defaultNotebookCannotBeDeleted
    case emptyWord

    public var errorDescription: String? {
        switch self {
        case .notebookUnavailable: return "生词本不可用。"
        case .invalidNotebook: return "生词本格式无效或版本不受支持。"
        case let .database(message): return "生词本读写失败：\(message)"
        case .invalidName: return "请输入有效的生词本名称。"
        case .notebookAlreadyExists: return "这个生词本已经存在。"
        case .defaultNotebookCannotBeDeleted: return "默认生词本不能删除。"
        case .emptyWord: return "不能保存空单词。"
        }
    }
}

/// `.mabvocab` 是可携带的生词本包。每个包有独立 SQLite 索引，
/// 与句库数据完全分离，便于后续增加导入导出而不影响句库格式。
public final class VocabularyNotebookStore: @unchecked Sendable {
    private struct PendingMoveJournal: Codable {
        let id: UUID
        let sourceNotebookID: UUID
        let destinationNotebookID: UUID
        let entryIDs: [UUID]
    }

    public static let shared = VocabularyNotebookStore()
    public static let defaultNotebookName = "默认生词本"

    public let rootURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.studymate.vocabulary-notebook.store", qos: .utility)
    private var openDatabases: [UUID: OpaquePointer] = [:]
    private var initializedDatabases: Set<UUID> = []
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.rootURL = support
                .appendingPathComponent("StudyMate", isDirectory: true)
                .appendingPathComponent("VocabularyNotebooks", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    public func listNotebooks() -> [VocabularyNotebookDescriptor] {
        queue.sync {
            recoverPendingMovesUnlocked()
            guard let urls = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return urls
                .filter { $0.pathExtension.lowercased() == "mabvocab" }
                .compactMap(readManifest)
                .filter {
                    $0.format == VocabularyNotebookDescriptor.formatIdentifier &&
                    $0.version == VocabularyNotebookDescriptor.currentFormatVersion
                }
                .sorted { lhs, rhs in
                    if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                    return lhs.updatedAt > rhs.updatedAt
                }
        }
    }

    @discardableResult
    public func createNotebook(name: String) throws -> VocabularyNotebookDescriptor {
        try queue.sync {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw VocabularyNotebookError.invalidName }
            let normalized = trimmed.lowercased()
            if listNotebooksUnlocked().contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }) {
                throw VocabularyNotebookError.notebookAlreadyExists
            }
            let descriptor = VocabularyNotebookDescriptor(name: trimmed)
            let package = packageURL(for: descriptor.id)
            try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
            do {
                try writeManifest(descriptor, to: package)
                try withDatabase(notebookID: descriptor.id) { db in
                    try createSchema(in: db)
                }
            } catch {
                closeDatabaseUnlocked(notebookID: descriptor.id)
                try? fileManager.removeItem(at: package)
                throw error
            }
            return descriptor
        }
    }

    public func entries(
        notebookID: UUID,
        searchText: String = "",
        createdAfter: Date? = nil,
        createdBefore: Date? = nil,
        source: String = "",
        sortOrder: SentenceLibrarySortOrder = .newestFirst
    ) throws -> [VocabularyWordEntry] {
        try queue.sync {
            try validateNotebook(id: notebookID)
            return try withDatabase(notebookID: notebookID) { db in
                var clauses: [String] = []
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !query.isEmpty { clauses.append("word LIKE ? ESCAPE '\\' COLLATE NOCASE") }
                if createdAfter != nil { clauses.append("added_at >= ?") }
                if createdBefore != nil { clauses.append("added_at < ?") }
                if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clauses.append("source = ?") }
                let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
                let orderSQL = sortOrder == .newestFirst
                    ? "added_at DESC, rowid DESC"
                    : "added_at ASC, rowid ASC"
                let sql = """
                SELECT id, word, added_at, example_sentence, source
                FROM entries\(whereSQL)
                ORDER BY \(orderSQL);
                """
                var statement: OpaquePointer?
                try prepare(sql, db: db, statement: &statement)
                defer { sqlite3_finalize(statement) }
                var position: Int32 = 1
                if !query.isEmpty {
                    let escaped = query
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "%", with: "\\%")
                        .replacingOccurrences(of: "_", with: "\\_")
                    bind("%\(escaped)%", at: position, to: statement)
                    position += 1
                }
                if let createdAfter {
                    sqlite3_bind_double(statement, position, createdAfter.timeIntervalSince1970)
                    position += 1
                }
                if let createdBefore {
                    sqlite3_bind_double(statement, position, createdBefore.timeIntervalSince1970)
                    position += 1
                }
                if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    bind(source, at: position, to: statement)
                }
                var result: [VocabularyWordEntry] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let entry = entry(from: statement) { result.append(entry) }
                }
                return result
            }
        }
    }

    public func sourceNames(notebookID: UUID) throws -> [String] {
        try queue.sync {
            try validateNotebook(id: notebookID)
            return try withDatabase(notebookID: notebookID) { db in
                var statement: OpaquePointer?
                try prepare(
                    "SELECT DISTINCT source FROM entries WHERE trim(source) <> '' ORDER BY source COLLATE NOCASE ASC;",
                    db: db,
                    statement: &statement
                )
                defer { sqlite3_finalize(statement) }
                var result: [String] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    let value = text(statement, 0).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { result.append(value) }
                }
                return result
            }
        }
    }

    /// Return only normalized keys for the bookmark toggle state.  Loading the
    /// complete entry rows for every popover click is unnecessarily expensive
    /// for large notebooks.
    public func wordKeys(notebookID: UUID) throws -> Set<String> {
        try queue.sync {
            try validateNotebook(id: notebookID)
            return try withDatabase(notebookID: notebookID) { db in
                var statement: OpaquePointer?
                try prepare("SELECT word_key FROM entries;", db: db, statement: &statement)
                defer { sqlite3_finalize(statement) }
                var result = Set<String>()
                while sqlite3_step(statement) == SQLITE_ROW {
                    let key = text(statement, 0)
                    if !key.isEmpty { result.insert(key) }
                }
                return result
            }
        }
    }

    public func contains(word: String, in notebookID: UUID) throws -> Bool {
        let key = Self.normalizedWord(word)
        guard !key.isEmpty else { return false }
        return try queue.sync {
            try validateNotebook(id: notebookID)
            return try withDatabase(notebookID: notebookID) { db in
                var statement: OpaquePointer?
                try prepare("SELECT 1 FROM entries WHERE word_key = ? LIMIT 1;", db: db, statement: &statement)
                defer { sqlite3_finalize(statement) }
                bind(key, at: 1, to: statement)
                return sqlite3_step(statement) == SQLITE_ROW
            }
        }
    }

    @discardableResult
    public func add(_ entry: VocabularyWordEntry, to notebookID: UUID) throws -> VocabularyWordEntry {
        let trimmedWord = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.normalizedWord(trimmedWord)
        guard !key.isEmpty else { throw VocabularyNotebookError.emptyWord }
        return try queue.sync {
            try validateNotebook(id: notebookID)
            let saved = try withDatabase(notebookID: notebookID) { db in
                let sql = """
                INSERT INTO entries (id, word, word_key, added_at, example_sentence, source)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(word_key) DO UPDATE SET
                    word = excluded.word,
                    example_sentence = excluded.example_sentence,
                    source = excluded.source;
                """
                var statement: OpaquePointer?
                try prepare(sql, db: db, statement: &statement)
                defer { sqlite3_finalize(statement) }
                bind(entry.id.uuidString, at: 1, to: statement)
                bind(trimmedWord, at: 2, to: statement)
                bind(key, at: 3, to: statement)
                sqlite3_bind_double(statement, 4, entry.addedAt.timeIntervalSince1970)
                bind(entry.exampleSentence, at: 5, to: statement)
                bind(entry.source, at: 6, to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
                return try entryForWordUnlocked(key: key, db: db) ?? entry
            }
            // The entry transaction is already committed. Manifest ordering is
            // auxiliary metadata, so a write failure here must not report a
            // failed add or roll back a successfully stored word.
            try? touchManifestUnlocked(notebookID: notebookID)
            return saved
        }
    }

    /// Toggle one word in a single serialized transaction.  This avoids the
    /// contains -> add/remove race and saves one full SQLite round trip per
    /// bookmark click.
    @discardableResult
    public func toggle(_ entry: VocabularyWordEntry, in notebookID: UUID) throws -> Bool {
        let trimmedWord = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.normalizedWord(trimmedWord)
        guard !key.isEmpty else { throw VocabularyNotebookError.emptyWord }
        return try queue.sync {
            try validateNotebook(id: notebookID)
            return try withDatabase(notebookID: notebookID) { db in
                try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
                do {
                    var deleteStatement: OpaquePointer?
                    try prepare("DELETE FROM entries WHERE word_key = ?;", db: db, statement: &deleteStatement)
                    defer { sqlite3_finalize(deleteStatement) }
                    bind(key, at: 1, to: deleteStatement)
                    guard sqlite3_step(deleteStatement) == SQLITE_DONE else { throw databaseError(db) }
                    if sqlite3_changes(db) > 0 {
                        try execute("COMMIT;", in: db)
                        try? touchManifestUnlocked(notebookID: notebookID)
                        return false
                    }

                    var insertStatement: OpaquePointer?
                    try prepare(
                        "INSERT INTO entries (id, word, word_key, added_at, example_sentence, source) VALUES (?, ?, ?, ?, ?, ?);",
                        db: db,
                        statement: &insertStatement
                    )
                    defer { sqlite3_finalize(insertStatement) }
                    bind(entry.id.uuidString, at: 1, to: insertStatement)
                    bind(trimmedWord, at: 2, to: insertStatement)
                    bind(key, at: 3, to: insertStatement)
                    sqlite3_bind_double(insertStatement, 4, entry.addedAt.timeIntervalSince1970)
                    bind(entry.exampleSentence, at: 5, to: insertStatement)
                    bind(entry.source, at: 6, to: insertStatement)
                    guard sqlite3_step(insertStatement) == SQLITE_DONE else { throw databaseError(db) }
                    try execute("COMMIT;", in: db)
                    try? touchManifestUnlocked(notebookID: notebookID)
                    return true
                } catch {
                    try? execute("ROLLBACK;", in: db)
                    throw error
                }
            }
        }
    }

    @discardableResult
    public func remove(word: String, from notebookID: UUID) throws -> Bool {
        let key = Self.normalizedWord(word)
        guard !key.isEmpty else { return false }
        return try queue.sync {
            try validateNotebook(id: notebookID)
            return try withDatabase(notebookID: notebookID) { db in
                var statement: OpaquePointer?
                try prepare("DELETE FROM entries WHERE word_key = ?;", db: db, statement: &statement)
                defer { sqlite3_finalize(statement) }
                bind(key, at: 1, to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
                let changed = sqlite3_changes(db) > 0
                if changed { try? touchManifestUnlocked(notebookID: notebookID) }
                return changed
            }
        }
    }

    @discardableResult
    public func deleteEntries(ids: Set<UUID>, from notebookID: UUID) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try queue.sync {
            try validateNotebook(id: notebookID)
            return try withDatabase(notebookID: notebookID) { db in
                try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
                do {
                    var statement: OpaquePointer?
                    try prepare("DELETE FROM entries WHERE id = ?;", db: db, statement: &statement)
                    defer { sqlite3_finalize(statement) }
                    var changed = 0
                    for id in ids {
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        bind(id.uuidString, at: 1, to: statement)
                        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
                        changed += Int(sqlite3_changes(db))
                    }
                    try execute("COMMIT;", in: db)
                    if changed > 0 { try? touchManifestUnlocked(notebookID: notebookID) }
                    return changed
                } catch {
                    try? execute("ROLLBACK;", in: db)
                    throw error
                }
            }
        }
    }

    /// 目标生词本中如果已有相同单词，则保留目标条目并从源本移除源条目，
    /// 这样“移动”不会制造重复，也不会因为唯一约束导致用户操作失败。
    @discardableResult
    public func moveEntries(
        ids: Set<UUID>,
        from sourceNotebookID: UUID,
        to destinationNotebookID: UUID
    ) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        guard sourceNotebookID != destinationNotebookID else {
            throw VocabularyNotebookError.database("源生词本与目标生词本不能相同。")
        }
        return try queue.sync {
            try validateNotebook(id: sourceNotebookID)
            try validateNotebook(id: destinationNotebookID)
            let sourceEntries = try readEntriesUnlocked(ids: ids, notebookID: sourceNotebookID)
            guard !sourceEntries.isEmpty else { return 0 }

            let journal = PendingMoveJournal(
                id: UUID(),
                sourceNotebookID: sourceNotebookID,
                destinationNotebookID: destinationNotebookID,
                entryIDs: sourceEntries.map(\.id)
            )
            let journalURL = pendingMoveURL(for: journal.id)
            try writePendingMoveJournal(journal, to: journalURL)

            let insertedIDs: [UUID]
            do {
                insertedIDs = try withDatabase(notebookID: destinationNotebookID) { db in
                    try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
                    do {
                        let sql = """
                        INSERT INTO entries (id, word, word_key, added_at, example_sentence, source)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(word_key) DO NOTHING;
                        """
                        var statement: OpaquePointer?
                        try prepare(sql, db: db, statement: &statement)
                        defer { sqlite3_finalize(statement) }
                        var insertedIDs: [UUID] = []
                        for sourceEntry in sourceEntries {
                            sqlite3_reset(statement)
                            sqlite3_clear_bindings(statement)
                            bind(sourceEntry.id.uuidString, at: 1, to: statement)
                            bind(sourceEntry.word, at: 2, to: statement)
                            bind(Self.normalizedWord(sourceEntry.word), at: 3, to: statement)
                            sqlite3_bind_double(statement, 4, sourceEntry.addedAt.timeIntervalSince1970)
                            bind(sourceEntry.exampleSentence, at: 5, to: statement)
                            bind(sourceEntry.source, at: 6, to: statement)
                            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
                            if sqlite3_changes(db) > 0 { insertedIDs.append(sourceEntry.id) }
                        }
                        try execute("COMMIT;", in: db)
                        return insertedIDs
                    } catch {
                        try? execute("ROLLBACK;", in: db)
                        throw error
                    }
                }
            } catch {
                try? fileManager.removeItem(at: journalURL)
                throw error
            }

            do {
                let deletedCount = try deleteEntriesUnlocked(ids: ids, notebookID: sourceNotebookID)
                if deletedCount > 0 {
                    try? touchManifestUnlocked(notebookID: sourceNotebookID)
                    try? touchManifestUnlocked(notebookID: destinationNotebookID)
                }
                try? fileManager.removeItem(at: journalURL)
                return deletedCount
            } catch {
                // The two notebooks are independent SQLite packages.  If the
                // source deletion fails after the destination commit, remove
                // only rows inserted by this operation so the source remains
                // authoritative and a retry cannot silently duplicate data.
                if !insertedIDs.isEmpty {
                    do {
                        _ = try deleteEntriesUnlocked(ids: Set(insertedIDs), notebookID: destinationNotebookID)
                        try? fileManager.removeItem(at: journalURL)
                    } catch {
                        throw VocabularyNotebookError.database(
                            "移动失败，且无法回滚目标生词本新增记录：\(error.localizedDescription)"
                        )
                    }
                }
                throw error
            }
        }
    }

    public func deleteNotebook(id: UUID) throws {
        try queue.sync {
            try validateNotebook(id: id)
            if let descriptor = readManifest(at: packageURL(for: id)), descriptor.isDefault {
                throw VocabularyNotebookError.defaultNotebookCannotBeDeleted
            }
            if let db = openDatabases.removeValue(forKey: id) { sqlite3_close_v2(db) }
            initializedDatabases.remove(id)
            try fileManager.removeItem(at: packageURL(for: id))
        }
    }

    public func packageURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathExtension("mabvocab")
    }

    public static func normalizedWord(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private func listNotebooksUnlocked() -> [VocabularyNotebookDescriptor] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension.lowercased() == "mabvocab" }
            .compactMap(readManifest)
            .filter {
                $0.format == VocabularyNotebookDescriptor.formatIdentifier &&
                $0.version == VocabularyNotebookDescriptor.currentFormatVersion
            }
    }

    private func readEntriesUnlocked(ids: Set<UUID>, notebookID: UUID) throws -> [VocabularyWordEntry] {
        try withDatabase(notebookID: notebookID) { db in
            var statement: OpaquePointer?
            try prepare(
                "SELECT id, word, added_at, example_sentence, source FROM entries WHERE id = ?;",
                db: db,
                statement: &statement
            )
            defer { sqlite3_finalize(statement) }
            var result: [VocabularyWordEntry] = []
            for id in ids {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(id.uuidString, at: 1, to: statement)
                if sqlite3_step(statement) == SQLITE_ROW, let value = entry(from: statement) {
                    result.append(value)
                }
            }
            return result
        }
    }

    private func deleteEntriesUnlocked(ids: Set<UUID>, notebookID: UUID) throws -> Int {
        try withDatabase(notebookID: notebookID) { db in
            try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
            do {
                var statement: OpaquePointer?
                try prepare("DELETE FROM entries WHERE id = ?;", db: db, statement: &statement)
                defer { sqlite3_finalize(statement) }
                var changed = 0
                for id in ids {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bind(id.uuidString, at: 1, to: statement)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
                    changed += Int(sqlite3_changes(db))
                }
                try execute("COMMIT;", in: db)
                return changed
            } catch {
                try? execute("ROLLBACK;", in: db)
                throw error
            }
        }
    }

    private func entryForWordUnlocked(key: String, db: OpaquePointer) throws -> VocabularyWordEntry? {
        var statement: OpaquePointer?
        try prepare(
            "SELECT id, word, added_at, example_sentence, source FROM entries WHERE word_key = ? LIMIT 1;",
            db: db,
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return entry(from: statement)
    }

    private func entry(from statement: OpaquePointer?) -> VocabularyWordEntry? {
        guard let id = UUID(uuidString: text(statement, 0)) else { return nil }
        return VocabularyWordEntry(
            id: id,
            word: text(statement, 1),
            addedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            exampleSentence: text(statement, 3),
            source: text(statement, 4)
        )
    }

    private func validateNotebook(id: UUID) throws {
        guard let descriptor = readManifest(at: packageURL(for: id)),
              descriptor.id == id,
              descriptor.format == VocabularyNotebookDescriptor.formatIdentifier,
              descriptor.version == VocabularyNotebookDescriptor.currentFormatVersion else {
            throw VocabularyNotebookError.invalidNotebook
        }
    }

    private func readManifest(at package: URL) -> VocabularyNotebookDescriptor? {
        guard let data = try? Data(contentsOf: package.appendingPathComponent("manifest.json")) else { return nil }
        return try? Self.decoder.decode(VocabularyNotebookDescriptor.self, from: data)
    }

    private func writeManifest(_ descriptor: VocabularyNotebookDescriptor, to package: URL) throws {
        try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
        try Self.encoder.encode(descriptor).write(to: package.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func touchManifestUnlocked(notebookID: UUID) throws {
        let package = packageURL(for: notebookID)
        guard var descriptor = readManifest(at: package) else {
            throw VocabularyNotebookError.invalidNotebook
        }
        descriptor.updatedAt = Date()
        try writeManifest(descriptor, to: package)
    }

    private func pendingMoveURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(".move-(id.uuidString).json")
    }

    private func writePendingMoveJournal(_ journal: PendingMoveJournal, to url: URL) throws {
        let data = try Self.encoder.encode(journal)
        try data.write(to: url, options: .atomic)
    }

    /// Reconcile moves interrupted between the two notebook packages.  A
    /// journal is intentionally created before the destination commit. For
    /// each entry, source-present/destination-present means a pending copy
    /// and is rolled back; source-missing/destination-present means the move
    /// completed and only the journal needs cleanup.
    private func recoverPendingMovesUnlocked() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for url in urls where url.lastPathComponent.hasPrefix(".move-") &&
            url.pathExtension.caseInsensitiveCompare("json") == .orderedSame {
            guard let data = try? Data(contentsOf: url),
                  let journal = try? Self.decoder.decode(PendingMoveJournal.self, from: data) else {
                continue
            }
            do {
                let sourceIDs = Set(try readEntriesUnlocked(ids: Set(journal.entryIDs), notebookID: journal.sourceNotebookID).map(\.id))
                let destinationIDs = Set(try readEntriesUnlocked(ids: Set(journal.entryIDs), notebookID: journal.destinationNotebookID).map(\.id))
                var rollbackIDs = Set<UUID>()
                var hasUnrecoverableEntry = false
                for id in journal.entryIDs {
                    if sourceIDs.contains(id), destinationIDs.contains(id) {
                        rollbackIDs.insert(id)
                    } else if !sourceIDs.contains(id), !destinationIDs.contains(id) {
                        hasUnrecoverableEntry = true
                    }
                }
                if !rollbackIDs.isEmpty {
                    _ = try deleteEntriesUnlocked(ids: rollbackIDs, notebookID: journal.destinationNotebookID)
                }
                if !hasUnrecoverableEntry {
                    try? fileManager.removeItem(at: url)
                }
            } catch {
                // Keep the journal for the next startup if either package is
                // temporarily unavailable or its database is locked.
            }
        }
    }

    private func closeDatabaseUnlocked(notebookID: UUID) {
        if let db = openDatabases.removeValue(forKey: notebookID) {
            sqlite3_close_v2(db)
        }
        initializedDatabases.remove(notebookID)
    }

    private func databaseURL(for id: UUID) -> URL {
        packageURL(for: id).appendingPathComponent("Vocabulary.sqlite3")
    }

    private func withDatabase<T>(notebookID: UUID, operation: (OpaquePointer) throws -> T) throws -> T {
        let db: OpaquePointer
        if let cached = openDatabases[notebookID] {
            db = cached
        } else {
            var newDB: OpaquePointer?
            let result = sqlite3_open_v2(
                databaseURL(for: notebookID).path,
                &newDB,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard result == SQLITE_OK, let validDB = newDB else {
                if let newDB { sqlite3_close_v2(newDB) }
                throw VocabularyNotebookError.notebookUnavailable
            }
            sqlite3_busy_timeout(validDB, 5_000)
            openDatabases[notebookID] = validDB
            db = validDB
        }
        if !initializedDatabases.contains(notebookID) {
            try createSchema(in: db)
            initializedDatabases.insert(notebookID)
        }
        return try operation(db)
    }

    private func createSchema(in db: OpaquePointer) throws {
        try execute("PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL;", in: db)
        var versionStatement: OpaquePointer?
        try prepare("PRAGMA user_version;", db: db, statement: &versionStatement)
        defer { sqlite3_finalize(versionStatement) }
        let version = sqlite3_step(versionStatement) == SQLITE_ROW
            ? sqlite3_column_int(versionStatement, 0)
            : 0
        guard version == 0 || version == VocabularyNotebookDescriptor.currentFormatVersion else {
            throw VocabularyNotebookError.invalidNotebook
        }
        if version == 0 {
            try execute("""
            CREATE TABLE IF NOT EXISTS entries (
                id TEXT PRIMARY KEY NOT NULL,
                word TEXT NOT NULL,
                word_key TEXT NOT NULL UNIQUE,
                added_at REAL NOT NULL,
                example_sentence TEXT NOT NULL DEFAULT '',
                source TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS idx_vocabulary_entries_added_at ON entries(added_at DESC);
            CREATE INDEX IF NOT EXISTS idx_vocabulary_entries_source ON entries(source);
            PRAGMA user_version=1;
            """, in: db)
        }
    }

    private func prepare(_ sql: String, db: OpaquePointer, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError(db) }
    }

    private func execute(_ sql: String, in db: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            throw VocabularyNotebookError.database(message)
        }
    }

    private func databaseError(_ db: OpaquePointer) -> VocabularyNotebookError {
        .database(String(cString: sqlite3_errmsg(db)))
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    deinit {
        for (_, db) in openDatabases {
            _ = try? execute("PRAGMA wal_checkpoint(TRUNCATE);", in: db)
            sqlite3_close_v2(db)
        }
    }
}
