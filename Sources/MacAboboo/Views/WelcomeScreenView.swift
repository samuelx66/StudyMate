import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 欢迎首页（仿 Pixelmator Pro / macOS Pro App 双栏现代设计）
public struct WelcomeScreenView: View {
    @ObservedObject var historyStore: PlaybackHistoryStore
    @ObservedObject private var lang = LanguageManager.shared
    @Environment(\.colorScheme) private var colorScheme

    let onOpen: () -> Void
    let onOpenLibrary: () -> Void
    let onContinue: (URL) -> Void
    let onOpenHistoryItem: (URL) -> Void

    @State private var selectedURL: URL?
    @State private var hoveredURL: URL?
    @State private var isDropTargeted: Bool = false

    public static let welcomeSize = CGSize(width: 800, height: 520)

    public init(
        historyStore: PlaybackHistoryStore,
        onOpen: @escaping () -> Void,
        onOpenLibrary: @escaping () -> Void,
        onContinue: @escaping (URL) -> Void,
        onOpenHistoryItem: @escaping (URL) -> Void
    ) {
        self.historyStore = historyStore
        self.onOpen = onOpen
        self.onOpenLibrary = onOpenLibrary
        self.onContinue = onContinue
        self.onOpenHistoryItem = onOpenHistoryItem
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private var sortedHistory: [PlaybackHistoryEntry] {
        historyStore.entries
            .filter { FileManager.default.fileExists(atPath: $0.mediaURL.path) }
            .sorted { entry1, entry2 in
                let date1 = entry1.lastOpenedAt ?? entry1.addedAt
                let date2 = entry2.lastOpenedAt ?? entry2.addedAt
                return date1 > date2
            }
    }

    private var leftColumnBackground: Color {
        colorScheme == .dark
            ? Color(red: 32 / 255, green: 32 / 255, blue: 35 / 255)
            : Color.white
    }

    private var rightColumnBackground: Color {
        colorScheme == .dark
            ? Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255)
            : Color(red: 233.0 / 255.0, green: 233.0 / 255.0, blue: 233.0 / 255.0)
    }

    private var columnSeparatorColor: Color {
        colorScheme == .dark
            ? Color(red: 14 / 255, green: 14 / 255, blue: 16 / 255)
            : Color(red: 216.0 / 255.0, green: 216.0 / 255.0, blue: 216.0 / 255.0)
    }

    public var body: some View {
        HStack(spacing: 0) {
            // 左侧：App 品牌与主要操作区（自适应宽度，纯白/深色背景）
            leftActionColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(leftColumnBackground)

            // 分割线（紧密贴合，深浅色模式自适应融合）
            Rectangle()
                .fill(columnSeparatorColor)
                .frame(width: 1)
                .frame(maxHeight: .infinity)

            // 右侧：最近打开的文档列表（与原生窗口背景色完全一致）
            rightRecentsColumn
                .frame(width: 320)
                .frame(maxHeight: .infinity)
                .background(rightColumnBackground)
        }
        .frame(minWidth: 800, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .ignoresSafeArea()
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleFileDrop)
        .onAppear {
            if let first = sortedHistory.first {
                selectedURL = first.mediaURL
            }
        }
        .accessibilityIdentifier("macaboboo-welcome-screen")
    }

    // MARK: - 左侧操作区

    private var leftActionColumn: some View {
        VStack(spacing: 0) {
            Spacer()

            // 1. App 图标
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 106, height: 106)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 12, y: 5)

            Spacer().frame(height: 18)

            // 2. 软件名称与版本
            Text("MacAboboo")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.primary)

            Spacer().frame(height: 4)

            Text(String(format: lang.text("版本 %@", "Version %@"), appVersion))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer().frame(height: 34)

            // 3. 核心操作列表（Pixelmator Pro 风格）
            VStack(alignment: .leading, spacing: 18) {
                WelcomePrimaryActionRow(
                    systemImage: "plus.app",
                    title: lang.text("打开音视频文件", "Open Media File"),
                    subtitle: lang.text("从本地选择音视频开启智能断句与精听", "Select local audio or video to start learning"),
                    action: onOpen
                )

                WelcomePrimaryActionRow(
                    systemImage: "books.vertical",
                    title: lang.text("打开精听句库", "Open Sentence Library"),
                    subtitle: lang.text("复习重点难句、生词与跟读录音", "Review saved sentences, words, and recordings"),
                    action: onOpenLibrary
                )
            }
            .frame(maxWidth: 360, alignment: .leading)

            Spacer()
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
    }

    // MARK: - 右侧最近文件区

    private var rightRecentsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if sortedHistory.isEmpty {
                // 空历史记录占位
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary.opacity(0.6))

                    Text(lang.text("暂无最近打开文件", "No Recent Files"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(lang.text("打开或拖入音视频文件后将在此显示", "Opened files will appear here"))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(sortedHistory) { entry in
                            RecentMediaFileRow(
                                entry: entry,
                                isSelected: selectedURL?.standardizedFileURL == entry.mediaURL.standardizedFileURL,
                                isHovered: hoveredURL?.standardizedFileURL == entry.mediaURL.standardizedFileURL,
                                onSelect: {
                                    selectedURL = entry.mediaURL
                                },
                                onOpen: {
                                    onOpenHistoryItem(entry.mediaURL)
                                },
                                onRevealInFinder: {
                                    NSWorkspace.shared.activateFileViewerSelecting([entry.mediaURL])
                                },
                                onRemove: {
                                    historyStore.remove(entry.mediaURL)
                                    if selectedURL == entry.mediaURL {
                                        selectedURL = sortedHistory.first?.mediaURL
                                    }
                                }
                            )
                            .onHover { hovering in
                                hoveredURL = hovering ? entry.mediaURL : nil
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 24)
                    .padding(.bottom, 14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 拖拽处理

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let validURL = url else { return }
            DispatchQueue.main.async {
                onOpenHistoryItem(validURL)
            }
        }
        return true
    }
}

// MARK: - 左侧核心动作行组件

private struct WelcomePrimaryActionRow: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // 动作图标（Pixelmator 风格高亮蓝色大图标）
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 1.6)
                        .frame(width: 26, height: 26)

                    Image(systemName: iconGlyphName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var iconGlyphName: String {
        switch systemImage {
        case "plus.app", "plus.square":
            return "plus"
        case "books.vertical":
            return "books.vertical"
        case "folder":
            return "folder"
        default:
            return systemImage
        }
    }
}

// MARK: - 右侧最近打开媒体项行组件（Pixelmator Pro 胶囊选中风格）

private struct RecentMediaFileRow: View {
    let entry: PlaybackHistoryEntry
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onRevealInFinder: () -> Void
    let onRemove: () -> Void

    @ObservedObject private var lang = LanguageManager.shared

    private var isVideo: Bool {
        switch entry.mediaURL.pathExtension.lowercased() {
        case "mp4", "mov", "m4v", "mkv", "webm", "avi", "flv", "wmv", "ts":
            return true
        default:
            return false
        }
    }

    private var isUnderHome: Bool {
        let parentURL = entry.mediaURL.deletingLastPathComponent()
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        return parentURL.path.hasPrefix(homePath)
    }

    /// 路径面包屑格式化：如 Documents ▸ English
    private var pathBreadcrumb: String {
        let parentURL = entry.mediaURL.deletingLastPathComponent()
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path

        if parentURL.path == homePath {
            return ""
        } else if parentURL.path.hasPrefix(homePath) {
            let relativePath = String(parentURL.path.dropFirst(homePath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let components = relativePath.components(separatedBy: "/")
            if components.isEmpty || components.first?.isEmpty == true {
                return ""
            }
            return components.joined(separator: " ▸ ")
        } else {
            return parentURL.lastPathComponent
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // 缩略图标徽章（选中时白色底块，未选中时半透明底块）
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.white : Color.secondary.opacity(0.15))
                    .frame(width: 28, height: 28)

                Image(systemName: isVideo ? "video.fill" : "waveform")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }

            // 文件名与路径
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.filename)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 3) {
                    Image(systemName: isUnderHome ? "house" : "folder")
                        .font(.system(size: 9))

                    if !pathBreadcrumb.isEmpty {
                        Text("▸")
                            .font(.system(size: 8))
                        Text(pathBreadcrumb)
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor
                        : (isHovered ? Color.primary.opacity(0.06) : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onSelect()
            onOpen()
        }
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                onSelect()
            }
        )
        .contextMenu {
            Button(lang.text("在访达中显示", "Reveal in Finder")) {
                onRevealInFinder()
            }
            Divider()
            Button(lang.text("从最近打开中移除", "Remove from Recents"), role: .destructive) {
                onRemove()
            }
            Button(lang.text("清空最近打开记录", "Clear Recents"), role: .destructive) {
                PlaybackHistoryStore.shared.removeAll()
            }
        }
    }
}
