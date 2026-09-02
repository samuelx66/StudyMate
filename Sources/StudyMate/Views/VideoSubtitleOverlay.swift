import SwiftUI
import AppKit

/// 视频播放区双语字幕的显示与位置设置。设置保存在 UserDefaults，
/// 只影响播放区覆盖层，不会改写断句列表或字幕编辑区的字体。
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

    @Published public var originalFontName: String {
        didSet { defaults.set(originalFontName, forKey: Keys.originalFontName) }
    }
    @Published public var translationFontName: String {
        didSet { defaults.set(translationFontName, forKey: Keys.translationFontName) }
    }
    @Published public var originalFontSize: Double {
        didSet {
            let clamped = min(96.0, max(10.0, originalFontSize))
            if clamped != originalFontSize { originalFontSize = clamped }
            defaults.set(clamped, forKey: Keys.originalFontSize)
        }
    }
    @Published public var translationFontSize: Double {
        didSet {
            let clamped = min(96.0, max(10.0, translationFontSize))
            if clamped != translationFontSize { translationFontSize = clamped }
            defaults.set(clamped, forKey: Keys.translationFontSize)
        }
    }
    @Published public var originalBold: Bool {
        didSet { defaults.set(originalBold, forKey: Keys.originalBold) }
    }
    @Published public var translationBold: Bool {
        didSet { defaults.set(translationBold, forKey: Keys.translationBold) }
    }
    @Published public var originalItalic: Bool {
        didSet { defaults.set(originalItalic, forKey: Keys.originalItalic) }
    }
    @Published public var translationItalic: Bool {
        didSet { defaults.set(translationItalic, forKey: Keys.translationItalic) }
    }
    @Published public var originalColorHex: String {
        didSet { defaults.set(originalColorHex, forKey: Keys.originalColor) }
    }
    @Published public var translationColorHex: String {
        didSet { defaults.set(translationColorHex, forKey: Keys.translationColor) }
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

    public var originalColor: Color {
        get { Color(studymateHex: originalColorHex) }
        set { originalColorHex = newValue.studymateHex ?? "#FFFFFF" }
    }

    public var translationColor: Color {
        get { Color(studymateHex: translationColorHex) }
        set { translationColorHex = newValue.studymateHex ?? "#FFE36E" }
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
        originalFontName = defaults.string(forKey: Keys.originalFontName) ?? systemFamily
        translationFontName = defaults.string(forKey: Keys.translationFontName) ?? systemFamily
        originalFontSize = defaults.object(forKey: Keys.originalFontSize) as? Double ?? 28
        translationFontSize = defaults.object(forKey: Keys.translationFontSize) as? Double ?? 24
        originalBold = defaults.object(forKey: Keys.originalBold) as? Bool ?? true
        translationBold = defaults.object(forKey: Keys.translationBold) as? Bool ?? false
        originalItalic = defaults.object(forKey: Keys.originalItalic) as? Bool ?? false
        translationItalic = defaults.object(forKey: Keys.translationItalic) as? Bool ?? false
        originalColorHex = defaults.string(forKey: Keys.originalColor) ?? "#FFFFFF"
        translationColorHex = defaults.string(forKey: Keys.translationColor) ?? "#FFE36E"
        originalPositionX = defaults.object(forKey: Keys.originalPositionX) as? Double ?? 0.5
        originalPositionY = defaults.object(forKey: Keys.originalPositionY) as? Double ?? 0.76
        translationPositionX = defaults.object(forKey: Keys.translationPositionX) as? Double ?? 0.5
        translationPositionY = defaults.object(forKey: Keys.translationPositionY) as? Double ?? 0.86
    }

    private enum Keys {
        static let showOriginal = "StudyMate.VideoSubtitle.ShowOriginal"
        static let showTranslation = "StudyMate.VideoSubtitle.ShowTranslation"
        static let originalFontName = "StudyMate.VideoSubtitle.OriginalFontName"
        static let translationFontName = "StudyMate.VideoSubtitle.TranslationFontName"
        static let originalFontSize = "StudyMate.VideoSubtitle.OriginalFontSize"
        static let translationFontSize = "StudyMate.VideoSubtitle.TranslationFontSize"
        static let originalBold = "StudyMate.VideoSubtitle.OriginalBold"
        static let translationBold = "StudyMate.VideoSubtitle.TranslationBold"
        static let originalItalic = "StudyMate.VideoSubtitle.OriginalItalic"
        static let translationItalic = "StudyMate.VideoSubtitle.TranslationItalic"
        static let originalColor = "StudyMate.VideoSubtitle.OriginalColor"
        static let translationColor = "StudyMate.VideoSubtitle.TranslationColor"
        static let originalPositionX = "StudyMate.VideoSubtitle.OriginalPositionX"
        static let originalPositionY = "StudyMate.VideoSubtitle.OriginalPositionY"
        static let translationPositionX = "StudyMate.VideoSubtitle.TranslationPositionX"
        static let translationPositionY = "StudyMate.VideoSubtitle.TranslationPositionY"
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
        let horizontalPadding: CGFloat = 24
        let verticalPadding: CGFloat = 10
        let maxWidth = max(1, min(containerSize.width * 0.88, 900))
        let maxContentWidth = max(1, maxWidth - horizontalPadding)
        let attributes: [NSAttributedString.Key: Any] = [.font: subtitleFont]
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: maxContentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let contentWidth = min(maxContentWidth, max(1, ceil(bounds.width)))
        let lineHeight = max(1, ceil(subtitleFont.ascender - subtitleFont.descender + subtitleFont.leading))
        let contentHeight = min(lineHeight * 4, max(lineHeight, ceil(bounds.height)))
        return CGSize(
            width: min(maxWidth, contentWidth + horizontalPadding),
            height: max(28, min(140, contentHeight + verticalPadding))
        )
    }

    private var textContentSize: CGSize {
        CGSize(width: max(1, subtitleSize.width - 24), height: max(1, subtitleSize.height - 10))
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
                    let finalX = min(0.96, max(0.04, savedPosition.x + translation.width / width))
                    let finalY = min(0.96, max(0.04, savedPosition.y + translation.height / height))
                    setPosition(CGPoint(x: finalX, y: finalY))
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
                    let finalX = min(0.96, max(0.04, savedPosition.x + value.translation.width / width))
                    let finalY = min(0.96, max(0.04, savedPosition.y + value.translation.height / height))
                    setPosition(CGPoint(x: finalX, y: finalY))
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
            x: savedPosition.x * containerSize.width,
            y: savedPosition.y * containerSize.height
        )
        .onDisappear {
            if hasNotifiedEngineOfDrag {
                hasNotifiedEngineOfDrag = false
                engine.endVideoSubtitleDrag(segmentID: segmentID)
            }
            appKitDragActive = false
        }
    }

    private func setPosition(_ point: CGPoint) {
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
public struct VideoSubtitleFontSettingsPopover: View {
    @ObservedObject private var settings = VideoSubtitleSettings.shared
    @ObservedObject private var lang = LanguageManager.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(lang.text("播放区字幕字体设置", "Subtitle Font Settings"))
                .font(.headline)

            subtitleGroup(
                title: lang.text("原文", "Original"),
                fontName: $settings.originalFontName,
                fontSize: $settings.originalFontSize,
                bold: $settings.originalBold,
                italic: $settings.originalItalic,
                color: Binding(
                    get: { settings.originalColor },
                    set: { settings.originalColor = $0 }
                )
            )

            Divider()

            subtitleGroup(
                title: lang.text("译文", "Translation"),
                fontName: $settings.translationFontName,
                fontSize: $settings.translationFontSize,
                bold: $settings.translationBold,
                italic: $settings.translationItalic,
                color: Binding(
                    get: { settings.translationColor },
                    set: { settings.translationColor = $0 }
                )
            )

            HStack {
                Spacer()
                Button(lang.text("重置字幕位置", "Reset subtitle positions")) {
                    settings.resetPositions()
                }
            }
        }
        .padding(16)
        .frame(width: 370)
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

private extension Color {
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
