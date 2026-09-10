import SwiftUI
import AppKit

/// 单个界面模式（视频/列表/全文/句子）下的字幕字体独立配置
public struct ModeFontSettings: Codable, Equatable, Sendable {
    public var originalFontName: String
    public var translationFontName: String
    public var originalFontSize: Double
    public var translationFontSize: Double
    public var originalBold: Bool
    public var translationBold: Bool
    public var originalItalic: Bool
    public var translationItalic: Bool
    public var originalColorHex: String
    public var translationColorHex: String

    public init(
        originalFontName: String,
        translationFontName: String,
        originalFontSize: Double,
        translationFontSize: Double,
        originalBold: Bool,
        translationBold: Bool,
        originalItalic: Bool,
        translationItalic: Bool,
        originalColorHex: String,
        translationColorHex: String
    ) {
        self.originalFontName = originalFontName
        self.translationFontName = translationFontName
        self.originalFontSize = min(96.0, max(10.0, originalFontSize))
        self.translationFontSize = min(96.0, max(10.0, translationFontSize))
        self.originalBold = originalBold
        self.translationBold = translationBold
        self.originalItalic = originalItalic
        self.translationItalic = translationItalic
        self.originalColorHex = originalColorHex
        self.translationColorHex = translationColorHex
    }

    public var originalColor: Color {
        get { Color(studymateHex: originalColorHex) }
        set { originalColorHex = newValue.studymateHex ?? "#FFFFFF" }
    }

    public var translationColor: Color {
        get { Color(studymateHex: translationColorHex) }
        set { translationColorHex = newValue.studymateHex ?? "#FFE36E" }
    }

    public var originalNSColor: NSColor {
        NSColor(originalColor)
    }

    public var translationNSColor: NSColor {
        NSColor(translationColor)
    }

    public func makeOriginalFont() -> NSFont {
        VideoSubtitleSettings.makeFont(
            name: originalFontName,
            size: originalFontSize,
            isBold: originalBold,
            isItalic: originalItalic
        )
    }

    public func makeTranslationFont() -> NSFont {
        VideoSubtitleSettings.makeFont(
            name: translationFontName,
            size: translationFontSize,
            isBold: translationBold,
            isItalic: translationItalic
        )
    }
}

/// 媒体播放区双语字幕的显示、位置及各界面模式独立的字体设置。
/// 设置保存在 UserDefaults，4 种模式（视频/列表/全文/句子）拥有各自独立且隔离的字体配置。
@MainActor
public final class VideoSubtitleSettings: ObservableObject {
    public static let shared = VideoSubtitleSettings()

    private let defaults = UserDefaults.standard

    @Published public var showOriginal: Bool {
        didSet { defaults.set(showOriginal, forKey: Keys.showOriginal) }
    }
    @Published public var showTranslation: Bool {
        didSet { defaults.set(showTranslation, forKey: Keys.showTranslation) }
    }
    @Published public var showTranslationInFillInBlank: Bool {
        didSet { defaults.set(showTranslationInFillInBlank, forKey: Keys.showTranslationInFillInBlank) }
    }

    @Published public var showOriginalInFillInBlank: Bool = false
    private var originalPeekTimer: Task<Void, Never>?

    public func isOriginalVisible(for mode: PlaybackInterfaceMode) -> Bool {
        if mode == .fillInBlank {
            return showOriginalInFillInBlank
        }
        return showOriginal
    }

    public func toggleOriginal(for mode: PlaybackInterfaceMode) {
        if mode == .fillInBlank {
            originalPeekTimer?.cancel()
            originalPeekTimer = nil
            showOriginalInFillInBlank.toggle()
            if showOriginalInFillInBlank {
                originalPeekTimer = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.showOriginalInFillInBlank = false
                }
            }
        } else {
            showOriginal.toggle()
        }
    }

    public func hideOriginalPeekInFillInBlank() {
        originalPeekTimer?.cancel()
        originalPeekTimer = nil
        if showOriginalInFillInBlank {
            showOriginalInFillInBlank = false
        }
    }

    public func isTranslationVisible(for mode: PlaybackInterfaceMode) -> Bool {
        if mode == .fillInBlank {
            return showTranslationInFillInBlank
        }
        return showTranslation
    }

    public func toggleTranslation(for mode: PlaybackInterfaceMode) {
        if mode == .fillInBlank {
            showTranslationInFillInBlank.toggle()
        } else {
            showTranslation.toggle()
        }
    }

    // 5 种界面模式的独立字体设置
    // 预览字号时会暂时跳过持久化，但仍然发布变化让字幕实时更新。
    private var shouldPersistFontSettings = true

    @Published public var videoFontSettings: ModeFontSettings {
        didSet {
            if shouldPersistFontSettings {
                persistFontSettings(videoFontSettings, mode: .video)
            }
        }
    }
    @Published public var listFontSettings: ModeFontSettings {
        didSet {
            if shouldPersistFontSettings {
                persistFontSettings(listFontSettings, mode: .list)
            }
        }
    }
    @Published public var fullTextFontSettings: ModeFontSettings {
        didSet {
            if shouldPersistFontSettings {
                persistFontSettings(fullTextFontSettings, mode: .fullText)
            }
        }
    }
    @Published public var sentenceFontSettings: ModeFontSettings {
        didSet {
            if shouldPersistFontSettings {
                persistFontSettings(sentenceFontSettings, mode: .sentence)
            }
        }
    }
    @Published public var fillInBlankFontSettings: ModeFontSettings {
        didSet {
            if shouldPersistFontSettings {
                persistFontSettings(fillInBlankFontSettings, mode: .fillInBlank)
            }
        }
    }

    // Normalized coordinates keep the subtitle position stable when the video
    // window is resized.  (0, 0) is the top-left and (1, 1) is the bottom-right.
    @Published public var originalPositionX: Double {
        didSet { defaults.set(originalPositionX, forKey: Keys.originalPositionX) }
    }
    @Published public var originalPositionY: Double {
        didSet { defaults.set(originalPositionY, forKey: Keys.originalPositionY) }
    }
    @Published public var translationPositionX: Double {
        didSet { defaults.set(translationPositionX, forKey: Keys.translationPositionX) }
    }
    @Published public var translationPositionY: Double {
        didSet { defaults.set(translationPositionY, forKey: Keys.translationPositionY) }
    }

    public static let availableFontFamilies: [String] =
        NSFontManager.shared.availableFontFamilies.sorted()

    // MARK: - 模式字体存取与更新接口

    public func fontSettings(for mode: PlaybackInterfaceMode) -> ModeFontSettings {
        switch mode {
        case .video: return videoFontSettings
        case .list: return listFontSettings
        case .fullText: return fullTextFontSettings
        case .sentence: return sentenceFontSettings
        case .fillInBlank: return fillInBlankFontSettings
        }
    }

    /// 更新字体配置；预览更新仍会发布给字幕视图，但不会在每个滑块帧写入 UserDefaults。
    public func setFontSettings(
        _ newSettings: ModeFontSettings,
        for mode: PlaybackInterfaceMode,
        persist: Bool = true
    ) {
        let previousPersistence = shouldPersistFontSettings
        shouldPersistFontSettings = persist
        defer { shouldPersistFontSettings = previousPersistence }

        switch mode {
        case .video: videoFontSettings = newSettings
        case .list: listFontSettings = newSettings
        case .fullText: fullTextFontSettings = newSettings
        case .sentence: sentenceFontSettings = newSettings
        case .fillInBlank: fillInBlankFontSettings = newSettings
        }
    }

    public func updateFontSettings(for mode: PlaybackInterfaceMode, _ update: (inout ModeFontSettings) -> Void) {
        var current = fontSettings(for: mode)
        update(&current)
        setFontSettings(current, for: mode)
    }

    public func makeOriginalFont(for mode: PlaybackInterfaceMode = .video) -> NSFont {
        fontSettings(for: mode).makeOriginalFont()
    }

    public func makeTranslationFont(for mode: PlaybackInterfaceMode = .video) -> NSFont {
        fontSettings(for: mode).makeTranslationFont()
    }

    public func originalNSColor(for mode: PlaybackInterfaceMode = .video) -> NSColor {
        let settings = fontSettings(for: mode)
        return Self.readingColor(hex: settings.originalColorHex, mode: mode)
    }

    public func translationNSColor(for mode: PlaybackInterfaceMode = .video) -> NSColor {
        let settings = fontSettings(for: mode)
        return Self.readingColor(hex: settings.translationColorHex, mode: mode)
    }

    // Applying alpha directly to a semantic NSColor can resolve it immediately.
    // Keep the provider dynamic so an already-open document follows appearance changes.
    static let automaticTranslationColor = NSColor(name: nil) { appearance in
        var resolved = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            resolved = (NSColor.labelColor.usingColorSpace(.sRGB) ?? .black).withAlphaComponent(0.8)
        }
        return resolved
    }

    /// Legacy video defaults need a semantic foreground on document surfaces.
    static func readingColor(hex: String, mode: PlaybackInterfaceMode) -> NSColor {
        switch hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case StudyMateSubtitleColorToken.label:
            return .labelColor
        case StudyMateSubtitleColorToken.secondaryLabel:
            return Self.automaticTranslationColor
        default:
            break
        }
        if mode != .video && ["#FFFFFF", "#FFE36E"].contains(hex.uppercased()) {
            return .labelColor
        }
        return NSColor(Color(studymateHex: hex))
    }

    // MARK: - 视频模式属性快捷代理（向下兼容）

    public var originalFontName: String {
        get { videoFontSettings.originalFontName }
        set { updateFontSettings(for: .video) { $0.originalFontName = newValue } }
    }
    public var translationFontName: String {
        get { videoFontSettings.translationFontName }
        set { updateFontSettings(for: .video) { $0.translationFontName = newValue } }
    }
    public var originalFontSize: Double {
        get { videoFontSettings.originalFontSize }
        set { updateFontSettings(for: .video) { $0.originalFontSize = newValue } }
    }
    public var translationFontSize: Double {
        get { videoFontSettings.translationFontSize }
        set { updateFontSettings(for: .video) { $0.translationFontSize = newValue } }
    }
    public var originalBold: Bool {
        get { videoFontSettings.originalBold }
        set { updateFontSettings(for: .video) { $0.originalBold = newValue } }
    }
    public var translationBold: Bool {
        get { videoFontSettings.translationBold }
        set { updateFontSettings(for: .video) { $0.translationBold = newValue } }
    }
    public var originalItalic: Bool {
        get { videoFontSettings.originalItalic }
        set { updateFontSettings(for: .video) { $0.originalItalic = newValue } }
    }
    public var translationItalic: Bool {
        get { videoFontSettings.translationItalic }
        set { updateFontSettings(for: .video) { $0.translationItalic = newValue } }
    }
    public var originalColorHex: String {
        get { videoFontSettings.originalColorHex }
        set { updateFontSettings(for: .video) { $0.originalColorHex = newValue } }
    }
    public var translationColorHex: String {
        get { videoFontSettings.translationColorHex }
        set { updateFontSettings(for: .video) { $0.translationColorHex = newValue } }
    }

    public var originalColor: Color {
        get { videoFontSettings.originalColor }
        set { updateFontSettings(for: .video) { $0.originalColor = newValue } }
    }

    public var translationColor: Color {
        get { videoFontSettings.translationColor }
        set { updateFontSettings(for: .video) { $0.translationColor = newValue } }
    }

    public var originalNSColor: NSColor {
        videoFontSettings.originalNSColor
    }

    public var translationNSColor: NSColor {
        videoFontSettings.translationNSColor
    }

    nonisolated public static func makeFont(name: String, size: Double, isBold: Bool, isItalic: Bool) -> NSFont {
        let clampedSize = max(10, min(96, size))
        var descriptor = NSFontDescriptor(name: name, size: clampedSize)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if isBold { traits.insert(.bold) }
        if isItalic { traits.insert(.italic) }
        if !traits.isEmpty { descriptor = descriptor.withSymbolicTraits(traits) }
        return NSFont(descriptor: descriptor, size: clampedSize)
            ?? .systemFont(ofSize: clampedSize)
    }

    public func resetPositions() {
        originalPositionX = 0.5
        originalPositionY = 0.76
        translationPositionX = 0.5
        translationPositionY = 0.86
    }

    private init() {
        showOriginal = defaults.object(forKey: Keys.showOriginal) as? Bool ?? true
        showTranslation = defaults.object(forKey: Keys.showTranslation) as? Bool ?? true
        showTranslationInFillInBlank = defaults.object(forKey: Keys.showTranslationInFillInBlank) as? Bool ?? false

        let systemFamily = NSFont.systemFont(ofSize: 24).familyName ?? "Helvetica"

        let defaultVideo = ModeFontSettings(
            originalFontName: systemFamily,
            translationFontName: systemFamily,
            originalFontSize: 28,
            translationFontSize: 24,
            originalBold: true,
            translationBold: false,
            originalItalic: false,
            translationItalic: false,
            originalColorHex: "#FFFFFF",
            translationColorHex: "#FFE36E"
        )
        let defaultList = ModeFontSettings(
            originalFontName: systemFamily,
            translationFontName: systemFamily,
            originalFontSize: 14,
            translationFontSize: 13,
            originalBold: false,
            translationBold: false,
            originalItalic: false,
            translationItalic: false,
            originalColorHex: StudyMateSubtitleColorToken.label,
            translationColorHex: StudyMateSubtitleColorToken.secondaryLabel
        )
        let defaultFullText = ModeFontSettings(
            originalFontName: systemFamily,
            translationFontName: systemFamily,
            originalFontSize: 16,
            translationFontSize: 14,
            originalBold: false,
            translationBold: false,
            originalItalic: false,
            translationItalic: false,
            originalColorHex: StudyMateSubtitleColorToken.label,
            translationColorHex: StudyMateSubtitleColorToken.secondaryLabel
        )
        let defaultSentence = ModeFontSettings(
            originalFontName: systemFamily,
            translationFontName: systemFamily,
            originalFontSize: 24,
            translationFontSize: 20,
            originalBold: true,
            translationBold: false,
            originalItalic: false,
            translationItalic: false,
            originalColorHex: StudyMateSubtitleColorToken.label,
            translationColorHex: StudyMateSubtitleColorToken.secondaryLabel
        )
        let defaultFillInBlank = ModeFontSettings(
            originalFontName: systemFamily,
            translationFontName: systemFamily,
            originalFontSize: 24,
            translationFontSize: 20,
            originalBold: true,
            translationBold: false,
            originalItalic: false,
            translationItalic: false,
            originalColorHex: StudyMateSubtitleColorToken.label,
            translationColorHex: StudyMateSubtitleColorToken.secondaryLabel
        )

        videoFontSettings = Self.loadFontSettings(from: defaults, mode: .video, defaultSettings: defaultVideo)
        listFontSettings = Self.loadFontSettings(from: defaults, mode: .list, defaultSettings: defaultList)
        fullTextFontSettings = Self.loadFontSettings(from: defaults, mode: .fullText, defaultSettings: defaultFullText)
        sentenceFontSettings = Self.loadFontSettings(from: defaults, mode: .sentence, defaultSettings: defaultSentence)
        fillInBlankFontSettings = Self.loadFontSettings(from: defaults, mode: .fillInBlank, defaultSettings: defaultFillInBlank)

        originalPositionX = defaults.object(forKey: Keys.originalPositionX) as? Double ?? 0.5
        originalPositionY = defaults.object(forKey: Keys.originalPositionY) as? Double ?? 0.76
        translationPositionX = defaults.object(forKey: Keys.translationPositionX) as? Double ?? 0.5
        translationPositionY = defaults.object(forKey: Keys.translationPositionY) as? Double ?? 0.86
    }

    private static func loadFontSettings(
        from defaults: UserDefaults,
        mode: PlaybackInterfaceMode,
        defaultSettings: ModeFontSettings
    ) -> ModeFontSettings {
        let prefix = "StudyMate.FontSettings.\(mode.rawValue)."

        let origName: String
        if let val = defaults.string(forKey: prefix + "originalFontName") {
            origName = val
        } else if mode == .video, let legacy = defaults.string(forKey: Keys.legacyOriginalFontName) {
            origName = legacy
        } else {
            origName = defaultSettings.originalFontName
        }

        let transName: String
        if let val = defaults.string(forKey: prefix + "translationFontName") {
            transName = val
        } else if mode == .video, let legacy = defaults.string(forKey: Keys.legacyTranslationFontName) {
            transName = legacy
        } else {
            transName = defaultSettings.translationFontName
        }

        let origSize: Double
        if let val = defaults.object(forKey: prefix + "originalFontSize") as? Double {
            origSize = val
        } else if mode == .video, let legacy = defaults.object(forKey: Keys.legacyOriginalFontSize) as? Double {
            origSize = legacy
        } else {
            origSize = defaultSettings.originalFontSize
        }

        let transSize: Double
        if let val = defaults.object(forKey: prefix + "translationFontSize") as? Double {
            transSize = val
        } else if mode == .video, let legacy = defaults.object(forKey: Keys.legacyTranslationFontSize) as? Double {
            transSize = legacy
        } else {
            transSize = defaultSettings.translationFontSize
        }

        let origBold: Bool
        if let val = defaults.object(forKey: prefix + "originalBold") as? Bool {
            origBold = val
        } else if mode == .video, let legacy = defaults.object(forKey: Keys.legacyOriginalBold) as? Bool {
            origBold = legacy
        } else {
            origBold = defaultSettings.originalBold
        }

        let transBold: Bool
        if let val = defaults.object(forKey: prefix + "translationBold") as? Bool {
            transBold = val
        } else if mode == .video, let legacy = defaults.object(forKey: Keys.legacyTranslationBold) as? Bool {
            transBold = legacy
        } else {
            transBold = defaultSettings.translationBold
        }

        let origItalic: Bool
        if let val = defaults.object(forKey: prefix + "originalItalic") as? Bool {
            origItalic = val
        } else if mode == .video, let legacy = defaults.object(forKey: Keys.legacyOriginalItalic) as? Bool {
            origItalic = legacy
        } else {
            origItalic = defaultSettings.originalItalic
        }

        let transItalic: Bool
        if let val = defaults.object(forKey: prefix + "translationItalic") as? Bool {
            transItalic = val
        } else if mode == .video, let legacy = defaults.object(forKey: Keys.legacyTranslationItalic) as? Bool {
            transItalic = legacy
        } else {
            transItalic = defaultSettings.translationItalic
        }

        let origColor: String
        if let val = defaults.string(forKey: prefix + "originalColor") {
            origColor = val
        } else if mode == .video, let legacy = defaults.string(forKey: Keys.legacyOriginalColor) {
            origColor = legacy
        } else {
            origColor = defaultSettings.originalColorHex
        }

        let transColor: String
        if let val = defaults.string(forKey: prefix + "translationColor") {
            transColor = val
        } else if mode == .video, let legacy = defaults.string(forKey: Keys.legacyTranslationColor) {
            transColor = legacy
        } else {
            transColor = defaultSettings.translationColorHex
        }

        return ModeFontSettings(
            originalFontName: origName,
            translationFontName: transName,
            originalFontSize: origSize,
            translationFontSize: transSize,
            originalBold: origBold,
            translationBold: transBold,
            originalItalic: origItalic,
            translationItalic: transItalic,
            originalColorHex: origColor,
            translationColorHex: transColor
        )
    }

    private func persistFontSettings(_ settings: ModeFontSettings, mode: PlaybackInterfaceMode) {
        let prefix = "StudyMate.FontSettings.\(mode.rawValue)."
        defaults.set(settings.originalFontName, forKey: prefix + "originalFontName")
        defaults.set(settings.translationFontName, forKey: prefix + "translationFontName")
        defaults.set(settings.originalFontSize, forKey: prefix + "originalFontSize")
        defaults.set(settings.translationFontSize, forKey: prefix + "translationFontSize")
        defaults.set(settings.originalBold, forKey: prefix + "originalBold")
        defaults.set(settings.translationBold, forKey: prefix + "translationBold")
        defaults.set(settings.originalItalic, forKey: prefix + "originalItalic")
        defaults.set(settings.translationItalic, forKey: prefix + "translationItalic")
        defaults.set(settings.originalColorHex, forKey: prefix + "originalColor")
        defaults.set(settings.translationColorHex, forKey: prefix + "translationColor")

        if mode == .video {
            defaults.set(settings.originalFontName, forKey: Keys.legacyOriginalFontName)
            defaults.set(settings.translationFontName, forKey: Keys.legacyTranslationFontName)
            defaults.set(settings.originalFontSize, forKey: Keys.legacyOriginalFontSize)
            defaults.set(settings.translationFontSize, forKey: Keys.legacyTranslationFontSize)
            defaults.set(settings.originalBold, forKey: Keys.legacyOriginalBold)
            defaults.set(settings.translationBold, forKey: Keys.legacyTranslationBold)
            defaults.set(settings.originalItalic, forKey: Keys.legacyOriginalItalic)
            defaults.set(settings.translationItalic, forKey: Keys.legacyTranslationItalic)
            defaults.set(settings.originalColorHex, forKey: Keys.legacyOriginalColor)
            defaults.set(settings.translationColorHex, forKey: Keys.legacyTranslationColor)
        }
    }

    private enum Keys {
        static let showOriginal = "StudyMate.VideoSubtitle.ShowOriginal"
        static let showTranslation = "StudyMate.VideoSubtitle.ShowTranslation"
        static let showTranslationInFillInBlank = "StudyMate.VideoSubtitle.ShowTranslation.FillInBlank"
        static let originalPositionX = "StudyMate.VideoSubtitle.OriginalPositionX"
        static let originalPositionY = "StudyMate.VideoSubtitle.OriginalPositionY"
        static let translationPositionX = "StudyMate.VideoSubtitle.TranslationPositionX"
        static let translationPositionY = "StudyMate.VideoSubtitle.TranslationPositionY"

        static let legacyOriginalFontName = "StudyMate.VideoSubtitle.OriginalFontName"
        static let legacyTranslationFontName = "StudyMate.VideoSubtitle.TranslationFontName"
        static let legacyOriginalFontSize = "StudyMate.VideoSubtitle.OriginalFontSize"
        static let legacyTranslationFontSize = "StudyMate.VideoSubtitle.TranslationFontSize"
        static let legacyOriginalBold = "StudyMate.VideoSubtitle.OriginalBold"
        static let legacyTranslationBold = "StudyMate.VideoSubtitle.TranslationBold"
        static let legacyOriginalItalic = "StudyMate.VideoSubtitle.OriginalItalic"
        static let legacyTranslationItalic = "StudyMate.VideoSubtitle.TranslationItalic"
        static let legacyOriginalColor = "StudyMate.VideoSubtitle.OriginalColor"
        static let legacyTranslationColor = "StudyMate.VideoSubtitle.TranslationColor"
    }
}

private enum VideoSubtitleTrack {
    case original
    case translation
}

private struct DraggableVideoSubtitle: View {
    @ObservedObject var settings: VideoSubtitleSettings
    let engine: PlaybackEngine
    let segmentID: UUID
    let track: VideoSubtitleTrack
    let text: String
    let containerSize: CGSize
    let context: String?
    let isOSDVisible: Bool

    @State private var dragOffset: CGSize = .zero
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var hasNotifiedEngineOfDrag = false
    /// AppKit owns modifier-dragging inside the selectable NSTextView.  The
    /// outer SwiftUI gesture remains as a fallback for the rounded padding,
    /// but must stand down while AppKit is handling the same gesture.
    @State private var appKitDragActive = false
    /// Text measurement is expensive enough to be visible during a native
    /// modifier-drag. Cache it so only the offset changes at pointer speed.
    @State private var cachedSubtitleSize: CGSize = .zero
    @State private var cachedSubtitleFont: NSFont?

    private var savedPosition: CGPoint {
        switch track {
        case .original:
            return CGPoint(x: settings.originalPositionX, y: settings.originalPositionY)
        case .translation:
            return CGPoint(x: settings.translationPositionX, y: settings.translationPositionY)
        }
    }

    private var fontName: String {
        switch track {
        case .original: return settings.originalFontName
        case .translation: return settings.translationFontName
        }
    }

    private var fontSize: Double {
        switch track {
        case .original: return settings.originalFontSize
        case .translation: return settings.translationFontSize
        }
    }

    private var isBold: Bool {
        switch track {
        case .original: return settings.originalBold
        case .translation: return settings.translationBold
        }
    }

    private var isItalic: Bool {
        switch track {
        case .original: return settings.originalItalic
        case .translation: return settings.translationItalic
        }
    }

    private var color: Color {
        switch track {
        case .original: return settings.originalColor
        case .translation: return settings.translationColor
        }
    }

    private var subtitleFont: NSFont {
        if let cachedSubtitleFont {
            return cachedSubtitleFont
        }
        return makeSubtitleFont()
    }

    private func makeSubtitleFont() -> NSFont {
        let size = max(10, min(96, fontSize))
        var descriptor = NSFontDescriptor(name: fontName, size: size)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if isBold { traits.insert(.bold) }
        if isItalic { traits.insert(.italic) }
        if !traits.isEmpty { descriptor = descriptor.withSymbolicTraits(traits) }
        return NSFont(descriptor: descriptor, size: size)
            ?? .systemFont(ofSize: size)
    }

    private var subtitleSize: CGSize {
        if cachedSubtitleSize.width > 0, cachedSubtitleSize.height > 0 {
            return cachedSubtitleSize
        }
        return calculateSubtitleSize(using: subtitleFont)
    }

    private var layoutKey: SubtitleLayoutKey {
        SubtitleLayoutKey(
            text: text,
            fontName: fontName,
            fontSize: fontSize,
            isBold: isBold,
            isItalic: isItalic,
            containerWidth: containerSize.width,
            containerHeight: containerSize.height
        )
    }

    private func calculateSubtitleSize(using font: NSFont) -> CGSize {
        let horizontalPadding: CGFloat = 24
        let verticalPadding: CGFloat = 10
        let maxWidth = max(1, min(containerSize.width * 0.88, 900))
        let maxContentWidth = max(1, maxWidth - horizontalPadding)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: maxContentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let contentWidth = min(maxContentWidth, max(1, ceil(bounds.width)))
        let lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        let contentHeight = min(lineHeight * 4, max(lineHeight, ceil(bounds.height)))
        return CGSize(
            width: min(maxWidth, contentWidth + horizontalPadding),
            height: max(28, min(140, contentHeight + verticalPadding))
        )
    }

    private var textContentSize: CGSize {
        CGSize(width: max(1, subtitleSize.width - 24), height: max(1, subtitleSize.height - 10))
    }

    /// Positions are stored as normalized centers. Keep the entire rendered
    /// subtitle card inside the video bounds, not just its center; this also
    /// repairs old saved positions after a window resize or font change.
    private var constrainedSavedPosition: CGPoint {
        constrainedPosition(savedPosition)
    }

    private func constrainedPosition(_ point: CGPoint) -> CGPoint {
        let safeWidth = max(1, containerSize.width)
        let safeHeight = max(1, containerSize.height)
        let halfWidth = min(0.5, subtitleSize.width / safeWidth / 2)
        let halfHeight = min(0.5, subtitleSize.height / safeHeight / 2)
        let minX = halfWidth
        let maxX = max(minX, 1 - halfWidth)
        let minY = halfHeight
        let maxY = max(minY, 1 - halfHeight)
        let safeX = point.x.isFinite ? point.x : 0.5
        let safeY = point.y.isFinite ? point.y : 0.5
        return CGPoint(
            x: min(maxX, max(minX, safeX)),
            y: min(maxY, max(minY, safeY))
        )
    }

    /// 当字幕处于画面靠下区域时，检测是否需要动态避让底部 OSD 控制面板
    private var isBottomSubtitle: Bool {
        constrainedSavedPosition.y > 0.65
    }

    /// 当底部 OSD 浮现且当前字幕位于底部时，平滑向上避让 68pt，防止字幕被遮挡
    private var avoidanceOffset: CGFloat {
        if isOSDVisible && isBottomSubtitle && !isDragging && !appKitDragActive {
            return -68
        }
        return 0
    }

    private func updateCachedLayout() {
        let font = makeSubtitleFont()
        cachedSubtitleFont = font
        cachedSubtitleSize = calculateSubtitleSize(using: font)
    }

    var body: some View {
        DictionarySelectableText(
            text: text,
            font: subtitleFont,
            color: NSColor(color),
            context: context,
            alignment: .center,
            onHoverChanged: { inside in
                if isHovering != inside {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isHovering = inside
                    }
                }
            },
            onDoubleClick: {
                let coordinator = DictionaryInteractionCoordinator.shared
                coordinator.bindPlaybackEngine(engine)
                coordinator.pausePlaybackForVideoSubtitleSelection()
            },
            onOptionDrag: { phase in
                switch phase {
                case .started:
                    appKitDragActive = true
                    if !hasNotifiedEngineOfDrag {
                        hasNotifiedEngineOfDrag = true
                        engine.beginVideoSubtitleDrag(segmentID: segmentID)
                    }
                    isDragging = true
                case .changed(let translation):
                    dragOffset = translation
                case .ended(let translation):
                    let width = max(1, containerSize.width)
                    let height = max(1, containerSize.height)
                    let finalPosition = constrainedPosition(CGPoint(
                        x: constrainedSavedPosition.x + translation.width / width,
                        y: constrainedSavedPosition.y + translation.height / height
                    ))
                    setPosition(finalPosition)
                    dragOffset = .zero
                    isDragging = false
                    appKitDragActive = false
                    if hasNotifiedEngineOfDrag {
                        hasNotifiedEngineOfDrag = false
                        engine.endVideoSubtitleDrag(segmentID: segmentID)
                    }
                }
            }
        )
        .frame(width: textContentSize.width, height: textContentSize.height)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            Color.black.opacity(isDragging ? 0.65 : 0.45),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isDragging ? Color.white.opacity(0.35) : Color.white.opacity(0.06),
                    lineWidth: 1
                )
        )
        .shadow(
            color: .black.opacity(isDragging ? 0.85 : 0.65),
            radius: isDragging ? 6 : 3,
            x: 0,
            y: isDragging ? 2 : 1
        )
        .frame(width: subtitleSize.width, height: subtitleSize.height)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard !appKitDragActive,
                          NSEvent.modifierFlags.contains(.option) || NSEvent.modifierFlags.contains(.command) || isDragging else { return }
                    if !hasNotifiedEngineOfDrag {
                        hasNotifiedEngineOfDrag = true
                        engine.beginVideoSubtitleDrag(segmentID: segmentID)
                    }
                    isDragging = true
                    dragOffset = value.translation
                }
                .onEnded { value in
                    guard !appKitDragActive, isDragging else { return }
                    let width = max(1, containerSize.width)
                    let height = max(1, containerSize.height)
                    let finalPosition = constrainedPosition(CGPoint(
                        x: constrainedSavedPosition.x + value.translation.width / width,
                        y: constrainedSavedPosition.y + value.translation.height / height
                    ))
                    setPosition(finalPosition)
                    dragOffset = .zero
                    isDragging = false
                    if hasNotifiedEngineOfDrag {
                        hasNotifiedEngineOfDrag = false
                        engine.endVideoSubtitleDrag(segmentID: segmentID)
                    }
                }
        )
        .offset(
            x: dragOffset.width,
            y: dragOffset.height + avoidanceOffset
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: avoidanceOffset)
        .position(
            x: constrainedSavedPosition.x * containerSize.width,
            y: constrainedSavedPosition.y * containerSize.height
        )
        .onDisappear {
            if hasNotifiedEngineOfDrag {
                hasNotifiedEngineOfDrag = false
                engine.endVideoSubtitleDrag(segmentID: segmentID)
            }
            appKitDragActive = false
        }
        .onAppear {
            updateCachedLayout()
        }
        .onChange(of: layoutKey) { _, _ in
            updateCachedLayout()
        }
    }

    private func setPosition(_ point: CGPoint) {
        let point = constrainedPosition(point)
        switch track {
        case .original:
            settings.originalPositionX = point.x
            settings.originalPositionY = point.y
        case .translation:
            settings.translationPositionX = point.x
            settings.translationPositionY = point.y
        }
    }
}

private struct SubtitleLayoutKey: Equatable {
    let text: String
    let fontName: String
    let fontSize: Double
    let isBold: Bool
    let isItalic: Bool
    let containerWidth: CGFloat
    let containerHeight: CGFloat
}

/// 只覆盖视频画面的双语字幕层。时间轴和播放仍由 PlaybackEngine 管理，
/// 所以字幕会随着当前活动句实时切换；支持随底部 OSD 控制面板呼出平滑上浮避让。
public struct VideoSubtitleOverlay: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject private var activeSegmentState: ActiveSegmentPresentationState
    var isOSDVisible: Bool
    @ObservedObject private var settings = VideoSubtitleSettings.shared

    public init(engine: PlaybackEngine, isOSDVisible: Bool = false) {
        self.engine = engine
        self._activeSegmentState = ObservedObject(wrappedValue: engine.activeSegmentState)
        self.isOSDVisible = isOSDVisible
    }

    public var body: some View {
        GeometryReader { geometry in
            if engine.currentMedia != nil,
               let index = activeSegmentState.index,
               engine.segments.indices.contains(index) {
                let segment = engine.segments[index]
                ZStack {
                    // Always keep one native NSTextView mounted for each track.
                    // A cue with empty text or a temporarily hidden track is
                    // made transparent and non-interactive instead of removing
                    // the AppKit responder. This keeps the video host and any
                    // open Display > Waveforms submenu stable at cue boundaries.
                    DraggableVideoSubtitle(
                        settings: settings,
                        engine: engine,
                        segmentID: segment.id,
                        track: .original,
                        text: segment.text,
                        containerSize: geometry.size,
                        context: segmentContext(segment),
                        isOSDVisible: isOSDVisible
                    )
                    .id("video-subtitle-original-track")
                    .opacity(settings.showOriginal && !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0)
                    .allowsHitTesting(settings.showOriginal && !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHidden(!settings.showOriginal || segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    // Keep the original subtitle's move affordance above
                    // the translation layer when the two cards approach.
                    .zIndex(2)

                    DraggableVideoSubtitle(
                        settings: settings,
                        engine: engine,
                        segmentID: segment.id,
                        track: .translation,
                        text: segment.translation,
                        containerSize: geometry.size,
                        context: segmentContext(segment),
                        isOSDVisible: isOSDVisible
                    )
                    .id("video-subtitle-translation-track")
                    .opacity(settings.showTranslation && !segment.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0)
                    .allowsHitTesting(settings.showTranslation && !segment.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHidden(!settings.showTranslation || segment.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .zIndex(1)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .allowsHitTesting(true)
    }

    private func segmentContext(_ segment: SentenceSegment) -> String {
        [segment.text, segment.translation]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// 工具栏“字体设置”按钮打开的紧凑配置面板。
/// 支持对视频模式、列表模式、全文模式、句子模式 4 种界面模式的字体独立调优。
@MainActor
public struct VideoSubtitleFontSettingsPopover: View {
    // 弹窗使用本地草稿，不订阅整个全局设置对象；这样字幕实时预览仍然生效，
    // 但字体设置对象的其它变化不会让弹窗整棵视图树重新计算。
    private let settings: VideoSubtitleSettings
    @ObservedObject private var lang = LanguageManager.shared
    @State private var selectedMode: PlaybackInterfaceMode
    @State private var draftSettings: ModeFontSettings
    @State private var isAdjustingFontSize = false

    public init(initialMode: PlaybackInterfaceMode = .video) {
        let settings = VideoSubtitleSettings.shared
        self.settings = settings
        _selectedMode = State(initialValue: initialMode)
        _draftSettings = State(initialValue: settings.fontSettings(for: initialMode))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(lang.text("播放区字幕字体设置", "Subtitle Font Settings"))
                .font(.headline)

            // 模式选择分段器
            Picker("", selection: $selectedMode) {
                ForEach(PlaybackInterfaceMode.allCases) { mode in
                    Label(mode.localized(with: lang), systemImage: mode.iconName)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(lang.text("设置界面模式", "Settings interface mode"))

            subtitleGroup(
                title: lang.text("原文", "Original"),
                fontName: Binding(
                    get: { draftSettings.originalFontName },
                    set: { val in updateDraft { $0.originalFontName = val } }
                ),
                fontSize: Binding(
                    get: { draftSettings.originalFontSize },
                    set: { val in updateDraft({ $0.originalFontSize = val }, persist: !isAdjustingFontSize) }
                ),
                bold: Binding(
                    get: { draftSettings.originalBold },
                    set: { val in updateDraft { $0.originalBold = val } }
                ),
                italic: Binding(
                    get: { draftSettings.originalItalic },
                    set: { val in updateDraft { $0.originalItalic = val } }
                ),
                color: Binding(
                    get: { draftSettings.originalColor },
                    set: { val in updateDraft { $0.originalColor = val } }
                ),
                onFontSizeEditingChanged: handleFontSizeEditingChanged
            )

            Divider()

            subtitleGroup(
                title: lang.text("译文", "Translation"),
                fontName: Binding(
                    get: { draftSettings.translationFontName },
                    set: { val in updateDraft { $0.translationFontName = val } }
                ),
                fontSize: Binding(
                    get: { draftSettings.translationFontSize },
                    set: { val in updateDraft({ $0.translationFontSize = val }, persist: !isAdjustingFontSize) }
                ),
                bold: Binding(
                    get: { draftSettings.translationBold },
                    set: { val in updateDraft { $0.translationBold = val } }
                ),
                italic: Binding(
                    get: { draftSettings.translationItalic },
                    set: { val in updateDraft { $0.translationItalic = val } }
                ),
                color: Binding(
                    get: { draftSettings.translationColor },
                    set: { val in updateDraft { $0.translationColor = val } }
                ),
                onFontSizeEditingChanged: handleFontSizeEditingChanged
            )

            if selectedMode != .video {
                HStack {
                    Text(lang.text("自动配色随浅色与深色外观调整", "Automatic colors adapt to Light and Dark Mode"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(lang.text("恢复自动配色", "Use automatic colors")) {
                        updateDraft {
                            $0.originalColorHex = StudyMateSubtitleColorToken.label
                            $0.translationColorHex = StudyMateSubtitleColorToken.secondaryLabel
                        }
                    }
                }
            }

            if selectedMode == .video {
                HStack {
                    Spacer()
                    Button(lang.text("重置字幕位置", "Reset subtitle positions")) {
                        settings.resetPositions()
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 450)
        .onAppear {
            draftSettings = settings.fontSettings(for: selectedMode)
        }
        .onChange(of: selectedMode) { _, newMode in
            draftSettings = settings.fontSettings(for: newMode)
        }
        .onDisappear {
            if isAdjustingFontSize {
                settings.setFontSettings(draftSettings, for: selectedMode)
            }
        }
    }

    private func updateDraft(
        _ update: (inout ModeFontSettings) -> Void,
        persist: Bool = true
    ) {
        var updated = draftSettings
        update(&updated)
        draftSettings = updated
        settings.setFontSettings(updated, for: selectedMode, persist: persist)
    }

    private func handleFontSizeEditingChanged(_ isEditing: Bool) {
        isAdjustingFontSize = isEditing
        if !isEditing {
            // Slider 拖动期间只更新实时预览；鼠标释放后再持久化一次。
            settings.setFontSettings(draftSettings, for: selectedMode)
        }
    }

    @ViewBuilder
    private func subtitleGroup(
        title: String,
        fontName: Binding<String>,
        fontSize: Binding<Double>,
        bold: Binding<Bool>,
        italic: Binding<Bool>,
        color: Binding<Color>,
        onFontSizeEditingChanged: @escaping (Bool) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))

            HStack {
                Text(lang.text("字体", "Font"))
                    .frame(width: 48, alignment: .leading)
                SubtitleFontFamilyMenu(selection: fontName)
                    .frame(maxWidth: .infinity)
            }

            HStack {
                Text(lang.text("大小", "Size"))
                    .frame(width: 48, alignment: .leading)
                Slider(value: fontSize, in: 10...72, step: 1, onEditingChanged: onFontSizeEditingChanged)
                Text("\(Int(fontSize.wrappedValue))")
                    .monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
            }

            HStack(spacing: 14) {
                Toggle(lang.text("粗体", "Bold"), isOn: bold)
                Toggle(lang.text("斜体", "Italic"), isOn: italic)
                ColorPicker(lang.text("颜色", "Color"), selection: color, supportsOpacity: false)
            }
            .toggleStyle(.checkbox)
        }
    }
}

/// 字体列表延迟到系统菜单真正展开时构建；菜单项使用系统字体，避免打开设置面板时
/// 为数百个字体同步创建自定义字体对象。当前选中的字体保留一个轻量预览。
private struct SubtitleFontFamilyMenu: View {
    @Binding var selection: String
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        Menu {
            ForEach(VideoSubtitleSettings.availableFontFamilies, id: \.self) { family in
                Button {
                    selection = family
                } label: {
                    if selection == family {
                        Label(family, systemImage: "checkmark")
                    } else {
                        Text(family)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selection)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("Aa")
                    .font(.custom(selection, size: 12))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(lang.text("字幕字体", "Subtitle font"))
        .accessibilityValue(selection)
        .help(lang.text("选择字幕字体", "Choose subtitle font"))
    }
}

/// 文本类界面使用语义色，随 macOS 浅色/深色外观自动切换；视频字幕仍保留
/// 对视频画面更稳定的高对比默认色。
fileprivate enum StudyMateSubtitleColorToken {
    static let label = "system.label"
    static let secondaryLabel = "system.secondarylabel"
}

extension Color {
    init(studymateHex hex: String) {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        if normalized.lowercased() == StudyMateSubtitleColorToken.label {
            self.init(nsColor: .labelColor)
            return
        }
        if normalized.lowercased() == StudyMateSubtitleColorToken.secondaryLabel {
            self.init(nsColor: VideoSubtitleSettings.automaticTranslationColor)
            return
        }
        var value: UInt64 = 0
        Scanner(string: normalized).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }

    var studymateHex: String? {
        guard let nsColor = NSColor(self).usingColorSpace(.deviceRGB) else { return nil }
        let red = Int(round(nsColor.redComponent * 255))
        let green = Int(round(nsColor.greenComponent * 255))
        let blue = Int(round(nsColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
