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

    private static func slideAndFadeTransition(from edge: Edge) -> AnyTransition {
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
    @AppStorage("StudyMate.ShowSubtitleEditor") private var isSubtitleEditVisible: Bool = true
    @State private var isVideoSubtitleFontSettingsPresented: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var isClosingCurrentMedia: Bool = false
    @State private var isProjectRecoveryDialogPresented: Bool = false
    @AppStorage("StudyMate.ShowStatusBar") private var isStatusBarVisible: Bool = false
    @AppStorage("StudyMate.PlaybackInterfaceMode") private var playbackInterfaceMode: PlaybackInterfaceMode = .video
    @State private var savedLoopModeBeforeFillInBlank: PlaybackLoopMode? = nil
    @State private var playlistWidth: Double = UserDefaults.standard.double(forKey: "studymate_playlist_width") >= 240 ? UserDefaults.standard.double(forKey: "studymate_playlist_width") : 360
    @State private var sidebarWidth: Double = {
        let saved = UserDefaults.standard.double(forKey: "studymate_sentence_list_width")
        return (saved >= 260 && saved <= 650) ? saved : 320
    }()
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
        .animation(Self.panelSpringAnimation, value: shouldShowStatusBar)
        .animation(Self.panelSpringAnimation, value: isWaveformsVisible)
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
                videoModeWorkspace
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

    private var videoModeWorkspace: some View {
        HStack(spacing: 0) {
            // 左侧工作主区（顶部双波形图 + 中间自适应音视频视窗 + 底部字幕编辑栏）
            PlaybackWorkspaceContainer(
                engine: engine,
                isWaveformsVisible: isWaveformsVisible,
                isSubtitleEditVisible: isSubtitleEditVisible
            ) {
                VideoPlayerView(engine: engine)
            }
            .frame(minWidth: 420, maxWidth: .infinity, minHeight: 450, maxHeight: .infinity)

            if isSidebarVisible {
                HStack(spacing: 0) {
                    SegmentListResizeBorderRepresentable(
                        sidebarWidth: $sidebarWidth,
                        onResizeEnded: {
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
                .transition(Self.slideAndFadeTransition(from: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

/// 原生 AppKit 极致丝滑边框拉伸组件（采用 Finder / NSSplitView 同款 modal event tracking loop）
private struct SegmentListResizeBorderRepresentable: NSViewRepresentable {
    @Binding var sidebarWidth: Double
    let onResizeEnded: () -> Void

    func makeNSView(context: Context) -> SegmentListResizeBorderView {
        let view = SegmentListResizeBorderView()
        view.onDragDelta = { deltaX in
            let newWidth = min(max(260, sidebarWidth - Double(deltaX)), 650)
            if newWidth != sidebarWidth {
                sidebarWidth = newWidth
            }
        }
        view.onDragEnded = onResizeEnded
        return view
    }

    func updateNSView(_ nsView: SegmentListResizeBorderView, context: Context) {
        nsView.onDragDelta = { deltaX in
            let newWidth = min(max(260, sidebarWidth - Double(deltaX)), 650)
            if newWidth != sidebarWidth {
                sidebarWidth = newWidth
            }
        }
        nsView.onDragEnded = onResizeEnded
    }
}

private final class SegmentListResizeBorderView: NSView {
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

    private var listModeWorkspace: some View {
        PlaybackWorkspaceContainer(
            engine: engine,
            isWaveformsVisible: isWaveformsVisible,
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

    /// 媒体标题是状态信息，不能与右侧主要操作争抢工具栏空间。
    private static let mediaTitleMaxWidth: CGFloat = 180

    private var repeatLabel: String {
        engine.repeatCountLimit == 0 ? "∞" : "\(engine.repeatCountLimit)×"
    }

    private var pauseLabel: String {
        if engine.shadowingPauseSeconds > 0 {
            return "\(Int(engine.shadowingPauseSeconds))s"
        }
        return engine.shadowingPauseRatio == 0 ? lang.text("关", "Off") : String(format: "%.2g×", engine.shadowingPauseRatio)
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
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
        }
        ToolbarItem(placement: .navigation) {
            Button(action: onOpenLibrary) { Image(systemName: "books.vertical").studymateToolbarIcon() }
                .help(StudyMateShortcutCatalog.help(lang.text("打开句库", "Open sentence library"), shortcut: .openSentenceLibrary))
                .accessibilityLabel(lang.text("打开句库", "Open sentence library"))
                .keyboardShortcut("l", modifiers: [.command])
        }
        ToolbarItem(placement: .navigation) {
            Button(action: onOpenVocabulary) { Image(systemName: "book.closed").studymateToolbarIcon() }
                .help(lang.text("打开生词本", "Open vocabulary"))
                .accessibilityLabel(lang.text("打开生词本", "Open vocabulary"))
        }
        ToolbarItem(placement: .navigation) {
            Button(action: onOpenMedia) { Image(systemName: "folder.badge.plus").studymateToolbarIcon() }
                .help(StudyMateShortcutCatalog.help(lang.text("打开音视频文件", "Open audio or video"), shortcut: .openMedia))
                .accessibilityLabel(lang.text("打开音视频文件", "Open audio or video"))
        }
        if let media = engine.currentMedia {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 5) {
                    Image(systemName: media.isVideo ? "video.fill" : "music.note").font(.caption).foregroundColor(StudyMateMediaStyle.accent)
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

        ToolbarItemGroup(placement: .primaryAction) {
            PlaybackLoopModeToolbarPicker(engine: engine, lang: lang)

            Menu {
                ForEach(repeatOptions, id: \.count) { option in
                    Button { engine.repeatCountLimit = option.count; engine.currentRepeatCount = 1 } label: {
                        if engine.repeatCountLimit == option.count { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                    }
                }
            } label: {
                Label(repeatLabel, systemImage: "repeat.circle").studymateToolbarValueLabel()
                    .foregroundColor(engine.repeatCountLimit == 1 ? .primary : StudyMateMediaStyle.accent)
            }
            .help(StudyMateShortcutCatalog.help(lang.text("设置单句复读次数", "Set sentence repeat count"), shortcut: .repeatCountMenu))
            .accessibilityLabel(lang.text("单句复读次数", "Sentence repeat count"))
            .accessibilityValue(repeatLabel)
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Menu {
                Button {
                    engine.setShadowingPauseRatio(0)
                } label: {
                    if engine.shadowingPauseRatio == 0 && engine.shadowingPauseSeconds == 0 {
                        Label(lang.text("关闭", "Off"), systemImage: "checkmark")
                    } else {
                        Text(lang.text("关闭", "Off"))
                    }
                }

                Divider()

                ForEach(shadowingPauseSecondsOptions, id: \.self) { sec in
                    Button {
                        engine.setShadowingPauseSeconds(Double(sec))
                    } label: {
                        if abs(engine.shadowingPauseSeconds - Double(sec)) < 0.001 {
                            Label("\(sec)s", systemImage: "checkmark")
                        } else {
                            Text("\(sec)s")
                        }
                    }
                }

                Divider()

                ForEach(shadowingPauseRatioOptions, id: \.ratio) { option in
                    Button {
                        engine.setShadowingPauseRatio(option.ratio)
                    } label: {
                        if engine.shadowingPauseSeconds == 0 && abs(engine.shadowingPauseRatio - option.ratio) < 0.001 {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                Label(pauseLabel, systemImage: "pause.circle").studymateToolbarValueLabel()
                    .foregroundStyle((engine.shadowingPauseRatio == 0 && engine.shadowingPauseSeconds == 0) ? Color.primary : StudyMateMediaStyle.success)
            }
            .help(StudyMateShortcutCatalog.help(lang.text("设置句末跟读停顿", "Set shadowing pause"), shortcut: .shadowingPauseMenu))
            .accessibilityLabel(lang.text("句末跟读停顿", "Shadowing pause"))
            .accessibilityValue(pauseLabel)
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { videoSubtitleSettings.toggleOriginal(for: playbackInterfaceMode) } label: {
                let isOriginalVisible = videoSubtitleSettings.isOriginalVisible(for: playbackInterfaceMode)
                Image(systemName: isOriginalVisible ? "captions.bubble.fill" : "captions.bubble")
                    .studymateToolbarIcon()
            }
            .help(StudyMateShortcutCatalog.help(videoSubtitleSettings.isOriginalVisible(for: playbackInterfaceMode) ? lang.text("隐藏画面原文字幕", "Hide original subtitles") : lang.text("显示画面原文字幕", "Show original subtitles"), shortcut: .toggleVideoOriginalSubtitle))
            .accessibilityLabel(lang.text("画面原文字幕", "Original subtitles"))
            .accessibilityValue(videoSubtitleSettings.isOriginalVisible(for: playbackInterfaceMode) ? lang.text("已显示", "Shown") : lang.text("已隐藏", "Hidden"))
            .accessibilityHint(lang.text("切换画面原文字幕", "Toggle original subtitles"))
            .accessibilityAddTraits(videoSubtitleSettings.isOriginalVisible(for: playbackInterfaceMode) ? .isSelected : [])
            .keyboardShortcut("o", modifiers: [.command, .option])

            Button { videoSubtitleSettings.toggleTranslation(for: playbackInterfaceMode) } label: {
                let isTranslationVisible = videoSubtitleSettings.isTranslationVisible(for: playbackInterfaceMode)
                Image(systemName: isTranslationVisible ? "character.bubble.fill" : "character.bubble")
                    .studymateToolbarIcon()
            }
            .help(StudyMateShortcutCatalog.help(videoSubtitleSettings.isTranslationVisible(for: playbackInterfaceMode) ? lang.text("隐藏画面译文字幕", "Hide translated subtitles") : lang.text("显示画面译文字幕", "Show translated subtitles"), shortcut: .toggleVideoTranslationSubtitle))
            .accessibilityLabel(lang.text("画面译文字幕", "Translated subtitles"))
            .accessibilityValue(videoSubtitleSettings.isTranslationVisible(for: playbackInterfaceMode) ? lang.text("已显示", "Shown") : lang.text("已隐藏", "Hidden"))
            .accessibilityHint(lang.text("切换画面译文字幕", "Toggle translated subtitles"))
            .accessibilityAddTraits(videoSubtitleSettings.isTranslationVisible(for: playbackInterfaceMode) ? .isSelected : [])
            .keyboardShortcut("t", modifiers: [.command, .option])

            Button { isVideoSubtitleFontSettingsPresented.toggle() } label: {
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

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach([0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0] as [Float], id: \.self) { speed in
                    Button { engine.playbackRate = speed } label: {
                        if abs(engine.playbackRate - speed) < 0.01 { Label(String(format: "%.2fx", speed), systemImage: "checkmark") } else { Text(String(format: "%.2fx", speed)) }
                    }
                }
                Divider()
                Button { engine.playbackRate = 1 } label: { Label(lang.text("恢复原速 (1.00x)", "Reset to 1.00x"), systemImage: "arrow.counterclockwise") }
            } label: {
                Label(String(format: "%.2fx", engine.playbackRate), systemImage: "gauge.with.needle")
                    .studymateToolbarValueLabel()
                    .foregroundColor(abs(engine.playbackRate - 1) > 0.001 ? StudyMateMediaStyle.accent : .primary)
            }
            .help(StudyMateShortcutCatalog.help(lang.text("调节播放语速", "Playback rate"), shortcut: .playbackRateMenu))
            .accessibilityLabel(lang.text("播放速度", "Playback speed"))
            .accessibilityValue(String(format: "%.2fx", engine.playbackRate))
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker(lang.text("界面模式", "Interface Mode"), selection: $playbackInterfaceMode) {
                    ForEach(PlaybackInterfaceMode.allCases) { mode in
                        Label(mode.localized(with: lang), systemImage: mode.iconName)
                            .tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: playbackInterfaceMode.iconName).studymateToolbarIcon()
            }
            .help(lang.text("选择界面模式：视频模式 / 列表模式 / 全文模式 / 句子模式 / 填空模式", "Choose interface mode"))
            .accessibilityLabel(lang.text("界面模式", "Interface mode"))
            .accessibilityValue(playbackInterfaceMode.localized(with: lang))
            .accessibilityHint(lang.text("选择播放界面模式", "Choose the playback interface mode"))
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { withAnimation(MainContentView.panelSpringAnimation) { isWaveformsVisible.toggle() } } label: {
                Image(systemName: "waveform.path.ecg").studymateToolbarIcon()
            }
                .help(StudyMateShortcutCatalog.help(isWaveformsVisible ? lang.text("隐藏波形图工作区", "Hide waveforms") : lang.text("显示波形图工作区", "Show waveforms"), shortcut: .toggleWaveforms))
                .accessibilityLabel(lang.text("波形图工作区", "Waveform workspace"))
                .accessibilityValue(isWaveformsVisible ? lang.text("已显示", "Shown") : lang.text("已隐藏", "Hidden"))
                .accessibilityHint(lang.text("切换波形图工作区", "Toggle waveform workspace"))
                .accessibilityAddTraits(isWaveformsVisible ? .isSelected : [])
                .keyboardShortcut("w", modifiers: [.option])
            Button { withAnimation(MainContentView.panelSpringAnimation) { isSubtitleEditVisible.toggle() } } label: {
                Image(systemName: "square.and.pencil").studymateToolbarIcon()
            }
                .help(StudyMateShortcutCatalog.help(isSubtitleEditVisible ? lang.text("隐藏字幕双语编辑区", "Hide subtitle editor") : lang.text("显示字幕双语编辑区", "Show subtitle editor"), shortcut: .toggleSubtitleEditor))
                .accessibilityLabel(lang.text("字幕双语编辑区", "Subtitle bilingual editor"))
                .accessibilityValue(isSubtitleEditVisible ? lang.text("已显示", "Shown") : lang.text("已隐藏", "Hidden"))
                .accessibilityHint(lang.text("切换字幕双语编辑区", "Toggle subtitle bilingual editor"))
                .accessibilityAddTraits(isSubtitleEditVisible ? .isSelected : [])
                .keyboardShortcut("s", modifiers: [.option])
            Button(action: onTogglePlaylist) { Image(systemName: "music.note.list").studymateToolbarIcon() }
                .help(StudyMateShortcutCatalog.help(lang.text("显示或隐藏播放列表", "Show or hide playlist"), shortcut: .togglePlaylist))
                .accessibilityLabel(lang.text("播放列表", "Playlist"))
                .accessibilityHint(lang.text("显示或隐藏播放列表", "Show or hide playlist"))
                .keyboardShortcut("p", modifiers: [.option])
            Button { withAnimation(MainContentView.panelSpringAnimation) { isSidebarVisible.toggle() } } label: {
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

    private var currentErrorMessage: String? {
        statusCenter.errorMessage ?? engine.statusErrorMessage ?? libraryManager.lastErrorMessage
    }

    var body: some View {
        HStack(spacing: 10) {
            Label(playbackInterfaceMode.localized(with: lang), systemImage: playbackInterfaceMode.iconName)

            Divider()
                .frame(height: 14)

            Label(currentSegmentText, systemImage: "number")

            Divider()
                .frame(height: 14)
            Label(engine.loopMode.localized(with: lang), systemImage: engine.loopMode.iconName)
                .accessibilityLabel(engine.loopMode.localized(with: lang))

            if abs(engine.playbackRate - 1.0) > 0.001 {
                Divider()
                    .frame(height: 14)
                Label(String(format: "%.2fx", engine.playbackRate), systemImage: "gauge.with.needle")
                    .foregroundColor(StudyMateMediaStyle.accent)
            }

            if engine.repeatCountLimit != 1 {
                Divider()
                    .frame(height: 14)
                Label(repeatCountText, systemImage: "repeat.circle")
            }

            if engine.shadowingPauseRatio > 0 || engine.shadowingPauseSeconds > 0 {
                Divider()
                    .frame(height: 14)
                Label(shadowingText, systemImage: engine.isShadowingPaused ? "mic.fill" : "pause.circle")
                    .foregroundStyle(engine.isShadowingPaused ? StudyMateMediaStyle.success : Color.secondary)
            }

            Spacer(minLength: 8)

            if let successMessage = statusCenter.successMessage {
                StatusBarSuccessView(message: successMessage)
            } else if let progress = currentProgress {
                StatusBarProgressView(
                    progress: progress,
                    canCancel: canCancelCurrentProgress,
                    onCancel: cancelCurrentProgress
                )
            }

            if let currentErrorMessage {
                if currentProgress != nil || statusCenter.successMessage != nil {
                    Divider()
                        .frame(height: 14)
                }
                StatusBarErrorView(
                    message: currentErrorMessage,
                    onDismiss: dismissCurrentError,
                    onResolveProjectRecovery: engine.canUseExistingProject
                        ? onResolveProjectRecovery
                        : nil
                )
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(minHeight: 26)
        .studymateContentSurface(cornerRadius: 0)
        .overlay(
            Rectangle()
                .frame(height: 1)
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

    private func dismissCurrentError() {
        engine.dismissStatusError()
        libraryManager.dismissErrorMessage()
        statusCenter.clearError()
    }
}

private struct StatusBarSuccessView: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(StudyMateMediaStyle.success)
                .font(.system(size: 12, weight: .semibold))

            Text(message)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(.primary)
        }
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
                        .frame(width: 18, height: 18)
                }
                .studymateChromeButton(shape: .circle)
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
    let onResolveProjectRecovery: (() -> Void)?
    @ObservedObject private var lang = LanguageManager.shared

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: isHovering ? .top : .center, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StudyMateMediaStyle.warning)

            Text(message)
                .lineLimit(isHovering ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360, alignment: .leading)
                .layoutPriority(1)

            if let onResolveProjectRecovery {
                Button(lang.text("处理工程", "Handle Project"), action: onResolveProjectRecovery)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(lang.text("选择继续使用原工程或重新断句", "Choose the existing project or re-segment"))
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .frame(width: 18, height: 18)
            }
            .studymateChromeButton(shape: .circle)
            .help(lang.text("关闭提示", "Dismiss message"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, isHovering ? 4 : 0)
        .background(StudyMateMediaStyle.warning.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { isHovering = $0 }
        .help(message)
    }
}

private struct PlaybackLoopModeToolbarPicker: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var lang: LanguageManager

    var body: some View {
        Picker(
            lang.text("播放模式", "Playback mode"),
            selection: Binding(
                get: { engine.loopMode },
                set: { engine.loopMode = $0 }
            )
        ) {
            ForEach(PlaybackLoopMode.allCases) { mode in
                Image(systemName: mode.iconName)
                    .studymateToolbarIcon()
                    .accessibilityLabel(mode.localized(with: lang))
                    .help(StudyMateShortcutCatalog.help(mode.localized(with: lang), shortcut: mode.shortcutID))
                    .tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.regular)
        .help(lang.text("播放模式：连续播放 / 单句重复 / 句后停顿 / 全篇循环（⌘1 / ⌘2 / ⌘3 / ⌘4）", "Playback mode"))
        .accessibilityLabel(lang.text("播放模式", "Playback mode"))
        .accessibilityValue(engine.loopMode.localized(with: lang))
    }
}
