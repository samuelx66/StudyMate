import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 主窗口右侧播放列表（遵循 macOS 26 Liquid Glass 设计规范：侧拉门毛玻璃质感、卡片式行项、动态播报徽标与平滑拖拽调整）
public struct PlaybackListView: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var historyStore: PlaybackHistoryStore
    @Binding var playlistWidth: Double
    var onResizeEnded: () -> Void
    @ObservedObject private var lang = LanguageManager.shared
    
    @State private var selectedMediaURL: URL? = nil
    @State private var hoveredMediaURL: URL? = nil
    @State private var fileExistence: [String: Bool] = [:]

    public init(
        engine: PlaybackEngine,
        historyStore: PlaybackHistoryStore,
        playlistWidth: Binding<Double> = .constant(360),
        onResizeEnded: @escaping () -> Void = {}
    ) {
        self.engine = engine
        self.historyStore = historyStore
        self._playlistWidth = playlistWidth
        self.onResizeEnded = onResizeEnded
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            // 播放列表内容区
            VStack(spacing: 0) {
                // 顶部 Header（macOS 26 悬浮磨砂玻璃工具条）
                HStack(spacing: 8) {
                    Label(lang.text("播放列表", "Playlist"), systemImage: "music.note.list")
                        .font(.system(size: 13, weight: .bold))

                    Text("\(historyStore.entries.count)")
                        .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))

                    Spacer()

                    // 使用独立的 AppKit 命中视图。播放列表作为浮层时，不能让工具栏
                    // 的鼠标追踪区域落到底下的断句列表按钮上。
                    PlaybackListToolbarIconButton(
                        symbolName: "plus",
                        toolTip: lang.text("添加音视频文件", "Add audio or video files"),
                        isEnabled: true,
                        action: addFiles
                    )
                    .frame(width: 26, height: 26)
                    .fixedSize()

                    // 移除当前选中条目（只从播放列表移除，不删除源媒体文件）。
                    PlaybackListToolbarIconButton(
                        symbolName: "minus",
                        toolTip: lang.text("从播放列表移除选中的媒体文件", "Remove selected media from playlist"),
                        isEnabled: selectedEntryURL != nil
                    ) {
                        guard let mediaURL = selectedEntryURL else { return }
                        selectedMediaURL = nil
                        Task { await engine.removeFromPlaybackHistory(mediaURL) }
                    }
                    .frame(width: 26, height: 26)
                    .fixedSize()

                    // 清空列表按钮
                    PlaybackListToolbarIconButton(
                        symbolName: "trash",
                        toolTip: lang.text("清空播放列表", "Clear playlist"),
                        isEnabled: !historyStore.entries.isEmpty
                    ) {
                        selectedMediaURL = nil
                        Task { await engine.clearPlaybackHistory() }
                    }
                    .frame(width: 26, height: 26)
                    .fixedSize()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()
                    .opacity(0.6)

                if historyStore.entries.isEmpty {
                    ContentUnavailableView {
                        Label(lang.text("播放列表为空", "Playlist Is Empty"), systemImage: "music.note.list")
                    } description: {
                        Text(lang.text(
                            "打开过的音视频会自动出现在这里。",
                            "Opened media appears here automatically."
                        ))
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(historyStore.entries) { entry in
                                playbackRow(entry)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                }
            }

            // 左侧边缘拉伸调整宽度手柄（原生 AppKit 120Hz 丝滑事件追踪，无高亮线干扰）
            HStack(spacing: 0) {
                PlaylistResizeBorderRepresentable(
                    playlistWidth: $playlistWidth,
                    onResizeEnded: onResizeEnded
                )
                .frame(width: 8)

                Spacer()
            }
        }
        .studymateNavigationSurface(cornerRadius: 0)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(StudyMateMediaStyle.separator.opacity(0.45))
                .frame(width: 1)
        }
        .shadow(color: Color.black.opacity(0.24), radius: 22, x: -7, y: 0)
        .contentShape(Rectangle())
        .task(id: historyStore.entries.map(\.mediaPath)) {
            let paths = historyStore.entries.map(\.mediaPath)
            let result = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: paths.map { ($0, FileManager.default.fileExists(atPath: $0)) })
            }.value
            guard !Task.isCancelled else { return }
            fileExistence = result
        }
    }

    private func playbackRow(_ entry: PlaybackHistoryEntry) -> some View {
        let isCurrent = engine.currentMedia?.url.standardizedFileURL == entry.mediaURL
        let isSelected = selectedMediaURL == entry.mediaURL
        let exists = fileExistence[entry.mediaPath] ?? true
        let isHovered = hoveredMediaURL == entry.mediaURL

        return HStack(spacing: 10) {
            // 媒体类型徽章（macOS 26 玻璃质感圆角微标）
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isCurrent
                            ? Color.accentColor.opacity(0.18)
                            : (exists ? Color.primary.opacity(0.06) : StudyMateMediaStyle.destructive.opacity(0.12))
                    )
                    .frame(width: 28, height: 28)

                Image(systemName: mediaIcon(for: entry.mediaURL))
                    .font(.system(size: 13))
                    .foregroundStyle(
                        isCurrent
                            ? Color.accentColor
                            : (exists ? Color.primary.opacity(0.7) : StudyMateMediaStyle.destructive)
                    )
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.filename)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(
                        exists
                            ? (isCurrent ? Color.accentColor : Color.primary)
                            : Color.secondary
                    )
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !exists {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text(lang.text("原文件已不存在或移动", "Original file is missing"))
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(StudyMateMediaStyle.destructive.opacity(0.85))
                } else {
                    Text(entry.mediaURL.deletingLastPathComponent().lastPathComponent)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if isCurrent {
                // 正在播放动效指示器
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.trailing, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.16)
                        : (isCurrent
                            ? Color.accentColor.opacity(0.08)
                            : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isSelected
                        ? Color.accentColor.opacity(0.5)
                        : (isCurrent ? Color.accentColor.opacity(0.25) : (isHovered ? Color.primary.opacity(0.08) : Color.clear)),
                    lineWidth: 1
                )
        )
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3.5, height: 18)
                    .padding(.leading, 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // 双击：选中并立即切换播放
            selectedMediaURL = entry.mediaURL
            engine.loadMedia(from: entry.mediaURL)
        }
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                // 单击：仅选中条目，不切换播放
                selectedMediaURL = entry.mediaURL
            }
        )
        .onHover { hovering in
            hoveredMediaURL = hovering ? entry.mediaURL : nil
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contextMenu {
            Button(role: .destructive) {
                Task { await engine.removeFromPlaybackHistory(entry.mediaURL) }
            } label: {
                Label(lang.text("从列表中移除", "Remove from List"), systemImage: "trash")
            }

            Button {
                revealInFinder(entry.mediaURL)
            } label: {
                Label(lang.text("在访达中显示", "Show in Finder"), systemImage: "folder")
            }

            Divider()

            Button(action: addFiles) {
                Label(lang.text("添加文件…", "Add Files…"), systemImage: "plus")
            }
        }
        .help(entry.mediaPath)
    }

    private var selectedEntryURL: URL? {
        guard let selectedMediaURL,
              historyStore.entries.contains(where: { $0.mediaURL == selectedMediaURL }) else {
            return nil
        }
        return selectedMediaURL
    }

    private func revealInFinder(_ mediaURL: URL) {
        if FileManager.default.fileExists(atPath: mediaURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([mediaURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([mediaURL.deletingLastPathComponent()])
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.allowedMediaTypes
        panel.message = lang.text(
            "所选文件将添加到播放列表末尾，不会立即切换播放。",
            "Selected files will be appended without switching playback."
        )
        if panel.runModal() == .OK {
            historyStore.add(panel.urls)
        }
    }

    private func mediaIcon(for url: URL) -> String {
        let videoExtensions: Set<String> = [
            "mkv", "mp4", "mov", "m4v", "avi", "webm", "flv", "wmv", "ts", "vob", "ogv", "rmvb", "3gp"
        ]
        return videoExtensions.contains(url.pathExtension.lowercased()) ? "film" : "music.note"
    }

    private static let allowedMediaTypes: [UTType] = [
        .audio,
        .movie,
        .mp3,
        .mpeg4Audio,
        .mpeg4Movie,
        .quickTimeMovie,
        .wav,
        UTType(filenameExtension: "flac") ?? .audio,
        UTType(filenameExtension: "m4a") ?? .audio,
        UTType(filenameExtension: "mkv") ?? .movie,
        UTType(filenameExtension: "webm") ?? .movie,
        UTType(filenameExtension: "avi") ?? .movie,
        UTType(filenameExtension: "flv") ?? .movie,
        UTType(filenameExtension: "wmv") ?? .movie,
        UTType(filenameExtension: "ts") ?? .movie,
        UTType(filenameExtension: "ogg") ?? .audio,
        UTType(filenameExtension: "opus") ?? .audio,
        UTType(filenameExtension: "ape") ?? .audio
    ]
}

/// 播放列表工具条的原生图标按钮。
///
/// 使用独立 `NSButton`，而非只依赖 SwiftUI 的 `.help` 追踪区域，确保浮层里的
/// tooltip 与鼠标事件均由最上层播放列表消费，不会命中下层断句列表的控件。
private struct PlaybackListToolbarIconButton: NSViewRepresentable {
    let symbolName: String
    let toolTip: String
    let isEnabled: Bool
    let action: () -> Void

    init(
        symbolName: String,
        toolTip: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) {
        self.symbolName = symbolName
        self.toolTip = toolTip
        self.isEnabled = isEnabled
        self.action = action
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> PlaylistToolbarIconNSButton {
        let button = PlaylistToolbarIconNSButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        return button
    }

    func updateNSView(_ nsView: PlaylistToolbarIconNSButton, context: Context) {
        context.coordinator.action = action
        nsView.toolTip = toolTip
        nsView.setAccessibilityLabel(toolTip)
        nsView.isEnabled = isEnabled
        nsView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: toolTip
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: PlaylistToolbarIconNSButton,
        context: Context
    ) -> CGSize? {
        CGSize(width: 26, height: 26)
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            action()
        }
    }
}

private final class PlaylistToolbarIconNSButton: NSButton {
    override var intrinsicContentSize: NSSize {
        NSSize(width: 26, height: 26)
    }

    init() {
        super.init(frame: .init(x: 0, y: 0, width: 26, height: 26))
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .none
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        alphaValue = 0.58
        super.mouseDown(with: event)
        alphaValue = 1
    }
}

/// 原生 AppKit 极致丝滑边框拉伸组件（采用 Finder / NSSplitView 同款 modal event tracking loop）
private struct PlaylistResizeBorderRepresentable: NSViewRepresentable {
    @Binding var playlistWidth: Double
    let onResizeEnded: () -> Void

    func makeNSView(context: Context) -> PlaylistResizeBorderView {
        let view = PlaylistResizeBorderView()
        view.onDragDelta = { deltaX in
            let newWidth = min(max(240, playlistWidth - Double(deltaX)), 750)
            if newWidth != playlistWidth {
                playlistWidth = newWidth
            }
        }
        view.onDragEnded = onResizeEnded
        return view
    }

    func updateNSView(_ nsView: PlaylistResizeBorderView, context: Context) {
        nsView.onDragDelta = { deltaX in
            let newWidth = min(max(240, playlistWidth - Double(deltaX)), 750)
            if newWidth != playlistWidth {
                playlistWidth = newWidth
            }
        }
        nsView.onDragEnded = onResizeEnded
    }
}

private final class PlaylistResizeBorderView: NSView {
    var onDragDelta: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        postsFrameChangedNotifications = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window = self.window else { return }
        var lastLocation = NSEvent.mouseLocation
        
        NSCursor.resizeLeftRight.push()
        defer { NSCursor.pop() }
        
        while true {
            guard let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                break
            }
            if nextEvent.type == .leftMouseUp {
                onDragEnded?()
                break
            }
            let currentLocation = NSEvent.mouseLocation
            let deltaX = currentLocation.x - lastLocation.x
            lastLocation = currentLocation
            
            if deltaX != 0 {
                onDragDelta?(deltaX)
            }
        }
    }
}
