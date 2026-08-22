import Foundation
import SQLite3

/// 断句工程持久化数据结构
public struct SavedProjectData: Codable, Sendable {
    public let mediaURLString: String
    public let title: String
    public let duration: Double
    public let lastPosition: Double
    public let segments: [SentenceSegment]
    public let updatedAt: Date
    
    public init(
        mediaURLString: String,
        title: String,
        duration: Double,
        lastPosition: Double,
        segments: [SentenceSegment],
        updatedAt: Date = Date()
    ) {
        self.mediaURLString = mediaURLString
        self.title = title
        self.duration = duration
        self.lastPosition = lastPosition
        self.segments = segments
        self.updatedAt = updatedAt
    }
}

/// 基于 SQLite3 的本地断句工程持久化存储管理器
public final class SegmentationStore: @unchecked Sendable {
    public static let shared = SegmentationStore()
    
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.macaboboo.segmentation.store", qos: .utility)
    
    public init(databaseURL: URL? = nil) {
        setupDatabase(databaseURL: databaseURL)
    }
    
    deinit {
        queue.sync {
            if let db = db {
                sqlite3_close_v2(db)
            }
        }
    }
    
    private func setupDatabase(databaseURL: URL?) {
        let resolvedURL: URL
        if let databaseURL {
            resolvedURL = databaseURL
        } else {
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return
            }
            resolvedURL = appSupport
                .appendingPathComponent("MacAboboo", isDirectory: true)
                .appendingPathComponent("projects.sqlite3")
        }
        try? FileManager.default.createDirectory(
            at: resolvedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbPath = resolvedURL.path
        
        queue.sync {
            if sqlite3_open(dbPath, &db) == SQLITE_OK {
                let createTableSQL = """
                CREATE TABLE IF NOT EXISTS projects (
                    url_key TEXT PRIMARY KEY,
                    title TEXT,
                    duration REAL,
                    last_position REAL,
                    segments_json TEXT,
                    updated_at INTEGER
                );
                """
                var errMsg: UnsafeMutablePointer<CChar>?
                if sqlite3_exec(db, createTableSQL, nil, nil, &errMsg) != SQLITE_OK {
                    if let err = errMsg {
                        print("SQLite table creation failed: \(String(cString: err))")
                        sqlite3_free(errMsg)
                    }
                }
            }
        }
    }
    
    /// 保存当前媒体的断句工程
    public func saveProject(for url: URL, title: String, duration: Double, lastPosition: Double, segments: [SentenceSegment]) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db, !segments.isEmpty else { return }
            
            let urlKey = url.path
            guard let jsonData = try? JSONEncoder().encode(segments),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return
            }
            
            let insertSQL = """
            INSERT OR REPLACE INTO projects (url_key, title, duration, last_position, segments_json, updated_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """
            
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (urlKey as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (title as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 3, duration)
                sqlite3_bind_double(stmt, 4, lastPosition)
                sqlite3_bind_text(stmt, 5, (jsonString as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 6, Int64(Date().timeIntervalSince1970))
                
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }
    
    /// 加载指定媒体已保存的断句工程
    public func loadProject(for url: URL) -> SavedProjectData? {
        return queue.sync {
            guard let db = db else { return nil }
            
            let urlKey = url.path
            let querySQL = "SELECT title, duration, last_position, segments_json, updated_at FROM projects WHERE url_key = ? LIMIT 1;"
            
            var stmt: OpaquePointer?
            var result: SavedProjectData?
            
            if sqlite3_prepare_v2(db, querySQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (urlKey as NSString).utf8String, -1, nil)
                
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let title = String(cString: sqlite3_column_text(stmt, 0))
                    let duration = sqlite3_column_double(stmt, 1)
                    let lastPos = sqlite3_column_double(stmt, 2)
                    let jsonStr = String(cString: sqlite3_column_text(stmt, 3))
                    let timestamp = sqlite3_column_int64(stmt, 4)
                    
                    if let data = jsonStr.data(using: .utf8),
                       let segments = try? JSONDecoder().decode([SentenceSegment].self, from: data) {
                        result = SavedProjectData(
                            mediaURLString: url.absoluteString,
                            title: title,
                            duration: duration,
                            lastPosition: lastPos,
                            segments: segments,
                            updatedAt: Date(timeIntervalSince1970: TimeInterval(timestamp))
                        )
                    }
                }
            }
            sqlite3_finalize(stmt)
            return result
        }
    }

    public func flush() {
        queue.sync {}
    }
}
