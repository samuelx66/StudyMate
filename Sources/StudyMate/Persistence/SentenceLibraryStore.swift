import Foundation
import SQLite3

public enum SentenceLibraryError: LocalizedError {
    case libraryUnavailable
    case invalidLibrary
    case database(String)
    case invalidName
    case libraryAlreadyExists
    case defaultLibraryCannotBeDeleted
    case operationInProgress

    public var errorDescription: String? {
        switch self {
        case .libraryUnavailable: return "句库不可用。"
        case .invalidLibrary: return "句库格式无效或版本不受支持。"
        case let .database(message): return "句库读写失败：\(message)"
        case .invalidName: return "请输入有效的句库名称。"
        case .libraryAlreadyExists: return "这个句库已经存在。"
        case .defaultLibraryCannotBeDeleted: return "默认句库不能删除。"
        case .operationInProgress: return "句库正在处理上一项操作，请稍候。"
        }
    }
}

/// `.mablib` 是可携带目录包：manifest.json 保存格式版本，Library.sqlite3
/// 保存可检索字段，Previews/ 保存 JPEG，Media/ 保存每条句子的独立 AAC M4A 片段。
/// 图片、媒体与索引分离，可避免数据库因大对象频繁增删而膨胀；
/// 句库播放不依赖原始音视频文件。
public final class SentenceLibraryStore: @unchecked Sendable {
    public static let shared = SentenceLibraryStore()

    public let rootURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.studymate.sentence-library.store", qos: .utility)
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
                .appendingPathComponent("SentenceLibraries", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    public func listLibraries() -> [SentenceLibraryDescriptor] {
        queue.sync {
            // 旧版句库仍保留在原目录中；首次扫描时原地升级，之后只会看到 v3。
            migrateLegacyLibrariesIfNeededUnlocked()
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
                    $0.version == SentenceLibraryDescriptor.currentFormatVersion
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
        createdBefore: Date? = nil,
        sourceMediaName: String? = nil,
        sortOrder: SentenceLibrarySortOrder = .newestFirst
    ) throws -> [SentenceLibraryEntry] {
        try queue.sync {
            try validateLibrary(id: libraryID)
            return try withDatabase(libraryID: libraryID) { db in
                var clauses: [String] = []
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                // FTS5 trigram 保持中文、英文片段与现有 LIKE 子串搜索的语义；
                // 单个或两个字符没有完整 trigram，仍精确回退到 LIKE。
                let usesFullTextIndex = query.count >= 3
                if !query.isEmpty {
                    if usesFullTextIndex {
                        clauses.append("entries_fts MATCH ?")
                    } else {
                        clauses.append("(original_text LIKE ? ESCAPE '\\' COLLATE NOCASE OR translation LIKE ? ESCAPE '\\' COLLATE NOCASE)")
                    }
                }
                if createdAfter != nil { clauses.append("created_at >= ?") }
                if createdBefore != nil { clauses.append("created_at < ?") }
                if let sourceMediaName,
                   !sourceMediaName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    clauses.append("source_media_name = ?")
                }
                let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
                let orderSQL: String
                switch sortOrder {
                case .newestFirst:
                    orderSQL = "entries.created_at DESC, entries.rowid DESC"
                case .oldestFirst:
                    orderSQL = "entries.created_at ASC, entries.rowid ASC"
                }
                let sql = """
                SELECT entries.id, entries.original_text, entries.translation, entries.note, entries.source_media_name,
                       entries.source_media_path, entries.start_time, entries.end_time, entries.created_at, entries.preview_filename,
                       entries.media_filename
                FROM entries\(usesFullTextIndex ? " JOIN entries_fts ON entries_fts.rowid = entries.rowid" : "")\(whereSQL)
                ORDER BY \(orderSQL);
                """
                var statement: OpaquePointer?
                try prepare(sql, db: db, statement: &statement)
                defer { sqlite3_finalize(statement) }
                var position: Int32 = 1
                if !query.isEmpty {
                    if usesFullTextIndex {
                        // 作为短语传入，特殊字符不会被解释成 MATCH 运算符。
                        let phrase = query.lowercased().replacingOccurrences(of: "\"", with: "\"\"")
                        bind("\"\(phrase)\"", at: position, to: statement); position += 1
                    } else {
                        let escaped = query
                            .replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "%", with: "\\%")
                            .replacingOccurrences(of: "_", with: "\\_")
                        bind("%\(escaped)%", at: position, to: statement); position += 1
                        bind("%\(escaped)%", at: position, to: statement); position += 1
                    }
                }
                if let createdAfter {
                    sqlite3_bind_double(statement, position, createdAfter.timeIntervalSince1970)
                    position += 1
                }
                if let createdBefore {
                    sqlite3_bind_double(statement, position, createdBefore.timeIntervalSince1970)
                    position += 1
                }
                if let sourceMediaName,
                   !sourceMediaName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    bind(sourceMediaName, at: position, to: statement)
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
                        mediaFilename: text(statement, 10),
                        previewFilename: optionalText(statement, 9)
                    ))
                }
                return result
            }
        }
    }

    /// 返回当前句库中所有不重复的来源名称，供来源筛选器使用。
    public func sourceMediaNames(libraryID: UUID) throws -> [String] {
        try queue.sync {
            try validateLibrary(id: libraryID)
            return try withDatabase(libraryID: libraryID) { db in
                var statement: OpaquePointer?
                try prepare(
                    "SELECT DISTINCT source_media_name FROM entries WHERE trim(source_media_name) <> '' ORDER BY source_media_name COLLATE NOCASE ASC;",
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

    public func add(
        entries: [SentenceLibraryEntry],
        previewData: [UUID: Data],
        to libraryID: UUID,
        mediaURLs: [UUID: URL],
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
                    do {
                        try data.write(to: destination, options: .atomic)
                        storedPreviewIDs.insert(id)
                    } catch {
                        throw SentenceLibraryError.database(
                            "预览图写入失败：\(destination.lastPathComponent)（\(error.localizedDescription)）"
                        )
                    }
                }
                for entry in entries {
                    let mediaFilename = entry.mediaFilename
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
                            guard storedMediaFilenames.contains(entry.mediaFilename) else {
                                throw SentenceLibraryError.database("句子媒体片段未完成写入。")
                            }
                            bind(entry.mediaFilename, at: 11, to: statement)
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

    @discardableResult
    public func deleteEntries(ids: Set<UUID>, from libraryID: UUID) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        return try queue.sync {
            try validateLibrary(id: libraryID)
            let oldEntries = try readEntriesUnlocked(libraryID: libraryID, ids: ids)
            try deleteEntriesUnlocked(ids: ids, from: libraryID)
            var cleanupFailures: [String] = []
            for filename in oldEntries.compactMap(\.previewFilename) {
                if let safeFilename = safeFilename(filename) {
                    removeFileIfPresent(
                        previewsURL(for: libraryID).appendingPathComponent(safeFilename),
                        failures: &cleanupFailures
                    )
                }
            }
            for filename in oldEntries.compactMap(\.mediaFilename) {
                if let safeFilename = safeFilename(filename) {
                    removeFileIfPresent(
                        mediaURL(for: libraryID).appendingPathComponent(safeFilename),
                        failures: &cleanupFailures
                    )
                }
            }
            do {
                try touchManifest(libraryID: libraryID)
            } catch {
                // The database deletion is already committed. Surface a
                // cleanup warning instead of reporting the whole operation as
                // failed and leaving the UI with stale entries.
                cleanupFailures.append("句库清单：\(error.localizedDescription)")
            }
            return cleanupFailures
        }
    }

    public func deleteLibrary(id: UUID) throws {
        try queue.sync {
            try validateLibrary(id: id)
            if let descriptor = readManifest(at: packageURL(for: id)), descriptor.isDefault {
                throw SentenceLibraryError.defaultLibraryCannotBeDeleted
            }
            if let db = openDatabases.removeValue(forKey: id) {
                sqlite3_close_v2(db)
            }
            initializedDatabases.remove(id)
            try fileManager.removeItem(at: packageURL(for: id))
        }
    }

    /// 将源句库中选中的句子移动到目标句库。媒体和缩略图先复制到目标包，
    /// 目标索引写入成功后才删除源索引，因此任一步失败都不会造成句子内容丢失。
    @discardableResult
    public func moveEntries(
        ids: Set<UUID>,
        from sourceLibraryID: UUID,
        to destinationLibraryID: UUID,
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        guard sourceLibraryID != destinationLibraryID else {
            throw SentenceLibraryError.database("源句库与目标句库不能相同。")
        }
        return try queue.sync {
            try validateLibrary(id: sourceLibraryID)
            try validateLibrary(id: destinationLibraryID)
            let sourceEntries = try readEntriesUnlocked(libraryID: sourceLibraryID, ids: ids).sorted {
                if $0.createdAt == $1.createdAt {
                    if $0.startTime == $1.startTime { return $0.id.uuidString < $1.id.uuidString }
                    return $0.startTime < $1.startTime
                }
                return $0.createdAt < $1.createdAt
            }
            guard !sourceEntries.isEmpty else { return [] }

            let destinationMediaDirectory = mediaURL(for: destinationLibraryID)
            let destinationPreviewDirectory = previewsURL(for: destinationLibraryID)
            try fileManager.createDirectory(at: destinationMediaDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: destinationPreviewDirectory, withIntermediateDirectories: true)

            let total = max(1, sourceEntries.count)
            var destinationEntries: [SentenceLibraryEntry] = []
            var copiedMedia: [String] = []
            var copiedPreviews: [String] = []
            var sourceDeleted = false
            var cleanupFailures: [String] = []
            do {
                for (offset, sourceEntry) in sourceEntries.enumerated() {
                    guard let sourceMediaFilename = safeFilename(sourceEntry.mediaFilename) else {
                        throw SentenceLibraryError.database("句子媒体文件名无效。")
                    }
                    let sourceMedia = mediaURL(for: sourceLibraryID).appendingPathComponent(sourceMediaFilename)
                    guard fileManager.fileExists(atPath: sourceMedia.path) else {
                        throw SentenceLibraryError.database("源句库缺少句子音频：\(sourceEntry.originalText)")
                    }

                    let destinationID = UUID()
                    let destinationMediaFilename = "\(destinationID.uuidString).m4a"
                    let destinationMedia = destinationMediaDirectory.appendingPathComponent(destinationMediaFilename)
                    try fileManager.copyItem(at: sourceMedia, to: destinationMedia)
                    copiedMedia.append(destinationMediaFilename)

                    var destinationPreviewFilename: String?
                    if let sourcePreviewFilename = sourceEntry.previewFilename,
                       let safePreviewFilename = safeFilename(sourcePreviewFilename) {
                        let sourcePreview = previewsURL(for: sourceLibraryID).appendingPathComponent(safePreviewFilename)
                        if fileManager.fileExists(atPath: sourcePreview.path) {
                            let filename = "\(destinationID.uuidString).jpg"
                            try fileManager.copyItem(at: sourcePreview, to: destinationPreviewDirectory.appendingPathComponent(filename))
                            copiedPreviews.append(filename)
                            destinationPreviewFilename = filename
                        }
                    }

                    let destinationEntry = SentenceLibraryEntry(
                        id: destinationID,
                        originalText: sourceEntry.originalText,
                        translation: sourceEntry.translation,
                        note: sourceEntry.note,
                        sourceMediaName: sourceEntry.sourceMediaName,
                        sourceMediaPath: sourceEntry.sourceMediaPath,
                        startTime: sourceEntry.startTime,
                        endTime: sourceEntry.endTime,
                        createdAt: sourceEntry.createdAt,
                        mediaFilename: destinationMediaFilename,
                        previewFilename: destinationPreviewFilename
                    )
                    destinationEntries.append(destinationEntry)
                    progress(0.35 * Double(offset + 1) / Double(total), "复制句子媒体")
                }

                try insertEntriesUnlocked(destinationEntries, into: destinationLibraryID)
                progress(0.65, "写入目标句库")

                do {
                    try deleteEntriesUnlocked(ids: Set(sourceEntries.map(\.id)), from: sourceLibraryID)
                } catch {
                    // 目标已写入但源删除失败时回滚目标索引与文件，保持“移动”而不是复制。
                    try? deleteEntriesUnlocked(ids: Set(destinationEntries.map(\.id)), from: destinationLibraryID)
                    throw error
                }
                sourceDeleted = true

                for filename in sourceEntries.compactMap(\.previewFilename) {
                    if let safeFilename = safeFilename(filename) {
                        removeFileIfPresent(
                            previewsURL(for: sourceLibraryID).appendingPathComponent(safeFilename),
                            failures: &cleanupFailures
                        )
                    }
                }
                for filename in sourceEntries.compactMap(\.mediaFilename) {
                    if let safeFilename = safeFilename(filename) {
                        removeFileIfPresent(
                            mediaURL(for: sourceLibraryID).appendingPathComponent(safeFilename),
                            failures: &cleanupFailures
                        )
                    }
                }
                do {
                    try touchManifest(libraryID: sourceLibraryID)
                } catch {
                    cleanupFailures.append("源句库清单：\(error.localizedDescription)")
                }
                do {
                    try touchManifest(libraryID: destinationLibraryID)
                } catch {
                    cleanupFailures.append("目标句库清单：\(error.localizedDescription)")
                }
                progress(
                    1,
                    cleanupFailures.isEmpty ? "移动完成" : "移动完成，但部分文件清理失败"
                )
                return cleanupFailures
            } catch {
                if !sourceDeleted {
                    for filename in copiedMedia {
                        try? fileManager.removeItem(at: destinationMediaDirectory.appendingPathComponent(filename))
                    }
                    for filename in copiedPreviews {
                        try? fileManager.removeItem(at: destinationPreviewDirectory.appendingPathComponent(filename))
                    }
                }
                throw error
            }
        }
    }

    public func previewURL(for entry: SentenceLibraryEntry, libraryID: UUID) -> URL? {
        guard let filename = entry.previewFilename else { return nil }
        return previewsURL(for: libraryID).appendingPathComponent(filename)
    }

    public func mediaURL(for entry: SentenceLibraryEntry, libraryID: UUID) -> URL? {
        let filename = entry.mediaFilename
        guard URL(fileURLWithPath: filename).lastPathComponent == filename, !filename.isEmpty else { return nil }
        // Constructing a package-local URL must not synchronously touch disk.
        // Playback/export validates it on their existing background or action path.
        return mediaURL(for: libraryID).appendingPathComponent(filename)
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

    /// 一次性原地迁移 v1/v2 句库。目录、SQLite 文件以及 Media/、Previews/
    /// 中的原始文件都不搬移、不重编码，只升级数据库索引和 manifest 版本。
    /// 这样迁移后仍使用原句库 UUID，已保存的当前句库选择也不会失效。
    private func migrateLegacyLibrariesIfNeededUnlocked() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for packageURL in urls where packageURL.pathExtension.lowercased() == "mablib" {
            guard let legacy = readManifest(at: packageURL),
                  legacy.format == SentenceLibraryDescriptor.formatIdentifier,
                  legacy.version > 0,
                  legacy.version < SentenceLibraryDescriptor.currentFormatVersion else {
                continue
            }
            do {
                try migrateLegacyLibraryUnlocked(legacy, packageURL: packageURL)
            } catch {
                // 保留旧 manifest 以便下次启动重试，绝不因迁移失败删除或覆盖旧数据。
                continue
            }
        }
    }

    private func migrateLegacyLibraryUnlocked(
        _ legacy: SentenceLibraryDescriptor,
        packageURL: URL
    ) throws {
        let databaseURL = packageURL.appendingPathComponent("Library.sqlite3")
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, database != nil else {
            if let database { sqlite3_close_v2(database) }
            throw SentenceLibraryError.libraryUnavailable
        }
        let openedDatabase = database!
        do {
            sqlite3_busy_timeout(openedDatabase, 5_000)
            try createSchema(in: openedDatabase)
            // 将旧 WAL 中的提交合并回主数据库文件，避免迁移完成后遗漏 WAL 数据。
            try execute("PRAGMA wal_checkpoint(TRUNCATE);", in: openedDatabase)
            sqlite3_close_v2(openedDatabase)
            database = nil
            let migrated = SentenceLibraryDescriptor(
                id: legacy.id,
                name: legacy.name,
                createdAt: legacy.createdAt,
                updatedAt: legacy.updatedAt
            )
            try writeManifest(migrated, to: packageURL)
        } catch {
            if let database { sqlite3_close_v2(database) }
            throw error
        }
    }

    private func readManifest(at packageURL: URL) -> SentenceLibraryDescriptor? {
        guard let data = try? Data(contentsOf: packageURL.appendingPathComponent("manifest.json")) else { return nil }
        return try? Self.decoder.decode(SentenceLibraryDescriptor.self, from: data)
    }

    private func validateLibrary(id: UUID) throws {
        guard let descriptor = readManifest(at: packageURL(for: id)),
              descriptor.id == id,
              descriptor.format == SentenceLibraryDescriptor.formatIdentifier,
              descriptor.version == SentenceLibraryDescriptor.currentFormatVersion else {
            throw SentenceLibraryError.invalidLibrary
        }
    }

    private func writeManifest(_ descriptor: SentenceLibraryDescriptor, to packageURL: URL) throws {
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(descriptor)
        try data.write(to: packageURL.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func removeFileIfPresent(_ url: URL, failures: inout [String]) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    private func touchManifest(libraryID: UUID) throws {
        guard var descriptor = readManifest(at: packageURL(for: libraryID)) else {
            throw SentenceLibraryError.invalidLibrary
        }
        descriptor.updatedAt = Date()
        try writeManifest(descriptor, to: packageURL(for: libraryID))
    }

    private func readEntriesUnlocked(libraryID: UUID, ids: Set<UUID>? = nil) throws -> [SentenceLibraryEntry] {
        try withDatabase(libraryID: libraryID) { db in
            var statement: OpaquePointer?
            let sql: String
            if ids == nil {
                sql = """
                SELECT id, original_text, translation, note, source_media_name, source_media_path,
                       start_time, end_time, created_at, preview_filename, media_filename
                FROM entries ORDER BY created_at ASC, rowid ASC;
                """
            } else {
                sql = """
                SELECT id, original_text, translation, note, source_media_name, source_media_path,
                       start_time, end_time, created_at, preview_filename, media_filename
                FROM entries WHERE id = ?;
                """
            }
            try prepare(sql, db: db, statement: &statement)
            defer { sqlite3_finalize(statement) }
            var result: [SentenceLibraryEntry] = []
            if let ids {
                for id in ids {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bind(id.uuidString, at: 1, to: statement)
                    if sqlite3_step(statement) == SQLITE_ROW, let entry = entry(from: statement) {
                        result.append(entry)
                    }
                }
            } else {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let entry = entry(from: statement) { result.append(entry) }
                }
            }
            return result
        }
    }

    private func entry(from statement: OpaquePointer?) -> SentenceLibraryEntry? {
        guard let id = UUID(uuidString: text(statement, 0)) else { return nil }
        return SentenceLibraryEntry(
            id: id,
            originalText: text(statement, 1),
            translation: text(statement, 2),
            note: text(statement, 3),
            sourceMediaName: text(statement, 4),
            sourceMediaPath: text(statement, 5),
            startTime: sqlite3_column_double(statement, 6),
            endTime: sqlite3_column_double(statement, 7),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
            mediaFilename: text(statement, 10),
            previewFilename: optionalText(statement, 9)
        )
    }

    private func deleteEntriesUnlocked(ids: Set<UUID>, from libraryID: UUID) throws {
        guard !ids.isEmpty else { return }
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
    }

    private func insertEntriesUnlocked(_ entries: [SentenceLibraryEntry], into libraryID: UUID) throws {
        guard !entries.isEmpty else { return }
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
                    if let previewFilename = entry.previewFilename {
                        bind(previewFilename, at: 10, to: statement)
                    } else {
                        sqlite3_bind_null(statement, 10)
                    }
                    bind(entry.mediaFilename, at: 11, to: statement)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
                }
                try execute("COMMIT;", in: db)
            } catch {
                try? execute("ROLLBACK;", in: db)
                throw error
            }
        }
    }

    private func safeFilename(_ filename: String) -> String? {
        let candidate = URL(fileURLWithPath: filename).lastPathComponent
        guard !candidate.isEmpty, candidate == filename else { return nil }
        return candidate
    }

    private func withDatabase<T>(libraryID: UUID, operation: (OpaquePointer) throws -> T) throws -> T {
        let db: OpaquePointer
        if let cached = openDatabases[libraryID] {
            db = cached
        } else {
            var newDB: OpaquePointer?
            let path = databaseURL(for: libraryID).path
            guard sqlite3_open_v2(path, &newDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let validDB = newDB else {
                if let newDB { sqlite3_close_v2(newDB) }
                throw SentenceLibraryError.libraryUnavailable
            }
            sqlite3_busy_timeout(validDB, 5_000)
            openDatabases[libraryID] = validDB
            db = validDB
        }
        if !initializedDatabases.contains(libraryID) {
            try createSchema(in: db)
            initializedDatabases.insert(libraryID)
        }
        return try operation(db)
    }

    public func checkpointAllDatabases() {
        queue.async {
            for (_, db) in self.openDatabases {
                _ = try? self.execute("PRAGMA wal_checkpoint(TRUNCATE);", in: db)
            }
        }
    }

    deinit {
        for (_, db) in openDatabases {
            _ = try? execute("PRAGMA wal_checkpoint(TRUNCATE);", in: db)
            sqlite3_close_v2(db)
        }
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
                media_filename TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_entries_created_at ON entries(created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_entries_source_media ON entries(source_media_name);
            \(Self.ftsSchemaSQL)
            PRAGMA user_version=4;
            """, in: db)
        } else if version >= 1 && version <= 3 {
            // v1/v2 的 entries 表与当前字段基本兼容；缺少的新字段只补列，
            // 不改写原有行，也不触碰 Media/ 和 Previews/ 中的文件。
            let columns = try tableColumns(in: db)
            if !columns.contains("id") {
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
                """, in: db)
            } else {
                if !columns.contains("preview_filename") {
                    try execute("ALTER TABLE entries ADD COLUMN preview_filename TEXT;", in: db)
                }
                if !columns.contains("media_filename") {
                    try execute("ALTER TABLE entries ADD COLUMN media_filename TEXT;", in: db)
                }
            }
            try execute("""
            CREATE INDEX IF NOT EXISTS idx_entries_created_at ON entries(created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_entries_source_media ON entries(source_media_name);
            \(Self.ftsSchemaSQL)
            PRAGMA user_version=4;
            """, in: db)
        } else if version != 4 {
            throw SentenceLibraryError.invalidLibrary
        }
    }

    private func tableColumns(in db: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        try prepare("PRAGMA table_info(entries);", db: db, statement: &statement)
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            columns.insert(text(statement, 1))
        }
        return columns
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

    /// 外部内容表避免复制句库其余字段；触发器保证新增、修改和删除时索引
    /// 与主表同一事务保持一致。
    private static let ftsSchemaSQL = """
    CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
        original_text,
        translation,
        content='entries',
        content_rowid='rowid',
        tokenize='trigram case_sensitive 0'
    );
    CREATE TRIGGER IF NOT EXISTS entries_ai AFTER INSERT ON entries BEGIN
        INSERT INTO entries_fts(rowid, original_text, translation)
        VALUES (new.rowid, lower(new.original_text), lower(new.translation));
    END;
    CREATE TRIGGER IF NOT EXISTS entries_ad AFTER DELETE ON entries BEGIN
        INSERT INTO entries_fts(entries_fts, rowid, original_text, translation)
        VALUES ('delete', old.rowid, lower(old.original_text), lower(old.translation));
    END;
    CREATE TRIGGER IF NOT EXISTS entries_au AFTER UPDATE OF original_text, translation ON entries BEGIN
        INSERT INTO entries_fts(entries_fts, rowid, original_text, translation)
        VALUES ('delete', old.rowid, lower(old.original_text), lower(old.translation));
        INSERT INTO entries_fts(rowid, original_text, translation)
        VALUES (new.rowid, lower(new.original_text), lower(new.translation));
    END;
    INSERT INTO entries_fts(rowid, original_text, translation)
        SELECT rowid, lower(original_text), lower(translation) FROM entries
        WHERE rowid NOT IN (SELECT rowid FROM entries_fts);
    """
}
