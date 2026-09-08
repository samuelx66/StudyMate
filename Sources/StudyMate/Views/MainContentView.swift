import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    public static let studyMateCloseCurrentMedia = Notification.Name("StudyMate.CloseCurrentMedia")
    public static let studyMateTogglePlaylist = Notification.Name("StudyMate.TogglePlaylist")
}

/// 主视窗内容容器（波形图置顶、视频视窗自动扩展占满剩余空间、底部控制栏、可自由调整窗口大小）
public struct MainContentView: View {
    /// 播放列表侧拉门平滑物理阻尼动画参数（模拟真实侧拉抽屉滑入门效）
    private static let playlistPanelAnimationDuration: Double = 0.32
    private static let playlistPanelAnimation = Animation.spring(response: 0.34, dampingFraction: 0.85)
    /// macOS 26 原生工作区面板折叠与展开物理弹簧动画参数（平滑阻尼，避免机械式生硬跳变）
    static let panelSpringAnimation = Animation.spring(response: 0.32, dampingFraction: 0.86)

    fileprivate static func slideAndFadeTransition(from edge: Edge) -> AnyTransition {
        .asymmetric(
            insertion: .move(edge: edge).combined(with: .opacity),
            removal: .move(edge: edge).combined(with: .opacity)
        )
    }

    @StateObject private var engine = PlaybackEngine.shared
    @ObservedObject private var waveformState = PlaybackEngine.shared.waveformState
    @ObservedObject private var lang = LanguageManager.shared
    @ObservedObject private var playbackHistory = PlaybackHistoryStore.shared
    @ObservedObject private var libraryStatus = SentenceLibraryStatusCenter.shared
    @ObservedObject private var statusCenter = MainStatusCenter.shared
    @ObservedObject private var videoSubtitleSettings = VideoSubtitleSettings.shared
    @ObservedObject private var dictionaryCoordinator = DictionaryInteractionCoordinator.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    
    // 首次进入媒体工作区显示断句列表、波形图和字幕编辑区；之后由
    // AppStorage 恢复用户上一次的布局选择。
    @AppStorage("StudyMate.ShowSentenceList") private var isSidebarVisible: Bool = true
    @AppStorage("StudyMate.ShowPlaylist") private var isPlaylistVisible: Bool = false
    /// 播放列表的挂载状态与显示状态分开：收回动画完成后才卸载内容，避免
    /// SwiftUI 在动画中途直接销毁面板；同时也让隐藏状态不再保留列表的后台任务。
    @State private var isPlaylistMounted: Bool = false
    /// 右侧抽屉的展开比例。面板右边缘始终固定，比例变化只改变左边界的位置，
    /// 因而得到 IINA 同款的实体侧栏滑入/滑出效果，而不是淡入淡出。
    @State private var playlistRevealProgress: CGFloat = 0
    @State private var playlistAnimationToken = UUID()
    @AppStorage("StudyMate.ShowWaveforms") private var isWaveformsVisible: Bool = true
    @AppStorage("StudyMate.ShowSecondaryWaveform") private var isSecondaryWaveformVisible: Bool = true
    @AppStorage("StudyMate.ShowSubtitleEditor") private var isSubtitleEditVisible: Bool = true
    @State private var isVideoSubtitleFontSettingsPresented: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var isClosingCurrentMedia: Bool = false
    @State private var isProjectRecoveryDialogPresented: Bool = false
    @AppStorage("StudyMate.ShowStatusBar") private var isStatusBarVisible: Bool = false
    @AppStorage("StudyMate.PlaybackInterfaceMode") private var playbackInterfaceMode: PlaybackInterfaceMode = .video
    @State private var savedLoopModeBeforeFillInBlank: PlaybackLoopMode? = nil
    @State private var playlistWidth: Double = UserDefaults.standard.double(forKey: "studymate_playlist_width") >= 240 ? UserDefaults.standard.double(forKey: "studymate_playlist_width") : 360
    private let onWindowDidAppear: () -> Void
    
    public init(onWindowDidAppear: @escaping () -> Void = {}) {
        self.onWindowDidAppear = onWindowDidAppear
    }

    public var body: some View {
        workspaceContent
            // 媒体工作区允许自由调整窗口大小，最小尺寸 800×550。
            .frame(minWidth: 800, maxWidth: .infinity, minHeight: 550, maxHeight: .infinity)
            // 全屏模式下忽略顶部安全区，工具栏以悬浮浮层形式平滑滑入滑出，避免画面上下跳动
            .ignoresSafeArea(.container, edges: engine.isFullScreen ? .top : [])
        .background(WindowTextInputFocusDismissalBridge())
        .background {
            Button("") {
                withAnimation(Self.panelSpringAnimation) {
                    isSecondaryWaveformVisible.toggle()
                }
            }
            .keyboardShortcut("w", modifiers: [.option, .shift])
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .animation(Self.panelSpringAnimation, value: shouldShowStatusBar)
        .animation(Self.panelSpringAnimation, value: isWaveformsVisible)
        .animation(Self.panelSpringAnimation, value: isSecondaryWaveformVisible)
        .animation(Self.panelSpringAnimation, value: isSubtitleEditVisible)
        .animation(Self.panelSpringAnimation, value: isSidebarVisible)
        // 播放列表使用窗口内容区最上层浮层：覆盖断句列表，顶部紧贴工具栏。
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleMediaDrop)
        .overlay(dropTargetOverlay)
        // 字幕选词操作条与结果面板位于媒体窗口最上层，但不改变句子列表的
        // 点击播放语义；只有真正存在选区时才接管命中测试。
        .overlay { DictionaryLookupOverlay(engine: engine) }
        // 必须在其它覆盖层之后挂载，保证播放列表及其原生控件始终位于
        // 断句列表等工作区控件的命中层之上。
        .overlay(alignment: .topTrailing) { playlistOverlay }
        .onAppear {
            // SwiftUI may reuse the scene's view storage when the main window
            // is reopened.  Reset the one-shot close guard here; otherwise a
            // second “文件 > 关闭” is ignored after the first close cycle.
            isClosingCurrentMedia = false
            engine.setHighFrequencyPresentationEnabled(isWaveformsVisible && scenePhase == .active)
            if isPlaylistVisible {
                // 持久化的布局在窗口恢复时直接进入最终状态，避免每次启动都播放一次抽屉动画。
                isPlaylistMounted = true
                playlistRevealProgress = 1
            } else {
                isPlaylistMounted = false
                playlistRevealProgress = 0
            }
            // 主窗口内容已经开始渲染后，才销毁欢迎页场景，避免两个窗口同时
            // 长时间存在，也避免欢迎页提前关闭导致主窗口首帧无宿主窗口。
            onWindowDidAppear()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .studyMateCloseCurrentMedia),
            perform: handleCloseCurrentMediaRequest
        )
        .onReceive(
            NotificationCenter.default.publisher(for: .studyMateOpenDictionaryWindow)
        ) { _ in
            openWindow(id: "dictionary")
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .studyMateTogglePlaylist)
        ) { _ in
            togglePlaylist()
        }
        .onChange(of: isWaveformsVisible) { _, visible in
            engine.setHighFrequencyPresentationEnabled(visible && scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            engine.setHighFrequencyPresentationEnabled(isWaveformsVisible && phase == .active)
        }
        .onChange(of: playbackInterfaceMode) { _, newMode in
            handlePlaybackInterfaceModeChange(to: newMode)
        }
        .onAppear {
            if playbackInterfaceMode == .fillInBlank {
                handlePlaybackInterfaceModeChange(to: .fillInBlank)
            }
        }
        // 顶部工具栏 (首帧静态直出，彻底消除异步挂载滞后与抖动)
        .tint(StudyMateMediaStyle.accent)
        .toolbar { windowToolbar }
        .confirmationDialog(
            lang.text("工程文件处理", "Project Recovery"),
            isPresented: $isProjectRecoveryDialogPresented,
            titleVisibility: .visible
        ) {
            Button(lang.text("继续使用原工程", "Use Existing Project")) {
                engine.continueUsingExistingProject()
            }
            Button(lang.text("重新断句（智能）", "Re-segment (Intelligent)"), role: .destructive) {
                engine.performSegmentation(mode: .intelligent)
            }
            Button(lang.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(lang.text(
                "工程对应的媒体文件信息已经变化。继续使用原工程会保留现有断句、原文和译文；重新断句会覆盖当前时间轴，请确认你的选择。",
                "The media information no longer matches the project. Using the existing project keeps its sentences and subtitles; re-segmenting replaces the current timeline. Please confirm your choice."
            ))
        }
    }

    /// 有后台任务或错误时即使用户关闭了常驻状态栏，也临时显示状态栏，
    /// 避免进度和错误没有任何可见出口；任务结束/错误关闭后恢复用户的隐藏设置。

    private var shouldShowStatusBar: Bool {
        isStatusBarVisible
            || waveformState.isExtracting
            || engine.isAITranscribing
            || engine.isAutoTranslating
            || libraryStatus.isWorking
            || engine.statusErrorMessage != nil
            || libraryStatus.errorMessage != nil
            || statusCenter.progress != nil
            || statusCenter.errorMessage != nil
            || statusCenter.successMessage != nil
            || !statusCenter.issues.isEmpty
    }

    private var windowToolbar: MainWindowToolbar {
        MainWindowToolbar(
            engine: engine,
            lang: lang,
            videoSubtitleSettings: videoSubtitleSettings,
            dictionaryCoordinator: dictionaryCoordinator,
            isWaveformsVisible: $isWaveformsVisible,
            isSubtitleEditVisible: $isSubtitleEditVisible,
            isVideoSubtitleFontSettingsPresented: $isVideoSubtitleFontSettingsPresented,
            isSidebarVisible: $isSidebarVisible,
            playbackInterfaceMode: $playbackInterfaceMode,
            onOpenLibrary: { openWindow(id: "sentence-library") },
            onOpenVocabulary: { openWindow(id: "vocabulary") },
            onOpenDictionary: {
                _ = dictionaryCoordinator.captureCurrentSelectionForDictionary()
                if let query = dictionaryCoordinator.selectedText, !query.isEmpty {
                    dictionaryCoordinator.bindPlaybackEngine(engine)
                    dictionaryCoordinator.pausePlaybackForVideoSubtitleSelection()
                }
                dictionaryCoordinator.openDictionaryWindow()
            },
            onOpenMedia: openFileDialog,
            onTogglePlaylist: togglePlaylist
        )
    }

    @ViewBuilder
    private var dropTargetOverlay: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 8)
                .stroke(StudyMateMediaStyle.accent, lineWidth: 3)
                .background(StudyMateMediaStyle.accent.opacity(0.1))
        }
    }

    private var workspaceContent: some View {
        VStack(spacing: 0) {
            switch playbackInterfaceMode {
            case .video:
                VideoModeWorkspaceView(
                    engine: engine,
                    isWaveformsVisible: isWaveformsVisible,
                    isSecondaryWaveformVisible: isSecondaryWaveformVisible,
                    isSubtitleEditVisible: isSubtitleEditVisible,
                    isSidebarVisible: isSidebarVisible,
                    isPlaylistMounted: isPlaylistMounted
                )
            case .list:
                listModeWorkspace
            case .fullText:
                fullTextModeWorkspace
            case .sentence:
                sentenceModeWorkspace
            case .fillInBlank:
                fillInBlankModeWorkspace
            }

            if shouldShowStatusBar {
                PlaybackStatusBar(
                    engine: engine,
                    libraryManager: SentenceLibraryManager.shared,
                    waveformState: waveformState,
                    statusCenter: statusCenter,
                    playbackInterfaceMode: playbackInterfaceMode,
                    onResolveProjectRecovery: { isProjectRecoveryDialogPresented = true }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .transaction { transaction in
            if engine.isWindowResizing {
                transaction.animation = nil
            }
        }
    }

    // 视频模式工作区已抽离为独立的 VideoModeWorkspaceView，将拖拽尺寸变化局限在视口内，防止根视图重绘。
}

/// 视频模式工作区视图。将侧边栏宽度 (@State) 与拖拽事件彻底隔离在此组件内，
/// 拖动分割线时仅局部触发视频与列表 HStack 尺寸重绘，
/// 避免驱动整个 MainContentView（顶部工具栏、底部状态栏、全局抽屉等）全量重算。
private struct VideoModeWorkspaceView: View {
    @ObservedObject var engine: PlaybackEngine
    let isWaveformsVisible: Bool
    let isSecondaryWaveformVisible: Bool
    let isSubtitleEditVisible: Bool
    let isSidebarVisible: Bool
    let isPlaylistMounted: Bool

    @State private var sidebarWidth: Double = {
        let saved = UserDefaults.standard.double(forKey: "studymate_sentence_list_width")
        return (saved >= 260 && saved <= 650) ? saved : 320
    }()

    var body: some View {
        HStack(spacing: 0) {
            // 左侧工作主区（顶部双波形图 + 中间自适应音视频视窗 + 底部字幕编辑栏）
            PlaybackWorkspaceContainer(
                engine: engine,
                isWaveformsVisible: isWaveformsVisible,
                isSecondaryWaveformVisible: isSecondaryWaveformVisible,
                isSubtitleEditVisible: isSubtitleEditVisible
            ) {
                VideoPlayerView(engine: engine)
            }
            .frame(minWidth: 420, maxWidth: .infinity, minHeight: 450, maxHeight: .infinity)

            if isSidebarVisible {
                HStack(spacing: 0) {
                    SegmentListResizeBorderRepresentable(
                        sidebarWidth: $sidebarWidth,
                        onDragBegan: {
                            engine.setWindowResizing(true)
                        },
                        onResizeEnded: {
                            engine.setWindowResizing(false)
                            UserDefaults.standard.set(sidebarWidth, forKey: "studymate_sentence_list_width")
                        }
                    )
                    .frame(width: 6)
                    .overlay {
                        Rectangle()
                            .fill(StudyMateMediaStyle.separator.opacity(0.65))
                            .frame(width: 1)
                    }

                    SegmentListView(
                        engine: engine,
                        suppressToolTips: isPlaylistMounted
                    )
                    .frame(width: max(260, sidebarWidth))
                    // 抽屉在屏幕上时不允许下层列表继续响应；关闭抽屉后立即恢复。
                    .allowsHitTesting(!isPlaylistMounted)
                }
                .frame(maxHeight: .infinity)
                .clipped()
                .transition(MainContentView.slideAndFadeTransition(from: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 原生 AppKit 高性能边框拉伸组件（非阻塞异步事件，拖拽期间抑制动画并联动低开销布局）
private struct SegmentListResizeBorderRepresentable: NSViewRepresentable {
    @Binding var sidebarWidth: Double
    let onDragBegan: () -> Void
    let onResizeEnded: () -> Void

    func makeNSView(context: Context) -> SegmentListResizeBorderView {
        let view = SegmentListResizeBorderView()
        updateNSViewProps(view)
        return view
    }

    func updateNSView(_ nsView: SegmentListResizeBorderView, context: Context) {
        updateNSViewProps(nsView)
    }

    private func updateNSViewProps(_ view: SegmentListResizeBorderView) {
        view.onDragBegan = onDragBegan
        view.onDragDelta = { deltaX in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                let newWidth = min(max(260, sidebarWidth - Double(deltaX)), 650)
                if newWidth != sidebarWidth {
                    sidebarWidth = newWidth
                }
            }
        }
        view.onDragEnded = onResizeEnded
    }
}

private final class SegmentListResizeBorderView: NSView {
    var onDragBegan: (() -> Void)?
    var onDragDelta: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private var lastMouseX: CGFloat = 0
    private var isDragging = false

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
        isDragging = true
        lastMouseX = event.locationInWindow.x
        NSCursor.resizeLeftRight.push()
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let currentX = event.locationInWindow.x
        let deltaX = currentX - lastMouseX
        guard abs(deltaX) >= 1.0 else { return }
        lastMouseX = currentX
        onDragDelta?(deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        NSCursor.pop()
        onDragEnded?()
    }
}

extension MainContentView {

    private var listModeWorkspace: some View {
        PlaybackWorkspaceContainer(
            engine: engine,
            isWaveformsVisible: isWaveformsVisible,
            isSecondaryWaveformVisible: isSecondaryWaveformVisible,
            isSubtitleEditVisible: isSubtitleEditVisible
        ) {
            PlaybackListModeTableView(
                engine: engine,
                videoSubtitleSettings: videoSubtitleSettings,
                lang: lang
            )
        }
    }

    private var fullTextModeWorkspace: some View {
        PlaybackWorkspaceContainer(
            engine: engine,
            isWaveformsVisible: isWaveformsVisible,
            isSecondaryWaveformVisible: isSecondaryWaveformVisible,
            isSubtitleEditVisible: isSubtitleEditVisible
        ) {
            PlaybackFullTextModeView(
                engine: engine,
                videoSubtitleSettings: videoSubtitleSettings,
                lang: lang
            )
        }
    }

    private var sentenceModeWorkspace: some View {
        PlaybackWorkspaceContainer(
            engine: engine,
            isWaveformsVisible: isWaveformsVisible,
            isSecondaryWaveformVisible: isSecondaryWaveformVisible,
            isSubtitleEditVisible: isSubtitleEditVisible
        ) {
            PlaybackSentenceModeView(
                engine: engine,
                videoSubtitleSettings: videoSubtitleSettings,
                lang: lang
            )
        }
    }

    private var fillInBlankModeWorkspace: some View {
        PlaybackWorkspaceContainer(
            engine: engine,
            isWaveformsVisible: isWaveformsVisible,
            isSecondaryWaveformVisible: isSecondaryWaveformVisible,
            isSubtitleEditVisible: isSubtitleEditVisible
        ) {
            PlaybackFillInBlankModeView(
                engine: engine,
                videoSubtitleSettings: videoSubtitleSettings,
                lang: lang
            )
        }
    }

    private func handlePlaybackInterfaceModeChange(to newMode: PlaybackInterfaceMode) {
        if newMode == .fillInBlank {
            if savedLoopModeBeforeFillInBlank == nil {
                savedLoopModeBeforeFillInBlank = engine.loopMode
            }
            engine.pauseAfterSegmentHoldsCurrentSegment = true
            engine.loopMode = .pauseAfterSegment
            if engine.currentMedia != nil && !engine.segments.isEmpty {
                let targetIdx = engine.activeSegmentIndex ?? 0
                engine.jumpToSegment(at: targetIdx)
                engine.play()
            }
        } else {
            engine.pauseAfterSegmentHoldsCurrentSegment = false
            if let prev = savedLoopModeBeforeFillInBlank {
                engine.loopMode = prev
                savedLoopModeBeforeFillInBlank = nil
            }
        }
    }

    private func handleMediaDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let validURL = url else { return }
            DispatchQueue.main.async {
                engine.loadMedia(from: validURL)
            }
        }
        return true
    }
    
    @ViewBuilder
    private var playlistOverlay: some View {
        if isPlaylistMounted {
            ZStack(alignment: .topTrailing) {
                // 点击播放列表之外的任意内容区域时自动收起，带柔和的暗色毛玻璃遮罩（侧拉门背景景深）
                Color.black
                    .opacity(0.16 * playlistRevealProgress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        hidePlaylist()
                    }

                playlistPanel
                    .frame(width: CGFloat(playlistWidth))
                    .frame(maxHeight: .infinity, alignment: .topTrailing)
                    .offset(x: (1.0 - playlistRevealProgress) * CGFloat(playlistWidth))
                    .zIndex(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .zIndex(100)
            .clipped()
        }
    }

    private var playlistPanel: some View {
        PlaybackListView(
            engine: engine,
            historyStore: playbackHistory,
            playlistWidth: $playlistWidth,
            onResizeEnded: {
                UserDefaults.standard.set(playlistWidth, forKey: "studymate_playlist_width")
            }
        )
        .frame(width: CGFloat(playlistWidth))
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .allowsHitTesting(true)
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

    private func handleCloseCurrentMediaRequest(_: Notification) {
        guard !isClosingCurrentMedia else { return }
        isClosingCurrentMedia = true
        hidePlaylist()
        let closeGeneration = statusCenter.begin(MainStatusProgress(
            fraction: 0,
            phase: lang.text("正在关闭媒体…", "Closing media…")
        ))
        Task { @MainActor in
            // 先完整保存并释放媒体工作区资源，再销毁主窗口场景。
            await engine.closeCurrentMedia()
            statusCenter.finish(generation: closeGeneration)
            // Allow the same main-window scene to be used for the next media
            // session instead of leaving its local guard permanently locked.
            isClosingCurrentMedia = false
            dismissMainWindowThenShowWelcome()
        }
    }

    private func dismissMainWindowThenShowWelcome() {
        let showWelcome = {
            openWindow(id: "welcome")
            DispatchQueue.main.async {
                if let welcomeWindow = NSApp.windows.first(where: {
                    $0.identifier == NSUserInterfaceItemIdentifier("studymate-welcome-window")
                }) {
                    welcomeWindow.makeKeyAndOrderFront(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        // 1. 显式通知 SwiftUI 注销并关闭主窗口场景
        dismiss()
        dismissWindow(id: "main")

        // 2. 找到所有主窗口实例，强制隐藏并关闭
        let mainWindows = NSApp.windows.filter {
            $0.identifier == NSUserInterfaceItemIdentifier("studymate-main-window")
        }

        for window in mainWindows {
            window.orderOut(nil)
            window.close()
        }

        // 3. 立即呈现并置顶欢迎首屏
        showWelcome()
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


/// 将工具栏从主视图的超长泛型表达式中隔离出来，避免 Release 优化编译器
/// 因 SwiftUI 类型推断复杂度而失败；所有动作仍回调至主窗口状态。
/// macOS 26 分组工具栏（Grouped Toolbar）：
/// - 左区（核心控制与资源）：打开媒体、学习工具组（词典/句库/生词本）、媒体信息、五种学习模式分段控件直接外露
/// - 中区（播放调节）：语速、复读、跟读一体化胶囊药丸合集（Liquid Glass Capsule）
/// - 右区（工作区面板开关与字幕）：字幕控制组（原文/译文/样式）、播放列表、Xcode 风格三段面板切换开关
private struct MainWindowToolbar: ToolbarContent {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var lang: LanguageManager
    @ObservedObject var videoSubtitleSettings: VideoSubtitleSettings
    @ObservedObject var dictionaryCoordinator: DictionaryInteractionCoordinator
    @Binding var isWaveformsVisible: Bool
    @Binding var isSubtitleEditVisible: Bool
    @Binding var isVideoSubtitleFontSettingsPresented: Bool
    @Binding var isSidebarVisible: Bool
    @Binding var playbackInterfaceMode: PlaybackInterfaceMode
    let onOpenLibrary: () -> Void
    let onOpenVocabulary: () -> Void
    let onOpenDictionary: () -> Void
    let onOpenMedia: () -> Void
    let onTogglePlaylist: () -> Void

    /// 媒体标题是状态信息，不能与主要操作争抢工具栏空间。
    private static let mediaTitleMaxWidth: CGFloat = 140

    var body: some ToolbarContent {
        // MARK: - 左区：核心控制与资源入口
        ToolbarItem(placement: .navigation) {
            Button(action: onOpenMedia) {
                Image(systemName: "folder.badge.plus").studymateToolbarIcon()
            }
            .help(StudyMateShortcutCatalog.help(lang.text("打开音视频文件", "Open audio or video"), shortcut: .openMedia))
            .accessibilityLabel(lang.text("打开音视频文件", "Open audio or video"))
        }

        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button(action: onOpenDictionary) {
                    Image(systemName: "character.book.closed").studymateToolbarIcon()
                }
                .help(StudyMateShortcutCatalog.help(
                    lang.text("打开词典", "Open dictionary"),
                    shortcut: .openDictionary
                ))
                .accessibilityLabel(lang.text("打开词典", "Open dictionary"))
                .accessibilityHint(lang.text("打开当前选中文本的词典释义", "Open dictionary definitions for the current selection"))
                .keyboardShortcut("d", modifiers: [.command, .control])

                Button(action: onOpenLibrary) {
                    Image(systemName: "books.vertical").studymateToolbarIcon()
                }
                .help(StudyMateShortcutCatalog.help(lang.text("打开句库", "Open sentence library"), shortcut: .openSentenceLibrary))
                .accessibilityLabel(lang.text("打开句库", "Open sentence library"))
                .keyboardShortcut("l", modifiers: [.command])

                Button(action: onOpenVocabulary) {
                    Image(systemName: "book.closed").studymateToolbarIcon()
                }
                .help(lang.text("打开生词本", "Open vocabulary"))
                .accessibilityLabel(lang.text("打开生词本", "Open vocabulary"))
            }
        }

        if let media = engine.currentMedia {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 5) {
                    Image(systemName: media.isVideo ? "video.fill" : "music.note")
                        .font(.caption)
                        .foregroundColor(StudyMateMediaStyle.accent)
                    Text(media.title)
                        .font(.caption.bold())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 0, maxWidth: Self.mediaTitleMaxWidth, alignment: .leading)
                        .layoutPriority(-1)
                        .help(media.title)
                    Text("(\(media.formattedDuration))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize()
                }
            }
        }

        // 五种学习模式分段控件直接外露
        ToolbarItem(placement: .navigation) {
            Picker(
                lang.text("学习模式", "Study Mode"),
                selection: $playbackInterfaceMode
            ) {
                ForEach(PlaybackInterfaceMode.allCases) { mode in
                    Image(systemName: mode.iconName)
                        .studymateToolbarIcon()
                        .tag(mode)
                        .help(mode.localized(with: lang))
                        .accessibilityLabel(mode.localized(with: lang))
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.regular)
            .help(lang.text("界面学习模式：视频模式 / 列表模式 / 全文模式 / 句子模式 / 填空模式", "Study modes: Video / List / Full Text / Sentence / Fill-in-the-Blank"))
            .accessibilityLabel(lang.text("学习模式", "Study mode"))
            .accessibilityValue(playbackInterfaceMode.localized(with: lang))
        }

        // MARK: - 中区：播放调节胶囊药丸合集
        ToolbarItem(placement: .principal) {
            PlaybackAdjustmentCapsule(engine: engine, lang: lang)
        }

        // MARK: - 右区：工作区面板开关与字幕控制
        ToolbarItemGroup(placement: .primaryAction) {
            // 画面字幕显隐与字体设置组合
            ControlGroup {
                Toggle(isOn: Binding(
                    get: { videoSubtitleSettings.isOriginalVisible(for: playbackInterfaceMode) },
                    set: { _ in videoSubtitleSettings.toggleOriginal(for: playbackInterfaceMode) }
                )) {
                    Image(systemName: videoSubtitleSettings.isOriginalVisible(for: playbackInterfaceMode) ? "captions.bubble.fill" : "captions.bubble")
                        .studymateToolbarIcon()
                }
                .help(StudyMateShortcutCatalog.help(
                    videoSubtitleSettings.isOriginalVisible(for: playbackInterfaceMode)
                        ? lang.text("隐藏画面原文字幕", "Hide original subtitles")
                        : lang.text("显示画面原文字幕", "Show original subtitles"),
                    shortcut: .toggleVideoOriginalSubtitle
                ))
                .accessibilityLabel(lang.text("画面原文字幕", "Original subtitles"))
                .accessibilityValue(videoSubtitleSettings.isOriginalVisible(for: playbackInterfaceMode) ? lang.text("已显示", "Shown") : lang.text("已隐藏", "Hidden"))
                .accessibilityHint(lang.text("切换画面原文字幕", "Toggle original subtitles"))
                .accessibilityAddTraits(videoSubtitleSettings.isOriginalVisible(for: playbackInterfaceMode) ? .isSelected : [])
                .keyboardShortcut("o", modifiers: [.command, .option])

                Toggle(isOn: Binding(
                    get: { videoSubtitleSettings.isTranslationVisible(for: playbackInterfaceMode) },
                    set: { _ in videoSubtitleSettings.toggleTranslation(for: playbackInterfaceMode) }
                )) {
                    Image(systemName: videoSubtitleSettings.isTranslationVisible(for: playbackInterfaceMode) ? "character.bubble.fill" : "character.bubble")
                        .studymateToolbarIcon()
                }
                .help(StudyMateShortcutCatalog.help(
                    videoSubtitleSettings.isTranslationVisible(for: playbackInterfaceMode)
                        ? lang.text("隐藏画面译文字幕", "Hide translated subtitles")
                        : lang.text("显示画面译文字幕", "Show translated subtitles"),
                    shortcut: .toggleVideoTranslationSubtitle
                ))
                .accessibilityLabel(lang.text("画面译文字幕", "Translated subtitles"))
                .accessibilityValue(videoSubtitleSettings.isTranslationVisible(for: playbackInterfaceMode) ? lang.text("已显示", "Shown") : lang.text("已隐藏", "Hidden"))
                .accessibilityHint(lang.text("切换画面译文字幕", "Toggle translated subtitles"))
                .accessibilityAddTraits(videoSubtitleSettings.isTranslationVisible(for: playbackInterfaceMode) ? .isSelected : [])
                .keyboardShortcut("t", modifiers: [.command, .option])

                Button {
                    isVideoSubtitleFontSettingsPresented.toggle()
                } label: {
                    Image(systemName: "textformat.size").studymateToolbarIcon()
                }
                .help(StudyMateShortcutCatalog.help(lang.text("设置字幕字体", "Set subtitle fonts"), shortcut: .videoSubtitleFontSettings))
                .accessibilityLabel(lang.text("设置字幕字体", "Set subtitle fonts"))
                .accessibilityHint(lang.text("打开字幕字体、字号和颜色设置", "Open subtitle font, size, and color settings"))
                .keyboardShortcut("f", modifiers: [.command, .option])
                .popover(isPresented: $isVideoSubtitleFontSettingsPresented, arrowEdge: .bottom) {
                    VideoSubtitleFontSettingsPopover(initialMode: playbackInterfaceMode)
                }
            }

            // 播放列表按钮
            Button(action: onTogglePlaylist) {
                Image(systemName: "music.note.list").studymateToolbarIcon()
            }
            .help(StudyMateShortcutCatalog.help(lang.text("显示或隐藏播放列表", "Show or hide playlist"), shortcut: .togglePlaylist))
            .accessibilityLabel(lang.text("播放列表", "Playlist"))
            .accessibilityHint(lang.text("显示或隐藏播放列表", "Show or hide playlist"))
            .keyboardShortcut("p", modifiers: [.option])

            // Xcode / Logic Pro 风格标准三段面板切换开关（波形图、字幕编辑区、断句列表）
            ControlGroup {
                Toggle(isOn: Binding(
                    get: { isWaveformsVisible },
                    set: { newValue in
                        withAnimation(MainContentView.panelSpringAnimation) {
                            isWaveformsVisible = newValue
                        }
                    }
                )) {
                    Image(systemName: "waveform.path.ecg").studymateToolbarIcon()
                }
                .help(StudyMateShortcutCatalog.help(
                    isWaveformsVisible ? lang.text("隐藏波形图工作区", "Hide waveforms") : lang.text("显示波形图工作区", "Show waveforms"),
                    shortcut: .toggleWaveforms
                ))
                .accessibilityLabel(lang.text("波形图工作区", "Waveform workspace"))
                .accessibilityValue(isWaveformsVisible ? lang.text("已显示", "Shown") : lang.text("已隐藏", "Hidden"))
                .accessibilityHint(lang.text("切换波形图工作区", "Toggle waveform workspace"))
                .accessibilityAddTraits(isWaveformsVisible ? .isSelected : [])
                .keyboardShortcut("w", modifiers: [.option])
                .disabled(playbackInterfaceMode != .video)

                Toggle(isOn: Binding(
                    get: { isSubtitleEditVisible },
                    set: { newValue in
                        withAnimation(MainContentView.panelSpringAnimation) {
                            isSubtitleEditVisible = newValue
                        }
                    }
                )) {
                    Image(systemName: "square.and.pencil").studymateToolbarIcon()
                }
                .help(StudyMateShortcutCatalog.help(
                    isSubtitleEditVisible ? lang.text("隐藏字幕双语编辑区", "Hide subtitle editor") : lang.text("显示字幕双语编辑区", "Show subtitle editor"),
                    shortcut: .toggleSubtitleEditor
                ))
                .accessibilityLabel(lang.text("字幕双语编辑区", "Subtitle bilingual editor"))
                .accessibilityValue(isSubtitleEditVisible ? lang.text("已显示", "Shown") : lang.text("已隐藏", "Hidden"))
                .accessibilityHint(lang.text("切换字幕双语编辑区", "Toggle subtitle bilingual editor"))
                .accessibilityAddTraits(isSubtitleEditVisible ? .isSelected : [])
                .keyboardShortcut("s", modifiers: [.option])
                .disabled(playbackInterfaceMode != .video)

                Toggle(isOn: Binding(
                    get: { isSidebarVisible },
                    set: { newValue in
                        withAnimation(MainContentView.panelSpringAnimation) {
                            isSidebarVisible = newValue
                        }
                    }
                )) {
                    Image(systemName: "sidebar.right").studymateToolbarIcon()
                }
                .help(StudyMateShortcutCatalog.help(lang.text("显示或隐藏断句列表", "Show or hide sentence list"), shortcut: .toggleSegmentList))
                .accessibilityLabel(lang.text("断句列表", "Sentence list"))
                .accessibilityValue(isSidebarVisible ? lang.text("已显示", "Shown") : lang.text("已隐藏", "Hidden"))
                .accessibilityHint(lang.text("切换断句列表", "Toggle sentence list"))
                .accessibilityAddTraits(isSidebarVisible ? .isSelected : [])
                .keyboardShortcut("l", modifiers: [.option])
                .disabled(playbackInterfaceMode != .video)
            }
        }
    }
}

/// 播放调节胶囊药丸合集（语速、复读、跟读）
private struct PlaybackAdjustmentCapsule: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var lang: LanguageManager

    private var repeatOptions: [(label: String, count: Int)] {
        [(lang.text("1次", "1×"), 1), (lang.text("2次", "2×"), 2),
         (lang.text("3次", "3×"), 3), (lang.text("5次", "5×"), 5),
         (lang.text("7次", "7×"), 7), (lang.text("10次", "10×"), 10),
         (lang.text("20次", "20×"), 20), (lang.text("无限", "∞"), 0)]
    }

    private let shadowingPauseSecondsOptions = [1, 2, 3, 5]
    private let shadowingPauseRatioOptions: [(label: String, ratio: Double)] = [
        ("0.25×", 0.25), ("0.5×", 0.5), ("0.75×", 0.75),
        ("1×", 1.0), ("1.5×", 1.5), ("2×", 2.0)
    ]

    private var repeatLabel: String {
        engine.repeatCountLimit == 0 ? "∞" : "\(engine.repeatCountLimit)×"
    }

    private var pauseLabel: String {
        if engine.shadowingPauseSeconds > 0 {
            return "\(Int(engine.shadowingPauseSeconds))s"
        }
        return engine.shadowingPauseRatio == 0 ? lang.text("关", "Off") : String(format: "%.2g×", engine.shadowingPauseRatio)
    }

    private var isSpeedActive: Bool {
        abs(engine.playbackRate - 1.0) > 0.001
    }

    private var isRepeatActive: Bool {
        engine.repeatCountLimit != 1 || engine.loopMode == .singleSegment || engine.loopMode == .all
    }

    private var isShadowingActive: Bool {
        engine.shadowingPauseSeconds > 0 || engine.shadowingPauseRatio > 0
    }

    var body: some View {
        HStack(spacing: 0) {
            // 语速
            Menu {
                ForEach([0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0] as [Float], id: \.self) { speed in
                    Button { engine.playbackRate = speed } label: {
                        if abs(engine.playbackRate - speed) < 0.01 {
                            Label(String(format: "%.2fx", speed), systemImage: "checkmark")
                        } else {
                            Text(String(format: "%.2fx", speed))
                        }
                    }
                }
                Divider()
                Button { engine.playbackRate = 1.0 } label: {
                    Label(lang.text("恢复原速 (1.00x)", "Reset to 1.00x"), systemImage: "arrow.counterclockwise")
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "gauge.with.needle")
                        .font(.system(size: 11, weight: .semibold))
                    Text(String(format: "%.2fx", engine.playbackRate))
                        .studymateToolbarValueLabel()
                }
                .foregroundStyle(isSpeedActive ? StudyMateMediaStyle.accent : Color.primary)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(StudyMateShortcutCatalog.help(lang.text("调节播放语速", "Playback rate"), shortcut: .playbackRateMenu))
            .accessibilityLabel(lang.text("播放速度", "Playback speed"))
            .accessibilityValue(String(format: "%.2fx", engine.playbackRate))
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()
                .frame(height: 12)
                .padding(.horizontal, 5)

            // 复读
            Menu {
                Section(lang.text("播放循环模式", "Loop Mode")) {
                    Button {
                        engine.loopMode = .normal
                    } label: {
                        if engine.loopMode == .normal {
                            Label(lang.text("连续播放", "Continuous Play"), systemImage: "checkmark")
                        } else {
                            Label(lang.text("连续播放", "Continuous Play"), systemImage: PlaybackLoopMode.normal.iconName)
                        }
                    }
                    Button {
                        engine.loopMode = .singleSegment
                    } label: {
                        if engine.loopMode == .singleSegment {
                            Label(lang.text("单句重复", "Repeat Sentence"), systemImage: "checkmark")
                        } else {
                            Label(lang.text("单句重复", "Repeat Sentence"), systemImage: PlaybackLoopMode.singleSegment.iconName)
                        }
                    }
                    Button {
                        engine.loopMode = .all
                    } label: {
                        if engine.loopMode == .all {
                            Label(lang.text("全篇循环", "Loop Entire File"), systemImage: "checkmark")
                        } else {
                            Label(lang.text("全篇循环", "Loop Entire File"), systemImage: PlaybackLoopMode.all.iconName)
                        }
                    }
                }

                Divider()

                Section(lang.text("单句复读次数", "Repeat Limit")) {
                    ForEach(repeatOptions, id: \.count) { option in
                        Button {
                            engine.repeatCountLimit = option.count
                            engine.currentRepeatCount = 1
                            if option.count != 1 && engine.loopMode == .normal {
                                engine.loopMode = .singleSegment
                            }
                        } label: {
                            if engine.repeatCountLimit == option.count {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: engine.loopMode == .singleSegment ? "repeat.1" : (engine.loopMode == .all ? "repeat" : "repeat.circle"))
                        .font(.system(size: 11, weight: .semibold))
                    Text(repeatLabel)
                        .studymateToolbarValueLabel()
                }
                .foregroundStyle(isRepeatActive ? StudyMateMediaStyle.accent : Color.primary)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(StudyMateShortcutCatalog.help(lang.text("设置单句复读", "Set sentence repeat"), shortcut: .repeatCountMenu))
            .accessibilityLabel(lang.text("单句复读", "Sentence repeat"))
            .accessibilityValue(repeatLabel)

            Divider()
                .frame(height: 12)
                .padding(.horizontal, 5)

            // 跟读
            Menu {
                Button {
                    engine.setShadowingPauseRatio(0)
                    if engine.loopMode == .pauseAfterSegment {
                        engine.loopMode = .normal
                    }
                } label: {
                    if !isShadowingActive {
                        Label(lang.text("关闭停顿", "Off"), systemImage: "checkmark")
                    } else {
                        Text(lang.text("关闭停顿", "Off"))
                    }
                }

                Divider()

                Section(lang.text("固定停顿秒数", "Fixed Seconds")) {
                    ForEach(shadowingPauseSecondsOptions, id: \.self) { sec in
                        Button {
                            engine.setShadowingPauseSeconds(Double(sec))
                            if engine.loopMode == .pauseAfterSegment {
                                engine.loopMode = .normal
                            }
                        } label: {
                            if isShadowingActive && abs(engine.shadowingPauseSeconds - Double(sec)) < 0.001 {
                                Label("\(sec)s", systemImage: "checkmark")
                            } else {
                                Text("\(sec)s")
                            }
                        }
                    }
                }

                Divider()

                Section(lang.text("依句长停顿比例", "Ratio by Length")) {
                    ForEach(shadowingPauseRatioOptions, id: \.ratio) { option in
                        Button {
                            engine.setShadowingPauseRatio(option.ratio)
                            if engine.loopMode == .pauseAfterSegment {
                                engine.loopMode = .normal
                            }
                        } label: {
                            if isShadowingActive && engine.shadowingPauseSeconds == 0 && abs(engine.shadowingPauseRatio - option.ratio) < 0.001 {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text(pauseLabel)
                        .studymateToolbarValueLabel()
                }
                .foregroundStyle(isShadowingActive ? StudyMateMediaStyle.success : Color.primary)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(StudyMateShortcutCatalog.help(lang.text("设置句末跟读停顿", "Set shadowing pause"), shortcut: .shadowingPauseMenu))
            .accessibilityLabel(lang.text("句末跟读停顿", "Shadowing pause"))
            .accessibilityValue(pauseLabel)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                .overlay(
                    Capsule()
                        .stroke(StudyMateMediaStyle.separator.opacity(0.45), lineWidth: 0.8)
                )
        )
    }
}

#Preview("StudyMate 主界面") {
    MainContentView()
        .frame(width: 1200, height: 800)
}

/// 主窗口底部的紧凑播放状态栏；它位于 HSplitView 之后，因此断句列表始终在其上方。
/// 播放信息靠左，所有进度与错误提示统一靠右显示。
private struct PlaybackStatusBar: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var libraryManager: SentenceLibraryManager
    @ObservedObject var waveformState: WaveformPresentationState
    @ObservedObject var statusCenter: MainStatusCenter
    let playbackInterfaceMode: PlaybackInterfaceMode
    let onResolveProjectRecovery: () -> Void
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

        if engine.shadowingPauseSeconds > 0 {
            return "\(lang.text("跟读停顿", "Shadowing pause")) \(Int(engine.shadowingPauseSeconds))s"
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
        if waveformState.isExtracting {
            return MainStatusProgress(
                fraction: waveformState.extractionProgress,
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

    private var allActiveIssues: [StatusIssueItem] {
        var result = statusCenter.issues

        if let msg = engine.statusErrorMessage, !result.contains(where: { $0.message == msg }) {
            result.append(
                StatusIssueItem(
                    message: msg,
                    level: .error,
                    actionTitle: engine.canUseExistingProject ? lang.text("处理工程", "Handle Project") : nil,
                    actionKind: engine.canUseExistingProject ? .projectRecovery : .none
                )
            )
        }

        if let msg = libraryManager.lastErrorMessage, !result.contains(where: { $0.message == msg }) {
            result.append(
                StatusIssueItem(
                    message: msg,
                    level: .error
                )
            )
        }

        return result
    }

    var body: some View {
        HStack(spacing: 8) {
            Label(playbackInterfaceMode.localized(with: lang), systemImage: playbackInterfaceMode.iconName)

            Divider()
                .frame(height: 12)

            Label(currentSegmentText, systemImage: "number")

            Divider()
                .frame(height: 12)
            Label(engine.loopMode.localized(with: lang), systemImage: engine.loopMode.iconName)
                .accessibilityLabel(engine.loopMode.localized(with: lang))

            if abs(engine.playbackRate - 1.0) > 0.001 {
                Divider()
                    .frame(height: 12)
                Label(String(format: "%.2fx", engine.playbackRate), systemImage: "gauge.with.needle")
                    .foregroundColor(StudyMateMediaStyle.accent)
            }

            if engine.repeatCountLimit != 1 {
                Divider()
                    .frame(height: 12)
                Label(repeatCountText, systemImage: "repeat.circle")
            }

            if engine.shadowingPauseRatio > 0 || engine.shadowingPauseSeconds > 0 {
                Divider()
                    .frame(height: 12)
                Label(shadowingText, systemImage: engine.isShadowingPaused ? "mic.fill" : "pause.circle")
                    .foregroundStyle(engine.isShadowingPaused ? StudyMateMediaStyle.success : Color.secondary)
            }

            Spacer(minLength: 8)

            // 右侧通知与反馈区：第一层（短暂通知/进度）在左，第三层（错误与任务中心）在最右侧，绝不互相覆盖
            HStack(spacing: 8) {
                // 第一层：短暂操作反馈 / 任务进度条
                if let successMessage = statusCenter.successMessage {
                    StatusBarSuccessView(message: successMessage)
                } else if let progress = currentProgress {
                    StatusBarProgressView(
                        progress: progress,
                        canCancel: canCancelCurrentProgress,
                        onCancel: cancelCurrentProgress
                    )
                }

                // 第一层与第三层同时存在时，以细分割线并排区分
                if (statusCenter.successMessage != nil || currentProgress != nil) && !allActiveIssues.isEmpty {
                    Divider()
                        .frame(height: 12)
                }

                // 第三层：重要报错与任务中心（状态栏最右侧轻柔徽章）
                if !allActiveIssues.isEmpty {
                    StatusBarIssuesBadgeView(
                        issues: allActiveIssues,
                        lastIssueToken: statusCenter.lastIssueToken,
                        onDismissIssue: { id in
                            statusCenter.dismissIssue(id: id)
                            if engine.statusErrorMessage != nil {
                                engine.dismissStatusError()
                            }
                            if libraryManager.lastErrorMessage != nil {
                                libraryManager.dismissErrorMessage()
                            }
                        },
                        onClearAll: {
                            statusCenter.clearAllIssues()
                            engine.dismissStatusError()
                            libraryManager.dismissErrorMessage()
                        },
                        onResolveProjectRecovery: engine.canUseExistingProject ? onResolveProjectRecovery : nil
                    )
                }
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .frame(minHeight: 22, maxHeight: 24)
        .studymateContentSurface(cornerRadius: 0)
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(StudyMateMediaStyle.separator),
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
}

private struct StatusBarSuccessView: View {
    let message: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(StudyMateMediaStyle.success)
                .font(.system(size: 11, weight: .semibold))

            Text(message)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(StudyMateMediaStyle.success.opacity(0.12))
        .clipShape(Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

private struct StatusBarProgressView: View {
    @ObservedObject private var lang = LanguageManager.shared
    let progress: MainStatusProgress
    let canCancel: Bool
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(width: 80)

            Text(progress.phase.isEmpty ? lang.text("处理中", "Working") : progress.phase)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160, alignment: .leading)

            if !progress.currentItem.isEmpty {
                Text(progress.currentItem)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 100, alignment: .leading)
            }

            Text("\(Int(progress.fraction * 100))%")
                .monospacedDigit()
                .foregroundColor(.secondary)

            if canCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 14, height: 14)
                }
                .studymateChromeButton(shape: .circle)
                .help(lang.text("取消当前任务", "Cancel current task"))
            }
        }
        .frame(maxWidth: 420, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(progress.phase)
    }
}

private struct StatusBarIssuesBadgeView: View {
    let issues: [StatusIssueItem]
    let lastIssueToken: UUID
    let onDismissIssue: (UUID) -> Void
    let onClearAll: () -> Void
    let onResolveProjectRecovery: (() -> Void)?

    @ObservedObject private var lang = LanguageManager.shared
    @State private var isPopoverPresented = false
    @State private var bounceScale: CGFloat = 1.0

    private var hasError: Bool {
        issues.contains(where: { $0.level == .error })
    }

    private var badgeColor: Color {
        hasError ? StudyMateMediaStyle.destructive : StudyMateMediaStyle.warning
    }

    var body: some View {
        Button(action: { isPopoverPresented.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: hasError ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(badgeColor)

                Text("\(issues.count)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundColor(badgeColor)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.12))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(badgeColor.opacity(0.35), lineWidth: 0.5)
            )
            .scaleEffect(bounceScale)
        }
        .buttonStyle(.plain)
        .help(lang.text("查看问题与任务中心 (\(issues.count))", "View issues & task center (\(issues.count))"))
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            StatusBarIssuesPopoverView(
                issues: issues,
                onDismissIssue: onDismissIssue,
                onClearAll: {
                    onClearAll()
                    isPopoverPresented = false
                },
                onResolveProjectRecovery: {
                    isPopoverPresented = false
                    onResolveProjectRecovery?()
                }
            )
        }
        .onChange(of: lastIssueToken) { _, _ in
            triggerBounce()
        }
        .onChange(of: issues.count) { _, _ in
            triggerBounce()
        }
    }

    private func triggerBounce() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.45, blendDuration: 0)) {
            bounceScale = 1.18
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                bounceScale = 1.0
            }
        }
    }
}

private struct StatusBarIssuesPopoverView: View {
    let issues: [StatusIssueItem]
    let onDismissIssue: (UUID) -> Void
    let onClearAll: () -> Void
    let onResolveProjectRecovery: () -> Void

    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(
                    lang.text("问题与通知", "Issues & Notifications"),
                    systemImage: "bell.badge"
                )
                .font(.system(size: 12, weight: .semibold))

                Text("\(issues.count)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())

                Spacer()

                if !issues.isEmpty {
                    Button(action: onClearAll) {
                        Text(lang.text("全部清空", "Clear All"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(lang.text("清空所有问题记录", "Clear all issue records"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if issues.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text(lang.text("暂无未解决的问题", "No active issues"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(issues) { item in
                            StatusBarIssueRowView(
                                issue: item,
                                onDismiss: { onDismissIssue(item.id) },
                                onAction: {
                                    if item.actionKind == .projectRecovery {
                                        onResolveProjectRecovery()
                                    }
                                }
                            )

                            if item.id != issues.last?.id {
                                Divider()
                                    .padding(.leading, 28)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 350)
    }
}

private struct StatusBarIssueRowView: View {
    let issue: StatusIssueItem
    let onDismiss: () -> Void
    let onAction: () -> Void

    @ObservedObject private var lang = LanguageManager.shared

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: issue.level == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(issue.level == .error ? StudyMateMediaStyle.destructive : StudyMateMediaStyle.warning)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(Self.timeFormatter.string(from: issue.timestamp))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary)

                    Spacer()

                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help(lang.text("忽略/移除", "Dismiss"))
                }

                Text(issue.message)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let actionTitle = issue.actionTitle {
                    Button(action: onAction) {
                        Text(actionTitle)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

