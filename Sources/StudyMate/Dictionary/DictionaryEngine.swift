import Foundation
import AppKit

/// A platform-neutral value returned by the Rust dictionary core.
public struct StudyMateDictionarySummary: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let encoding: String
    public let format: String
    public let entryCount: Int
    public let resourceCount: Int
    public let importedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, encoding, format
        case entryCount = "entry_count"
        case resourceCount = "resource_count"
        case importedAt = "imported_at"
    }

    public init(
        id: String,
        title: String,
        encoding: String,
        format: String,
        entryCount: Int,
        resourceCount: Int,
        importedAt: Date
    ) {
        self.id = id
        self.title = title
        self.encoding = encoding
        self.format = format
        self.entryCount = entryCount
        self.resourceCount = resourceCount
        self.importedAt = importedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        encoding = try container.decode(String.self, forKey: .encoding)
        format = try container.decode(String.self, forKey: .format)
        entryCount = try container.decodeIfPresent(Int.self, forKey: .entryCount) ?? 0
        resourceCount = try container.decodeIfPresent(Int.self, forKey: .resourceCount) ?? 0
        let seconds = try container.decodeIfPresent(Double.self, forKey: .importedAt) ?? 0
        importedAt = Date(timeIntervalSince1970: seconds)
    }
}

public struct StudyMateDictionaryLookup: Codable, Identifiable, Hashable, Sendable {
    public let key: String
    public let text: String
    public let dictionaryID: String
    public let dictionaryTitle: String

    public var id: String { "\(dictionaryID):\(key)" }

    enum CodingKeys: String, CodingKey {
        case key, text
        case dictionaryID = "dictionary_id"
        case dictionaryTitle = "dictionary_title"
    }
}

/// A dictionary resource extracted from an MDD package.
///
/// The path points inside the imported `.mabdict` package and is exposed as a
/// value object so a future AppKit/iOS/Android adapter can hand the resource
/// to an image/audio renderer without knowing the SQLite schema.
public struct StudyMateDictionaryResource: Codable, Identifiable, Hashable, Sendable {
    public let key: String
    public let path: String
    public let size: Int

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, path, size
    }
}

public struct StudyMateDictionaryError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Main-actor adapter for a long-lived Rust JSONL process.
///
/// Only this small adapter is macOS-specific. The Rust core stores portable
/// dictionary packages under Application Support and can be reused by mobile
/// clients through a future C ABI without sharing any SwiftUI code.
@MainActor
public final class DictionaryEngine: ObservableObject {
    public static let shared = DictionaryEngine()

    @Published public private(set) var dictionaries: [StudyMateDictionarySummary] = []
    @Published public private(set) var searchResults: [StudyMateDictionaryLookup] = []
    @Published public private(set) var isBusy = false
    @Published public private(set) var progress: Double?
    @Published public private(set) var lastError: String?
    @Published public private(set) var requestedQuery: String?

    public let dictionaryRoot: URL

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputBuffer = Data()
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var requestCounter: UInt64 = 0
    private var searchTask: Task<Void, Never>?

    public init(root: URL? = nil) {
        if let root {
            dictionaryRoot = root
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            dictionaryRoot = support
                .appendingPathComponent("StudyMate", isDirectory: true)
                .appendingPathComponent("Dictionaries", isDirectory: true)
        }
    }

    deinit {
        output?.readabilityHandler = nil
        process?.terminate()
    }

    public func refresh() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.request(operation: "list")
                self.dictionaries = try self.decode([StudyMateDictionarySummary].self, from: value)
                self.lastError = nil
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    public func search(query: String, dictionaryID: String? = nil) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            do {
                var fields: [String: Any] = [
                    "query": trimmed,
                    "limit": 30
                ]
                if let dictionaryID {
                    fields["dictionaryID"] = dictionaryID
                }
                let operation = dictionaryID == nil ? "lookupAll" : "lookup"
                let value = try await self.request(operation: operation, fields: fields)
                self.searchResults = try self.decode([StudyMateDictionaryLookup].self, from: value)
                self.lastError = nil
            } catch is CancellationError {
                // A newer query superseded this one.
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    public func importDictionary(
        mdx: URL,
        mdd: [URL] = [],
        registrationCode: String? = nil,
        userID: String? = nil
    ) {
        guard !isBusy else { return }
        isBusy = true
        progress = 0
        lastError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                var fields: [String: Any] = [
                    "mdxPath": mdx.path,
                    "mddPaths": mdd.map(\.path)
                ]
                if let registrationCode, !registrationCode.isEmpty {
                    fields["registrationCode"] = registrationCode
                }
                if let userID, !userID.isEmpty {
                    fields["userID"] = userID
                }
                let stem = mdx.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: " ", with: "-")
                if !stem.isEmpty { fields["dictionaryID"] = stem }
                let value = try await self.request(operation: "import", fields: fields)
                let result = try self.decode(StudyMateDictionaryImportResult.self, from: value)
                self.dictionaries.append(result.dictionary)
                self.dictionaries.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                self.progress = 1
            } catch {
                self.lastError = error.localizedDescription
            }
            self.isBusy = false
            self.progress = nil
        }
    }

    public func clearError() {
        lastError = nil
    }

    public func clearSearch() {
        searchTask?.cancel()
        searchResults = []
    }

    /// Resolve an MDD resource through the Rust core.  The returned URL is
    /// only valid while its dictionary package remains installed; callers
    /// should copy the bytes they need rather than persist this path as an
    /// external application reference.
    public func resourceURL(dictionaryID: String, key: String) async throws -> URL? {
        let value = try await request(operation: "resource", fields: [
            "dictionaryID": dictionaryID,
            "key": key
        ])
        let resource = try decode(StudyMateDictionaryResource?.self, from: value)
        guard let resource else { return nil }
        return URL(fileURLWithPath: resource.path, isDirectory: false)
    }

    public func reportError(_ message: String) {
        lastError = message
    }

    public func requestLookup(_ query: String) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        requestedQuery = value
    }

    /// Capture the currently selected subtitle text before opening the
    /// dictionary window. SwiftUI's selectable Text is backed by NSTextView
    /// on macOS, so this keeps the lookup affordance identical for the menu,
    /// keyboard shortcut, and toolbar button.
    public func requestLookupFromCurrentSelection() {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }
        let selected = (textView.string as NSString).substring(with: range)
        requestLookup(selected)
    }

    public func consumeRequestedQuery() -> String? {
        let value = requestedQuery
        requestedQuery = nil
        return value
    }

    private struct StudyMateDictionaryImportResult: Codable {
        let dictionary: StudyMateDictionarySummary
        let packagePath: String

        enum CodingKeys: String, CodingKey {
            case dictionary
            case packagePath = "package_path"
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    private func request(operation: String, fields: [String: Any] = [:]) async throws -> Data {
        try ensureProcess()
        requestCounter &+= 1
        let id = String(requestCounter)
        var object = fields
        object["id"] = id
        object["op"] = operation
        object["root"] = dictionaryRoot.path
        let encoded = try JSONSerialization.data(withJSONObject: object)
        var line = encoded
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try input?.write(contentsOf: line)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func ensureProcess() throws {
        if process?.isRunning == true { return }
        try FileManager.default.createDirectory(
            at: dictionaryRoot,
            withIntermediateDirectories: true
        )
        let executable = try helperURL()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["serve"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consume(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.failPending(with: StudyMateDictionaryError(
                    message: "词典引擎已退出，请重试。"
                ))
            }
        }
        try process.run()
        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
    }

    private func helperURL() throws -> URL {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "studymate-dict", withExtension: nil, subdirectory: "Helpers"),
            Bundle.main.resourceURL?.appendingPathComponent("Helpers/studymate-dict"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/studymate-dict"),
            Bundle.main.bundleURL.appendingPathComponent("Helpers/studymate-dict"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Dictionary/target/release/studymate-dict"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Dictionary/target/release/studymate-dict"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Dictionary/target/debug/studymate-dict")
        ]
        if let url = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return url
        }
        throw StudyMateDictionaryError(
            message: "未找到词典引擎。请重新构建 StudyMate，或把 studymate-dict 放入应用的 Resources/Helpers。"
        )
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard
                let object = try? JSONSerialization.jsonObject(with: line),
                let dictionary = object as? [String: Any]
            else { continue }
            if let event = dictionary["event"] as? String, event == "progress" {
                if let fraction = dictionary["fraction"] as? Double {
                    progress = fraction
                }
                continue
            }
            guard let id = dictionary["id"] as? String, let continuation = pending.removeValue(forKey: id) else {
                continue
            }
            if let ok = dictionary["ok"] as? Bool, ok,
               let result = dictionary["result"] {
                if let resultData = try? JSONSerialization.data(withJSONObject: result) {
                    continuation.resume(returning: resultData)
                } else {
                    continuation.resume(throwing: StudyMateDictionaryError(message: "词典返回数据无法解析。"))
                }
            } else {
                let message = (dictionary["error"] as? [String: Any])?["message"] as? String
                    ?? "词典请求失败。"
                continuation.resume(throwing: StudyMateDictionaryError(message: message))
            }
        }
    }

    private func failPending(with error: Error) {
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting {
            continuation.resume(throwing: error)
        }
        process = nil
        input = nil
        output = nil
    }
}
