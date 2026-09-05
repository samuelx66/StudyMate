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

    // 4 种界面模式的独立字体设置
    @Published public var videoFontSettings: ModeFontSettings {
        didSet { persistFontSettings(videoFontSettings, mode: .video) }
    }
    @Published public var listFontSettings: ModeFontSettings {
        didSet { persistFontSettings(listFontSettings, mode: .list) }
    }
    @Published public var fullTextFontSettings: ModeFontSettings {
        didSet { persistFontSettings(fullTextFontSettings, mode: .fullText) }
    }
    @Published public var sentenceFontSettings: ModeFontSettings {
        didSet { persistFontSettings(sentenceFontSettings, mode: .sentence) }
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
        }
    }

    public func setFontSettings(_ newSettings: ModeFontSettings, for mode: PlaybackInterfaceMode) {
        switch mode {
        case .video: videoFontSettings = newSettings
        case .list: listFontSettings = newSettings
        case .fullText: fullTextFontSettings = newSettings
        case .sentence: sentenceFontSettings = newSettings
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
        fontSettings(for: mode).originalNSColor
    }

    public func translationNSColor(for mode: PlaybackInterfaceMode = .video) -> NSColor {
        fontSettings(for: mode).translationNSColor
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
            originalColorHex: "#FFFFFF",
            translationColorHex: "#FFE36E"
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
            originalColorHex: "#FFFFFF",
            translationColorHex: "#FFE36E"
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
            originalColorHex: "#FFFFFF",
            translationColorHex: "#FFE36E"
        )

        videoFontSettings = Self.loadFontSettings(from: defaults, mode: .video, defaultSettings: defaultVideo)
        listFontSettings = Self.loadFontSettings(from: defaults, mode: .list, defaultSettings: defaultList)
        fullTextFontSettings = Self.loadFontSettings(from: defaults, mode: .fullText, defaultSettings: defaultFullText)
        sentenceFontSettings = Self.loadFontSettings(from: defaults, mode: .sentence, defaultSettings: defaultSentence)

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
        .offset(dragOffset)
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
/// 所以字幕会随着当前活动句实时切换。
public struct VideoSubtitleOverlay: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject private var settings = VideoSubtitleSettings.shared

    public init(engine: PlaybackEngine) {
        self.engine = engine
    }

    public var body: some View {
        GeometryReader { geometry in
            if engine.currentMedia != nil,
               let index = engine.activeSegmentIndex,
               engine.segments.indices.contains(index) {
                let segment = engine.segments[index]
                ZStack {
                    if settings.showOriginal, !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DraggableVideoSubtitle(
                            settings: settings,
                            engine: engine,
                            segmentID: segment.id,
                            track: .original,
                            text: segment.text,
                            containerSize: geometry.size,
                            context: segmentContext(segment)
                        )
                        .id("\(segment.id)_original")
                        // Keep the original subtitle's move affordance above
                        // the translation layer when the two cards approach.
                        .zIndex(2)
                    }
                    if settings.showTranslation, !segment.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DraggableVideoSubtitle(
                            settings: settings,
                            engine: engine,
                            segmentID: segment.id,
                            track: .translation,
                            text: segment.translation,
                            containerSize: geometry.size,
                            context: segmentContext(segment)
                        )
                        .id("\(segment.id)_translation")
                        .zIndex(1)
                    }
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
public struct VideoSubtitleFontSettingsPopover: View {
    @ObservedObject private var settings = VideoSubtitleSettings.shared
    @ObservedObject private var lang = LanguageManager.shared
    @State private var selectedMode: PlaybackInterfaceMode

    public init(initialMode: PlaybackInterfaceMode = .video) {
        _selectedMode = State(initialValue: initialMode)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(lang.text("播放区字幕字体设置", "Subtitle Font Settings"))
                .font(.headline)

            // 模式选择分段器
            Picker("", selection: $selectedMode) {
                ForEach(PlaybackInterfaceMode.allCases) { mode in
                    Text(mode.localized(with: lang)).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            subtitleGroup(
                title: lang.text("原文", "Original"),
                fontName: Binding(
                    get: { settings.fontSettings(for: selectedMode).originalFontName },
                    set: { val in settings.updateFontSettings(for: selectedMode) { $0.originalFontName = val } }
                ),
                fontSize: Binding(
                    get: { settings.fontSettings(for: selectedMode).originalFontSize },
                    set: { val in settings.updateFontSettings(for: selectedMode) { $0.originalFontSize = val } }
                ),
                bold: Binding(
                    get: { settings.fontSettings(for: selectedMode).originalBold },
                    set: { val in settings.updateFontSettings(for: selectedMode) { $0.originalBold = val } }
                ),
                italic: Binding(
                    get: { settings.fontSettings(for: selectedMode).originalItalic },
                    set: { val in settings.updateFontSettings(for: selectedMode) { $0.originalItalic = val } }
                ),
                color: Binding(
                    get: { settings.fontSettings(for: selectedMode).originalColor },
                    set: { val in settings.updateFontSettings(for: selectedMode) { $0.originalColor = val } }
                )
            )

            Divider()

            subtitleGroup(
                title: lang.text("译文", "Translation"),
                fontName: Binding(
                    get: { settings.fontSettings(for: selectedMode).translationFontName },
                    set: { val in settings.updateFontSettings(for: selectedMode) { $0.translationFontName = val } }
                ),
                fontSize: Binding(
                    get: { settings.fontSettings(for: selectedMode).translationFontSize },
                    set: { val in settings.updateFontSettings(for: selectedMode) { $0.translationFontSize = val } }
                ),
                bold: Binding(
                    get: { settings.fontSettings(for: selectedMode).translationBold },
                    set: { val in settings.updateFontSettings(for: selectedMode) { $0.translationBold = val } }
                ),
                italic: Binding(
                    get: { settings.fontSettings(for: selectedMode).translationItalic },
                    set: { val in settings.updateFontSettings(for: selectedMode) { $0.translationItalic = val } }
                ),
                color: Binding(
                    get: { settings.fontSettings(for: selectedMode).translationColor },
                    set: { val in settings.updateFontSettings(for: selectedMode) { $0.translationColor = val } }
                )
            )

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
        .frame(width: 380)
    }

    @ViewBuilder
    private func subtitleGroup(
        title: String,
        fontName: Binding<String>,
        fontSize: Binding<Double>,
        bold: Binding<Bool>,
        italic: Binding<Bool>,
        color: Binding<Color>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))

            HStack {
                Text(lang.text("字体", "Font"))
                    .frame(width: 48, alignment: .leading)
                Picker("", selection: fontName) {
                    ForEach(VideoSubtitleSettings.availableFontFamilies, id: \.self) { family in
                        Text(family).font(.custom(family, size: 12)).tag(family)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            HStack {
                Text(lang.text("大小", "Size"))
                    .frame(width: 48, alignment: .leading)
                Slider(value: fontSize, in: 10...72, step: 1)
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

extension Color {
    init(studymateHex hex: String) {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
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
