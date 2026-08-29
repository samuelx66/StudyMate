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
        get { Color(macabobooHex: originalColorHex) }
        set { originalColorHex = newValue.macabobooHex ?? "#FFFFFF" }
    }

    public var translationColor: Color {
        get { Color(macabobooHex: translationColorHex) }
        set { translationColorHex = newValue.macabobooHex ?? "#FFE36E" }
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
        static let showOriginal = "MacAboboo.VideoSubtitle.ShowOriginal"
        static let showTranslation = "MacAboboo.VideoSubtitle.ShowTranslation"
        static let originalFontName = "MacAboboo.VideoSubtitle.OriginalFontName"
        static let translationFontName = "MacAboboo.VideoSubtitle.TranslationFontName"
        static let originalFontSize = "MacAboboo.VideoSubtitle.OriginalFontSize"
        static let translationFontSize = "MacAboboo.VideoSubtitle.TranslationFontSize"
        static let originalBold = "MacAboboo.VideoSubtitle.OriginalBold"
        static let translationBold = "MacAboboo.VideoSubtitle.TranslationBold"
        static let originalItalic = "MacAboboo.VideoSubtitle.OriginalItalic"
        static let translationItalic = "MacAboboo.VideoSubtitle.TranslationItalic"
        static let originalColor = "MacAboboo.VideoSubtitle.OriginalColor"
        static let translationColor = "MacAboboo.VideoSubtitle.TranslationColor"
        static let originalPositionX = "MacAboboo.VideoSubtitle.OriginalPositionX"
        static let originalPositionY = "MacAboboo.VideoSubtitle.OriginalPositionY"
        static let translationPositionX = "MacAboboo.VideoSubtitle.TranslationPositionX"
        static let translationPositionY = "MacAboboo.VideoSubtitle.TranslationPositionY"
    }
}

private enum VideoSubtitleTrack {
    case original
    case translation
}

private struct DraggableVideoSubtitle: View, Equatable {
    @ObservedObject var settings: VideoSubtitleSettings
    let engine: PlaybackEngine
    let segmentID: UUID
    let track: VideoSubtitleTrack
    let text: String
    let containerSize: CGSize

    static func == (lhs: DraggableVideoSubtitle, rhs: DraggableVideoSubtitle) -> Bool {
        lhs.track == rhs.track
            && lhs.segmentID == rhs.segmentID
            && lhs.text == rhs.text
            && lhs.containerSize == rhs.containerSize
            && lhs.settings.originalPositionX == rhs.settings.originalPositionX
            && lhs.settings.originalPositionY == rhs.settings.originalPositionY
            && lhs.settings.translationPositionX == rhs.settings.translationPositionX
            && lhs.settings.translationPositionY == rhs.settings.translationPositionY
            && lhs.settings.originalFontSize == rhs.settings.originalFontSize
            && lhs.settings.translationFontSize == rhs.settings.translationFontSize
            && lhs.settings.originalColorHex == rhs.settings.originalColorHex
            && lhs.settings.translationColorHex == rhs.settings.translationColorHex
            && lhs.settings.originalBold == rhs.settings.originalBold
            && lhs.settings.translationBold == rhs.settings.translationBold
            && lhs.settings.originalItalic == rhs.settings.originalItalic
            && lhs.settings.translationItalic == rhs.settings.translationItalic
            && lhs.settings.originalFontName == rhs.settings.originalFontName
            && lhs.settings.translationFontName == rhs.settings.translationFontName
    }

    @State private var dragStart: CGPoint?
    /// Keep pointer-driven position changes local to this view.  Persisting
    /// UserDefaults and publishing two settings properties for every gesture
    /// event makes the entire video overlay re-layout and causes visible
    /// lag behind the mouse on long/large videos.
    @State private var transientPosition: CGPoint?
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var hasNotifiedEngineOfDrag = false

    private var position: CGPoint {
        if let transientPosition {
            return transientPosition
        }
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

    var body: some View {
        Text(text)
            .font(.custom(fontName, size: max(10, min(96, fontSize))))
            .fontWeight(isBold ? .bold : .regular)
            .italic(isItalic)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.black.opacity(0.46), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        isHovering || isDragging
                            ? Color.accentColor.opacity(isDragging ? 0.9 : 0.7)
                            : Color.clear,
                        lineWidth: isDragging ? 1.4 : 1
                    )
            )
            .scaleEffect(isDragging ? 1.02 : 1.0)
            .shadow(color: .black.opacity(isDragging ? 0.9 : 0.75), radius: isDragging ? 5 : 3, x: 0, y: 1)
            .compositingGroup()
            .frame(maxWidth: max(180, containerSize.width * 0.88))
            .position(
                x: position.x * containerSize.width,
                y: position.y * containerSize.height
            )
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !hasNotifiedEngineOfDrag {
                            hasNotifiedEngineOfDrag = true
                            engine.beginVideoSubtitleDrag(segmentID: segmentID)
                        }
                        isDragging = true
                        if dragStart == nil { dragStart = position }
                        guard let start = dragStart else { return }
                        let width = max(1, containerSize.width)
                        let height = max(1, containerSize.height)
                        let nextX = min(0.98, max(0.02, start.x + value.translation.width / width))
                        let nextY = min(0.98, max(0.02, start.y + value.translation.height / height))
                        transientPosition = CGPoint(x: nextX, y: nextY)
                    }
                    .onEnded { _ in
                        if let transientPosition {
                            setPosition(transientPosition)
                        }
                        transientPosition = nil
                        dragStart = nil
                        isDragging = false
                        if hasNotifiedEngineOfDrag {
                            hasNotifiedEngineOfDrag = false
                            engine.endVideoSubtitleDrag(segmentID: segmentID)
                        }
                    }
            )
            .onHover { isHovering = $0 }
            .onDisappear {
                // A view can disappear while a pointer is down (for example
                // when the active sentence changes). Never leave the playback
                // engine in its drag lock in that case.
                if hasNotifiedEngineOfDrag {
                    hasNotifiedEngineOfDrag = false
                    engine.endVideoSubtitleDrag(segmentID: segmentID)
                }
            }
            .help(isDragging ? "" : "拖动字幕调整位置")
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
                            containerSize: geometry.size
                        )
                        .equatable()
                    }
                    if settings.showTranslation, !segment.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DraggableVideoSubtitle(
                            settings: settings,
                            engine: engine,
                            segmentID: segment.id,
                            track: .translation,
                            text: segment.translation,
                            containerSize: geometry.size
                        )
                        .equatable()
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .allowsHitTesting(true)
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
    init(macabobooHex hex: String) {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: normalized).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }

    var macabobooHex: String? {
        guard let nsColor = NSColor(self).usingColorSpace(.deviceRGB) else { return nil }
        let red = Int(round(nsColor.redComponent * 255))
        let green = Int(round(nsColor.greenComponent * 255))
        let blue = Int(round(nsColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
