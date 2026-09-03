import Foundation
import AppKit
import Combine
import OSLog
import NaturalLanguage

/// macOS 原生自然语言词形还原器，用于在词典查询变形词（如 running、studied、better）未命中时，
/// 自动分析提取原型（lemma，如 run、study、good）进行无感回退查询。
public enum StudyMateLemmatizer {
    public static func lemma(for word: String) -> String? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = trimmed
        let (tag, _) = tagger.tag(at: trimmed.startIndex, unit: .word, scheme: .lemma)
        guard let raw = tag?.rawValue else { return fallbackLemma(for: trimmed) }
        let rawLemma = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawLemma.isEmpty,
              rawLemma.lowercased() != trimmed.lowercased() else {
            return fallbackLemma(for: trimmed)
        }
        return rawLemma
    }

    /// NaturalLanguage normally supplies the result, but its bundled language
    /// resources can be unavailable during early app startup or in a fresh
    /// test/runtime sandbox. Keep common English inflections usable in that
    /// case so a missing system tag does not silently disable dictionary
    /// fallback lookup.
    private static func fallbackLemma(for word: String) -> String? {
        let lower = word.lowercased()
        let candidate: String?
        if lower.hasSuffix("ies"), lower.count > 4 {
            candidate = String(lower.dropLast(3)) + "y"
        } else if lower.hasSuffix("es"), lower.count > 4 {
            let stem = String(lower.dropLast(2))
            candidate = ["s", "x", "z", "ch", "sh"].contains(where: { stem.hasSuffix($0) })
                ? stem
                : nil
        } else if lower.hasSuffix("ing"), lower.count > 5 {
            var stem = String(lower.dropLast(3))
            if stem.count >= 2 {
                let chars = Array(stem)
                if chars[chars.count - 1] == chars[chars.count - 2] {
                    stem.removeLast()
                }
            }
            candidate = stem
        } else if lower.hasSuffix("ed"), lower.count > 4 {
            var stem = String(lower.dropLast(2))
            if stem.hasSuffix("i") {
                stem.removeLast()
                stem.append("y")
            }
            candidate = stem
        } else if lower.hasSuffix("s"), lower.count > 3 {
            candidate = String(lower.dropLast())
        } else {
            candidate = nil
        }
        guard let candidate, candidate != lower, candidate.count > 1 else { return nil }
        return candidate
    }
}

enum DictionaryResponseEvent {
    case progress(id: String?, fraction: Double, phase: String?)
    case response(id: String, data: Data?, errorMessage: String?)
}

/// JSONL parsing is intentionally kept off the main actor. Rust responses
/// can contain large HTML records; decoding and re-encoding them on the main
/// actor made fast lookup sequences visibly stutter.
final class DictionaryResponseParser: @unchecked Sendable {
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
                    id: dictionary["id"] as? String,
                    fraction: dictionary["fraction"] as? Double ?? 0,
                    phase: dictionary["phase"] as? String
                ))
                continue
            }
            guard let id = dictionary["id"] as? String else { continue }
            if (dictionary["ok"] as? Bool) == true,
               let result = dictionary["result"],
               // Rust responses may legitimately contain a JSON fragment at
               // the top level: `delete` returns a Boolean and `findAudio`
               // returns null when no pronunciation resource exists. The
               // default Foundation writer rejects those fragments by
               // throwing an Objective-C exception, which cannot be caught by
               // Swift's `try?` and terminates the application. Allowing JSON
               // fragments keeps the JSONL bridge total for every valid Rust
               // response shape.
               let resultData = try? JSONSerialization.data(
                   withJSONObject: result,
                   options: [.fragmentsAllowed]
               ) {
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

private struct DeferredDictionarySearch: Sendable {
    let query: String
    let dictionaryID: String?
    let includeDetails: Bool
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

    /// The user-facing name. The raw MDX metadata remains available through
    /// `title`; this presentation name is resolved from the stable package ID
    /// so renaming never changes lookup, resource, or pronunciation behavior.
    public var displayName: String {
        DictionarySourceSettings.shared.displayName(for: id, fallback: title)
    }

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

/// Stores the user's dictionary enablement and lookup priority without
/// touching the dictionary packages or creating another index. The IDs are
/// stable Rust package IDs, so renaming a dictionary in its MDX metadata does
/// not reset the user's choices.
public final class DictionarySourceSettings: ObservableObject {
    public static let shared = DictionarySourceSettings()

    public static let orderUserDefaultsKey = "StudyMate.DictionarySourceOrder"
    public static let enabledUserDefaultsKey = "StudyMate.EnabledDictionaryIDs"
    public static let displayNamesUserDefaultsKey = "StudyMate.DictionaryDisplayNames"
    public static let lookupScopeDictionaryIDUserDefaultsKey = "StudyMate.LookupScopeDictionaryID"

    @Published public private(set) var orderedDictionaryIDs: [String]
    @Published public private(set) var enabledDictionaryIDs: Set<String>
    @Published public private(set) var customDisplayNames: [String: String]
    /// 选词查词界面限定使用的词典 ID，nil 表示“全部”（默认值）
    @Published public private(set) var lookupScopeDictionaryID: String?
    /// A lightweight lifecycle signal for views that need to refresh the
    /// current query after a toggle or a reorder.
    @Published public private(set) var revision: UInt64 = 0
    /// Name-only changes refresh labels and rendered source badges without
    /// restarting the active dictionary query.
    @Published public private(set) var displayNameRevision: UInt64 = 0

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        orderedDictionaryIDs = defaults.stringArray(forKey: Self.orderUserDefaultsKey) ?? []
        enabledDictionaryIDs = Set(
            defaults.stringArray(forKey: Self.enabledUserDefaultsKey) ?? []
        )
        customDisplayNames = (defaults.dictionary(forKey: Self.displayNamesUserDefaultsKey) as? [String: String]) ?? [:]
        lookupScopeDictionaryID = defaults.string(forKey: Self.lookupScopeDictionaryIDUserDefaultsKey)
    }

    /// Reconciles persisted choices with the installed packages. New
    /// dictionaries are appended and enabled by default; removed packages are
    /// discarded from both persisted collections.
    public func synchronize(with dictionaries: [StudyMateDictionarySummary]) {
        // An empty snapshot can be observed while the helper is still
        // starting. Keep the persisted choices until a real package list is
        // available; successful deletion explicitly removes its ID below.
        guard !dictionaries.isEmpty else { return }
        let installedIDs = dictionaries.map(\.id)
        let installedSet = Set(installedIDs)

        var reconciledOrder: [String] = []
        var seen = Set<String>()
        for id in orderedDictionaryIDs where installedSet.contains(id) {
            if seen.insert(id).inserted {
                reconciledOrder.append(id)
            }
        }
        for id in installedIDs where seen.insert(id).inserted {
            reconciledOrder.append(id)
        }

        let hasStoredEnabledState = defaults.object(forKey: Self.enabledUserDefaultsKey) != nil
        var reconciledEnabled: Set<String> = hasStoredEnabledState
            ? enabledDictionaryIDs.intersection(installedSet)
            : installedSet
        if hasStoredEnabledState {
            // An installed ID absent from the persisted order is a newly
            // imported dictionary. Preserve explicit user disables for older
            // IDs, but make the new package immediately usable by default.
            let previouslyKnownIDs = Set(orderedDictionaryIDs)
            for id in installedIDs where !previouslyKnownIDs.contains(id) {
                reconciledEnabled.insert(id)
            }
        }

        let orderChanged = reconciledOrder != orderedDictionaryIDs
        let enabledChanged = reconciledEnabled != enabledDictionaryIDs
        let reconciledDisplayNames = customDisplayNames.filter { installedSet.contains($0.key) }
        let displayNamesChanged = reconciledDisplayNames != customDisplayNames
        if let currentScope = lookupScopeDictionaryID, !installedSet.contains(currentScope) {
            lookupScopeDictionaryID = nil
            defaults.removeObject(forKey: Self.lookupScopeDictionaryIDUserDefaultsKey)
        }
        guard orderChanged || enabledChanged || displayNamesChanged || (!installedIDs.isEmpty && !hasStoredEnabledState) else {
            return
        }

        orderedDictionaryIDs = reconciledOrder
        enabledDictionaryIDs = reconciledEnabled
        customDisplayNames = reconciledDisplayNames
        persist()
        if orderChanged || enabledChanged || (!installedIDs.isEmpty && !hasStoredEnabledState) {
            revision &+= 1
        }
        if displayNamesChanged {
            displayNameRevision &+= 1
        }
    }

    public func orderedDictionaries(
        from dictionaries: [StudyMateDictionarySummary]
    ) -> [StudyMateDictionarySummary] {
        let byID = Dictionary(uniqueKeysWithValues: dictionaries.map { ($0.id, $0) })
        return orderedDictionaryIDs.compactMap { byID[$0] }
    }

    public func enabledDictionaries(
        from dictionaries: [StudyMateDictionarySummary]
    ) -> [StudyMateDictionarySummary] {
        orderedDictionaries(from: dictionaries).filter {
            enabledDictionaryIDs.contains($0.id)
        }
    }

    public func isEnabled(_ dictionaryID: String) -> Bool {
        enabledDictionaryIDs.contains(dictionaryID)
    }

    /// Returns the stable, user-facing name for a dictionary. The fallback is
    /// deliberately supplied by the caller so this method also works for
    /// search/detail records that only carry the Rust metadata title.
    public func displayName(for dictionaryID: String, fallback: String) -> String {
        guard let customName = customDisplayNames[dictionaryID] else { return fallback }
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    public func hasCustomDisplayName(for dictionaryID: String) -> Bool {
        guard let customName = customDisplayNames[dictionaryID] else { return false }
        return !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Empty input restores the MDX metadata name. Names are presentation
    /// overrides only and never modify the imported dictionary package.
    public func setDisplayName(_ name: String?, for dictionaryID: String) {
        guard !dictionaryID.isEmpty else { return }
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = customDisplayNames
        if let normalizedName, !normalizedName.isEmpty {
            updated[dictionaryID] = normalizedName
        } else {
            updated.removeValue(forKey: dictionaryID)
        }
        guard updated != customDisplayNames else { return }
        customDisplayNames = updated
        persist()
        displayNameRevision &+= 1
    }

    public func setEnabled(_ enabled: Bool, for dictionaryID: String) {
        guard !dictionaryID.isEmpty else { return }
        var updated = enabledDictionaryIDs
        if enabled {
            updated.insert(dictionaryID)
        } else {
            updated.remove(dictionaryID)
        }
        guard updated != enabledDictionaryIDs else { return }
        enabledDictionaryIDs = updated
        persist()
        revision &+= 1
    }

    public func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var updated = orderedDictionaryIDs
        updated.move(fromOffsets: offsets, toOffset: destination)
        guard updated != orderedDictionaryIDs else { return }
        orderedDictionaryIDs = updated
        persist()
        revision &+= 1
    }

    /// Applies a complete visible order in one transaction. Drag previews
    /// should stay in memory while the pointer moves; persisting and notifying
    /// the dictionary engine only once when the drop finishes keeps reordering
    /// responsive even with many installed dictionaries.
    public func setOrder(_ requestedOrder: [String]) {
        let knownIDs = Set(orderedDictionaryIDs)
        var seen = Set<String>()
        let reorderedKnownIDs = requestedOrder.filter { id in
            knownIDs.contains(id) && seen.insert(id).inserted
        }
        guard !reorderedKnownIDs.isEmpty else { return }

        let updated = reorderedKnownIDs + orderedDictionaryIDs.filter {
            !seen.contains($0)
        }
        guard updated != orderedDictionaryIDs else { return }
        orderedDictionaryIDs = updated
        persist()
        revision &+= 1
    }

    public func setLookupScopeDictionaryID(_ id: String?) {
        let normalized = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = (normalized?.isEmpty == false) ? normalized : nil
        guard effective != lookupScopeDictionaryID else { return }
        lookupScopeDictionaryID = effective
        if let effective {
            defaults.set(effective, forKey: Self.lookupScopeDictionaryIDUserDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.lookupScopeDictionaryIDUserDefaultsKey)
        }
    }

    public func remove(dictionaryID: String) {
        guard !dictionaryID.isEmpty else { return }
        if lookupScopeDictionaryID == dictionaryID {
            lookupScopeDictionaryID = nil
            defaults.removeObject(forKey: Self.lookupScopeDictionaryIDUserDefaultsKey)
        }
        let updatedOrder = orderedDictionaryIDs.filter { $0 != dictionaryID }
        var updatedEnabled = enabledDictionaryIDs
        updatedEnabled.remove(dictionaryID)
        var updatedDisplayNames = customDisplayNames
        updatedDisplayNames.removeValue(forKey: dictionaryID)
        let sourceSettingsChanged = updatedOrder != orderedDictionaryIDs
            || updatedEnabled != enabledDictionaryIDs
        let displayNameChanged = updatedDisplayNames != customDisplayNames
        guard sourceSettingsChanged || displayNameChanged else { return }
        orderedDictionaryIDs = updatedOrder
        enabledDictionaryIDs = updatedEnabled
        customDisplayNames = updatedDisplayNames
        persist()
        if sourceSettingsChanged {
            revision &+= 1
        }
        if displayNameChanged {
            displayNameRevision &+= 1
        }
    }

    private func persist() {
        defaults.set(orderedDictionaryIDs, forKey: Self.orderUserDefaultsKey)
        defaults.set(Array(enabledDictionaryIDs), forKey: Self.enabledUserDefaultsKey)
        if customDisplayNames.isEmpty {
            defaults.removeObject(forKey: Self.displayNamesUserDefaultsKey)
        } else {
            defaults.set(customDisplayNames, forKey: Self.displayNamesUserDefaultsKey)
        }
    }
}

public struct StudyMateDictionaryLookup: Codable, Identifiable, Hashable, Sendable {
    public let key: String
    public let text: String
    public let dictionaryID: String
    public let dictionaryTitle: String
    public let format: String
    public let css: String?
    public let resourceRoot: String?

    public var displayName: String {
        DictionarySourceSettings.shared.displayName(for: dictionaryID, fallback: dictionaryTitle)
    }

    public var id: String { "\(dictionaryID):\(key)" }

    public init(
        key: String,
        text: String,
        dictionaryID: String,
        dictionaryTitle: String,
        format: String = "Html",
        css: String? = nil,
        resourceRoot: String? = nil
    ) {
        self.key = key
        self.text = text
        self.dictionaryID = dictionaryID
        self.dictionaryTitle = dictionaryTitle
        self.format = format
        self.css = css
        self.resourceRoot = resourceRoot
    }

    enum CodingKeys: String, CodingKey {
        case key, text, format, css
        case dictionaryID = "dictionary_id"
        case dictionaryTitle = "dictionary_title"
        case resourceRoot = "resource_root"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        text = try container.decode(String.self, forKey: .text)
        dictionaryID = try container.decode(String.self, forKey: .dictionaryID)
        dictionaryTitle = try container.decode(String.self, forKey: .dictionaryTitle)
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? "Html"
        css = try container.decodeIfPresent(String.self, forKey: .css)
        resourceRoot = try container.decodeIfPresent(String.self, forKey: .resourceRoot)
    }
}

/// Lightweight row returned while the user is typing.  Full HTML and CSS
/// are intentionally fetched only after a row is selected.
public struct StudyMateDictionarySearchHit: Codable, Identifiable, Hashable, Sendable {
    public let key: String
    public let dictionaryID: String
    public let dictionaryTitle: String
    public let resourceRoot: String?

    public var displayName: String {
        DictionarySourceSettings.shared.displayName(for: dictionaryID, fallback: dictionaryTitle)
    }

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

/// A dictionary resource returned by the native MDX/MDD reader. Embedded MDD
/// resources are transferred only when requested; `dataBase64` is absent for
/// metadata-only responses and `path` may be a `studymate-resource://` URL.
public struct StudyMateDictionaryResource: Codable, Identifiable, Hashable, Sendable {
    public let key: String
    public let path: String
    public let size: Int
    public let dataBase64: String?
    public let mimeType: String?

    public var id: String { key }

    public init(
        key: String,
        path: String = "",
        size: Int,
        dataBase64: String? = nil,
        mimeType: String? = nil
    ) {
        self.key = key
        self.path = path
        self.size = size
        self.dataBase64 = dataBase64
        self.mimeType = mimeType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        // `resourceData` intentionally omits `path` for embedded MDD data.
        // The bytes are transferred directly, so path must remain optional at
        // the JSON boundary even though metadata-only `resource` responses
        // still provide it.
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        size = try container.decodeIfPresent(Int.self, forKey: .size) ?? 0
        dataBase64 = try container.decodeIfPresent(String.self, forKey: .dataBase64)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
    }

    enum CodingKeys: String, CodingKey {
        case key, path, size
        case dataBase64 = "data_base64"
        case mimeType = "mime_type"
    }
}

/// Finds the first usable pronunciation resource while preserving dictionary
/// priority.  The lookup and readability checks are injected so this logic
/// can be tested without installing real user dictionaries.
enum DictionaryPronunciationResolver {
    typealias ResourceLookup =
        (StudyMateDictionarySummary, String) async throws -> StudyMateDictionaryResource?

    static func firstReadableURL(
        in dictionaries: [StudyMateDictionarySummary],
        word: String,
        lookup: @escaping ResourceLookup,
        isReadable: (URL) -> Bool = { url in
            FileManager.default.isReadableFile(atPath: url.path)
        }
    ) async throws -> URL? {
        for dictionary in dictionaries {
            try Task.checkCancellation()

            do {
                guard let resource = try await lookup(dictionary, word),
                      resource.size > 0,
                      !resource.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    continue
                }

                let url = URL(fileURLWithPath: resource.path, isDirectory: false)
                guard isReadable(url) else { continue }
                return url
            } catch is CancellationError {
                // Cancellation is control flow, not a failed dictionary. It
                // must reach speakPreferred so it cannot trigger TTS.
                throw CancellationError()
            } catch {
                // A broken package or failed per-dictionary request should
                // not hide a matching pronunciation in a later dictionary.
                continue
            }
        }
        return nil
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

    private static let dictionaryEngineLogger = Logger(
        subsystem: "com.samuel.StudyMate",
        category: "dictionary-engine"
    )

    private static let detailCache: NSCache<NSString, DictionaryLookupCacheValue> = {
        let cache = NSCache<NSString, DictionaryLookupCacheValue>()
        cache.countLimit = 8
        // This is only a small UI responsiveness cache; dictionary data
        // itself remains in the native block reader. Keep it small so a
        // sequence of large definitions cannot compete with WebKit or the
        // reader's block cache for resident memory.
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    @Published public private(set) var dictionaries: [StudyMateDictionarySummary] = []
    @Published public private(set) var searchHits: [StudyMateDictionarySearchHit] = []
    /// Changes for every completed key search, including a response whose
    /// hits are equal to the previous response. Views use this as the search
    /// lifecycle signal instead of relying only on array equality.
    @Published public private(set) var searchRevision: UInt64 = 0
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
    /// Each explicit request gets a new identity, including repeated text.
    /// This lets the standalone dictionary window synchronize when the query
    /// string itself did not change.
    @Published public private(set) var lookupRequestID: UInt64 = 0
    /// If the current search result was produced via automatic lemmatization fallback
    /// (e.g. searching for "running" fell back to "run"), this holds the original query.
    @Published public private(set) var lemmaOriginalQuery: String?

    public let dictionaryRoot: URL
    private let dictionarySourceSettings = DictionarySourceSettings.shared

    /// Installed dictionaries in the user's visible priority order.
    public var orderedDictionaries: [StudyMateDictionarySummary] {
        dictionarySourceSettings.orderedDictionaries(from: dictionaries)
    }

    /// Installed and enabled dictionaries in the order used by search,
    /// definitions, source tabs, and pronunciation fallback.
    public var enabledDictionaries: [StudyMateDictionarySummary] {
        dictionarySourceSettings.enabledDictionaries(from: dictionaries)
    }

    public func resourcesURL(for dictionaryID: String) -> URL {
        let encodedID = dictionaryID.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? dictionaryID
        return URL(string: "studymate-resource://\(encodedID)/")
            ?? URL(string: "studymate-resource://dictionary/")!
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
    private var prefetchTask: Task<Void, Never>?
    private var prefetchGeneration: UInt64 = 0
    /// Keep only the latest query typed while a dictionary package is being
    /// imported or deleted. Retry it after the serialized mutation finishes.
    private var deferredSearchAfterBusy: DeferredDictionarySearch?
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
    private var dictionaryMutationGeneration: UInt64 = 0
    private var activeProgressRequestID: String?
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
        prefetchTask?.cancel()
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
                let updated = try await Self.decodeInBackground([StudyMateDictionarySummary].self, from: value)
                self.dictionaries = updated
                self.dictionarySourceSettings.synchronize(with: updated)
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
        cancelPrefetch()
        searchGeneration &+= 1
        detailGeneration &+= 1
        deferredSearchAfterBusy = nil
        searchHits = []
        searchRevision &+= 1
        searchResults = []
        isSearching = false
        isLoadingDefinition = false
        definitionQuery = nil
        lemmaOriginalQuery = nil
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
        detailTask?.cancel()
        detailTask = nil
        searchGeneration &+= 1
        detailGeneration &+= 1
        let generation = searchGeneration
        let lookupQuery = Self.canonicalQuery(query)

        guard !lookupQuery.isEmpty else {
            deferredSearchAfterBusy = nil
            searchHits = []
            searchRevision &+= 1
            searchResults = []
            isSearching = false
            isLoadingDefinition = false
            definitionQuery = nil
            lemmaOriginalQuery = nil
            return
        }

        if isBusy {
            deferredSearchAfterBusy = DeferredDictionarySearch(
                query: lookupQuery,
                dictionaryID: dictionaryID,
                includeDetails: includeDetails
            )
            searchHits = []
            searchRevision &+= 1
            searchResults = []
            definitionQuery = nil
            isSearching = true
            isLoadingDefinition = includeDetails
            lemmaOriginalQuery = nil
            return
        }
        deferredSearchAfterBusy = nil
        cancelPrefetch()
        lemmaOriginalQuery = nil

        if includeDetails {
            searchResults = []
            definitionQuery = nil
            isLoadingDefinition = true
        } else {
            // A new window search must not let an older detail request finish
            // later and overwrite the definition selected for this query.
            searchResults = []
            definitionQuery = nil
            isLoadingDefinition = false
        }
        isSearching = true

        // 180 ms is long enough to coalesce ordinary typing. Explicit
        // toolbar/shortcut lookups bypass the debounce entirely.
        if immediate {
            startSearch(
                query: lookupQuery,
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
                    query: lookupQuery,
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
        generation: UInt64,
        isLemmaFallback: Bool = false,
        originalQuery: String? = nil
    ) {
        guard generation == searchGeneration else {
            return
        }
        guard !isBusy else {
            // A package mutation may start after the debounce expires. Keep
            // the latest search pending and retry after the mutation finishes.
            return
        }

        let limit = adaptiveSearchLimit(for: query)
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let hits = try await self.lookupKeys(
                    query: query,
                    limit: limit,
                    dictionaryID: dictionaryID
                )
                guard !Task.isCancelled,
                      generation == self.searchGeneration,
                      !self.isBusy else { return }

                if hits.isEmpty && !isLemmaFallback,
                   let lemma = StudyMateLemmatizer.lemma(for: query),
                   lemma.caseInsensitiveCompare(query) != .orderedSame {
                    // 当原始词查不到任何候选时，自动回退到原生词形还原（如 running -> run, better -> good）
                    self.startSearch(
                        query: lemma,
                        dictionaryID: dictionaryID,
                        includeDetails: includeDetails,
                        generation: generation,
                        isLemmaFallback: true,
                        originalQuery: query
                    )
                    return
                }

                self.searchHits = hits
                self.searchRevision &+= 1
                self.isSearching = false
                self.lastError = nil
                self.lemmaOriginalQuery = isLemmaFallback ? originalQuery : nil

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
                self.searchRevision &+= 1
                self.searchResults = []
                self.isSearching = false
                self.isLoadingDefinition = false
                self.definitionQuery = nil
                self.lemmaOriginalQuery = nil
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Load one complete definition after a result row is selected.
    public func loadDefinition(for key: String, dictionaryID: String? = nil) {
        cancelPrefetch()
        loadDefinition(for: key, dictionaryID: dictionaryID, expectedSearchGeneration: nil, immediate: false)
    }

    private func loadDefinition(
        for key: String,
        dictionaryID: String?,
        expectedSearchGeneration: UInt64?,
        immediate: Bool
    ) {
        let lookupKey = Self.canonicalQuery(key)
        let normalizedKey = Self.normalizedQuery(lookupKey)
        guard !normalizedKey.isEmpty else { return }
        if let expectedSearchGeneration, expectedSearchGeneration != searchGeneration { return }

        detailTask?.cancel()
        detailGeneration &+= 1
        let generation = detailGeneration

        // A cached definition still advances the generation and cancels the
        // previous request first.  This makes a fast row change deterministic:
        // an older in-flight lookup cannot publish after this cache hit.
        if let cached = Self.detailCache.object(forKey: Self.detailCacheKey(for: lookupKey, dictionaryID: dictionaryID)) {
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
                let entries = try await self.lookupDefinitions(
                    query: lookupKey,
                    limit: 1,
                    dictionaryID: dictionaryID
                )
                guard !Task.isCancelled,
                      generation == self.detailGeneration,
                      !self.isBusy else { return }
                if !entries.isEmpty {
                    Self.detailCache.setObject(
                        DictionaryLookupCacheValue(entries: entries),
                        forKey: Self.detailCacheKey(for: lookupKey, dictionaryID: dictionaryID),
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

    /// Quietly prefetch the full definition for a selected word into memory cache
    /// while the user sees the floating action bar. If the user clicks "Look up",
    /// the definition will appear instantly (0ms) from cache.
    public func prefetchDefinition(for word: String, dictionaryID: String? = nil) {
        let lookupKey = Self.canonicalQuery(word)
        guard !lookupKey.isEmpty, !isBusy else { return }
        let cacheKey = Self.detailCacheKey(for: lookupKey, dictionaryID: dictionaryID)
        if Self.detailCache.object(forKey: cacheKey) != nil {
            return
        }

        cancelPrefetch()
        let generation = prefetchGeneration
        prefetchTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                // Selection notifications can arrive for every glyph while a
                // phrase is being dragged. Wait for the selection to settle
                // before issuing a full-definition IPC request.
                try await Task.sleep(nanoseconds: 140_000_000)
                try Task.checkCancellation()
                let entries = try await self.lookupDefinitions(
                    query: lookupKey,
                    limit: 1,
                    dictionaryID: dictionaryID
                )
                guard !Task.isCancelled,
                      self.prefetchGeneration == generation,
                      !self.isBusy else { return }
                guard !entries.isEmpty else { return }
                Self.detailCache.setObject(
                    DictionaryLookupCacheValue(entries: entries),
                    forKey: cacheKey,
                    cost: Self.detailCacheCost(entries)
                )
            } catch {
                // Background prefetch is best-effort
            }
            if self.prefetchGeneration == generation {
                self.prefetchTask = nil
            }
        }
    }

    private func cancelPrefetch() {
        prefetchGeneration &+= 1
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    private func retryDeferredSearchIfNeeded() {
        guard !isBusy, let deferred = deferredSearchAfterBusy else { return }
        deferredSearchAfterBusy = nil
        search(
            query: deferred.query,
            dictionaryID: deferred.dictionaryID,
            includeDetails: deferred.includeDetails,
            immediate: true
        )
    }

    /// Loads the installed package list only when a lookup arrives before the
    /// dictionary window's initial refresh has completed. This keeps the
    /// settings model authoritative without making the first query depend on
    /// timing between two independent tasks.
    private func installedDictionariesForLookup() async throws -> [StudyMateDictionarySummary] {
        if dictionaries.isEmpty, !isBusy {
            let value = try await request(operation: "list")
            let updated = try await Self.decodeInBackground(
                [StudyMateDictionarySummary].self,
                from: value
            )
            guard !Task.isCancelled else { return [] }
            dictionaries = updated
            dictionarySourceSettings.synchronize(with: updated)
        }
        return dictionarySourceSettings.orderedDictionaries(from: dictionaries)
    }

    private func lookupDictionaries(
        dictionaryID: String?
    ) async throws -> [StudyMateDictionarySummary] {
        let installed = try await installedDictionariesForLookup()
        guard let dictionaryID else { return installed.filter { dictionarySourceSettings.isEnabled($0.id) } }
        guard dictionarySourceSettings.isEnabled(dictionaryID) else { return [] }
        return installed.filter { $0.id == dictionaryID }
    }

    /// The Rust helper performs every MDX/MDD lookup using its native
    /// random-access reader. The enabled IDs are sent in one request so the
    /// helper can walk them in the exact user-defined order without adding a
    /// JSONL round trip for every dictionary.
    private func lookupKeys(
        query: String,
        limit: Int,
        dictionaryID: String?
    ) async throws -> [StudyMateDictionarySearchHit] {
        let candidates = try await lookupDictionaries(dictionaryID: dictionaryID)
        guard !candidates.isEmpty else { return [] }

        try Task.checkCancellation()
        let fields: [String: Any]
        let operation: String
        if let dictionaryID {
            operation = "lookupKeys"
            fields = [
                "dictionaryID": dictionaryID,
                "query": query,
                "limit": limit
            ]
        } else {
            operation = "lookupAllKeys"
            fields = [
                "query": query,
                "limit": limit,
                "dictionaryIDs": candidates.map(\.id)
            ]
        }
        let value = try await request(operation: operation, fields: fields)
        return try await Self.decodeInBackground(
            [StudyMateDictionarySearchHit].self,
            from: value
        )
    }

    private func lookupDefinitions(
        query: String,
        limit: Int,
        dictionaryID: String?
    ) async throws -> [StudyMateDictionaryLookup] {
        let candidates = try await lookupDictionaries(dictionaryID: dictionaryID)
        guard !candidates.isEmpty else { return [] }

        try Task.checkCancellation()
        let fields: [String: Any]
        let operation: String
        if let dictionaryID {
            operation = "lookup"
            fields = [
                "dictionaryID": dictionaryID,
                "query": query,
                "limit": limit
            ]
        } else {
            operation = "lookupAll"
            fields = [
                "query": query,
                "limit": limit,
                "dictionaryIDs": candidates.map(\.id)
            ]
        }
        let value = try await request(operation: operation, fields: fields)
        return try await Self.decodeInBackground(
            [StudyMateDictionaryLookup].self,
            from: value
        )
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

        dictionaryMutationGeneration &+= 1
        let generation = dictionaryMutationGeneration
        activeProgressRequestID = nil
        isBusy = true
        progress = nil
        progressPhase = LanguageManager.shared.text("正在删除词典…", "Deleting dictionary…")
        lastError = nil

        dictionaryMutationTask?.cancel()
        dictionaryMutationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.dictionaryMutationGeneration == generation {
                    self.dictionaryMutationTask = nil
                    self.activeProgressRequestID = nil
                    self.isBusy = false
                    self.progress = nil
                    self.progressPhase = nil
                }
            }
            do {
                // Let SwiftUI apply the cleared results and dismantle any
                // WKWebView that may still reference package resources.
                await Task.yield()
                guard !Task.isCancelled, self.dictionaryMutationGeneration == generation else { return }
                let deletedData = try await self.request(
                    operation: "delete",
                    fields: ["dictionaryID": id]
                )
                guard !Task.isCancelled, self.dictionaryMutationGeneration == generation else { return }
                let deleted = try await Self.decodeInBackground(Bool.self, from: deletedData)
                guard !Task.isCancelled, self.dictionaryMutationGeneration == generation else { return }
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
                        self.dictionarySourceSettings.synchronize(with: updated)
                    }
                    self.dictionarySourceSettings.remove(dictionaryID: id)
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
                self.dictionarySourceSettings.remove(dictionaryID: id)

                let value = try await self.request(operation: "list")
                guard !Task.isCancelled, self.dictionaryMutationGeneration == generation else { return }
                let updated = try await Self.decodeInBackground([StudyMateDictionarySummary].self, from: value)
                guard !Task.isCancelled, self.dictionaryMutationGeneration == generation else { return }

                self.dictionaries = updated
                self.dictionarySourceSettings.synchronize(with: updated)
                self.searchResults.removeAll { $0.dictionaryID == id }
                self.isBusy = false
                self.progressPhase = nil
                self.lastError = nil
                self.retryDeferredSearchIfNeeded()
                self.showNotification(
                    LanguageManager.shared.text("已删除词典", "Dictionary deleted")
                )
            } catch {
                guard self.dictionaryMutationGeneration == generation else { return }
                self.isBusy = false
                self.progressPhase = nil
                self.retryDeferredSearchIfNeeded()
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
        dictionaryMutationGeneration &+= 1
        let generation = dictionaryMutationGeneration
        activeProgressRequestID = nil
        isBusy = true
        progress = 0.05
        progressPhase = LanguageManager.shared.text("正在准备导入词典…", "Preparing to import dictionary…")
        lastError = nil

        let mdxPath = mdx.path
        let mddPaths = mdd.map(\.path)
        dictionaryMutationTask?.cancel()
        // NSOpenPanel grants file access through a security-scoped URL. Keep
        // each scope alive for the complete helper import, including sibling
        // `.js`, `.css`, image and font discovery. Starting it only around
        // `fs.copy` in the UI would end before the Rust child process reads
        // the source directory, causing scripts to be silently omitted.
        // A file selection grants the helper access to the selected file, but
        // sibling resource discovery also needs the MDX directory itself.
        // Keep both the directory and explicitly selected MDD scopes alive
        // until the Rust import has fully completed.
        let sourceDirectoryURL = mdx.deletingLastPathComponent()
        let scopedURLs = [sourceDirectoryURL, mdx] + mdd
        let scopedAccess = scopedURLs.map { url in
            (url: url, isActive: url.startAccessingSecurityScopedResource())
        }
        dictionaryMutationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                for scope in scopedAccess where scope.isActive {
                    scope.url.stopAccessingSecurityScopedResource()
                }
                if self.dictionaryMutationGeneration == generation {
                    self.dictionaryMutationTask = nil
                    self.activeProgressRequestID = nil
                }
            }
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
                let value = try await self.request(operation: "import", fields: fields)
                guard !Task.isCancelled, self.dictionaryMutationGeneration == generation else { return }
                let result = try await Self.decodeInBackground(StudyMateDictionaryImportResult.self, from: value)
                guard !Task.isCancelled, self.dictionaryMutationGeneration == generation else { return }

                self.dictionaries.append(result.dictionary)
                self.dictionaries.sort(by: Self.dictionaryPrioritySort)
                self.dictionarySourceSettings.synchronize(with: self.dictionaries)
                self.progress = 1.0
                self.progressPhase = nil
                self.isBusy = false
                self.lastError = nil
                self.retryDeferredSearchIfNeeded()
                self.showNotification(
                    LanguageManager.shared.text("已成功导入词典“\(result.dictionary.displayName)”", "Imported dictionary “\(result.dictionary.displayName)”")
                )
            } catch {
                guard self.dictionaryMutationGeneration == generation else { return }
                self.isBusy = false
                self.progress = nil
                self.progressPhase = nil
                self.retryDeferredSearchIfNeeded()
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

    /// Resolve one resource through the native MDX/MDD reader. Embedded MDD
    /// data is decompressed only for this request; no resource database or
    /// extracted MDD tree is created.
    public func resourceURL(dictionaryID: String, key: String) async throws -> URL? {
        let value = try await request(operation: "resource", fields: [
            "dictionaryID": dictionaryID,
            "key": key
        ])
        let resource = try await Self.decodeInBackground(StudyMateDictionaryResource?.self, from: value)
        guard let resource else { return nil }
        if let url = URL(string: resource.path), url.scheme?.lowercased() == "studymate-resource" {
            return url
        }
        guard !resource.path.isEmpty else { return nil }
        return URL(fileURLWithPath: resource.path, isDirectory: false)
    }

    public func resourceData(dictionaryID: String, key: String) async throws -> (data: Data, mimeType: String)? {
        Self.dictionaryEngineLogger.debug(
            "resourceData request: dictionary \(dictionaryID, privacy: .public), key \(key, privacy: .public)"
        )
        do {
            let value = try await request(operation: "resourceData", fields: [
                "dictionaryID": dictionaryID,
                "key": key
            ])
            Self.dictionaryEngineLogger.debug("resourceData JSON payload received: \(value.count, privacy: .public) bytes")
            let resource = try await Self.decodeInBackground(StudyMateDictionaryResource?.self, from: value)
            guard let resource, let encoded = resource.dataBase64,
                  let data = Data(base64Encoded: encoded), !data.isEmpty else {
                Self.dictionaryEngineLogger.debug("resourceData response did not contain usable base64 data")
                return nil
            }
            Self.dictionaryEngineLogger.debug(
                "resourceData decoded: \(data.count, privacy: .public) bytes, MIME \(resource.mimeType ?? "nil", privacy: .public)"
            )
            return (data, resource.mimeType ?? "application/octet-stream")
        } catch {
            let nsError = error as NSError
            Self.dictionaryEngineLogger.error(
                "resourceData failed: domain \(nsError.domain, privacy: .public), code \(nsError.code, privacy: .public), message \(nsError.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    /// Resolve a pronunciation from the installed MDX dictionaries in their
    /// visible priority order. A missing audio file in the first dictionary
    /// must not hide a matching pronunciation in a later dictionary.
    public func firstDictionaryPronunciationURL(for word: String) async throws -> URL? {
        var candidates = enabledDictionaries
        if dictionaries.isEmpty, !isBusy {
            let value = try await request(operation: "list")
            let summaries = try await Self.decodeInBackground([StudyMateDictionarySummary].self, from: value)
            guard !Task.isCancelled else { return nil }
            dictionaries = summaries
            dictionarySourceSettings.synchronize(with: summaries)
            candidates = enabledDictionaries
        }

        let audioCandidates = candidates.filter { $0.resourceCount > 0 }
        guard !audioCandidates.isEmpty else { return nil }

        return try await DictionaryPronunciationResolver.firstReadableURL(
            in: audioCandidates,
            word: word
        ) { [weak self] dictionary, word in
            guard let self else { return nil }
            let value = try await self.request(operation: "findAudio", fields: [
                "dictionaryID": dictionary.id,
                "word": word
            ])
            return try await Self.decodeInBackground(
                StudyMateDictionaryResource?.self,
                from: value
            )
        }
    }

    /// Read the first pronunciation resource directly from the dictionaries
    /// in UI priority order. Returning the MIME type matters: MDD audio is
    /// transferred as raw bytes and has no filename extension for the native
    /// audio decoder to inspect.
    public func firstDictionaryPronunciation(for word: String) async throws -> (data: Data, mimeType: String?)? {
        var candidates = enabledDictionaries
        if dictionaries.isEmpty, !isBusy {
            let value = try await request(operation: "list")
            let summaries = try await Self.decodeInBackground([StudyMateDictionarySummary].self, from: value)
            guard !Task.isCancelled else { return nil }
            dictionaries = summaries
            dictionarySourceSettings.synchronize(with: summaries)
            candidates = enabledDictionaries
        }

        // Fast-path: 仅探测包含实际资源（resourceCount > 0）的词典，跳过纯文本词典，避免串行无意义 IPC 延迟
        let audioCandidates = candidates.filter { $0.resourceCount > 0 }
        guard !audioCandidates.isEmpty else { return nil }

        for dictionary in audioCandidates {
            try Task.checkCancellation()
            do {
                let value = try await request(operation: "findAudio", fields: [
                    "dictionaryID": dictionary.id,
                    "word": word
                ])
                let resource = try await Self.decodeInBackground(StudyMateDictionaryResource?.self, from: value)
                guard let resource else { continue }
                if let encoded = resource.dataBase64,
                   let data = Data(base64Encoded: encoded), !data.isEmpty {
                    return (data, resource.mimeType)
                }
                if !resource.path.isEmpty,
                   !resource.path.lowercased().hasPrefix("studymate-resource:") {
                    let url = URL(fileURLWithPath: resource.path)
                    if FileManager.default.isReadableFile(atPath: url.path) {
                        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                        if !data.isEmpty { return (data, resource.mimeType) }
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return nil
    }

    /// Data-only compatibility wrapper for callers that do not need the
    /// decoder hint. The audio UI uses `firstDictionaryPronunciation` above
    /// so an embedded MP3 is decoded with its MDD MIME type.
    public func firstDictionaryPronunciationData(for word: String) async throws -> Data? {
        try await firstDictionaryPronunciation(for: word)?.data
    }

    public func reportError(_ message: String) {
        lastError = message
    }

    public func requestLookup(_ query: String) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        requestedQuery = value
        lookupRequestID &+= 1
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

    public nonisolated static let boundaryPunctuation = CharacterSet(charactersIn: #",.:;!?…"'“”‘’`()[]{}<>«»—–/"#)
        .union(.whitespacesAndNewlines)

    public nonisolated static func cleanQueryWord(_ value: String) -> String {
        value.trimmingCharacters(in: boundaryPunctuation)
    }

    public nonisolated static func normalizedQuery(_ value: String) -> String {
        canonicalQuery(value).lowercased()
    }

    public nonisolated static func canonicalQuery(_ value: String) -> String {
        let cleaned = cleanQueryWord(value)
        return cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private nonisolated static func dictionaryPrioritySort(
        _ lhs: StudyMateDictionarySummary,
        _ rhs: StudyMateDictionarySummary
    ) -> Bool {
        if lhs.importedAt != rhs.importedAt {
            return lhs.importedAt < rhs.importedAt
        }
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private nonisolated static func detailCacheKey(for query: String, dictionaryID: String?) -> NSString {
        let scope = dictionaryID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "*"
        // Case is significant here: MDX can legally contain distinct records
        // whose only difference is the original key casing.
        return "\(scope)|\(canonicalQuery(query))" as NSString
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
        if operation == "import" {
            activeProgressRequestID = id
        }
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
                    guard let input else {
                        pending.removeValue(forKey: id)
                        continuation.resume(throwing: StudyMateDictionaryError(message: "词典引擎输入管道不可用。"))
                        return
                    }
                    try input.write(contentsOf: line)
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
        if process != nil || !pending.isEmpty {
            // Process.terminationHandler is delivered asynchronously. A new
            // request can otherwise restart the helper first, causing the
            // old termination callback to be ignored by the generation guard
            // and leaving its continuations suspended forever.
            helperGeneration &+= 1
            failPending(with: StudyMateDictionaryError(
                message: "词典引擎已退出，请重试。"
            ))
        }
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
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let self, let parser else { return }
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
        case let .progress(id, fraction, phase):
            guard let id, id == activeProgressRequestID else { return }
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
        output?.readabilityHandler = nil
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
