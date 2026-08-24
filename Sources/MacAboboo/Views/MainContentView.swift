import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 主视窗内容容器（波形图置顶、视频视窗自动扩展占满剩余空间、底部控制栏、可自由调整窗口大小）
public struct MainContentView: View {
    @StateObject private var engine = PlaybackEngine.shared
    @ObservedObject private var lang = LanguageManager.shared
    @ObservedObject private var playbackHistory = PlaybackHistoryStore.shared
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var isSidebarVisible: Bool = true
    @State private var isPlaylistVisible: Bool = false
    @State private var isWaveformsVisible: Bool = true
    @State private var isSubtitleEditVisible: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var playlistWidth: Double = UserDefaults.standard.double(forKey: "macaboboo_playlist_width") >= 240 ? UserDefaults.standard.double(forKey: "macaboboo_playlist_width") : 360
    
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
                
                // 2. 中间：音视频播放视窗（波形图/字幕区折叠时自适应最大化填满全部可用纵向空间）
                VideoPlayerView(engine: engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // 2.5 字幕编辑区（原文 + 译文双行输入，支持折叠/展开动画，焦点离开时自动保存）
                if isSubtitleEditVisible {
                    SubtitleEditView(engine: engine)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .bottom).combined(with: .opacity)
                        ))
                }
            }
            .frame(minWidth: 550, maxWidth: .infinity, minHeight: 450, maxHeight: .infinity)
            
            // 右侧断句侧边栏
            if isSidebarVisible {
                SegmentListView(engine: engine)
                    .frame(minWidth: 320, idealWidth: 320, maxWidth: 480, maxHeight: .infinity)
            }

        }
        // 允许用户自由拖拽缩放窗口大小，最小尺寸 800x550，无最大限制
        .frame(minWidth: 800, maxWidth: .infinity, minHeight: 550, maxHeight: .infinity)
        .background(globalKeyboardShortcuts)
        // 播放列表使用窗口内容区最上层浮层：覆盖断句列表，顶部紧贴工具栏。
        .overlay(alignment: .topTrailing) {
            playlistOverlay
        }
        .onAppear {
            engine.restoreLastOpenedMediaIfNeeded()
            engine.setHighFrequencyPresentationEnabled(isWaveformsVisible && scenePhase == .active)
        }
        .onChange(of: isWaveformsVisible) { _, visible in
            engine.setHighFrequencyPresentationEnabled(visible && scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            engine.setHighFrequencyPresentationEnabled(isWaveformsVisible && phase == .active)
        }
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
                // 1. 四种循环模式切换器 (Segmented Control)
                Picker("", selection: $engine.loopMode) {
                    ForEach(PlaybackLoopMode.allCases) { mode in
                        Image(systemName: mode.iconName)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help(lang.text("切换播放循环模式（普通 / 单句复读 / 句后停顿 / 全篇循环）", "Playback loop mode"))
                
                // 2. 播放倍速切换下拉菜单
                Menu {
                    ForEach([0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0] as [Float], id: \.self) { speed in
                        Button(action: { engine.playbackRate = speed }) {
                            if abs(engine.playbackRate - speed) < 0.01 {
                                Label(String(format: "%.2fx", speed), systemImage: "checkmark")
                            } else {
                                Text(String(format: "%.2fx", speed))
                            }
                        }
                    }
                    
                    Divider()
                    
                    Button(action: { engine.playbackRate = 1.0 }) {
                        Label(lang.text("恢复原速 (1.00x)", "Reset to 1.00x"), systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "gauge.with.needle")
                        Text(String(format: "%.2fx", engine.playbackRate))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                    .foregroundColor(abs(engine.playbackRate - 1.0) > 0.001 ? .blue : .primary)
                }
                .help(lang.text("调节播放语速", "Playback rate"))
                
                // 3. 显示/隐藏视图开关组（播放列表、波形图、字幕编辑区、断句列表）
                ControlGroup {
                    Toggle(isOn: $isPlaylistVisible) {
                        Image(systemName: "music.note.list")
                    }
                    .help(lang.text("显示或隐藏播放列表", "Show or hide the playlist"))
                    
                    Toggle(isOn: $isWaveformsVisible) {
                        Image(systemName: isWaveformsVisible ? "waveform.path.ecg" : "waveform.slash")
                    }
                    .help(isWaveformsVisible
                        ? lang.text("隐藏波形图工作区（⌥W）", "Hide waveforms (⌥W)")
                        : lang.text("显示波形图工作区（⌥W）", "Show waveforms (⌥W)"))
                    
                    Toggle(isOn: $isSubtitleEditVisible) {
                        Image(systemName: isSubtitleEditVisible ? "captions.bubble.fill" : "captions.bubble")
                    }
                    .help(isSubtitleEditVisible
                        ? lang.text("隐藏字幕双语编辑区（⌥S）", "Hide subtitle editor (⌥S)")
                        : lang.text("显示字幕双语编辑区（⌥S）", "Show subtitle editor (⌥S)"))
                    
                    Toggle(isOn: $isSidebarVisible) {
                        Image(systemName: "sidebar.right")
                    }
                    .help(lang.text("显示或隐藏断句列表", "Show or hide the sentence list"))
                }
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
    
    private var globalKeyboardShortcuts: some View {
        Group {
            Button(action: {
                withAnimation { isWaveformsVisible.toggle() }
            }) {
                EmptyView()
            }
            .keyboardShortcut("w", modifiers: [.option])
            
            Button(action: {
                withAnimation { isSubtitleEditVisible.toggle() }
            }) {
                EmptyView()
            }
            .keyboardShortcut("s", modifiers: [.option])
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var playlistOverlay: some View {
        if isPlaylistVisible {
            ZStack(alignment: .topTrailing) {
                // 点击播放列表之外的任意内容区域时自动收起，并阻止点击穿透到底层。
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        hidePlaylist()
                    }

                playlistPanel
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            ))
        }
    }

    private var playlistPanel: some View {
        PlaybackListView(
            engine: engine,
            historyStore: playbackHistory,
            playlistWidth: $playlistWidth,
            onResizeEnded: {
                UserDefaults.standard.set(playlistWidth, forKey: "macaboboo_playlist_width")
            }
        )
        .frame(width: CGFloat(playlistWidth))
        .frame(maxHeight: .infinity)
    }

    private func hidePlaylist() {
        withAnimation(.easeInOut(duration: 0.24)) {
            isPlaylistVisible = false
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

#Preview("MacAboboo 主界面") {
    MainContentView()
        .frame(width: 1200, height: 800)
}
