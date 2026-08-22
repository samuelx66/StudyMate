import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 主视窗内容容器（波形图置顶、视频视窗自动扩展占满剩余空间、底部控制栏、可自由调整窗口大小）
public struct MainContentView: View {
    @StateObject private var engine = PlaybackEngine.shared
    @ObservedObject private var lang = LanguageManager.shared
    
    @State private var isSidebarVisible: Bool = true
    @State private var isWaveformsVisible: Bool = true
    @State private var isSubtitleEditVisible: Bool = true
    @State private var isDropTargeted: Bool = false
    
    public init() {}
    
    public var body: some View {
        HSplitView {
            // 左侧工作主区（顶部双波形图 + 中间自适应音视频视窗 + 底部控制栏）
            VStack(spacing: 0) {
                // 1. 顶部：主次双波形图工作区（支持折叠/展开动画）
                if isWaveformsVisible {
                    VStack(spacing: 4) {
                        PrimaryWaveformView(engine: engine)
                        SecondaryWaveformView(engine: engine)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
                }
                
                // 次波形图与视频播放画面之间的折叠/展开联动条
                WaveformCollapseToggleBar(isWaveformsVisible: $isWaveformsVisible)
                
                // 2. 中间：音视频播放视窗（波形图/字幕区折叠时自适应最大化填满全部可用纵向空间）
                VideoPlayerView(engine: engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // 视频画面播放区与字幕编辑区之间的折叠/展开联动条
                SubtitleCollapseToggleBar(isSubtitleEditVisible: $isSubtitleEditVisible)
                
                // 2.5 字幕编辑区（原文 + 译文双行输入，支持折叠/展开动画，焦点离开时自动保存）
                if isSubtitleEditVisible {
                    SubtitleEditView(engine: engine)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .bottom).combined(with: .opacity)
                        ))
                }
                
                Divider()
                
                // 3. 底部：固定播放与精听控制栏
                PlaybackControlView(engine: engine)
            }
            .frame(minWidth: 550, maxWidth: .infinity, minHeight: 450, maxHeight: .infinity)
            
            // 右侧断句侧边栏
            if isSidebarVisible {
                SegmentListView(engine: engine)
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 480, maxHeight: .infinity)
            }
        }
        // 允许用户自由拖拽缩放窗口大小，最小尺寸 800x550，无最大限制
        .frame(minWidth: 800, maxWidth: .infinity, minHeight: 550, maxHeight: .infinity)
        // 顶部工具栏 (紧凑型设计)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // 打开文件按钮
                Button(action: openFileDialog) {
                    Label(lang.localized(.openFile), systemImage: "folder.badge.plus")
                }
                .help(lang.text(
                    "打开音视频文件（MP3、WAV、M4A、FLAC、MKV、MP4、MOV、WebM、AVI）",
                    "Open audio or video (MP3, WAV, M4A, FLAC, MKV, MP4, MOV, WebM, AVI)"
                ))
            }
            
            if let media = engine.currentMedia {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 5) {
                        Image(systemName: media.isVideo ? "video.fill" : "music.note")
                            .font(.caption)
                            .foregroundColor(.blue)
                        Text(media.title)
                            .font(.caption.bold())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 220)
                        Text("(\(media.formattedDuration))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            ToolbarItemGroup(placement: .primaryAction) {
                // 语言切换选择器
                Picker(selection: $lang.currentLanguage, label: Image(systemName: "globe")) {
                    ForEach(AppLanguage.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 95)
                
                // 波形图折叠/展开开关
                Button(action: {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        isWaveformsVisible.toggle()
                    }
                }) {
                    Image(systemName: isWaveformsVisible ? "rectangle.split.1x2" : "rectangle.expand.vertical")
                }
                .help(isWaveformsVisible
                    ? lang.text("折叠双波形图，最大化播放画面（⌥W）", "Hide waveforms and maximize video (⌥W)")
                    : lang.text("展开双波形图（⌥W）", "Show waveforms (⌥W)"))
                .keyboardShortcut("w", modifiers: [.option])
                
                // 侧边栏折叠开关
                Button(action: {
                    withAnimation {
                        isSidebarVisible.toggle()
                    }
                }) {
                    Image(systemName: "sidebar.right")
                }
                .help(lang.text("显示或隐藏断句列表", "Show or hide the sentence list"))
            }
        }
        // 支持直接拖拽音视频文件到窗口
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let validURL = url {
                    DispatchQueue.main.async {
                        engine.loadMedia(from: validURL)
                    }
                }
            }
            return true
        }
        .overlay(
            Group {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.blue, lineWidth: 3)
                        .background(Color.blue.opacity(0.1))
                }
            }
        )
        .alert(lang.text("提示", "Notice"), isPresented: Binding(
            get: { engine.lastErrorMessage != nil },
            set: { if !$0 { engine.lastErrorMessage = nil } }
        )) {
            Button(lang.text("好", "OK"), role: .cancel) {}
        } message: {
            Text(engine.lastErrorMessage ?? "")
        }
    }
    
    /// 弹出 macOS 原生打开文件面板
    private func openFileDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
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
        
        if panel.runModal() == .OK, let url = panel.url {
            engine.loadMedia(from: url)
        }
    }
}

/// 次波形图与视频播放画面之间的折叠/展开联动条（左侧极简图标，鼠标悬停时平滑展开完整内容与快捷键）
public struct WaveformCollapseToggleBar: View {
    @Binding var isWaveformsVisible: Bool
    @ObservedObject var lang = LanguageManager.shared
    
    @State private var isHovered: Bool = false
    
    public init(isWaveformsVisible: Binding<Bool>) {
        self._isWaveformsVisible = isWaveformsVisible
    }
    
    public var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                isWaveformsVisible.toggle()
            }
        }) {
            ZStack(alignment: .leading) {
                // 背景细分割线
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.35))
                    .frame(height: 1)
                
                // 左侧极简交互胶囊按钮（默认仅显示图标，悬停时丝滑展开文字与快捷键）
                HStack(spacing: 5) {
                    Image(systemName: isWaveformsVisible ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                    
                    Image(systemName: isWaveformsVisible ? "rectangle.expand.vertical" : "waveform.path.ecg")
                        .font(.system(size: 9))
                    
                    if isHovered {
                        Text(isWaveformsVisible
                            ? lang.text("收起波形 • 最大化画面", "Hide waveforms • Maximize video")
                            : lang.text("展开双波形图", "Show waveforms"))
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .fixedSize()
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                        
                        Text("⌥W")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(2)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(
                    Capsule()
                        .fill(isHovered ? Color.blue.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
                        .shadow(color: Color.black.opacity(isHovered ? 0.12 : 0.04), radius: 2, y: 1)
                )
                .overlay(
                    Capsule()
                        .stroke(isHovered ? Color.blue.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.8)
                )
                .foregroundColor(isHovered ? .blue : .secondary)
                .padding(.leading, 12)
                .scaleEffect(isHovered ? 1.02 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHovered)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .help(isWaveformsVisible
            ? lang.text("点击折叠主次波形图，最大化视频画面（⌥W）", "Hide both waveforms and maximize video (⌥W)")
            : lang.text("点击恢复主次波形图（⌥W）", "Restore both waveforms (⌥W)"))
    }
}

/// 视频画面播放区与字幕编辑区之间的折叠/展开联动条（左侧极简图标，鼠标悬停时平滑展开完整内容与快捷键 ⌥S）
public struct SubtitleCollapseToggleBar: View {
    @Binding var isSubtitleEditVisible: Bool
    @ObservedObject var lang = LanguageManager.shared
    
    @State private var isHovered: Bool = false
    
    public init(isSubtitleEditVisible: Binding<Bool>) {
        self._isSubtitleEditVisible = isSubtitleEditVisible
    }
    
    public var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                isSubtitleEditVisible.toggle()
            }
        }) {
            ZStack(alignment: .leading) {
                // 背景细分割线
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.35))
                    .frame(height: 1)
                
                // 左侧极简交互胶囊按钮（默认仅显示图标，悬停时丝滑展开文字提示与快捷键）
                HStack(spacing: 5) {
                    Image(systemName: isSubtitleEditVisible ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                    
                    Image(systemName: isSubtitleEditVisible ? "text.bubble" : "character.cursor.ibeam")
                        .font(.system(size: 9))
                    
                    if isHovered {
                        Text(isSubtitleEditVisible
                            ? lang.text("收起字幕编辑 • 扩展画面", "Hide subtitle editor • Expand video")
                            : lang.text("展开字幕编辑区", "Show subtitle editor"))
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .fixedSize()
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                        
                        Text("⌥S")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(2)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(
                    Capsule()
                        .fill(isHovered ? Color.blue.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
                        .shadow(color: Color.black.opacity(isHovered ? 0.12 : 0.04), radius: 2, y: 1)
                )
                .overlay(
                    Capsule()
                        .stroke(isHovered ? Color.blue.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.8)
                )
                .foregroundColor(isHovered ? .blue : .secondary)
                .padding(.leading, 12)
                .scaleEffect(isHovered ? 1.02 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHovered)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: [.option])
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .help(isSubtitleEditVisible
            ? lang.text("点击折叠字幕编辑区，扩展视频画面（⌥S）", "Hide subtitle editor and expand video (⌥S)")
            : lang.text("点击展开字幕编辑区（⌥S）", "Show subtitle editor (⌥S)"))
    }
}

#Preview("MacAboboo 主界面") {
    MainContentView()
        .frame(width: 1200, height: 800)
}
