import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 主窗口右侧播放列表（支持单击选中、双击切换、左侧拖拽拉伸宽度、磨砂半透明玻璃质感、平面化 Header）
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
                // 顶部 Header（同平面，无凸起阴影与独立底色，仅保留底部分割线）
                HStack(spacing: 6) {
                    Label(lang.text("播放列表", "Playlist"), systemImage: "music.note.list")
                        .font(.system(size: 13, weight: .semibold))
                    Text("(\(historyStore.entries.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Button(action: addFiles) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .macabobooChromeButton(shape: .circle)
                    .help(lang.text("添加音视频文件", "Add audio or video files"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                Divider()

                if historyStore.entries.isEmpty {
                    ContentUnavailableView {
                        Label(lang.text("播放列表为空", "Playlist Is Empty"), systemImage: "music.note.list")
                    } description: {
                        Text(lang.text(
                            "打开过的音视频会自动出现在这里，也可以手动添加文件。",
                            "Opened media appears here automatically, or you can add files manually."
                        ))
                    } actions: {
                        Button(lang.text("添加文件…", "Add Files…"), action: addFiles)
                            .macabobooChromeButton(prominent: true)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(historyStore.entries) { entry in
                                playbackRow(entry)
                            }
                        }
                        .padding(6)
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
        .macabobooNavigationSurface(cornerRadius: 0)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(MacAbobooMediaStyle.separator.opacity(0.45))
                .frame(width: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 14, x: -4, y: 2)
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

        return HStack(spacing: 8) {
            Image(systemName: mediaIcon(for: entry.mediaURL))
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(isCurrent ? Color.accentColor : (exists ? Color.secondary : Color.red))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.filename)
                    .font(.system(size: 11.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(exists ? (isSelected ? Color.primary : (isCurrent ? Color.accentColor : Color.primary)) : Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !exists {
                    Text(lang.text("原文件已不存在", "Original file is missing"))
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.18)
                        : (isCurrent
                            ? Color.accentColor.opacity(0.08)
                            : (hoveredMediaURL == entry.mediaURL ? Color.primary.opacity(0.06) : Color.clear))
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.65) : (isCurrent ? Color.accentColor.opacity(0.3) : .clear), lineWidth: 1)
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
        .animation(.easeOut(duration: 0.12), value: hoveredMediaURL == entry.mediaURL)
        .contextMenu {
            Button(role: .destructive) {
                Task { await engine.removeFromPlaybackHistory(entry.mediaURL) }
            } label: {
                Label(lang.text("删除", "Delete"), systemImage: "trash")
            }

            Button {
                revealInFinder(entry.mediaURL)
            } label: {
                Label(lang.text("在访达中显示", "Show in Finder"), systemImage: "folder")
            }

            Button(action: addFiles) {
                Label(lang.text("添加文件", "Add Files"), systemImage: "plus")
            }
        }
        .help(entry.mediaPath)
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
