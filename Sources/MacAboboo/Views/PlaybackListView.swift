import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 主窗口右侧播放列表。条目只保存媒体路径，不复制或移动原始文件。
public struct PlaybackListView: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var historyStore: PlaybackHistoryStore
    @ObservedObject private var lang = LanguageManager.shared
    @State private var fileExistence: [String: Bool] = [:]

    public init(engine: PlaybackEngine, historyStore: PlaybackHistoryStore) {
        self.engine = engine
        self.historyStore = historyStore
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Label(lang.text("播放列表", "Playlist"), systemImage: "music.note.list")
                    .font(.subheadline.bold())
                Text("(\(historyStore.entries.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: addFiles) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help(lang.text("添加音视频文件", "Add audio or video files"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.78))

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
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(historyStore.entries) { entry in
                            playbackRow(entry)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.82))
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
        let exists = fileExistence[entry.mediaPath] ?? true

        return Button {
            engine.loadMedia(from: entry.mediaURL)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: mediaIcon(for: entry.mediaURL))
                    .frame(width: 18)
                    .foregroundStyle(isCurrent ? Color.blue : (exists ? Color.secondary : Color.red))

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.filename)
                        .font(.caption)
                        .foregroundStyle(exists ? Color.primary : Color.secondary)
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
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrent ? Color.blue.opacity(0.14) : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isCurrent ? Color.blue.opacity(0.5) : .clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
