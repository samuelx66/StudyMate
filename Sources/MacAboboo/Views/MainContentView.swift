import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 主视窗内容容器（波形图置顶、视频视窗自动扩展占满剩余空间、底部控制栏、可自由调整窗口大小）
public struct MainContentView: View {
    /// 波形图、字幕编辑区和断句列表使用的过渡参数。
    private static let workspacePanelAnimation = Animation.easeInOut(duration: 0.22)
    /// 播放列表的滑入/滑出速度为原来的 50%：时长从 0.22 秒加倍到 0.44 秒。
    private static let playlistPanelAnimationDuration: Double = 0.44
    private static let playlistPanelAnimation = Animation.easeInOut(duration: playlistPanelAnimationDuration)

    private static func slideAndFadeTransition(from edge: Edge) -> AnyTransition {
        .asymmetric(
            insertion: .move(edge: edge).combined(with: .opacity),
            removal: .move(edge: edge).combined(with: .opacity)
        )
    }

    private var repeatOptions: [(label: String, count: Int)] {
        [(lang.text("1次", "1×"), 1), (lang.text("2次", "2×"), 2),
         (lang.text("3次", "3×"), 3), (lang.text("5次", "5×"), 5),
         (lang.text("10次", "10×"), 10), (lang.text("无限", "∞"), 0)]
    }

    private var shadowingPauseOptions: [(label: String, ratio: Double)] {
        [
            (lang.text("关闭", "Off"), 0),
            ("0.25×", 0.25),
            ("0.5×", 0.5),
            ("0.75×", 0.75),
            ("1×", 1.0),
            ("1.5×", 1.5),
            ("2×", 2.0)
        ]
    }

    @StateObject private var engine = PlaybackEngine.shared
    @ObservedObject private var lang = LanguageManager.shared
    @ObservedObject private var playbackHistory = PlaybackHistoryStore.shared
    @ObservedObject private var libraryManager = SentenceLibraryManager.shared
    @ObservedObject private var statusCenter = MainStatusCenter.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var isSidebarVisible: Bool = true
    @State private var isPlaylistVisible: Bool = false
    /// 播放列表的挂载状态与显示状态分开：收回动画完成后才卸载内容，避免
    /// SwiftUI 在动画中途直接销毁面板；同时也让隐藏状态不再保留列表的后台任务。
    @State private var isPlaylistMounted: Bool = false
    /// 右侧抽屉的展开比例。面板右边缘始终固定，比例变化只改变左边界的位置，
    /// 因而得到 IINA 同款的实体侧栏滑入/滑出效果，而不是淡入淡出。
    @State private var playlistRevealProgress: CGFloat = 0
    @State private var playlistAnimationToken = UUID()
    @State private var isWaveformsVisible: Bool = true
    @State private var isSubtitleEditVisible: Bool = false
    @State private var isDropTargeted: Bool = false
    @AppStorage("MacAboboo.ShowStatusBar") private var isStatusBarVisible: Bool = false
    @State private var playlistWidth: Double = UserDefaults.standard.double(forKey: "macaboboo_playlist_width") >= 240 ? UserDefaults.standard.double(forKey: "macaboboo_playlist_width") : 360
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
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
                    .transition(Self.slideAndFadeTransition(from: .top))
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
                    .transition(Self.slideAndFadeTransition(from: .trailing))
            }

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if shouldShowStatusBar {
                PlaybackStatusBar(
                    engine: engine,
                    libraryManager: libraryManager,
                    statusCenter: statusCenter
                )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // 允许用户自由拖拽缩放窗口大小，最小尺寸 800x550，无最大限制
        .frame(minWidth: 800, maxWidth: .infinity, minHeight: 550, maxHeight: .infinity)
        .background(WindowTextInputFocusDismissalBridge())
        .animation(.easeInOut(duration: 0.22), value: shouldShowStatusBar)
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
                Button {
                    openWindow(id: "sentence-library")
                } label: {
                    Label(lang.text("句库", "Sentence Library"), systemImage: "books.vertical")
                }
                .help(MacAbobooShortcutCatalog.help(
                    lang.text("打开句库", "Open sentence library"),
                    shortcut: .openSentenceLibrary
                ))
                .keyboardShortcut("l", modifiers: [.command])
            }

            ToolbarItem(placement: .navigation) {
                // 打开文件按钮
                Button(action: openFileDialog) {
                    Label(lang.localized(.openFile), systemImage: "folder.badge.plus")
                }
                .help(MacAbobooShortcutCatalog.help(
                    lang.text(
                        "打开音视频文件（MP3、WAV、M4A、FLAC、MKV、MP4、MOV、WebM、AVI）",
                        "Open audio or video (MP3, WAV, M4A, FLAC, MKV, MP4, MOV, WebM, AVI)"
                    ),
                    shortcut: .openMedia
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
                            .help(MacAbobooShortcutCatalog.help(
                                mode.localized(with: lang),
                                shortcut: mode.shortcutID
                            ))
                            .accessibilityLabel(mode.localized(with: lang))
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help(lang.text(
                    "播放模式：连续播放 / 单句重复 / 句后停顿 / 全篇循环（⌘1 / ⌘2 / ⌘3 / ⌘4）",
                    "Playback mode: Continuous Play / Repeat Sentence / Pause After Sentence / Loop Entire File (⌘1 / ⌘2 / ⌘3 / ⌘4)"
                ))
                
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
                .help(MacAbobooShortcutCatalog.help(
                    lang.text("调节播放语速", "Playback rate"),
                    shortcut: .playbackRateMenu
                ))
                .keyboardShortcut("r", modifiers: [.command, .shift])

                // 3. 单句复读次数下拉菜单
                Menu {
                    ForEach(repeatOptions, id: \.count) { option in
                        Button(action: {
                            engine.repeatCountLimit = option.count
                            engine.currentRepeatCount = 1
                        }) {
                            if engine.repeatCountLimit == option.count {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "repeat.circle")
                        Text(repeatCountToolbarLabel)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                    .foregroundColor(engine.repeatCountLimit == 1 ? .primary : .blue)
                }
                .help(MacAbobooShortcutCatalog.help(
                    lang.text("设置单句复读次数", "Set sentence repeat count"),
                    shortcut: .repeatCountMenu
                ))
                .keyboardShortcut("c", modifiers: [.command, .shift])

                // 4. 句末跟读停顿下拉菜单
                Menu {
                    ForEach(shadowingPauseOptions, id: \.ratio) { option in
                        Button(action: {
                            engine.shadowingPauseRatio = option.ratio
                        }) {
                            if abs(engine.shadowingPauseRatio - option.ratio) < 0.001 {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "pause.circle")
                        Text(shadowingPauseToolbarLabel)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                    .foregroundColor(engine.shadowingPauseRatio == 0 ? .primary : .green)
                }
                .help(MacAbobooShortcutCatalog.help(
                    lang.text("设置句末跟读停顿", "Set shadowing pause"),
                    shortcut: .shadowingPauseMenu
                ))
                .keyboardShortcut("p", modifiers: [.command, .shift])
                
                // 5. 工作区视图显示/隐藏开关（标准工具栏动作按钮，无持久背景色）
                Button(action: {
                    togglePlaylist()
                }) {
                    Image(systemName: "music.note.list")
                }
                .help(MacAbobooShortcutCatalog.help(
                    lang.text("显示或隐藏播放列表", "Show or hide playlist"),
                    shortcut: .togglePlaylist
                ))
                .keyboardShortcut("p", modifiers: [.option])
                
                Button(action: {
                    withAnimation(Self.workspacePanelAnimation) {
                        isWaveformsVisible.toggle()
                    }
                }) {
                    Image(systemName: "waveform.path.ecg")
                }
                .help(MacAbobooShortcutCatalog.help(
                    isWaveformsVisible
                        ? lang.text("隐藏波形图工作区", "Hide waveforms")
                        : lang.text("显示波形图工作区", "Show waveforms"),
                    shortcut: .toggleWaveforms
                ))
                .keyboardShortcut("w", modifiers: [.option])
                
                Button(action: {
                    withAnimation(Self.workspacePanelAnimation) {
                        isSubtitleEditVisible.toggle()
                    }
                }) {
                    Image(systemName: "captions.bubble")
                }
                .help(MacAbobooShortcutCatalog.help(
                    isSubtitleEditVisible
                        ? lang.text("隐藏字幕双语编辑区", "Hide subtitle editor")
                        : lang.text("显示字幕双语编辑区", "Show subtitle editor"),
                    shortcut: .toggleSubtitleEditor
                ))
                .keyboardShortcut("s", modifiers: [.option])
                
                Button(action: {
                    withAnimation(Self.workspacePanelAnimation) {
                        isSidebarVisible.toggle()
                    }
                }) {
                    Image(systemName: "sidebar.right")
                }
                .help(MacAbobooShortcutCatalog.help(
                    lang.text("显示或隐藏断句列表", "Show or hide sentence list"),
                    shortcut: .toggleSegmentList
                ))
                .keyboardShortcut("l", modifiers: [.option])
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
    }

    /// 有后台任务或错误时即使用户关闭了常驻状态栏，也临时显示状态栏，
    /// 避免进度和错误没有任何可见出口；任务结束/错误关闭后恢复用户的隐藏设置。
    private var shouldShowStatusBar: Bool {
        isStatusBarVisible
            || engine.isExtractingWaveform
            || engine.isAITranscribing
            || engine.isAutoTranslating
            || libraryManager.isWorking
            || engine.statusErrorMessage != nil
            || libraryManager.lastErrorMessage != nil
            || statusCenter.progress != nil
            || statusCenter.errorMessage != nil
    }
    
    @ViewBuilder
    private var playlistOverlay: some View {
        if isPlaylistMounted {
            ZStack(alignment: .topTrailing) {
                // 点击播放列表之外的任意内容区域时自动收起，并阻止点击穿透到底层。
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        hidePlaylist()
                    }

                playlistPanel
                    // 固定右边缘、动画左边界：这是 IINA 播放列表的抽屉式展开方式。
                    // 外层窄框负责裁剪，内部面板仍保持完整宽度，因此材质、阴影和内容
                    // 都不会发生缩放或淡入淡出。
                    .frame(
                        width: max(1, CGFloat(playlistWidth) * playlistRevealProgress),
                        alignment: .trailing
                    )
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .zIndex(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .clipped()
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
        guard isPlaylistMounted else { return }

        isPlaylistVisible = false
        let token = UUID()
        playlistAnimationToken = token
        withAnimation(Self.playlistPanelAnimation) {
            playlistRevealProgress = 0
        }

        // 等完整收回后再卸载列表。这样列表内容向右离开视口的过程不会被条件渲染
        // 提前截断，同时隐藏后会释放列表的滚动与文件存在性检查任务。
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.playlistPanelAnimationDuration) {
            guard token == playlistAnimationToken,
                  !isPlaylistVisible,
                  playlistRevealProgress < 0.01 else { return }
            isPlaylistMounted = false
        }
    }

    private func togglePlaylist() {
        if isPlaylistVisible {
            hidePlaylist()
            return
        }

        let token = UUID()
        playlistAnimationToken = token
        isPlaylistVisible = true
        isPlaylistMounted = true
        // 先以零宽度挂载在右边缘，下一帧再启动动画；否则 SwiftUI 会在插入时
        // 直接以最终宽度布局，无法得到“从右向左拉开”的连续左边界。
        playlistRevealProgress = 0
        DispatchQueue.main.async {
            guard token == playlistAnimationToken, isPlaylistVisible else { return }
            withAnimation(Self.playlistPanelAnimation) {
                playlistRevealProgress = 1
            }
        }
    }

    private var repeatCountToolbarLabel: String {
        engine.repeatCountLimit == 0 ? "∞" : "\(engine.repeatCountLimit)×"
    }

    private var shadowingPauseToolbarLabel: String {
        engine.shadowingPauseRatio == 0 ? lang.text("关", "Off") : String(format: "%.2g×", engine.shadowingPauseRatio)
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

/// 主窗口底部的紧凑播放状态栏；它位于 HSplitView 之后，因此断句列表始终在其上方。
/// 播放信息靠左，所有进度与错误提示统一靠右显示。
private struct PlaybackStatusBar: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var libraryManager: SentenceLibraryManager
    @ObservedObject var statusCenter: MainStatusCenter
    @ObservedObject private var lang = LanguageManager.shared

    private var currentSegmentText: String {
        let current = engine.activeSegmentIndex.map { $0 + 1 } ?? 0
        return "\(current)/\(engine.segments.count)"
    }

    private var repeatCountText: String {
        let total = engine.repeatCountLimit == 0 ? "∞" : "\(engine.repeatCountLimit)"
        return "\(engine.currentRepeatCount)/\(total)"
    }

    private var shadowingText: String {
        if engine.isShadowingPaused {
            return "\(lang.text("正在跟读", "Shadowing")) \(String(format: "%.1fs", max(0, engine.shadowingCountdownRemaining)))"
        }

        return "\(lang.text("跟读停顿", "Shadowing pause")) \(String(format: "%.2g×", engine.shadowingPauseRatio))"
    }

    private var currentProgress: MainStatusProgress? {
        if engine.isAITranscribing {
            return MainStatusProgress(
                fraction: max(0.05, engine.aiTranscriptionProgress),
                phase: engine.aiTranscriptionStatusText
            )
        }
        if engine.isAutoTranslating {
            return MainStatusProgress(
                fraction: max(0.02, engine.autoTranslationProgress),
                phase: engine.autoTranslationStatusText
            )
        }
        if engine.isExtractingWaveform {
            return MainStatusProgress(
                fraction: engine.waveformExtractionProgress,
                phase: lang.localized(.extractingWaveform)
            )
        }
        if let progress = statusCenter.progress {
            return progress
        }
        if let progress = libraryManager.operationProgress {
            return MainStatusProgress(
                fraction: progress.fraction,
                phase: progress.phase,
                currentItem: progress.currentItem
            )
        }
        return nil
    }

    private var canCancelCurrentProgress: Bool {
        engine.isAITranscribing || engine.isAutoTranslating
    }

    private var currentErrorMessage: String? {
        statusCenter.errorMessage ?? engine.statusErrorMessage ?? libraryManager.lastErrorMessage
    }

    var body: some View {
        HStack(spacing: 10) {
            Label(currentSegmentText, systemImage: "number")

            Divider()
                .frame(height: 14)
            Label(engine.loopMode.localized(with: lang), systemImage: engine.loopMode.iconName)
                .accessibilityLabel(engine.loopMode.localized(with: lang))

            if abs(engine.playbackRate - 1.0) > 0.001 {
                Divider()
                    .frame(height: 14)
                Label(String(format: "%.2fx", engine.playbackRate), systemImage: "gauge.with.needle")
                    .foregroundColor(.blue)
            }

            if engine.repeatCountLimit != 1 {
                Divider()
                    .frame(height: 14)
                Label(repeatCountText, systemImage: "repeat.circle")
            }

            if engine.shadowingPauseRatio > 0 {
                Divider()
                    .frame(height: 14)
                Label(shadowingText, systemImage: engine.isShadowingPaused ? "mic.fill" : "pause.circle")
                    .foregroundColor(engine.isShadowingPaused ? .green : .secondary)
            }

            Spacer(minLength: 8)

            if let progress = currentProgress {
                StatusBarProgressView(
                    progress: progress,
                    canCancel: canCancelCurrentProgress,
                    onCancel: cancelCurrentProgress
                )
            }

            if let currentErrorMessage {
                if currentProgress != nil {
                    Divider()
                        .frame(height: 14)
                }
                StatusBarErrorView(
                    message: currentErrorMessage,
                    onDismiss: dismissCurrentError
                )
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(minHeight: 26)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color(nsColor: .separatorColor)),
            alignment: .top
        )
    }

    private func cancelCurrentProgress() {
        if engine.isAITranscribing {
            engine.cancelSegmentation()
        } else if engine.isAutoTranslating {
            engine.cancelAutomaticTranslation()
        }
    }

    private func dismissCurrentError() {
        engine.dismissStatusError()
        libraryManager.dismissErrorMessage()
        statusCenter.clearError()
    }
}

private struct StatusBarProgressView: View {
    @ObservedObject private var lang = LanguageManager.shared
    let progress: MainStatusProgress
    let canCancel: Bool
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(width: 92)

            Text(progress.phase.isEmpty ? lang.text("处理中", "Working") : progress.phase)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190, alignment: .leading)

            if !progress.currentItem.isEmpty {
                Text(progress.currentItem)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 115, alignment: .leading)
            }

            Text("\(Int(progress.fraction * 100))%")
                .monospacedDigit()
                .foregroundColor(.secondary)

            if canCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(lang.text("取消当前任务", "Cancel current task"))
            }
        }
        .frame(maxWidth: 470, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(progress.phase)
    }
}

private struct StatusBarErrorView: View {
    let message: String
    let onDismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: isHovering ? .top : .center, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)

            Text(message)
                .lineLimit(isHovering ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360, alignment: .leading)
                .layoutPriority(1)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭提示")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, isHovering ? 4 : 0)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { isHovering = $0 }
        .help(message)
    }
}
