import Foundation
import SQLite3
import AVFoundation
#if canImport(StudyMatePackage)
import StudyMatePackage
#endif

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

public struct StudyMateLearningPackageImportReport: Equatable, Sendable {
    public let added: Int
    public let updated: Int
    public let skipped: Int

    public init(added: Int, updated: Int, skipped: Int) {
        self.added = added
        self.updated = updated
        self.skipped = skipped
    }
}

/// `.mablib` 是可携带原生学习包：manifest.json 保存格式版本与会话状态，Library.sqlite3
/// 保存检索字段与深层学习元数据，Previews/ 保存 JPEG，Media/ 保存每条句子的独立 AAC M4A 片段。
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

    public static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        if let ubiquitousURL = fileManager.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("SentenceLibraries", isDirectory: true) {
            return ubiquitousURL
        }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("StudyMate", isDirectory: true)
            .appendingPathComponent("SentenceLibraries", isDirectory: true)
    }

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
            migrateLegacyLibrariesIfNeededUnlocked()
            guard let urls = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }
            for url in urls where url.pathExtension.lowercased() == "mablib" {
                let contentURL = url.appendingPathComponent("content.json")
                if !fileManager.fileExists(atPath: contentURL.path),
                   let desc = readManifest(at: url) {
                    syncContentJSONUnlocked(libraryID: desc.id)
                }
            }
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
            syncContentJSONUnlocked(libraryID: descriptor.id)
            return descriptor
        }
    }

    public func entries(
        libraryID: UUID,
        searchText: String = "",
        createdAfter: Date? = nil,
        createdBefore: Date? = nil,
        sourceMediaName: String? = nil,
        typeFilter: SentenceLibraryTypeFilter = .all,
        selectedTag: String? = nil,
        sortOrder: SentenceLibrarySortOrder = .newestFirst
    ) throws -> [SentenceLibraryEntry] {
        try queue.sync {
            try validateLibrary(id: libraryID)
            return try withDatabase(libraryID: libraryID) { db in
                var clauses: [String] = []
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                let usesFullTextIndex = query.count >= 3
                if !query.isEmpty {
                    if usesFullTextIndex {
                        clauses.append("entries_fts MATCH ?")
                    } else {
                        clauses.append("(entries.original_text LIKE ? ESCAPE '\\' COLLATE NOCASE OR entries.translation LIKE ? ESCAPE '\\' COLLATE NOCASE OR entries.note LIKE ? ESCAPE '\\' COLLATE NOCASE)")
                    }
                }
                if createdAfter != nil { clauses.append("entries.created_at >= ?") }
                if createdBefore != nil { clauses.append("entries.created_at < ?") }
                if let sourceMediaName,
                   !sourceMediaName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    clauses.append("entries.source_media_name = ?")
                }
                switch typeFilter {
                case .all:
                    break
                case .bookmarkedOnly:
                    clauses.append("entries.is_bookmarked = 1")
                case .withVocabularyOnly:
                    clauses.append("(entries.associated_words IS NOT NULL AND entries.associated_words LIKE '%\"word\"%')")
                }
                if let tag = selectedTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
                    clauses.append("entries.tags LIKE ?")
                }

                let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
                let orderSQL: String
                switch sortOrder {
                case .newestFirst:
                    orderSQL = "entries.created_at DESC, entries.rowid DESC"
                case .oldestFirst:
                    orderSQL = "entries.created_at ASC, entries.rowid ASC"
                case .originalIndexFirst:
                    orderSQL = "CASE WHEN entries.original_index > 0 THEN 0 ELSE 1 END, entries.original_index ASC, entries.start_time ASC, entries.created_at ASC, entries.rowid ASC"
                }

                let sql = """
                SELECT entries.id, entries.original_index, entries.original_text, entries.translation, entries.phonetic_text,
                       entries.note, entries.is_bookmarked, entries.tags, entries.associated_words, entries.context_before,
                       entries.context_after, entries.source_media_name, entries.source_media_path, entries.start_time,
                       entries.end_time, entries.created_at, entries.preview_filename, entries.media_filename,
                       entries.speaker_role, entries.speaker_id, entries.speaker_ids, entries.is_speaker_overlap,
                       entries.word_tokens, entries.shadowing
                FROM entries\(usesFullTextIndex ? " JOIN entries_fts ON entries_fts.rowid = entries.rowid" : "")\(whereSQL)
                ORDER BY \(orderSQL);
                """
                var statement: OpaquePointer?
                try prepare(sql, db: db, statement: &statement)
                defer { sqlite3_finalize(statement) }
                var position: Int32 = 1
                if !query.isEmpty {
                    if usesFullTextIndex {
                        let phrase = query.lowercased().replacingOccurrences(of: "\"", with: "\"\"")
                        bind("\"\(phrase)\"", at: position, to: statement); position += 1
                    } else {
                        let escaped = query
                            .replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "%", with: "\\%")
                            .replacingOccurrences(of: "_", with: "\\_")
                        bind("%\(escaped)%", at: position, to: statement); position += 1
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
                    position += 1
                }
                if let tag = selectedTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
                    bind("%\"\(tag)\"%", at: position, to: statement)
                    position += 1
                }

                var result: [SentenceLibraryEntry] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let entry = parseEntry(from: statement) {
                        result.append(entry)
                    }
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

    /// 返回当前句库中所有已打上的标签
    public func allTags(libraryID: UUID) throws -> [String] {
        try queue.sync {
            try validateLibrary(id: libraryID)
            return try withDatabase(libraryID: libraryID) { db in
                var statement: OpaquePointer?
                try prepare("SELECT tags FROM entries WHERE tags != '[]' AND tags IS NOT NULL;", db: db, statement: &statement)
                defer { sqlite3_finalize(statement) }
                var tagSet = Set<String>()
                while sqlite3_step(statement) == SQLITE_ROW {
                    let json = text(statement, 0)
                    if let tags = Self.deserializeJSON([String].self, from: json) {
                        for tag in tags {
                            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { tagSet.insert(trimmed) }
                        }
                    }
                }
                return tagSet.sorted()
            }
        }
    }

    /// 难句星标切换
    @discardableResult
    public func toggleBookmark(id: UUID, in libraryID: UUID) throws -> Bool {
        try queue.sync {
            try validateLibrary(id: libraryID)
            let isBookmarked: Bool = try withDatabase(libraryID: libraryID) { db in
                try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
                do {
                    var selectStmt: OpaquePointer?
                    try prepare("SELECT is_bookmarked FROM entries WHERE id = ?;", db: db, statement: &selectStmt)
                    defer { sqlite3_finalize(selectStmt) }
                    bind(id.uuidString, at: 1, to: selectStmt)
                    guard sqlite3_step(selectStmt) == SQLITE_ROW else {
                        throw SentenceLibraryError.database("句子不存在。")
                    }
                    let current = sqlite3_column_int(selectStmt, 0) != 0
                    let next = !current
                    var updateStmt: OpaquePointer?
                    try prepare("UPDATE entries SET is_bookmarked = ? WHERE id = ?;", db: db, statement: &updateStmt)
                    defer { sqlite3_finalize(updateStmt) }
                    sqlite3_bind_int(updateStmt, 1, next ? 1 : 0)
                    bind(id.uuidString, at: 2, to: updateStmt)
                    guard sqlite3_step(updateStmt) == SQLITE_DONE else { throw databaseError(db) }
                    try execute("COMMIT;", in: db)
                    return next
                } catch {
                    try? execute("ROLLBACK;", in: db)
                    throw error
                }
            }
            try touchManifest(libraryID: libraryID)
            return isBookmarked
        }
    }

    /// 更新单句的分类标签
    public func updateTags(id: UUID, tags: [String], in libraryID: UUID) throws {
        try queue.sync {
            try validateLibrary(id: libraryID)
            let json = Self.serializeJSON(tags)
            try withDatabase(libraryID: libraryID) { db in
                try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
                do {
                    var statement: OpaquePointer?
                    try prepare("UPDATE entries SET tags = ? WHERE id = ?;", db: db, statement: &statement)
                    defer { sqlite3_finalize(statement) }
                    bind(json, at: 1, to: statement)
                    bind(id.uuidString, at: 2, to: statement)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
                    try execute("COMMIT;", in: db)
                } catch {
                    try? execute("ROLLBACK;", in: db)
                    throw error
                }
            }
            try touchManifest(libraryID: libraryID)
        }
    }

    /// 批量为句子追加分类标签（保留原有标签并去重）
    public func batchAddTags(ids: Set<UUID>, tags: [String], in libraryID: UUID) throws {
        guard !ids.isEmpty, !tags.isEmpty else { return }
        let cleanTags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleanTags.isEmpty else { return }

        try queue.sync {
            try validateLibrary(id: libraryID)
            try withDatabase(libraryID: libraryID) { db in
                try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
                do {
                    var selectStmt: OpaquePointer?
                    try prepare("SELECT tags FROM entries WHERE id = ?;", db: db, statement: &selectStmt)
                    defer { sqlite3_finalize(selectStmt) }

                    var updateStmt: OpaquePointer?
                    try prepare("UPDATE entries SET tags = ? WHERE id = ?;", db: db, statement: &updateStmt)
                    defer { sqlite3_finalize(updateStmt) }

                    for id in ids {
                        sqlite3_reset(selectStmt)
                        sqlite3_clear_bindings(selectStmt)
                        bind(id.uuidString, at: 1, to: selectStmt)

                        var currentTags: [String] = []
                        if sqlite3_step(selectStmt) == SQLITE_ROW {
                            let json = text(selectStmt, 0)
                            if let parsed = Self.deserializeJSON([String].self, from: json) {
                                currentTags = parsed
                            }
                        }

                        var tagSet = Set(currentTags)
                        var updatedTags = currentTags
                        for t in cleanTags {
                            if !tagSet.contains(t) {
                                tagSet.insert(t)
                                updatedTags.append(t)
                            }
                        }

                        let newJSON = Self.serializeJSON(updatedTags)
                        sqlite3_reset(updateStmt)
                        sqlite3_clear_bindings(updateStmt)
                        bind(newJSON, at: 1, to: updateStmt)
                        bind(id.uuidString, at: 2, to: updateStmt)
                        guard sqlite3_step(updateStmt) == SQLITE_DONE else { throw databaseError(db) }
                    }
                    try execute("COMMIT;", in: db)
                } catch {
                    try? execute("ROLLBACK;", in: db)
                    throw error
                }
            }
            try touchManifest(libraryID: libraryID)
        }
    }

    /// 批量为句子覆盖设置分类标签
    public func batchSetTags(ids: Set<UUID>, tags: [String], in libraryID: UUID) throws {
        guard !ids.isEmpty else { return }
        let cleanTags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let json = Self.serializeJSON(cleanTags)

        try queue.sync {
            try validateLibrary(id: libraryID)
            try withDatabase(libraryID: libraryID) { db in
                try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
                do {
                    var updateStmt: OpaquePointer?
                    try prepare("UPDATE entries SET tags = ? WHERE id = ?;", db: db, statement: &updateStmt)
                    defer { sqlite3_finalize(updateStmt) }

                    for id in ids {
                        sqlite3_reset(updateStmt)
                        sqlite3_clear_bindings(updateStmt)
                        bind(json, at: 1, to: updateStmt)
                        bind(id.uuidString, at: 2, to: updateStmt)
                        guard sqlite3_step(updateStmt) == SQLITE_DONE else { throw databaseError(db) }
                    }
                    try execute("COMMIT;", in: db)
                } catch {
                    try? execute("ROLLBACK;", in: db)
                    throw error
                }
            }
            try touchManifest(libraryID: libraryID)
        }
    }

    /// 批量更新句子的关联生词
    public func batchUpdateAssociatedWords(_ updates: [UUID: [StudyMatePackageVocabularyCard]], in libraryID: UUID) throws {
        guard !updates.isEmpty else { return }
        try queue.sync {
            try validateLibrary(id: libraryID)
            try withDatabase(libraryID: libraryID) { db in
                try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
                do {
                    var statement: OpaquePointer?
                    try prepare("UPDATE entries SET associated_words = ? WHERE id = ?;", db: db, statement: &statement)
                    defer { sqlite3_finalize(statement) }
                    for (id, words) in updates {
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        let json = Self.serializeJSON(words)
                        bind(json, at: 1, to: statement)
                        bind(id.uuidString, at: 2, to: statement)
                        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
                    }
                    try execute("COMMIT;", in: db)
                } catch {
                    try? execute("ROLLBACK;", in: db)
                    throw error
                }
            }
            try touchManifest(libraryID: libraryID)
        }
    }

    /// 更新单句的独立说话人角色显示
    public func updateSpeakerRole(id: UUID, speakerRole: String?, in libraryID: UUID) throws {
        try queue.sync {
            try validateLibrary(id: libraryID)
            try withDatabase(libraryID: libraryID) { db in
                try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
                do {
                    var statement: OpaquePointer?
                    try prepare("UPDATE entries SET speaker_role = ? WHERE id = ?;", db: db, statement: &statement)
                    defer { sqlite3_finalize(statement) }
                    if let role = speakerRole {
                        bind(role, at: 1, to: statement)
                    } else {
                        sqlite3_bind_null(statement, 1)
                    }
                    bind(id.uuidString, at: 2, to: statement)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
                    try execute("COMMIT;", in: db)
                } catch {
                    try? execute("ROLLBACK;", in: db)
                    throw error
                }
            }
            try touchManifest(libraryID: libraryID)
        }
    }

    /// 更新句子来源名称
    /// - Parameters:
    ///   - entryID: 指定当前触发修改的单句 ID
    ///   - oldSourceName: 原来源名称
    ///   - newSourceName: 新来源名称
    ///   - applyToAllWithSameSource: 是否同步应用到相同来源名称的所有句子
    ///   - libraryID: 句库 ID
    /// - Returns: 受影响/已更新的句子数量
    @discardableResult
    public func updateSourceMediaName(
        entryID: UUID,
        oldSourceName: String,
        newSourceName: String,
        applyToAllWithSameSource: Bool,
        in libraryID: UUID
    ) throws -> Int {
        try queue.sync {
            try validateLibrary(id: libraryID)
            let trimmedNew = newSourceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedOld = oldSourceName.trimmingCharacters(in: .whitespacesAndNewlines)
            var count = 0
            try withDatabase(libraryID: libraryID) { db in
                try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
                do {
                    var statement: OpaquePointer?
                    defer { sqlite3_finalize(statement) }
                    if applyToAllWithSameSource && !trimmedOld.isEmpty {
                        try prepare("UPDATE entries SET source_media_name = ? WHERE source_media_name = ?;", db: db, statement: &statement)
                        bind(trimmedNew, at: 1, to: statement)
                        bind(trimmedOld, at: 2, to: statement)
                    } else {
                        try prepare("UPDATE entries SET source_media_name = ? WHERE id = ?;", db: db, statement: &statement)
                        bind(trimmedNew, at: 1, to: statement)
                        bind(entryID.uuidString, at: 2, to: statement)
                    }
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
                    count = Int(sqlite3_changes(db))
                    try execute("COMMIT;", in: db)
                } catch {
                    try? execute("ROLLBACK;", in: db)
                    throw error
                }
            }
            try touchManifest(libraryID: libraryID)
            return count
        }
    }

    /// 批量更新选定句子的来源名称
    @discardableResult
    public func batchUpdateSourceMediaName(
        ids: Set<UUID>,
        newSourceName: String,
        in libraryID: UUID
    ) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let trimmedNew = newSourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return try queue.sync {
            try validateLibrary(id: libraryID)
            var count = 0
            try withDatabase(libraryID: libraryID) { db in
                try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
                do {
                    var statement: OpaquePointer?
                    try prepare("UPDATE entries SET source_media_name = ? WHERE id = ?;", db: db, statement: &statement)
                    defer { sqlite3_finalize(statement) }
                    for id in ids {
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        bind(trimmedNew, at: 1, to: statement)
                        bind(id.uuidString, at: 2, to: statement)
                        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
                        count += Int(sqlite3_changes(db))
                    }
                    try execute("COMMIT;", in: db)
                } catch {
                    try? execute("ROLLBACK;", in: db)
                    throw error
                }
            }
            try touchManifest(libraryID: libraryID)
            return count
        }
    }

    /// 说话人重命名与合并排重：
    /// 当 sourceSpeakerID (如 s2) 重命名为 targetSpeakerID (如 s1，对应名称 targetName) 时，
    /// 数据库中所有指向 sourceSpeakerID 的句子统一变更为 targetSpeakerID，
    /// 并在 manifest.json 中移除旧 key、记录合并后的角色名。
    public func batchMergeSpeaker(
        sourceSpeakerID: Int,
        targetSpeakerID: Int,
        targetName: String?,
        in libraryID: UUID
    ) throws {
        try queue.sync {
            try validateLibrary(id: libraryID)
            try withDatabase(libraryID: libraryID) { db in
                try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
                do {
                    // 1. 更新单个 speaker_id 匹配的条目
                    var updateSingleStmt: OpaquePointer?
                    try prepare("UPDATE entries SET speaker_id = ?, speaker_role = ? WHERE speaker_id = ?;", db: db, statement: &updateSingleStmt)
                    defer { sqlite3_finalize(updateSingleStmt) }
                    sqlite3_bind_int(updateSingleStmt, 1, Int32(targetSpeakerID))
                    if let targetName {
                        bind(targetName, at: 2, to: updateSingleStmt)
                    } else {
                        sqlite3_bind_null(updateSingleStmt, 2)
                    }
                    sqlite3_bind_int(updateSingleStmt, 3, Int32(sourceSpeakerID))
                    guard sqlite3_step(updateSingleStmt) == SQLITE_DONE else { throw databaseError(db) }

                    // 2. 更新包含多说话人的 speaker_ids
                    var selectListStmt: OpaquePointer?
                    try prepare("SELECT id, speaker_ids FROM entries WHERE speaker_ids LIKE ?;", db: db, statement: &selectListStmt)
                    defer { sqlite3_finalize(selectListStmt) }
                    bind("%\(sourceSpeakerID)%", at: 1, to: selectListStmt)
                    var updates: [(id: String, ids: [Int])] = []
                    while sqlite3_step(selectListStmt) == SQLITE_ROW {
                        let id = text(selectListStmt, 0)
                        let idsJson = text(selectListStmt, 1)
                        if var ids = Self.deserializeJSON([Int].self, from: idsJson) {
                            if let idx = ids.firstIndex(of: sourceSpeakerID) {
                                ids[idx] = targetSpeakerID
                                let deduplicated = Array(NSOrderedSet(array: ids)) as? [Int] ?? ids
                                updates.append((id, deduplicated))
                            }
                        }
                    }

                    if !updates.isEmpty {
                        var updateListStmt: OpaquePointer?
                        try prepare("UPDATE entries SET speaker_ids = ? WHERE id = ?;", db: db, statement: &updateListStmt)
                        defer { sqlite3_finalize(updateListStmt) }
                        for item in updates {
                            sqlite3_reset(updateListStmt)
                            sqlite3_clear_bindings(updateListStmt)
                            bind(Self.serializeJSON(item.ids), at: 1, to: updateListStmt)
                            bind(item.id, at: 2, to: updateListStmt)
                            guard sqlite3_step(updateListStmt) == SQLITE_DONE else { throw databaseError(db) }
                        }
                    }

                    try execute("COMMIT;", in: db)
                } catch {
                    try? execute("ROLLBACK;", in: db)
                    throw error
                }
            }

            guard var descriptor = readManifest(at: packageURL(for: libraryID)) else { return }
            var names = descriptor.speakerNames ?? [:]
            let sourceKey = "s\(sourceSpeakerID + 1)"
            let targetKey = "s\(targetSpeakerID + 1)"
            names.removeValue(forKey: sourceKey)
            if let targetName {
                names[targetKey] = targetName
            }
            descriptor.speakerNames = names
            descriptor.updatedAt = Date()
            try writeManifest(descriptor, to: packageURL(for: libraryID))
        }
    }

    /// 更新句库全局说话人映射表
    public func updateSpeakerNames(_ names: [String: String], in libraryID: UUID) throws {
        try queue.sync {
            guard var descriptor = readManifest(at: packageURL(for: libraryID)) else {
                throw SentenceLibraryError.invalidLibrary
            }
            descriptor.speakerNames = names
            descriptor.updatedAt = Date()
            try writeManifest(descriptor, to: packageURL(for: libraryID))
        }
    }

    /// 跨端学习接力与复习断点保存
    public func updateSessionState(_ sessionState: StudyMatePackageSessionState, in libraryID: UUID) throws {
        try queue.sync {
            guard var descriptor = readManifest(at: packageURL(for: libraryID)) else {
                throw SentenceLibraryError.invalidLibrary
            }
            descriptor.session = sessionState
            descriptor.updatedAt = Date()
            try writeManifest(descriptor, to: packageURL(for: libraryID))
        }
    }

    /// 更新句库元数据信息（原片画幅、源语言、目标语言等）
    public func updateMetadata(
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        videoAspectRatio: String? = nil,
        in libraryID: UUID
    ) throws {
        try queue.sync {
            guard var descriptor = readManifest(at: packageURL(for: libraryID)) else {
                throw SentenceLibraryError.invalidLibrary
            }
            if let sourceLanguage { descriptor.sourceLanguage = sourceLanguage }
            if let targetLanguage { descriptor.targetLanguage = targetLanguage }
            if let videoAspectRatio { descriptor.videoAspectRatio = videoAspectRatio }
            descriptor.updatedAt = Date()
            try writeManifest(descriptor, to: packageURL(for: libraryID))
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
                            id, original_index, original_text, translation, phonetic_text,
                            note, is_bookmarked, tags, associated_words, context_before,
                            context_after, source_media_name, source_media_path, start_time,
                            end_time, created_at, preview_filename, media_filename,
                            speaker_role, speaker_id, speaker_ids, is_speaker_overlap,
                            word_tokens, shadowing
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                        """
                        var statement: OpaquePointer?
                        try prepare(sql, db: db, statement: &statement)
                        defer { sqlite3_finalize(statement) }
                        for entry in entries {
                            sqlite3_reset(statement)
                            sqlite3_clear_bindings(statement)
                            bindEntry(
                                entry,
                                statement: statement,
                                hasStoredPreview: storedPreviewIDs.contains(entry.id)
                            )
                            guard storedMediaFilenames.contains(entry.mediaFilename) else {
                                throw SentenceLibraryError.database("句子媒体片段未完成写入。")
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

    /// 更新句库中一条句子的原文、译文与注音
    public func updateEntry(
        id: UUID,
        originalText: String,
        translation: String,
        phoneticText: String? = nil,
        in libraryID: UUID
    ) throws {
        try queue.sync {
            try validateLibrary(id: libraryID)
            try withDatabase(libraryID: libraryID) { db in
                do {
                    try updateEntryUnlocked(
                        id: id,
                        originalText: originalText,
                        translation: translation,
                        phoneticText: phoneticText,
                        in: db
                    )
                } catch {
                    guard isFTSIndexCorruption(error) else { throw error }
                    try rebuildFTSIndex(in: db)
                    try updateEntryUnlocked(
                        id: id,
                        originalText: originalText,
                        translation: translation,
                        phoneticText: phoneticText,
                        in: db
                    )
                }
            }
            try touchManifest(libraryID: libraryID)
        }
    }

    public func updateWordTokensAndText(
        id: UUID,
        originalText: String,
        wordTokens: [StudyMatePackageWordToken]?,
        in libraryID: UUID
    ) throws {
        try queue.sync {
            try validateLibrary(id: libraryID)
            try withDatabase(libraryID: libraryID) { db in
                try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
                do {
                    var statement: OpaquePointer?
                    try prepare(
                        "UPDATE entries SET original_text = ?, word_tokens = ? WHERE id = ?;",
                        db: db,
                        statement: &statement
                    )
                    defer { sqlite3_finalize(statement) }
                    bind(originalText, at: 1, to: statement)
                    if let wordTokens, !wordTokens.isEmpty,
                       let data = try? JSONEncoder().encode(wordTokens),
                       let json = String(data: data, encoding: .utf8) {
                        bind(json, at: 2, to: statement)
                    } else {
                        bind("[]", at: 2, to: statement)
                    }
                    bind(id.uuidString, at: 3, to: statement)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw databaseError(db)
                    }
                    try execute("COMMIT;", in: db)
                } catch {
                    try? execute("ROLLBACK;", in: db)
                    throw error
                }
            }
            try touchManifest(libraryID: libraryID)
            syncContentJSONUnlocked(libraryID: libraryID)
        }
    }

    private func updateEntryUnlocked(
        id: UUID,
        originalText: String,
        translation: String,
        phoneticText: String?,
        in db: OpaquePointer
    ) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
        do {
            var statement: OpaquePointer?
            try prepare(
                "UPDATE entries SET original_text = ?, translation = ?, phonetic_text = ? WHERE id = ?;",
                db: db,
                statement: &statement
            )
            defer { sqlite3_finalize(statement) }
            bind(originalText, at: 1, to: statement)
            bind(translation, at: 2, to: statement)
            if let phoneticText {
                bind(phoneticText, at: 3, to: statement)
            } else {
                sqlite3_bind_null(statement, 3)
            }
            bind(id.uuidString, at: 4, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw databaseError(db)
            }
            guard sqlite3_changes(db) > 0 else {
                throw SentenceLibraryError.database("句子不存在。")
            }
            try execute("COMMIT;", in: db)
        } catch {
            try? execute("ROLLBACK;", in: db)
            throw error
        }
    }

    private func rebuildFTSIndex(in db: OpaquePointer) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
        do {
            try execute("INSERT INTO entries_fts(entries_fts) VALUES ('rebuild');", in: db)
            try execute("COMMIT;", in: db)
        } catch {
            try? execute("ROLLBACK;", in: db)
            throw error
        }
    }

    private func isFTSIndexCorruption(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("database disk image is malformed")
            || (message.contains("database disk image") && message.contains("malformed"))
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

    /// 将源句库中选中的句子移动到目标句库
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
                        originalIndex: sourceEntry.originalIndex,
                        originalText: sourceEntry.originalText,
                        translation: sourceEntry.translation,
                        phoneticText: sourceEntry.phoneticText,
                        note: sourceEntry.note,
                        isBookmarked: sourceEntry.isBookmarked,
                        tags: sourceEntry.tags,
                        associatedWords: sourceEntry.associatedWords,
                        contextBefore: sourceEntry.contextBefore,
                        contextAfter: sourceEntry.contextAfter,
                        sourceMediaName: sourceEntry.sourceMediaName,
                        sourceMediaPath: sourceEntry.sourceMediaPath,
                        startTime: sourceEntry.startTime,
                        endTime: sourceEntry.endTime,
                        createdAt: sourceEntry.createdAt,
                        mediaFilename: destinationMediaFilename,
                        previewFilename: destinationPreviewFilename,
                        speakerRole: sourceEntry.speakerRole,
                        speakerID: sourceEntry.speakerID,
                        speakerIDs: sourceEntry.speakerIDs,
                        isSpeakerOverlap: sourceEntry.isSpeakerOverlap,
                        wordTokens: sourceEntry.wordTokens,
                        shadowing: sourceEntry.shadowing
                    )
                    destinationEntries.append(destinationEntry)
                    progress(0.35 * Double(offset + 1) / Double(total), "复制句子媒体")
                }

                try insertEntriesUnlocked(destinationEntries, into: destinationLibraryID)
                progress(0.65, "写入目标句库")

                do {
                    try deleteEntriesUnlocked(ids: Set(sourceEntries.map(\.id)), from: sourceLibraryID)
                } catch {
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

    /// 导出为便携式跨端 `.mablib` 原生学习包（或独立 ZIP 包），包含完整的深层元数据与会话状态
    public func writeLearningPackage(
        entries: [SentenceLibraryEntry],
        libraryID: UUID,
        libraryTitle: String,
        destinationURL: URL,
        producerPlatform: String = "macOS"
    ) throws {
        guard !entries.isEmpty else { throw StudyMatePackageError.invalidContent("不能导出空句库。") }
        try queue.sync { () throws -> Void in
            try validateLibrary(id: libraryID)
            let descriptor = readManifest(at: packageURL(for: libraryID))
            var portableEntries: [StudyMatePackageEntry] = []
            var assets: [StudyMatePackageAssetInput] = []
            var allVocabularyCards: [StudyMatePackageVocabularyCard] = []
            var seenVocabKeys = Set<String>()

            for (order, entry) in entries.enumerated() {
                guard let sourceURL = mediaURL(for: entry, libraryID: libraryID),
                      fileManager.fileExists(atPath: sourceURL.path),
                      let data = try? Data(contentsOf: sourceURL, options: [.mappedIfSafe]) else {
                    throw StudyMatePackageError.mediaValidationFailed(entry.originalText.isEmpty ? entry.id.uuidString : entry.originalText)
                }
                let fallbackDuration = max(0.05, entry.endTime - entry.startTime)
                let encodedDuration = AVURLAsset(url: sourceURL).duration.seconds
                let duration = encodedDuration.isFinite && encodedDuration > 0 ? encodedDuration : fallbackDuration
                let durationMs = max(1, Int((duration * 1_000).rounded()))

                if let words = entry.associatedWords {
                    for card in words {
                        let key = card.word.lowercased()
                        if !seenVocabKeys.contains(key) {
                            seenVocabKeys.insert(key)
                            allVocabularyCards.append(card)
                        }
                    }
                }

                var speakerRef: StudyMatePackageSpeakerReference? = nil
                if let sid = entry.speakerID {
                    let defaultLabel = "s\(sid + 1)"
                    let roleName = entry.speakerRole ?? descriptor?.speakerNames?[defaultLabel] ?? defaultLabel
                    speakerRef = StudyMatePackageSpeakerReference(
                        id: sid,
                        name: roleName,
                        ids: entry.speakerIDs.isEmpty ? [sid] : entry.speakerIDs,
                        isOverlap: entry.isSpeakerOverlap
                    )
                }

                portableEntries.append(StudyMatePackageEntry(
                    id: entry.id,
                    originCollectionID: libraryID,
                    order: order,
                    originalIndex: entry.originalIndex,
                    original: entry.originalText,
                    translation: entry.translation,
                    phoneticText: entry.phoneticText,
                    note: entry.note,
                    isBookmarked: entry.isBookmarked,
                    tags: entry.tags,
                    associatedWords: entry.associatedWords,
                    contextBefore: entry.contextBefore,
                    contextAfter: entry.contextAfter,
                    createdAt: entry.createdAt,
                    updatedAt: nil,
                    audio: StudyMatePackageAudioReference(assetID: entry.id, endMs: durationMs),
                    source: StudyMatePackageSourceReference(
                        mediaTitle: entry.sourceMediaName,
                        originalStartMs: Int((max(0, entry.startTime) * 1_000).rounded()),
                        originalEndMs: Int((max(entry.startTime, entry.endTime) * 1_000).rounded())
                    ),
                    preview: nil,
                    speaker: speakerRef,
                    wordTokens: entry.wordTokens,
                    shadowing: entry.shadowing
                ))
                assets.append(StudyMatePackageAssetInput(id: entry.id, data: data, durationMs: durationMs))
            }

            let isAllScope = entries.count == (try readEntriesUnlocked(libraryID: libraryID).count)
            let package = try StudyMateLearningPackage.make(
                collectionID: libraryID,
                title: libraryTitle,
                scope: isAllScope ? "all" : "selected",
                entries: portableEntries,
                assets: assets,
                sourceLanguage: descriptor?.sourceLanguage ?? "und",
                translationLanguage: descriptor?.targetLanguage ?? "und",
                videoAspectRatio: descriptor?.videoAspectRatio,
                speakerNames: descriptor?.speakerNames,
                session: descriptor?.session,
                producerPlatform: producerPlatform
            )
            try package.write(to: destinationURL)
        }
    }

    /// 导入跨端原生学习包，将深层元数据与音频无缝注入本地句库
    public func importLearningPackage(
        from packageURL: URL,
        into libraryID: UUID
    ) throws -> StudyMateLearningPackageImportReport {
        let package = try StudyMateLearningPackage.load(from: packageURL)
        return try queue.sync { () throws -> StudyMateLearningPackageImportReport in
            try validateLibrary(id: libraryID)
            let existing = try readEntriesUnlocked(libraryID: libraryID)
            let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            let targetMediaDirectory = mediaURL(for: libraryID)
            try fileManager.createDirectory(at: targetMediaDirectory, withIntermediateDirectories: true)

            var newEntries: [SentenceLibraryEntry] = []
            var updatePlans: [(old: SentenceLibraryEntry, incoming: StudyMatePackageEntry, mediaFilename: String?)] = []
            var stagedFiles: [URL] = []
            var added = 0
            var updated = 0
            var skipped = 0

            for incoming in package.content.entries.sorted(by: { $0.order < $1.order }) {
                guard let assetData = package.assetData[incoming.audio.assetID],
                      let asset = package.manifest.assets.first(where: { $0.id == incoming.audio.assetID }) else {
                    throw StudyMatePackageError.missingAsset(incoming.audio.assetID.uuidString)
                }
                if let old = existingByID[incoming.id] {
                    let oldDigest = mediaURL(for: old, libraryID: libraryID).flatMap { oldURL in
                        (try? Data(contentsOf: oldURL, options: [.mappedIfSafe])).map(StudyMateLearningPackage.sha256)
                    }
                    let sameMedia = oldDigest == asset.sha256
                    let sameText = old.originalText == incoming.original &&
                        old.translation == incoming.translation &&
                        old.note == incoming.note &&
                        old.phoneticText == incoming.phoneticText &&
                        old.isBookmarked == incoming.isBookmarked
                    if sameMedia && sameText {
                        skipped += 1
                        continue
                    }
                    var replacementFilename: String?
                    if !sameMedia {
                        replacementFilename = "\(UUID().uuidString).m4a"
                        let stagedURL = targetMediaDirectory.appendingPathComponent(replacementFilename!)
                        try assetData.write(to: stagedURL, options: .atomic)
                        stagedFiles.append(stagedURL)
                    }
                    updatePlans.append((old, incoming, replacementFilename))
                    updated += 1
                } else {
                    let mediaFilename = "\(UUID().uuidString).m4a"
                    let stagedURL = targetMediaDirectory.appendingPathComponent(mediaFilename)
                    try assetData.write(to: stagedURL, options: .atomic)
                    stagedFiles.append(stagedURL)
                    let sourceStart = incoming.source?.originalStartMs.map { Double($0) / 1_000 } ?? 0
                    let sourceEnd = incoming.source?.originalEndMs.map { Double($0) / 1_000 } ?? (Double(asset.durationMs) / 1_000)
                    newEntries.append(SentenceLibraryEntry(
                        id: incoming.id,
                        originalIndex: incoming.originalIndex,
                        originalText: incoming.original,
                        translation: incoming.translation,
                        phoneticText: incoming.phoneticText,
                        note: incoming.note,
                        isBookmarked: incoming.isBookmarked,
                        tags: incoming.tags,
                        associatedWords: incoming.associatedWords,
                        contextBefore: incoming.contextBefore,
                        contextAfter: incoming.contextAfter,
                        sourceMediaName: incoming.source?.mediaTitle ?? "",
                        sourceMediaPath: "",
                        startTime: sourceStart,
                        endTime: max(sourceStart + 0.05, sourceEnd),
                        createdAt: incoming.createdAt,
                        mediaFilename: mediaFilename,
                        previewFilename: nil,
                        speakerRole: incoming.speaker?.name,
                        speakerID: incoming.speaker?.id,
                        speakerIDs: incoming.speaker?.ids ?? (incoming.speaker?.id.map { [$0] } ?? []),
                        isSpeakerOverlap: incoming.speaker?.isOverlap ?? false,
                        wordTokens: incoming.wordTokens,
                        shadowing: incoming.shadowing
                    ))
                    added += 1
                }
            }

            do {
                try insertEntriesUnlocked(newEntries, into: libraryID)
                if !updatePlans.isEmpty {
                    try withDatabase(libraryID: libraryID) { db in
                        try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
                        do {
                            var statement: OpaquePointer?
                            try prepare(
                                """
                                UPDATE entries SET
                                    original_text = ?, translation = ?, phonetic_text = ?, note = ?,
                                    is_bookmarked = ?, tags = ?, associated_words = ?,
                                    source_media_name = ?, start_time = ?, end_time = ?,
                                    media_filename = COALESCE(?, media_filename)
                                WHERE id = ?;
                                """,
                                db: db,
                                statement: &statement
                            )
                            defer { sqlite3_finalize(statement) }
                            for plan in updatePlans {
                                sqlite3_reset(statement)
                                sqlite3_clear_bindings(statement)
                                bind(plan.incoming.original, at: 1, to: statement)
                                bind(plan.incoming.translation, at: 2, to: statement)
                                if let phonetics = plan.incoming.phoneticText {
                                    bind(phonetics, at: 3, to: statement)
                                } else {
                                    sqlite3_bind_null(statement, 3)
                                }
                                bind(plan.incoming.note, at: 4, to: statement)
                                sqlite3_bind_int(statement, 5, plan.incoming.isBookmarked ? 1 : 0)
                                bind(Self.serializeJSON(plan.incoming.tags), at: 6, to: statement)
                                bind(Self.serializeJSON(plan.incoming.associatedWords ?? []), at: 7, to: statement)
                                if let mediaTitle = plan.incoming.source?.mediaTitle, !mediaTitle.isEmpty {
                                    bind(mediaTitle, at: 8, to: statement)
                                } else {
                                    bind(plan.old.sourceMediaName, at: 8, to: statement)
                                }
                                sqlite3_bind_double(statement, 9, plan.incoming.source?.originalStartMs.map { Double($0) / 1_000 } ?? plan.old.startTime)
                                sqlite3_bind_double(statement, 10, plan.incoming.source?.originalEndMs.map { Double($0) / 1_000 } ?? plan.old.endTime)
                                if let mediaFilename = plan.mediaFilename { bind(mediaFilename, at: 11, to: statement) } else { sqlite3_bind_null(statement, 11) }
                                bind(plan.old.id.uuidString, at: 12, to: statement)
                                guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
                            }
                            try execute("COMMIT;", in: db)
                        } catch {
                            try? execute("ROLLBACK;", in: db)
                            throw error
                        }
                    }
                }
            } catch {
                for file in stagedFiles { try? fileManager.removeItem(at: file) }
                throw error
            }
            for plan in updatePlans where plan.mediaFilename != nil {
                if let oldURL = mediaURL(for: plan.old, libraryID: libraryID) {
                    try? fileManager.removeItem(at: oldURL)
                }
            }

            // 同步 manifest 中的说话人、画幅和语言等属性
            if var descriptor = readManifest(at: self.packageURL(for: libraryID)) {
                var touched = false
                if let pkgAspect = package.manifest.videoAspectRatio, descriptor.videoAspectRatio == nil {
                    descriptor.videoAspectRatio = pkgAspect
                    touched = true
                }
                if let pkgSrcLang = package.manifest.sourceLanguage, descriptor.sourceLanguage == nil {
                    descriptor.sourceLanguage = pkgSrcLang
                    touched = true
                }
                if let pkgTgtLang = package.manifest.targetLanguage, descriptor.targetLanguage == nil {
                    descriptor.targetLanguage = pkgTgtLang
                    touched = true
                }
                if let pkgSpeakerNames = package.manifest.speakerNames, !pkgSpeakerNames.isEmpty {
                    var names = descriptor.speakerNames ?? [:]
                    for (k, v) in pkgSpeakerNames {
                        if names[k] == nil {
                            names[k] = v
                        }
                    }
                    descriptor.speakerNames = names
                    touched = true
                }
                if touched {
                    descriptor.updatedAt = Date()
                    try writeManifest(descriptor, to: self.packageURL(for: libraryID))
                } else {
                    try touchManifest(libraryID: libraryID)
                }
            }

            return StudyMateLearningPackageImportReport(added: added, updated: updated, skipped: skipped)
        }
    }

    public func previewURL(for entry: SentenceLibraryEntry, libraryID: UUID) -> URL? {
        guard let filename = entry.previewFilename else { return nil }
        return previewsURL(for: libraryID).appendingPathComponent(filename)
    }

    public func mediaURL(for entry: SentenceLibraryEntry, libraryID: UUID) -> URL? {
        let filename = entry.mediaFilename
        guard URL(fileURLWithPath: filename).lastPathComponent == filename, !filename.isEmpty else { return nil }
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
            try execute("PRAGMA wal_checkpoint(TRUNCATE);", in: openedDatabase)
            sqlite3_close_v2(openedDatabase)
            database = nil
            let migrated = SentenceLibraryDescriptor(
                id: legacy.id,
                name: legacy.name,
                createdAt: legacy.createdAt,
                updatedAt: legacy.updatedAt,
                sourceLanguage: legacy.sourceLanguage,
                targetLanguage: legacy.targetLanguage,
                videoAspectRatio: legacy.videoAspectRatio,
                speakerNames: legacy.speakerNames,
                session: legacy.session
            )
            try writeManifest(migrated, to: packageURL)
        } catch {
            if let database { sqlite3_close_v2(database) }
            throw error
        }
    }

    public func readManifest(at packageURL: URL) -> SentenceLibraryDescriptor? {
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
        syncContentJSONUnlocked(libraryID: libraryID)
    }

    /// 在 .mablib 包根目录下同步写入 content.json 镜像，实现 macOS 目录 Bundle 与移动端跨平台标准数据层无缝对齐
    private func syncContentJSONUnlocked(libraryID: UUID) {
        let pkgURL = packageURL(for: libraryID)
        guard fileManager.fileExists(atPath: pkgURL.path) else { return }
        guard let dbEntries = try? readEntriesUnlocked(libraryID: libraryID) else { return }
        let descriptor = readManifest(at: pkgURL)
        var portableEntries: [StudyMatePackageEntry] = []
        for (order, entry) in dbEntries.enumerated() {
            var speakerRef: StudyMatePackageSpeakerReference? = nil
            if let sid = entry.speakerID {
                let defaultLabel = "s\(sid + 1)"
                let roleName = entry.speakerRole ?? descriptor?.speakerNames?[defaultLabel] ?? defaultLabel
                speakerRef = StudyMatePackageSpeakerReference(
                    id: sid,
                    name: roleName,
                    ids: entry.speakerIDs.isEmpty ? [sid] : entry.speakerIDs,
                    isOverlap: entry.isSpeakerOverlap
                )
            }
            let durationMs = max(1, Int(((entry.endTime - entry.startTime) * 1000).rounded()))
            portableEntries.append(StudyMatePackageEntry(
                id: entry.id,
                originCollectionID: libraryID,
                order: order,
                originalIndex: entry.originalIndex,
                original: entry.originalText,
                translation: entry.translation,
                phoneticText: entry.phoneticText,
                note: entry.note,
                isBookmarked: entry.isBookmarked,
                tags: entry.tags,
                associatedWords: entry.associatedWords,
                contextBefore: entry.contextBefore,
                contextAfter: entry.contextAfter,
                createdAt: entry.createdAt,
                updatedAt: nil,
                audio: StudyMatePackageAudioReference(assetID: entry.id, endMs: durationMs),
                source: StudyMatePackageSourceReference(
                    mediaTitle: entry.sourceMediaName,
                    originalStartMs: Int((max(0, entry.startTime) * 1000).rounded()),
                    originalEndMs: Int((max(entry.startTime, entry.endTime) * 1000).rounded())
                ),
                preview: entry.previewFilename.map { StudyMatePackagePreviewReference(path: "Previews/\($0)") },
                speaker: speakerRef,
                wordTokens: entry.wordTokens,
                shadowing: entry.shadowing
            ))
        }
        let content = StudyMatePackageContent(entries: portableEntries)
        if let data = try? StudyMateLearningPackage.encode(content) {
            let contentURL = pkgURL.appendingPathComponent("content.json")
            try? data.write(to: contentURL, options: .atomic)
        }
    }

    private func readEntriesUnlocked(libraryID: UUID, ids: Set<UUID>? = nil) throws -> [SentenceLibraryEntry] {
        try withDatabase(libraryID: libraryID) { db in
            var statement: OpaquePointer?
            let sql: String
            if ids == nil {
                sql = """
                SELECT id, original_index, original_text, translation, phonetic_text,
                       note, is_bookmarked, tags, associated_words, context_before,
                       context_after, source_media_name, source_media_path, start_time,
                       end_time, created_at, preview_filename, media_filename,
                       speaker_role, speaker_id, speaker_ids, is_speaker_overlap,
                       word_tokens, shadowing
                FROM entries ORDER BY created_at ASC, rowid ASC;
                """
            } else {
                sql = """
                SELECT id, original_index, original_text, translation, phonetic_text,
                       note, is_bookmarked, tags, associated_words, context_before,
                       context_after, source_media_name, source_media_path, start_time,
                       end_time, created_at, preview_filename, media_filename,
                       speaker_role, speaker_id, speaker_ids, is_speaker_overlap,
                       word_tokens, shadowing
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
                    if sqlite3_step(statement) == SQLITE_ROW, let entry = parseEntry(from: statement) {
                        result.append(entry)
                    }
                }
            } else {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let entry = parseEntry(from: statement) { result.append(entry) }
                }
            }
            return result
        }
    }

    private func parseEntry(from statement: OpaquePointer?) -> SentenceLibraryEntry? {
        guard let id = UUID(uuidString: text(statement, 0)) else { return nil }
        let originalIndex = Int(sqlite3_column_int(statement, 1))
        let originalText = text(statement, 2)
        let translation = text(statement, 3)
        let phoneticText = optionalText(statement, 4)
        let note = text(statement, 5)
        let isBookmarked = sqlite3_column_int(statement, 6) != 0
        let tagsJson = text(statement, 7)
        let tags = Self.deserializeJSON([String].self, from: tagsJson) ?? []
        let vocabJson = text(statement, 8)
        let rawAssociatedWords = Self.deserializeJSON([StudyMatePackageVocabularyCard].self, from: vocabJson)
        let associatedWords = (rawAssociatedWords?.isEmpty == true) ? nil : rawAssociatedWords
        let contextBefore = optionalText(statement, 9)
        let contextAfter = optionalText(statement, 10)
        let sourceMediaName = text(statement, 11)
        let sourceMediaPath = text(statement, 12)
        let startTime = sqlite3_column_double(statement, 13)
        let endTime = sqlite3_column_double(statement, 14)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 15))
        let previewFilename = optionalText(statement, 16)
        let mediaFilename = text(statement, 17)
        let speakerRole = optionalText(statement, 18)
        let speakerID = sqlite3_column_type(statement, 19) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 19))
        let speakerIDsJson = text(statement, 20)
        let speakerIDs = Self.deserializeJSON([Int].self, from: speakerIDsJson) ?? []
        let isSpeakerOverlap = sqlite3_column_int(statement, 21) != 0
        let wordTokensJson = text(statement, 22)
        let rawWordTokens = Self.deserializeJSON([StudyMatePackageWordToken].self, from: wordTokensJson)
        let wordTokens = (rawWordTokens?.isEmpty == true) ? nil : rawWordTokens
        let shadowingJson = optionalText(statement, 23)
        let shadowing = shadowingJson.flatMap { Self.deserializeJSON(StudyMatePackageShadowingReference.self, from: $0) }

        return SentenceLibraryEntry(
            id: id,
            originalIndex: originalIndex,
            originalText: originalText,
            translation: translation,
            phoneticText: phoneticText,
            note: note,
            isBookmarked: isBookmarked,
            tags: tags,
            associatedWords: associatedWords,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            sourceMediaName: sourceMediaName,
            sourceMediaPath: sourceMediaPath,
            startTime: startTime,
            endTime: endTime,
            createdAt: createdAt,
            mediaFilename: mediaFilename,
            previewFilename: previewFilename,
            speakerRole: speakerRole,
            speakerID: speakerID,
            speakerIDs: speakerIDs,
            isSpeakerOverlap: isSpeakerOverlap,
            wordTokens: wordTokens,
            shadowing: shadowing
        )
    }

    private func bindEntry(
        _ entry: SentenceLibraryEntry,
        statement: OpaquePointer?,
        hasStoredPreview: Bool
    ) {
        bind(entry.id.uuidString, at: 1, to: statement)
        sqlite3_bind_int(statement, 2, Int32(entry.originalIndex))
        bind(entry.originalText, at: 3, to: statement)
        bind(entry.translation, at: 4, to: statement)
        if let phonetics = entry.phoneticText {
            bind(phonetics, at: 5, to: statement)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        bind(entry.note, at: 6, to: statement)
        sqlite3_bind_int(statement, 7, entry.isBookmarked ? 1 : 0)
        bind(Self.serializeJSON(entry.tags), at: 8, to: statement)
        bind(Self.serializeJSON(entry.associatedWords ?? []), at: 9, to: statement)
        if let before = entry.contextBefore {
            bind(before, at: 10, to: statement)
        } else {
            sqlite3_bind_null(statement, 10)
        }
        if let after = entry.contextAfter {
            bind(after, at: 11, to: statement)
        } else {
            sqlite3_bind_null(statement, 11)
        }
        bind(entry.sourceMediaName, at: 12, to: statement)
        bind(entry.sourceMediaPath, at: 13, to: statement)
        sqlite3_bind_double(statement, 14, entry.startTime)
        sqlite3_bind_double(statement, 15, entry.endTime)
        sqlite3_bind_double(statement, 16, entry.createdAt.timeIntervalSince1970)
        if hasStoredPreview, let filename = entry.previewFilename {
            bind(filename, at: 17, to: statement)
        } else {
            sqlite3_bind_null(statement, 17)
        }
        bind(entry.mediaFilename, at: 18, to: statement)
        if let role = entry.speakerRole {
            bind(role, at: 19, to: statement)
        } else {
            sqlite3_bind_null(statement, 19)
        }
        if let sid = entry.speakerID {
            sqlite3_bind_int(statement, 20, Int32(sid))
        } else {
            sqlite3_bind_null(statement, 20)
        }
        bind(Self.serializeJSON(entry.speakerIDs), at: 21, to: statement)
        sqlite3_bind_int(statement, 22, entry.isSpeakerOverlap ? 1 : 0)
        bind(Self.serializeJSON(entry.wordTokens ?? []), at: 23, to: statement)
        if let shadowing = entry.shadowing, let json = try? String(data: Self.encoder.encode(shadowing), encoding: .utf8) {
            bind(json, at: 24, to: statement)
        } else {
            sqlite3_bind_null(statement, 24)
        }
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
                    id, original_index, original_text, translation, phonetic_text,
                    note, is_bookmarked, tags, associated_words, context_before,
                    context_after, source_media_name, source_media_path, start_time,
                    end_time, created_at, preview_filename, media_filename,
                    speaker_role, speaker_id, speaker_ids, is_speaker_overlap,
                    word_tokens, shadowing
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
                var statement: OpaquePointer?
                try prepare(sql, db: db, statement: &statement)
                defer { sqlite3_finalize(statement) }
                for entry in entries {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bindEntry(entry, statement: statement, hasStoredPreview: entry.previewFilename != nil)
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
                original_index INTEGER NOT NULL DEFAULT 0,
                original_text TEXT NOT NULL DEFAULT '',
                translation TEXT NOT NULL DEFAULT '',
                phonetic_text TEXT,
                note TEXT NOT NULL DEFAULT '',
                is_bookmarked INTEGER NOT NULL DEFAULT 0,
                tags TEXT NOT NULL DEFAULT '[]',
                associated_words TEXT NOT NULL DEFAULT '[]',
                context_before TEXT,
                context_after TEXT,
                source_media_name TEXT NOT NULL DEFAULT '',
                source_media_path TEXT NOT NULL DEFAULT '',
                start_time REAL NOT NULL,
                end_time REAL NOT NULL,
                created_at REAL NOT NULL,
                preview_filename TEXT,
                media_filename TEXT NOT NULL,
                speaker_role TEXT,
                speaker_id INTEGER,
                speaker_ids TEXT NOT NULL DEFAULT '[]',
                is_speaker_overlap INTEGER NOT NULL DEFAULT 0,
                word_tokens TEXT NOT NULL DEFAULT '[]',
                shadowing TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_entries_created_at ON entries(created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_entries_source_media ON entries(source_media_name);
            CREATE INDEX IF NOT EXISTS idx_entries_is_bookmarked ON entries(is_bookmarked);
            CREATE INDEX IF NOT EXISTS idx_entries_original_index ON entries(original_index ASC);
            CREATE INDEX IF NOT EXISTS idx_entries_speaker_id ON entries(speaker_id);
            \(Self.ftsSchemaSQL)
            PRAGMA user_version=5;
            """, in: db)
        } else if version >= 1 && version <= 4 {
            let columns = try tableColumns(in: db)
            if !columns.contains("original_index") {
                try execute("ALTER TABLE entries ADD COLUMN original_index INTEGER NOT NULL DEFAULT 0;", in: db)
            }
            if !columns.contains("phonetic_text") {
                try execute("ALTER TABLE entries ADD COLUMN phonetic_text TEXT;", in: db)
            }
            if !columns.contains("is_bookmarked") {
                try execute("ALTER TABLE entries ADD COLUMN is_bookmarked INTEGER NOT NULL DEFAULT 0;", in: db)
            }
            if !columns.contains("tags") {
                try execute("ALTER TABLE entries ADD COLUMN tags TEXT NOT NULL DEFAULT '[]';", in: db)
            }
            if !columns.contains("associated_words") {
                try execute("ALTER TABLE entries ADD COLUMN associated_words TEXT NOT NULL DEFAULT '[]';", in: db)
            }
            if !columns.contains("context_before") {
                try execute("ALTER TABLE entries ADD COLUMN context_before TEXT;", in: db)
            }
            if !columns.contains("context_after") {
                try execute("ALTER TABLE entries ADD COLUMN context_after TEXT;", in: db)
            }
            if !columns.contains("preview_filename") {
                try execute("ALTER TABLE entries ADD COLUMN preview_filename TEXT;", in: db)
            }
            if !columns.contains("media_filename") {
                try execute("ALTER TABLE entries ADD COLUMN media_filename TEXT;", in: db)
            }
            if !columns.contains("speaker_role") {
                try execute("ALTER TABLE entries ADD COLUMN speaker_role TEXT;", in: db)
            }
            if !columns.contains("speaker_id") {
                try execute("ALTER TABLE entries ADD COLUMN speaker_id INTEGER;", in: db)
            }
            if !columns.contains("speaker_ids") {
                try execute("ALTER TABLE entries ADD COLUMN speaker_ids TEXT NOT NULL DEFAULT '[]';", in: db)
            }
            if !columns.contains("is_speaker_overlap") {
                try execute("ALTER TABLE entries ADD COLUMN is_speaker_overlap INTEGER NOT NULL DEFAULT 0;", in: db)
            }
            if !columns.contains("word_tokens") {
                try execute("ALTER TABLE entries ADD COLUMN word_tokens TEXT NOT NULL DEFAULT '[]';", in: db)
            }
            if !columns.contains("shadowing") {
                try execute("ALTER TABLE entries ADD COLUMN shadowing TEXT;", in: db)
            }
            try execute("""
            CREATE INDEX IF NOT EXISTS idx_entries_created_at ON entries(created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_entries_source_media ON entries(source_media_name);
            CREATE INDEX IF NOT EXISTS idx_entries_is_bookmarked ON entries(is_bookmarked);
            CREATE INDEX IF NOT EXISTS idx_entries_original_index ON entries(original_index ASC);
            CREATE INDEX IF NOT EXISTS idx_entries_speaker_id ON entries(speaker_id);
            DROP TRIGGER IF EXISTS entries_ai;
            DROP TRIGGER IF EXISTS entries_ad;
            DROP TRIGGER IF EXISTS entries_au;
            DROP TABLE IF EXISTS entries_fts;
            \(Self.ftsSchemaSQL)
            PRAGMA user_version=5;
            """, in: db)
        } else if version != 5 {
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

    private static func serializeJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value), let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }

    private static func deserializeJSON<T: Decodable>(_ type: T.Type, from string: String) -> T? {
        guard !string.isEmpty, let data = string.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
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

    /// 外部内容表全文索引
    private static let ftsSchemaSQL = """
    CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
        original_text,
        translation,
        note,
        tags,
        content='entries',
        content_rowid='rowid',
        tokenize='trigram case_sensitive 0'
    );
    CREATE TRIGGER IF NOT EXISTS entries_ai AFTER INSERT ON entries BEGIN
        INSERT INTO entries_fts(rowid, original_text, translation, note, tags)
        VALUES (new.rowid, lower(new.original_text), lower(new.translation), lower(new.note), lower(new.tags));
    END;
    CREATE TRIGGER IF NOT EXISTS entries_ad AFTER DELETE ON entries BEGIN
        INSERT INTO entries_fts(entries_fts, rowid, original_text, translation, note, tags)
        VALUES ('delete', old.rowid, lower(old.original_text), lower(old.translation), lower(old.note), lower(old.tags));
    END;
    CREATE TRIGGER IF NOT EXISTS entries_au AFTER UPDATE ON entries BEGIN
        INSERT INTO entries_fts(entries_fts, rowid, original_text, translation, note, tags)
        VALUES ('delete', old.rowid, lower(old.original_text), lower(old.translation), lower(old.note), lower(old.tags));
        INSERT INTO entries_fts(rowid, original_text, translation, note, tags)
        VALUES (new.rowid, lower(new.original_text), lower(new.translation), lower(new.note), lower(new.tags));
    END;
    INSERT INTO entries_fts(rowid, original_text, translation, note, tags)
        SELECT rowid, lower(original_text), lower(translation), lower(note), lower(tags) FROM entries
        WHERE rowid NOT IN (SELECT rowid FROM entries_fts);
    """
}
