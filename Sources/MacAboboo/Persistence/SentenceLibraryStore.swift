import Foundation
import SQLite3

public enum SentenceLibraryError: LocalizedError {
    case libraryUnavailable
    case invalidLibrary
    case database(String)
    case invalidName
    case libraryAlreadyExists

    public var errorDescription: String? {
        switch self {
        case .libraryUnavailable: return "句库不可用。"
        case .invalidLibrary: return "句库格式无效或版本不受支持。"
        case let .database(message): return "句库读写失败：\(message)"
        case .invalidName: return "请输入有效的句库名称。"
        case .libraryAlreadyExists: return "这个句库已经存在。"
        }
    }
}

/// `.mablib` 是可携带目录包：manifest.json 保存格式版本，Library.sqlite3
/// 保存可检索字段，Previews/ 保存 JPEG，Media/ 保存每条句子的独立 AAC M4A 片段。
/// 图片、媒体与索引分离，可避免数据库因大对象频繁增删而膨胀；整个目录包复制、
/// 导出或导入后，句库播放不再依赖原始音视频文件。
public final class SentenceLibraryStore: @unchecked Sendable {
    public static let shared = SentenceLibraryStore()

    public let rootURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.macaboboo.sentence-library.store", qos: .utility)
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.rootURL = support
                .appendingPathComponent("MacAboboo", isDirectory: true)
                .appendingPathComponent("SentenceLibraries", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    public func listLibraries() -> [SentenceLibraryDescriptor] {
        queue.sync {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return urls
                .filter { $0.pathExtension.lowercased() == "mablib" }
                .compactMap(readManifest)
                .filter {
                    $0.format == SentenceLibraryDescriptor.formatIdentifier &&
                    $0.version <= SentenceLibraryDescriptor.currentFormatVersion
                }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    @discardableResult
    public func createLibrary(name: String) throws -> SentenceLibraryDescriptor {
        try queue.sync {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw SentenceLibraryError.invalidName }
            let descriptor = SentenceLibraryDescriptor(name: trimmed)
            let packageURL = packageURL(for: descriptor.id)
            try fileManager.createDirectory(at: previewsURL(for: descriptor.id), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: mediaURL(for: descriptor.id), withIntermediateDirectories: true)
            try writeManifest(descriptor, to: packageURL)
            try withDatabase(libraryID: descriptor.id) { db in
                try createSchema(in: db)
            }
            return descriptor
        }
    }

    public func entries(
        libraryID: UUID,
        searchText: String = "",
        createdAfter: Date? = nil,
        createdBefore: Date? = nil
    ) throws -> [SentenceLibraryEntry] {
        try queue.sync {
            try validateLibrary(id: libraryID)
            return try withDatabase(libraryID: libraryID) { db in
                var clauses: [String] = []
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !query.isEmpty {
                    clauses.append("(original_text LIKE ? ESCAPE '\\' COLLATE NOCASE OR translation LIKE ? ESCAPE '\\' COLLATE NOCASE)")
                }
                if createdAfter != nil { clauses.append("created_at >= ?") }
                if createdBefore != nil { clauses.append("created_at < ?") }
                let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
                let sql = """
                SELECT id, original_text, translation, note, source_media_name,
                       source_media_path, start_time, end_time, created_at, preview_filename,
                       media_filename
                FROM entries\(whereSQL)
                ORDER BY created_at DESC, rowid DESC;
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
                    bind("%\(escaped)%", at: position, to: statement); position += 1
                    bind("%\(escaped)%", at: position, to: statement); position += 1
                }
                if let createdAfter {
                    sqlite3_bind_double(statement, position, createdAfter.timeIntervalSince1970)
                    position += 1
                }
                if let createdBefore {
                    sqlite3_bind_double(statement, position, createdBefore.timeIntervalSince1970)
                }
                var result: [SentenceLibraryEntry] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let id = UUID(uuidString: text(statement, 0)) else { continue }
                    result.append(SentenceLibraryEntry(
                        id: id,
                        originalText: text(statement, 1),
                        translation: text(statement, 2),
                        note: text(statement, 3),
                        sourceMediaName: text(statement, 4),
                        sourceMediaPath: text(statement, 5),
                        startTime: sqlite3_column_double(statement, 6),
                        endTime: sqlite3_column_double(statement, 7),
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
                        previewFilename: optionalText(statement, 9),
                        mediaFilename: optionalText(statement, 10)
                    ))
                }
                return result
            }
        }
    }

    public func add(
        entries: [SentenceLibraryEntry],
        previewData: [UUID: Data],
        to libraryID: UUID,
        mediaURLs: [UUID: URL] = [:],
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) throws {
        guard !entries.isEmpty else { return }
        try queue.sync {
            try validateLibrary(id: libraryID)
            let previewDirectory = previewsURL(for: libraryID)
            let mediaDirectory = mediaURL(for: libraryID)
            try fileManager.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            var storedPreviewIDs: Set<UUID> = []
            var storedMediaFilenames: Set<String> = []
            do {
                for (id, data) in previewData {
                    let destination = previewDirectory.appendingPathComponent("\(id.uuidString).jpg")
                    if (try? data.write(to: destination, options: .atomic)) != nil {
                        storedPreviewIDs.insert(id)
                    }
                }
                for entry in entries {
                    guard let mediaFilename = entry.mediaFilename else { continue }
                    guard let sourceURL = mediaURLs[entry.id], fileManager.fileExists(atPath: sourceURL.path) else {
                        throw SentenceLibraryError.database("缺少句子媒体片段：\(mediaFilename)")
                    }
                    let safeFilename = URL(fileURLWithPath: mediaFilename).lastPathComponent
                    guard safeFilename == mediaFilename, !safeFilename.isEmpty else {
                        throw SentenceLibraryError.database("句子媒体文件名无效。")
                    }
                    let destination = mediaDirectory.appendingPathComponent(safeFilename)
                    try fileManager.copyItem(at: sourceURL, to: destination)
                    storedMediaFilenames.insert(safeFilename)
                }
            } catch {
                for id in storedPreviewIDs {
                    try? fileManager.removeItem(at: previewDirectory.appendingPathComponent("\(id.uuidString).jpg"))
                }
                for filename in storedMediaFilenames {
                    try? fileManager.removeItem(at: mediaDirectory.appendingPathComponent(filename))
                }
                throw error
            }
            progress(0.85)
            do {
                try withDatabase(libraryID: libraryID) { db in
                    try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
                    do {
                        let sql = """
                        INSERT INTO entries (
                            id, original_text, translation, note, source_media_name,
                            source_media_path, start_time, end_time, created_at, preview_filename,
                            media_filename
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                        """
                        var statement: OpaquePointer?
                        try prepare(sql, db: db, statement: &statement)
                        defer { sqlite3_finalize(statement) }
                        for entry in entries {
                            sqlite3_reset(statement)
                            sqlite3_clear_bindings(statement)
                            bind(entry.id.uuidString, at: 1, to: statement)
                            bind(entry.originalText, at: 2, to: statement)
                            bind(entry.translation, at: 3, to: statement)
                            bind(entry.note, at: 4, to: statement)
                            bind(entry.sourceMediaName, at: 5, to: statement)
                            bind(entry.sourceMediaPath, at: 6, to: statement)
                            sqlite3_bind_double(statement, 7, entry.startTime)
                            sqlite3_bind_double(statement, 8, entry.endTime)
                            sqlite3_bind_double(statement, 9, entry.createdAt.timeIntervalSince1970)
                            if storedPreviewIDs.contains(entry.id), let filename = entry.previewFilename {
                                bind(filename, at: 10, to: statement)
                            } else {
                                sqlite3_bind_null(statement, 10)
                            }
                            if storedMediaFilenames.contains(entry.mediaFilename ?? ""), let filename = entry.mediaFilename {
                                bind(filename, at: 11, to: statement)
                            } else {
                                sqlite3_bind_null(statement, 11)
                            }
                            guard sqlite3_step(statement) == SQLITE_DONE else {
                                throw databaseError(db)
                            }
                        }
                        try execute("COMMIT;", in: db)
                    } catch {
                        try? execute("ROLLBACK;", in: db)
                        throw error
                    }
                }
            } catch {
                for id in storedPreviewIDs {
                    try? fileManager.removeItem(at: previewDirectory.appendingPathComponent("\(id.uuidString).jpg"))
                }
                for filename in storedMediaFilenames {
                    try? fileManager.removeItem(at: mediaDirectory.appendingPathComponent(filename))
                }
                throw error
            }
            progress(1)
            try touchManifest(libraryID: libraryID)
        }
    }

    public func deleteEntries(ids: Set<UUID>, from libraryID: UUID) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            try validateLibrary(id: libraryID)
            let oldEntries = try entriesUnlocked(libraryID: libraryID, ids: ids)
            try withDatabase(libraryID: libraryID) { db in
                try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
                do {
                    var statement: OpaquePointer?
                    try prepare("DELETE FROM entries WHERE id = ?;", db: db, statement: &statement)
                    defer { sqlite3_finalize(statement) }
                    for id in ids {
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        bind(id.uuidString, at: 1, to: statement)
                        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
                    }
                    try execute("COMMIT;", in: db)
                } catch {
                    try? execute("ROLLBACK;", in: db)
                    throw error
                }
            }
            for filename in oldEntries.compactMap(\.previewFilename) {
                try? fileManager.removeItem(at: previewsURL(for: libraryID).appendingPathComponent(filename))
            }
            for filename in oldEntries.compactMap(\.mediaFilename) {
                try? fileManager.removeItem(at: mediaURL(for: libraryID).appendingPathComponent(filename))
            }
            try touchManifest(libraryID: libraryID)
        }
    }

    public func exportLibrary(id: UUID, to destinationURL: URL) throws {
        try queue.sync {
            try validateLibrary(id: id)
            let source = packageURL(for: id)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: source, to: destinationURL)
        }
    }

    @discardableResult
    public func importLibrary(from sourceURL: URL) throws -> SentenceLibraryDescriptor {
        try queue.sync {
            guard let descriptor = readManifest(at: sourceURL),
                  descriptor.format == SentenceLibraryDescriptor.formatIdentifier,
                  descriptor.version <= SentenceLibraryDescriptor.currentFormatVersion,
                  fileManager.fileExists(atPath: sourceURL.appendingPathComponent("Library.sqlite3").path) else {
                throw SentenceLibraryError.invalidLibrary
            }
            let destination = packageURL(for: descriptor.id)
            if fileManager.fileExists(atPath: destination.path) {
                try validateLibrary(id: descriptor.id)
                return readManifest(at: destination) ?? descriptor
            }
            do {
                try fileManager.copyItem(at: sourceURL, to: destination)
                try validateLibrary(id: descriptor.id)
                try withDatabase(libraryID: descriptor.id) { _ in () }
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
            return descriptor
        }
    }

    public func deleteLibrary(id: UUID) throws {
        try queue.sync {
            try validateLibrary(id: id)
            try fileManager.removeItem(at: packageURL(for: id))
        }
    }

    public func previewURL(for entry: SentenceLibraryEntry, libraryID: UUID) -> URL? {
        guard let filename = entry.previewFilename else { return nil }
        return previewsURL(for: libraryID).appendingPathComponent(filename)
    }

    public func mediaURL(for entry: SentenceLibraryEntry, libraryID: UUID) -> URL? {
        guard let filename = entry.mediaFilename else { return nil }
        guard URL(fileURLWithPath: filename).lastPathComponent == filename, !filename.isEmpty else { return nil }
        let url = mediaURL(for: libraryID).appendingPathComponent(filename)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    public func packageURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathExtension("mablib")
    }

    private func previewsURL(for id: UUID) -> URL {
        packageURL(for: id).appendingPathComponent("Previews", isDirectory: true)
    }

    private func mediaURL(for id: UUID) -> URL {
        packageURL(for: id).appendingPathComponent("Media", isDirectory: true)
    }

    private func databaseURL(for id: UUID) -> URL {
        packageURL(for: id).appendingPathComponent("Library.sqlite3")
    }

    private func manifestURL(for id: UUID) -> URL {
        packageURL(for: id).appendingPathComponent("manifest.json")
    }

    private func readManifest(at packageURL: URL) -> SentenceLibraryDescriptor? {
        guard let data = try? Data(contentsOf: packageURL.appendingPathComponent("manifest.json")) else { return nil }
        return try? Self.decoder.decode(SentenceLibraryDescriptor.self, from: data)
    }

    private func validateLibrary(id: UUID) throws {
        guard let descriptor = readManifest(at: packageURL(for: id)),
              descriptor.id == id,
              descriptor.format == SentenceLibraryDescriptor.formatIdentifier,
              descriptor.version <= SentenceLibraryDescriptor.currentFormatVersion else {
            throw SentenceLibraryError.invalidLibrary
        }
    }

    private func writeManifest(_ descriptor: SentenceLibraryDescriptor, to packageURL: URL) throws {
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(descriptor)
        try data.write(to: packageURL.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func touchManifest(libraryID: UUID) throws {
        guard var descriptor = readManifest(at: packageURL(for: libraryID)) else {
            throw SentenceLibraryError.invalidLibrary
        }
        descriptor.updatedAt = Date()
        try writeManifest(descriptor, to: packageURL(for: libraryID))
    }

    private func entriesUnlocked(libraryID: UUID, ids: Set<UUID>) throws -> [SentenceLibraryEntry] {
        try withDatabase(libraryID: libraryID) { db in
            var statement: OpaquePointer?
            try prepare("SELECT id, preview_filename, media_filename FROM entries WHERE id = ?;", db: db, statement: &statement)
            defer { sqlite3_finalize(statement) }
            var result: [SentenceLibraryEntry] = []
            for id in ids {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(id.uuidString, at: 1, to: statement)
                if sqlite3_step(statement) == SQLITE_ROW {
                    result.append(SentenceLibraryEntry(
                        id: id,
                        originalText: "", translation: "", sourceMediaName: "", sourceMediaPath: "",
                        startTime: 0, endTime: 0.05,
                        previewFilename: optionalText(statement, 1),
                        mediaFilename: optionalText(statement, 2)
                    ))
                }
            }
            return result
        }
    }

    private func withDatabase<T>(libraryID: UUID, operation: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let path = databaseURL(for: libraryID).path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close_v2(db) }
            throw SentenceLibraryError.libraryUnavailable
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 5_000)
        try createSchema(in: db)
        return try operation(db)
    }

    private func createSchema(in db: OpaquePointer) throws {
        try execute("PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL;", in: db)
        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &versionStatement, nil) == SQLITE_OK else {
            throw databaseError(db)
        }
        defer { sqlite3_finalize(versionStatement) }
        let version: Int32
        if sqlite3_step(versionStatement) == SQLITE_ROW {
            version = sqlite3_column_int(versionStatement, 0)
        } else {
            version = 0
        }
        if version == 0 {
            try execute("""
            CREATE TABLE IF NOT EXISTS entries (
                id TEXT PRIMARY KEY NOT NULL,
                original_text TEXT NOT NULL DEFAULT '',
                translation TEXT NOT NULL DEFAULT '',
                note TEXT NOT NULL DEFAULT '',
                source_media_name TEXT NOT NULL DEFAULT '',
                source_media_path TEXT NOT NULL DEFAULT '',
                start_time REAL NOT NULL,
                end_time REAL NOT NULL,
                created_at REAL NOT NULL,
                preview_filename TEXT,
                media_filename TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_entries_created_at ON entries(created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_entries_source_media ON entries(source_media_name);
            PRAGMA user_version=2;
            """, in: db)
        } else if version == 1 {
            try execute("ALTER TABLE entries ADD COLUMN media_filename TEXT; PRAGMA user_version=2;", in: db)
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
            throw SentenceLibraryError.database(message)
        }
    }

    private func databaseError(_ db: OpaquePointer) -> SentenceLibraryError {
        .database(String(cString: sqlite3_errmsg(db)))
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let value = text(statement, index)
        return value.isEmpty ? nil : value
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
}
