import Foundation
import AppKit

private enum DictionaryResponseEvent {
    case progress(fraction: Double, phase: String?)
    case response(id: String, data: Data?, errorMessage: String?)
}

/// JSONL parsing is intentionally kept off the main actor. Rust responses
/// can contain large HTML records; decoding and re-encoding them on the main
/// actor made fast lookup sequences visibly stutter.
private final class DictionaryResponseParser: @unchecked Sendable {
    private var buffer = Data()
    private let onEvent: (DictionaryResponseEvent) -> Void

    init(onEvent: @escaping (DictionaryResponseEvent) -> Void) {
        self.onEvent = onEvent
    }

    func append(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer.prefix(upTo: newline))
            buffer.removeSubrange(...newline)
            guard
                let object = try? JSONSerialization.jsonObject(with: line),
                let dictionary = object as? [String: Any]
            else { continue }

            if dictionary["event"] as? String == "progress" {
                onEvent(.progress(
                    fraction: dictionary["fraction"] as? Double ?? 0,
                    phase: dictionary["phase"] as? String
                ))
                continue
            }
            guard let id = dictionary["id"] as? String else { continue }
            if (dictionary["ok"] as? Bool) == true,
               let result = dictionary["result"],
               let resultData = try? JSONSerialization.data(withJSONObject: result) {
                onEvent(.response(id: id, data: resultData, errorMessage: nil))
            } else {
                let message = (dictionary["error"] as? [String: Any])?["message"] as? String
                    ?? "词典请求失败。"
                onEvent(.response(id: id, data: nil, errorMessage: message))
            }
        }
    }
}

/// A bounded in-process cache for complete definitions.  Search results are
/// intentionally not cached here because they are cheap indexed key lookups
/// and depend on the current result limit.  Full definitions can contain
/// several hundred KB of HTML/CSS, so the cache is bounded by both entry
/// count and an approximate byte cost.
private final class DictionaryLookupCacheValue: NSObject {
    let entries: [StudyMateDictionaryLookup]

    init(entries: [StudyMateDictionaryLookup]) {
        self.entries = entries
    }
}

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
    public let css: String?
    public let resourceRoot: String?

    public var id: String { "\(dictionaryID):\(key)" }

    public init(
        key: String,
        text: String,
        dictionaryID: String,
        dictionaryTitle: String,
        css: String? = nil,
        resourceRoot: String? = nil
    ) {
        self.key = key
        self.text = text
        self.dictionaryID = dictionaryID
        self.dictionaryTitle = dictionaryTitle
        self.css = css
        self.resourceRoot = resourceRoot
    }

    enum CodingKeys: String, CodingKey {
        case key, text, css
        case dictionaryID = "dictionary_id"
        case dictionaryTitle = "dictionary_title"
        case resourceRoot = "resource_root"
    }
}

/// Lightweight row returned while the user is typing.  Full HTML and CSS
/// are intentionally fetched only after a row is selected.
public struct StudyMateDictionarySearchHit: Codable, Identifiable, Hashable, Sendable {
    public let key: String
    public let dictionaryID: String
    public let dictionaryTitle: String
    public let resourceRoot: String?

    public var id: String { "\(dictionaryID):\(key)" }

    public init(key: String, dictionaryID: String, dictionaryTitle: String, resourceRoot: String? = nil) {
        self.key = key
        self.dictionaryID = dictionaryID
        self.dictionaryTitle = dictionaryTitle
        self.resourceRoot = resourceRoot
    }

    enum CodingKeys: String, CodingKey {
        case key
        case dictionaryID = "dictionary_id"
        case dictionaryTitle = "dictionary_title"
        case resourceRoot = "resource_root"
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

    private static let detailCache: NSCache<NSString, DictionaryLookupCacheValue> = {
        let cache = NSCache<NSString, DictionaryLookupCacheValue>()
        cache.countLimit = 64
        // Keep repeated lookups fast without allowing a large dictionary
        // definition to grow the app's resident memory without a bound.
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    @Published public private(set) var dictionaries: [StudyMateDictionarySummary] = []
    @Published public private(set) var searchHits: [StudyMateDictionarySearchHit] = []
    /// Full definitions for the currently selected hit. Kept separately from
    /// `searchHits` so prefix search never has to transfer/render full HTML.
    @Published public private(set) var searchResults: [StudyMateDictionaryLookup] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var isLoadingDefinition = false
    @Published public private(set) var definitionQuery: String?
    @Published public private(set) var isBusy = false
    @Published public private(set) var progress: Double?
    @Published public private(set) var progressPhase: String?
    @Published public private(set) var lastError: String?
    @Published public private(set) var requestedQuery: String?

    public let dictionaryRoot: URL

    public func resourcesURL(for dictionaryID: String) -> URL {
        let sanitized = dictionaryID.unicodeScalars.map { scalar -> String in
            let value = scalar.value
            if (48...57).contains(value) || (65...90).contains(value) ||
                (97...122).contains(value) || value == 45 || value == 95 || value == 46 {
                return String(Character(scalar))
            }
            return "-"
        }.joined().replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let safeName = sanitized.isEmpty ? "dictionary" : String(sanitized.prefix(80))
        return dictionaryRoot.appendingPathComponent("\(safeName).mabdict").appendingPathComponent("resources")
    }

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private let responseQueue = DispatchQueue(
        label: "com.studymate.dictionary.response-parser",
        qos: .userInitiated
    )
    private var responseParser: DictionaryResponseParser?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var requestCounter: UInt64 = 0
    /// Identifies the currently running helper process. Process termination
    /// and pipe callbacks can arrive after a replacement helper has started;
    /// stale callbacks must never fail that new process's pending requests.
    private var helperGeneration: UInt64 = 0
    private var searchTask: Task<Void, Never>?
    private var queryDebounceTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private var detailGeneration: UInt64 = 0
    /// A refresh started while the window opens must not publish a stale
    /// snapshot after a dictionary mutation has completed.
    private var refreshTask: Task<Void, Never>?
    /// Dictionary mutations must be serialized with lookup cancellation and
    /// package list refreshes. Without this guard, deleting a selected
    /// package while a search is still in flight can leave the WebKit result
    /// view pointing at a package that is being removed.
    private var dictionaryMutationTask: Task<Void, Never>?
    private var lastProgressDate = Date.distantPast
    private var lastProgressPhase: String?

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
        searchTask?.cancel()
        queryDebounceTask?.cancel()
        detailTask?.cancel()
        refreshTask?.cancel()
        dictionaryMutationTask?.cancel()
        output?.readabilityHandler = nil
        responseParser = nil
        process?.terminate()
    }

    public func refresh() {
        refreshTask?.cancel()
        guard !isBusy else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.request(operation: "list")
                guard !Task.isCancelled, !self.isBusy else { return }
                self.dictionaries = try await Self.decodeInBackground([StudyMateDictionarySummary].self, from: value)
                self.lastError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Invalidate every lookup pipeline before a package mutation. Cancelling
    /// the Task is not enough by itself: an already-delivered JSON response can
    /// still reach the main actor after cancellation, so both generations must
    /// advance before the filesystem mutation starts.
    private func invalidateLookupTasks() {
        queryDebounceTask?.cancel()
        queryDebounceTask = nil
        searchTask?.cancel()
        searchTask = nil
        detailTask?.cancel()
        detailTask = nil
        searchGeneration &+= 1
        detailGeneration &+= 1
        searchHits = []
        searchResults = []
        isSearching = false
        isLoadingDefinition = false
        definitionQuery = nil
    }

    /// Schedule a lightweight key search. A short debounce keeps fast typing
    /// from filling the serial JSONL helper with obsolete requests. Callers
    /// that need the complete definition (the lookup popover) opt in with
    /// `includeDetails`.
    public func search(
        query: String,
        dictionaryID: String? = nil,
        includeDetails: Bool = false,
        immediate: Bool = false
    ) {
        queryDebounceTask?.cancel()
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        let trimmed = Self.normalizedQuery(query)

        guard !trimmed.isEmpty else {
            searchHits = []
            searchResults = []
            isSearching = false
            isLoadingDefinition = false
            definitionQuery = nil
            return
        }

        if includeDetails {
            detailTask?.cancel()
            detailGeneration &+= 1
            searchResults = []
            definitionQuery = nil
            isLoadingDefinition = true
        } else {
            // A new window search must not let an older detail request finish
            // later and overwrite the definition selected for this query.
            detailTask?.cancel()
            detailTask = nil
            detailGeneration &+= 1
            searchResults = []
            definitionQuery = nil
            isLoadingDefinition = false
        }
        isSearching = true

        // 180 ms is long enough to coalesce ordinary typing. Explicit
        // toolbar/shortcut lookups bypass the debounce entirely.
        if immediate {
            startSearch(
                query: trimmed,
                dictionaryID: dictionaryID,
                includeDetails: includeDetails,
                generation: generation
            )
            return
        }
        queryDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled, let self else { return }
                    self.startSearch(
                    query: trimmed,
                    dictionaryID: dictionaryID,
                    includeDetails: includeDetails,
                    generation: generation
                )
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func startSearch(
        query: String,
        dictionaryID: String?,
        includeDetails: Bool,
        generation: UInt64
    ) {
        guard generation == searchGeneration, !isBusy else {
            if generation == searchGeneration { isSearching = false }
            return
        }

        let limit = adaptiveSearchLimit(for: query)
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                var fields: [String: Any] = [
                    "query": query,
                    "limit": limit
                ]
                if let dictionaryID {
                    fields["dictionaryID"] = dictionaryID
                }
                let operation = dictionaryID == nil ? "lookupAllKeys" : "lookupKeys"
                let value = try await self.request(operation: operation, fields: fields)
                let hits = try await Self.decodeInBackground([StudyMateDictionarySearchHit].self, from: value)
                guard !Task.isCancelled,
                      generation == self.searchGeneration,
                      !self.isBusy else { return }

                self.searchHits = hits
                self.isSearching = false
                self.lastError = nil
                if hits.isEmpty {
                    self.searchResults = []
                    self.definitionQuery = nil
                    self.isLoadingDefinition = false
                } else if includeDetails, let first = hits.first {
                    self.loadDefinition(
                        for: first.key,
                        dictionaryID: dictionaryID,
                        expectedSearchGeneration: generation,
                        immediate: true
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.searchGeneration, !self.isBusy else { return }
                self.searchHits = []
                self.searchResults = []
                self.isSearching = false
                self.isLoadingDefinition = false
                self.definitionQuery = nil
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Load one complete definition after a result row is selected.
    public func loadDefinition(for key: String, dictionaryID: String? = nil) {
        loadDefinition(for: key, dictionaryID: dictionaryID, expectedSearchGeneration: nil, immediate: false)
    }

    private func loadDefinition(
        for key: String,
        dictionaryID: String?,
        expectedSearchGeneration: UInt64?,
        immediate: Bool
    ) {
        let normalizedKey = Self.normalizedQuery(key)
        guard !normalizedKey.isEmpty else { return }
        if let expectedSearchGeneration, expectedSearchGeneration != searchGeneration { return }

        detailTask?.cancel()
        detailGeneration &+= 1
        let generation = detailGeneration

        // A cached definition still advances the generation and cancels the
        // previous request first.  This makes a fast row change deterministic:
        // an older in-flight lookup cannot publish after this cache hit.
        if let cached = Self.detailCache.object(forKey: Self.detailCacheKey(for: normalizedKey, dictionaryID: dictionaryID)) {
            searchResults = cached.entries
            definitionQuery = key
            isLoadingDefinition = false
            lastError = nil
            detailTask = nil
            return
        }

        isLoadingDefinition = true

        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !immediate {
                    try await Task.sleep(nanoseconds: 60_000_000)
                }
                try Task.checkCancellation()
                var fields: [String: Any] = [
                    "query": normalizedKey,
                    // The SQL ordering puts an exact match first. One row per
                    // dictionary is enough for the selected definition.
                    "limit": 1
                ]
                if let dictionaryID {
                    fields["dictionaryID"] = dictionaryID
                }
                let operation = dictionaryID == nil ? "lookupAll" : "lookup"
                let value = try await self.request(operation: operation, fields: fields)
                let entries = try await Self.decodeInBackground([StudyMateDictionaryLookup].self, from: value)
                guard !Task.isCancelled,
                      generation == self.detailGeneration,
                      !self.isBusy else { return }
                if !entries.isEmpty {
                    Self.detailCache.setObject(
                        DictionaryLookupCacheValue(entries: entries),
                        forKey: Self.detailCacheKey(for: normalizedKey, dictionaryID: dictionaryID),
                        cost: Self.detailCacheCost(entries)
                    )
                }
                self.searchResults = entries
                self.definitionQuery = key
                self.isLoadingDefinition = false
                self.lastError = nil
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.detailGeneration, !self.isBusy else { return }
                self.searchResults = []
                self.isLoadingDefinition = false
                self.lastError = error.localizedDescription
            }
        }
    }

    private func adaptiveSearchLimit(for query: String) -> Int {
        let count = query.unicodeScalars.count
        switch count {
        case 0...1: return 30
        case 2: return 60
        default: return 100
        }
    }

    @Published public private(set) var statusMessage: String?

    public func showNotification(_ message: String, autoDismissAfter seconds: Double = 3.0) {
        statusMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if self?.statusMessage == message {
                self?.statusMessage = nil
            }
        }
    }

    public func deleteDictionary(id: String) {
        guard !isBusy, !id.isEmpty else { return }

        // Stop publishing results that may still reference files inside the
        // package. The view can therefore dismantle its WKWebView before
        // the Rust core removes the package directory.
        invalidateLookupTasks()
        refreshTask?.cancel()
        refreshTask = nil
        Self.detailCache.removeAllObjects()

        isBusy = true
        progress = nil
        progressPhase = LanguageManager.shared.text("正在删除词典…", "Deleting dictionary…")
        lastError = nil

        dictionaryMutationTask?.cancel()
        dictionaryMutationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.dictionaryMutationTask = nil }
            do {
                // Let SwiftUI apply the cleared results and dismantle any
                // WKWebView that may still reference package resources.
                await Task.yield()
                let deletedData = try await self.request(
                    operation: "delete",
                    fields: ["dictionaryID": id]
                )
                let deleted = try await Self.decodeInBackground(Bool.self, from: deletedData)
                guard deleted else {
                    // The row may have been removed by another StudyMate
                    // instance (or by a previous interrupted cleanup). Bring
                    // the UI back in sync even though this request reports a
                    // miss, instead of leaving a dead row until the next
                    // window refresh.
                    self.dictionaries.removeAll { $0.id == id }
                    if let value = try? await self.request(operation: "list"),
                       let updated = try? await Self.decodeInBackground([StudyMateDictionarySummary].self, from: value) {
                        self.dictionaries = updated
                    }
                    throw StudyMateDictionaryError(message: LanguageManager.shared.text(
                        "未找到要删除的词典。",
                        "The dictionary to delete could not be found."
                    ))
                }

                // Reflect the completed filesystem mutation immediately. If
                // the follow-up list request is delayed or the helper exits,
                // the just-deleted row must not remain visible as if it were
                // still usable.
                self.dictionaries.removeAll { $0.id == id }

                let value = try await self.request(operation: "list")
                let updated = try await Self.decodeInBackground([StudyMateDictionarySummary].self, from: value)

                self.dictionaries = updated
                self.searchResults.removeAll { $0.dictionaryID == id }
                self.isBusy = false
                self.progressPhase = nil
                self.lastError = nil
                self.showNotification(
                    LanguageManager.shared.text("已删除词典", "Dictionary deleted")
                )
            } catch {
                self.isBusy = false
                self.progressPhase = nil
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
        invalidateLookupTasks()
        refreshTask?.cancel()
        refreshTask = nil
        Self.detailCache.removeAllObjects()
        isBusy = true
        progress = 0.05
        progressPhase = LanguageManager.shared.text("正在准备导入词典…", "Preparing to import dictionary…")
        lastError = nil

        let mdxPath = mdx.path
        let mddPaths = mdd.map(\.path)
        let stem = mdx.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " ", with: "-")

        dictionaryMutationTask?.cancel()
        dictionaryMutationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.dictionaryMutationTask = nil }
            do {
                var fields: [String: Any] = [
                    "mdxPath": mdxPath,
                    "mddPaths": mddPaths
                ]
                if let registrationCode, !registrationCode.isEmpty {
                    fields["registrationCode"] = registrationCode
                }
                if let userID, !userID.isEmpty {
                    fields["userID"] = userID
                }
                if !stem.isEmpty { fields["dictionaryID"] = stem }

                let value = try await self.request(operation: "import", fields: fields)
                let result = try await Self.decodeInBackground(StudyMateDictionaryImportResult.self, from: value)

                self.dictionaries.append(result.dictionary)
                self.dictionaries.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                self.progress = 1.0
                self.progressPhase = nil
                self.isBusy = false
                self.lastError = nil
                self.showNotification(
                    LanguageManager.shared.text("已成功导入词典“\(result.dictionary.title)”", "Imported dictionary “\(result.dictionary.title)”")
                )
            } catch {
                self.isBusy = false
                self.progress = nil
                self.progressPhase = nil
                self.lastError = error.localizedDescription
            }
        }
    }

    public func clearError() {
        lastError = nil
        statusMessage = nil
    }

    public func clearSearch() {
        invalidateLookupTasks()
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
        let resource = try await Self.decodeInBackground(StudyMateDictionaryResource?.self, from: value)
        guard let resource else { return nil }
        return URL(fileURLWithPath: resource.path, isDirectory: false)
    }

    /// Resolve a pronunciation from the first installed MDX dictionary. The
    /// Rust core searches the resources imported from its MDD volumes by
    /// filename, so this remains cheap even for large pronunciation packs.
    public func firstDictionaryPronunciationURL(for word: String) async throws -> URL? {
        var firstDictionary = dictionaries.first
        if firstDictionary == nil, !isBusy {
            let value = try await request(operation: "list")
            let summaries = try await Self.decodeInBackground([StudyMateDictionarySummary].self, from: value)
            guard !Task.isCancelled else { return nil }
            dictionaries = summaries
            firstDictionary = summaries.first
        }
        guard let firstDictionary else { return nil }
        let value = try await request(operation: "findAudio", fields: [
            "dictionaryID": firstDictionary.id,
            "word": word
        ])
        let resource = try await Self.decodeInBackground(StudyMateDictionaryResource?.self, from: value)
        guard let resource, resource.size > 0 else { return nil }
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
        let length = (textView.string as NSString).length
        guard range.length > 0,
              range.location != NSNotFound,
              range.location <= length,
              range.length <= length - range.location else { return }
        let selected = (textView.string as NSString).substring(with: range)
        requestLookup(selected)
    }

    public func consumeRequestedQuery() -> String? {
        let value = requestedQuery
        requestedQuery = nil
        return value
    }

    private struct StudyMateDictionaryImportResult: Codable, Sendable {
        let dictionary: StudyMateDictionarySummary
        let packagePath: String

        enum CodingKeys: String, CodingKey {
            case dictionary
            case packagePath = "package_path"
        }
    }

    private nonisolated static func normalizedQuery(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    private nonisolated static func detailCacheKey(for query: String, dictionaryID: String?) -> NSString {
        let scope = dictionaryID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "*"
        return "\(scope)|\(normalizedQuery(query))" as NSString
    }

    private nonisolated static func detailCacheCost(_ entries: [StudyMateDictionaryLookup]) -> Int {
        let bytes = entries.reduce(into: 0) { total, entry in
            total += entry.key.utf8.count
            total += entry.text.utf8.count
            total += entry.dictionaryID.utf8.count
            total += entry.dictionaryTitle.utf8.count
            total += entry.css?.utf8.count ?? 0
            total += entry.resourceRoot?.utf8.count ?? 0
        }
        // NSCache treats zero as an immediately discardable value. Keep a
        // small positive cost even for an unusually empty record.
        return max(bytes, 1)
    }

    private nonisolated static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    private nonisolated static func decodeInBackground<T: Decodable & Sendable>(
        _ type: T.Type,
        from data: Data
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try Self.decode(type, from: data)
        }.value
    }

    private func request(operation: String, fields: [String: Any] = [:]) async throws -> Data {
        try Task.checkCancellation()
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
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                do {
                    try input?.write(contentsOf: line)
                } catch {
                    pending.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelPendingRequest(id)
            }
        })
    }

    private func cancelPendingRequest(_ id: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func ensureProcess() throws {
        if process?.isRunning == true { return }
        try FileManager.default.createDirectory(
            at: dictionaryRoot,
            withIntermediateDirectories: true
        )
        let executable = try helperURL()
        let process = Process()
        helperGeneration &+= 1
        let generation = helperGeneration
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["serve"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        let parser = DictionaryResponseParser { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleResponseEvent(event, generation: generation)
            }
        }
        responseParser = parser
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self, weak parser] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self, let parser else { return }
            self.responseQueue.async {
                parser.append(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.helperDidTerminate(generation: generation)
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

    private func handleResponseEvent(_ event: DictionaryResponseEvent, generation: UInt64) {
        guard generation == helperGeneration else { return }
        switch event {
        case let .progress(fraction, phase):
            let now = Date()
            let phaseChanged = phase != lastProgressPhase
            guard phaseChanged || fraction >= 1 || now.timeIntervalSince(lastProgressDate) >= 0.05 else {
                return
            }
            lastProgressDate = now
            lastProgressPhase = phase
            progress = fraction
            progressPhase = phase
        case let .response(id, data, errorMessage):
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let data {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: StudyMateDictionaryError(
                    message: errorMessage ?? "词典请求失败。"
                ))
            }
        }
    }

    private func helperDidTerminate(generation: UInt64) {
        guard generation == helperGeneration else { return }
        // Invalidate any pipe/parser callbacks already queued for this helper
        // before a retry is allowed to start a replacement process.
        helperGeneration &+= 1
        failPending(with: StudyMateDictionaryError(
            message: "词典引擎已退出，请重试。"
        ))
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
        responseParser = nil
    }
}
