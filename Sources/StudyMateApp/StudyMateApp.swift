import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(StudyMateKit)
import StudyMateKit
#endif

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var keyMonitor: Any?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // 禁止应用启动时自动打开 WindowGroup 主视窗，保证启动只展示欢迎页
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        SentenceLibraryManager.cleanOrphanedTempFiles()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard event.keyCode == 49, modifiers.isEmpty else { return event }
            // 输入字幕、搜索框或在任何输入法/编辑框中时，空格必须留给文本编辑器，不能误触播放。
            if let responder = NSApp.keyWindow?.firstResponder {
                if responder is NSTextView || responder is NSTextField || responder is NSTextInputClient {
                    return event
                }
            }
            PlaybackEngine.shared.togglePlayPause()
            return nil
        }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler {
            Task {
                await SpeechSegmentationPipeline.shared.clearCaches()
                await AudioPCMExtractor.shared.purgeMemoryCache()
                WaveformExtractor.shared.purgeMemoryCache()
                await SpeakerDiarizationEngine.shared.unloadModels()
                await NativeSpeechRuntime.shared.unloadModels()
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        memoryPressureSource?.cancel()
        PlaybackEngine.shared.flushPendingPersistence()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(self)
            }
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    /// 主窗口有媒体时，系统“文件 > 关闭”和红色关闭按钮都只关闭媒体工作区，
    /// 并返回欢迎首屏；首屏本身仍保留 macOS 默认的关闭窗口行为。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.identifier == NSUserInterfaceItemIdentifier("studymate-main-window"),
              PlaybackEngine.shared.currentMedia != nil else {
            return true
        }
        NotificationCenter.default.post(name: .studyMateCloseCurrentMedia, object: nil)
        return false
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        // Let AppKit own the full-screen chrome transition. The system hides
        // the menu bar and unified toolbar together, then reveals them when
        // the pointer reaches the top edge without introducing a competing
        // SwiftUI overlay or an extra event-monitor loop.
        guard window.identifier?.rawValue == "studymate-main-window" else {
            return proposedOptions
        }
        return proposedOptions.union([.autoHideMenuBar, .autoHideToolbar])
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        PlaybackEngine.shared.isFullScreen = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        PlaybackEngine.shared.isFullScreen = false
    }
}

@main
struct StudyMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var languageManager = LanguageManager.shared
    @StateObject private var videoSubtitleSettings = VideoSubtitleSettings.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("StudyMate.ShowStatusBar") private var showStatusBar = true
    @AppStorage("StudyMate.PlaybackInterfaceMode") private var playbackInterfaceMode: PlaybackInterfaceMode = .video
    @AppStorage("StudyMate.ShowSentenceList") private var showSentenceList = true
    @AppStorage("StudyMate.ShowWaveforms") private var showWaveforms = true
    @AppStorage("StudyMate.ShowSecondaryWaveform") private var showSecondaryWaveform = true
    @AppStorage("StudyMate.ShowSubtitleEditor") private var showSubtitleEditor = true
    @AppStorage("StudyMate.ShowPlaylist") private var showPlaylist = false
    @AppStorage("StudyMate.SegmentFollowsPlayback") private var segmentFollowsPlayback = true

    @ObservedObject private var engine = PlaybackEngine.shared
    
    init() {
        UserDefaults.standard.register(defaults: [
            "NSWindowTabbingShouldShowTabBar": false,
            "AppleWindowTabbingMode": "manual",
            "StudyMate.ShowStatusBar": true,
            "StudyMate.ShowSecondaryWaveform": true,
            "StudyMate.SegmentFollowsPlayback": true
        ])
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    
    var body: some Scene {
        // 欢迎页是应用定义的第一个窗口场景，因此 macOS 启动时只创建它；
        // 主媒体窗口作为第二个场景，仅在用户打开文件时按需创建。
        Window(languageManager.text("学伴", "StudyMate"), id: "welcome") {
            WelcomeScreenView(
                historyStore: PlaybackHistoryStore.shared,
                onOpen: openFileAction,
                onOpenLibrary: { openWindow(id: "sentence-library") },
                onOpenHistoryItem: openMediaInMain,
                onRemoveHistoryItem: { url in
                    Task { await engine.removeFromPlaybackHistory(url) }
                },
                onClearHistory: {
                    Task { await engine.clearPlaybackHistory() }
                }
            )
            .background(WelcomeWindowAccessor())
            .onOpenURL { handleIncomingURL($0) }
        }
        .defaultSize(width: 800, height: 520)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        WindowGroup(languageManager.text("学伴", "StudyMate"), id: "main") {
            MainContentView(onWindowDidAppear: dismissWelcomeWindow)
                .environmentObject(languageManager)
                .background(WindowAccessor())
                .onOpenURL { handleIncomingURL($0) }
                .modifier(MainWindowToolbarFullScreenVisibilityModifier())
        }
        .defaultSize(width: 1050, height: 720)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentMinSize)
        .commands {
            // 应用菜单：将设置放在 StudyMate 菜单下，并使用 macOS 标准快捷键 ⌘,
            CommandGroup(after: .appInfo) {
                Button(languageManager.text("设置", "Settings")) {
                    openWindow(id: "settings")
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            // 帮助菜单：打开可搜索的两列快捷键总览窗口。
            CommandGroup(after: .help) {
                Button(languageManager.text("快捷键…", "Keyboard Shortcuts…")) {
                    openWindow(id: "shortcuts")
                }
            }

            // 独立词典窗口：不让词典初始化拖慢欢迎页或媒体窗口的冷启动。
            CommandGroup(after: .windowArrangement) {
                Button(languageManager.text("打开词典…", "Open Dictionary…")) {
                    openDictionaryAction()
                }
                .keyboardShortcut("d", modifiers: [.command, .control])

                Button(languageManager.text("打开句库…", "Open Sentence Library…")) {
                    openWindow(id: "sentence-library")
                }
                .keyboardShortcut("l", modifiers: [.command])

                Button(languageManager.text("打开生词本…", "Open Vocabulary…")) {
                    openWindow(id: "vocabulary")
                }
            }

            // 文件菜单
            CommandGroup(replacing: .newItem) {
                Button(languageManager.localized(.openFile)) {
                    openFileAction()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(replacing: .saveItem) {
                Button(languageManager.text("关闭", "Close")) {
                    closeCurrentMediaAction()
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(engine.currentMedia == nil)
            }

            // 显示菜单：集中管理工具栏中的字幕、工作区和界面模式按钮。
            CommandGroup(after: .toolbar) {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        showStatusBar.toggle()
                    }
                } label: {
                    HStack {
                        Text(languageManager.text("显示状态栏", "Show Status Bar"))
                        if showStatusBar {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Menu {
                    ForEach(PlaybackInterfaceMode.allCases) { mode in
                        Button {
                            playbackInterfaceMode = mode
                        } label: {
                            HStack {
                                Label(mode.localized(with: languageManager), systemImage: mode.iconName)
                                if playbackInterfaceMode == mode {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label(languageManager.text("界面模式", "Interface Mode"), systemImage: playbackInterfaceMode.iconName)
                }

                Divider()

                Button {
                    videoSubtitleSettings.toggleOriginal(for: playbackInterfaceMode)
                } label: {
                    HStack {
                        Text(videoSubtitleSettings.isOriginalVisible(for: playbackInterfaceMode)
                             ? languageManager.text("隐藏画面原文字幕", "Hide Original Subtitles")
                             : languageManager.text("显示画面原文字幕", "Show Original Subtitles"))
                        if videoSubtitleSettings.isOriginalVisible(for: playbackInterfaceMode) {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Button {
                    videoSubtitleSettings.toggleTranslation(for: playbackInterfaceMode)
                } label: {
                    HStack {
                        Text(videoSubtitleSettings.isTranslationVisible(for: playbackInterfaceMode)
                             ? languageManager.text("隐藏画面译文字幕", "Hide Translated Subtitles")
                             : languageManager.text("显示画面译文字幕", "Show Translated Subtitles"))
                        if videoSubtitleSettings.isTranslationVisible(for: playbackInterfaceMode) {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Button(languageManager.text("字幕字体设置…", "Subtitle Font Settings…")) {
                    openWindow(id: "subtitle-font-settings")
                }

                Divider()

                Menu {
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            showWaveforms.toggle()
                        }
                    } label: {
                        HStack {
                            Text(showWaveforms
                                 ? languageManager.text("隐藏波形图", "Hide Waveforms")
                                 : languageManager.text("显示波形图", "Show Waveforms"))
                            if showWaveforms {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .keyboardShortcut("w", modifiers: [.option])

                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            showSecondaryWaveform.toggle()
                        }
                    } label: {
                        HStack {
                            Text(showSecondaryWaveform
                                 ? languageManager.text("隐藏次波形图", "Hide Secondary Waveform")
                                 : languageManager.text("显示次波形图", "Show Secondary Waveform"))
                            if showSecondaryWaveform {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .keyboardShortcut("w", modifiers: [.option, .shift])
                    .disabled(!showWaveforms)
                } label: {
                    Text(languageManager.text("波形图", "Waveforms"))
                }

                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        showSubtitleEditor.toggle()
                    }
                } label: {
                    HStack {
                        Text(showSubtitleEditor
                             ? languageManager.text("隐藏字幕编辑区", "Hide Subtitle Editor")
                             : languageManager.text("显示字幕编辑区", "Show Subtitle Editor"))
                        if showSubtitleEditor {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Button {
                    NotificationCenter.default.post(name: .studyMateTogglePlaylist, object: nil)
                } label: {
                    HStack {
                        Text(showPlaylist
                             ? languageManager.text("隐藏播放列表", "Hide Playlist")
                             : languageManager.text("显示播放列表", "Show Playlist"))
                        if showPlaylist {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        showSentenceList.toggle()
                    }
                } label: {
                    HStack {
                        Text(showSentenceList
                             ? languageManager.text("隐藏断句列表", "Hide Sentence List")
                             : languageManager.text("显示断句列表", "Show Sentence List"))
                        if showSentenceList {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Menu {
                    if navigationBookmarks.isEmpty {
                        Text(languageManager.text("暂无书签", "No bookmarks"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(navigationBookmarks) { segment in
                            Button {
                                engine.jumpToSegment(id: segment.id)
                            } label: {
                                Label("#\(segment.index)", systemImage: "bookmark.fill")
                            }
                        }
                    }
                } label: {
                    Label(languageManager.text("书签", "Bookmarks"), systemImage: "bookmark")
                }
            }
            
            // 断句菜单：集中管理断句模式、生成、翻译、导入导出、句库、跟随、筛选与单句编辑
            CommandMenu(languageManager.text("断句", "Sentence")) {
                Menu {
                    Button {
                        engine.performSegmentation(mode: .fast)
                    } label: {
                        Label(languageManager.text("快速断句", "Fast Segmentation"), systemImage: "bolt.fill")
                    }
                    .keyboardShortcut("1", modifiers: [.control, .command])
                    .disabled(engine.currentMedia == nil || engine.isAITranscribing)

                    Button {
                        engine.performSegmentation(mode: .intelligent)
                    } label: {
                        Label(languageManager.text("智能断句", "Intelligent Segmentation"), systemImage: "wand.and.stars")
                    }
                    .keyboardShortcut("2", modifiers: [.control, .command])
                    .disabled(engine.currentMedia == nil || engine.isAITranscribing)
                } label: {
                    Label(languageManager.text("断句模式", "Segmentation Mode"), systemImage: "scissors")
                }

                Button {
                    ensureSentenceListVisible()
                    NotificationCenter.default.post(name: .studyMateRegenerateOriginal, object: nil)
                } label: {
                    Label(languageManager.text("重新生成原文…", "Regenerate Original Text…"), systemImage: "waveform.and.mic")
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(engine.currentMedia == nil || engine.segments.isEmpty || engine.isAITranscribing || engine.isAutoTranslating)

                Button {
                    ensureSentenceListVisible()
                    NotificationCenter.default.post(name: .studyMateTranslateSentences, object: nil)
                } label: {
                    Label(languageManager.text("翻译句子…", "Translate Sentences…"), systemImage: "translate")
                }
                .keyboardShortcut("t", modifiers: [.command])
                .disabled(engine.currentMedia == nil || engine.segments.isEmpty)

                Button {
                    ensureSentenceListVisible()
                    NotificationCenter.default.post(name: .studyMateImportSubtitles, object: nil)
                } label: {
                    Label(languageManager.text("导入字幕…", "Import Subtitles…"), systemImage: "arrow.down.doc")
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(engine.currentMedia == nil)

                Menu {
                    Button {
                        ensureSentenceListVisible()
                        NotificationCenter.default.post(name: .studyMateExportSeparate, object: nil)
                    } label: {
                        Label(languageManager.text("逐句导出 M4A 与 LRC/SRT…", "Export Separate M4A and LRC/SRT…"), systemImage: "doc.on.doc")
                    }
                    .keyboardShortcut("e", modifiers: [.command])
                    .disabled(engine.currentMedia == nil || engine.segments.isEmpty)

                    Button {
                        ensureSentenceListVisible()
                        NotificationCenter.default.post(name: .studyMateExportMerged, object: nil)
                    } label: {
                        Label(languageManager.text("合并导出 M4A 与 LRC/SRT…", "Export Merged M4A and LRC/SRT…"), systemImage: "rectangle.stack")
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(engine.currentMedia == nil || engine.segments.isEmpty)
                } label: {
                    Label(languageManager.text("导出已选句子", "Export Selected Sentences"), systemImage: "square.and.arrow.up")
                }
                .disabled(engine.currentMedia == nil || engine.segments.isEmpty)

                Button {
                    ensureSentenceListVisible()
                    NotificationCenter.default.post(name: .studyMateAddToLibrary, object: nil)
                } label: {
                    Label(languageManager.text("加入句库", "Add to Sentence Library"), systemImage: "text.badge.plus")
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(engine.currentMedia == nil || engine.segments.isEmpty)

                Divider()

                Button {
                    segmentFollowsPlayback.toggle()
                    NotificationCenter.default.post(name: .studyMateToggleFollowSentence, object: segmentFollowsPlayback)
                } label: {
                    HStack {
                        Text(languageManager.text("播放时自动跟随当前句", "Follow Active Sentence During Playback"))
                        if segmentFollowsPlayback {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button {
                    ensureSentenceListVisible()
                    NotificationCenter.default.post(name: .studyMateToggleSentenceFilter, object: nil)
                } label: {
                    Label(languageManager.text("筛选与搜索句子…", "Filter and Search Sentences…"), systemImage: "line.3.horizontal.decrease.circle")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(engine.currentMedia == nil || engine.segments.isEmpty)

                Button {
                    ensureSentenceListVisible()
                    NotificationCenter.default.post(name: .studyMateSelectAllVisibleSentences, object: nil)
                } label: {
                    Label(languageManager.text("全选当前显示句子", "Select All Visible Sentences"), systemImage: "checkmark.circle")
                }
                .keyboardShortcut("a", modifiers: [.command])
                .disabled(engine.currentMedia == nil || engine.segments.isEmpty)

                Button {
                    ensureSentenceListVisible()
                    NotificationCenter.default.post(name: .studyMateInvertVisibleSentenceSelection, object: nil)
                } label: {
                    Label(languageManager.text("反选当前显示句子", "Invert Visible Sentence Selection"), systemImage: "arrow.2.squarepath")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(engine.currentMedia == nil || engine.segments.isEmpty)

                Divider()

                Button {
                    ensureSentenceListVisible()
                    NotificationCenter.default.post(name: .studyMateEditActiveSentence, object: nil)
                } label: {
                    Label(languageManager.text("编辑当前句原文和译文…", "Edit Current Sentence…"), systemImage: "pencil")
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(activeSegment == nil)

                Button {
                    if let seg = activeSegment {
                        engine.splitSegment(id: seg.id, at: (seg.startTime + seg.endTime) / 2.0)
                        MainStatusCenter.shared.showSuccess(languageManager.text("已拆分当前句", "Current sentence split"))
                    }
                } label: {
                    Label(languageManager.text("拆分当前句", "Split Current Sentence"), systemImage: "scissors")
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(activeSegment == nil)

                Button {
                    if let seg = activeSegment {
                        engine.mergeSegmentWithPrevious(id: seg.id)
                        MainStatusCenter.shared.showSuccess(languageManager.text("已合并上一句", "Merged with previous sentence"))
                    }
                } label: {
                    Label(languageManager.text("合并上一句", "Merge with Previous Sentence"), systemImage: "arrow.up.and.line.horizontal.and.arrow.down")
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!engine.canMergeActiveSegmentWithPrevious)

                Button {
                    if let seg = activeSegment {
                        engine.mergeSegmentWithNext(id: seg.id)
                        MainStatusCenter.shared.showSuccess(languageManager.text("已合并下一句", "Merged with next sentence"))
                    }
                } label: {
                    Label(languageManager.text("合并下一句", "Merge with Next Sentence"), systemImage: "arrow.down.and.line.horizontal.and.arrow.up")
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!engine.canMergeActiveSegmentWithNext)

                Divider()

                Button {
                    if let seg = activeSegment {
                        let willBeBookmarked = !seg.isNavigationBookmarked
                        engine.toggleNavigationBookmark(for: seg.id)
                        MainStatusCenter.shared.showSuccess(
                            willBeBookmarked
                                ? languageManager.text("已加入书签", "Bookmark added")
                                : languageManager.text("已移出书签", "Bookmark removed")
                        )
                    }
                } label: {
                    Label(
                        activeSegment?.isNavigationBookmarked == true
                            ? languageManager.text("移出当前句书签", "Remove Current Sentence Bookmark")
                            : languageManager.text("加入当前句书签", "Add Current Sentence Bookmark"),
                        systemImage: activeSegment?.isNavigationBookmarked == true ? "bookmark.fill" : "bookmark"
                    )
                }
                .keyboardShortcut("b", modifiers: [.command])
                .disabled(activeSegment == nil)

                Button {
                    if let seg = activeSegment {
                        let willBeBookmarked = !seg.isBookmarked
                        engine.toggleBookmark(for: seg.id)
                        MainStatusCenter.shared.showSuccess(
                            willBeBookmarked
                                ? languageManager.text("已标为难句", "Marked as difficult")
                                : languageManager.text("已取消难句标记", "Removed difficulty mark")
                        )
                    }
                } label: {
                    Label(
                        activeSegment?.isBookmarked == true
                            ? languageManager.text("取消难句星标", "Remove Difficulty Star")
                            : languageManager.text("标为难句", "Mark as Difficult"),
                        systemImage: activeSegment?.isBookmarked == true ? "star.fill" : "star"
                    )
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(activeSegment == nil)

                Button {
                    if let seg = activeSegment {
                        engine.deleteSegment(id: seg.id)
                        MainStatusCenter.shared.showSuccess(languageManager.text("已删除当前句", "Current sentence deleted"))
                    }
                } label: {
                    Label(languageManager.text("删除当前句", "Delete Current Sentence"), systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(activeSegment == nil)
            }
            
            // 播放与复读控制菜单
            CommandMenu(languageManager.text("播放控制", "Playback")) {
                Button(engine.isPlaying ? languageManager.localized(.pause) : languageManager.localized(.play)) {
                    engine.togglePlayPause()
                }
                
                Divider()

                // 四种播放模式使用固定快捷键，和工具栏分段选择器保持一致。
                Button {
                    engine.loopMode = .normal
                } label: {
                    Label(
                        languageManager.text("连续播放", "Continuous Play"),
                        systemImage: PlaybackLoopMode.normal.iconName
                    )
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button {
                    engine.loopMode = .singleSegment
                } label: {
                    Label(
                        languageManager.text("单句重复", "Repeat Sentence"),
                        systemImage: PlaybackLoopMode.singleSegment.iconName
                    )
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button {
                    engine.loopMode = .pauseAfterSegment
                } label: {
                    Label(
                        languageManager.text("句后停顿", "Pause After Sentence"),
                        systemImage: PlaybackLoopMode.pauseAfterSegment.iconName
                    )
                }
                .keyboardShortcut("3", modifiers: [.command])

                Button {
                    engine.loopMode = .all
                } label: {
                    Label(
                        languageManager.text("全篇循环", "Loop Entire File"),
                        systemImage: PlaybackLoopMode.all.iconName
                    )
                }
                .keyboardShortcut("4", modifiers: [.command])

                Button {
                    engine.toggleMute()
                } label: {
                    Label(
                        languageManager.text("静音 / 取消静音", "Mute / Unmute"),
                        systemImage: engine.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
                    )
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Divider()
                
                Button(languageManager.localized(.previousSentence)) {
                    engine.previousSegment()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                
                Button(languageManager.localized(.nextSentence)) {
                    engine.nextSegment()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                
                Button(languageManager.localized(.repeatSentence)) {
                    engine.repeatCurrentSegment()
                }
                .keyboardShortcut("r", modifiers: [.command])
                
                Divider()
                
                Button(languageManager.text("加速（+0.1x）", "Speed Up (+0.1x)")) {
                    let current = engine.playbackRate
                    let next = round((current + 0.1) * 10) / 10
                    engine.playbackRate = min(2.0, next)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])
                
                Button(languageManager.text("减速（-0.1x）", "Slow Down (-0.1x)")) {
                    let current = engine.playbackRate
                    let next = round((current - 0.1) * 10) / 10
                    engine.playbackRate = max(0.5, next)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])
                
                Button(languageManager.text("重置为原速（1.0x）", "Reset Speed (1.0x)")) {
                    engine.playbackRate = 1.0
                }
                .keyboardShortcut("0", modifiers: [.command])

                Divider()

                Menu(languageManager.text("单句复读次数", "Sentence Repeat Count")) {
                    ForEach([1, 2, 3, 5, 7, 10, 20, 0], id: \.self) { count in
                        Button {
                            engine.repeatCountLimit = count
                            engine.currentRepeatCount = 1
                        } label: {
                            let label = count == 0 ? languageManager.text("无限", "Unlimited") : String(count) + "×"
                            if engine.repeatCountLimit == count {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                }

                Menu(languageManager.text("句末跟读停顿", "Shadowing Pause")) {
                    Button {
                        engine.setShadowingPauseRatio(0)
                    } label: {
                        if engine.shadowingPauseRatio == 0 && engine.shadowingPauseSeconds == 0 {
                            Label(languageManager.text("关闭", "Off"), systemImage: "checkmark")
                        } else {
                            Text(languageManager.text("关闭", "Off"))
                        }
                    }

                    Divider()

                    ForEach([1, 2, 3, 5], id: \.self) { seconds in
                        Button {
                            engine.setShadowingPauseSeconds(Double(seconds))
                        } label: {
                            if abs(engine.shadowingPauseSeconds - Double(seconds)) < 0.001 {
                                Label(String(seconds) + "s", systemImage: "checkmark")
                            } else {
                                Text(String(seconds) + "s")
                            }
                        }
                    }

                    Divider()

                    ForEach([0.25, 0.5, 0.75, 1.0, 1.5, 2.0], id: \.self) { ratio in
                        let label = String(format: "%.2g×", ratio)
                        Button {
                            engine.setShadowingPauseRatio(ratio)
                        } label: {
                            if engine.shadowingPauseSeconds == 0 && abs(engine.shadowingPauseRatio - ratio) < 0.001 {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                }

                Menu(languageManager.text("播放速度", "Playback Speed")) {
                    ForEach([0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0] as [Float], id: \.self) { speed in
                        Button {
                            engine.playbackRate = speed
                        } label: {
                            let label = String(format: "%.2fx", speed)
                            if abs(engine.playbackRate - speed) < 0.01 {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                    Divider()
                    Button {
                        engine.playbackRate = 1.0
                    } label: {
                        Label(languageManager.text("恢复原速", "Reset to Original Speed"), systemImage: "arrow.counterclockwise")
                    }
                }
            }
            
        }

        // 独立设置窗口：不使用 sheet，允许设置窗口与主窗口并行存在，
        // 且不设置 floating level，避免强制置顶遮挡其它应用。
        Window(languageManager.text("设置", "Settings"), id: "settings") {
            IntensiveSettingsPopover(engine: engine)
                .background(SettingsWindowAccessor())
        }
        .defaultSize(width: 960, height: 720)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)

        Window(languageManager.text("字幕字体设置", "Subtitle Font Settings"), id: "subtitle-font-settings") {
            VideoSubtitleFontSettingsPopover(initialMode: playbackInterfaceMode)
        }
        .defaultSize(width: 470, height: 520)
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)

        Window(languageManager.text("句库", "Sentence Library"), id: "sentence-library") {
            // 句库窗口独立按需创建；欢迎页启动时不读取数据库或创建默认句库。
            SentenceLibraryView(manager: SentenceLibraryManager.shared)
                .environmentObject(languageManager)
        }
        .defaultSize(width: 980, height: 680)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)

        Window(languageManager.text("生词本", "Vocabulary"), id: "vocabulary") {
            VocabularyNotebookView(manager: VocabularyNotebookManager.shared)
                .environmentObject(languageManager)
        }
        .defaultSize(width: 980, height: 640)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)

        Window(languageManager.text("快捷键", "Keyboard Shortcuts"), id: "shortcuts") {
            ShortcutHelpView()
        }
        .defaultSize(width: 560, height: 600)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)

        // 词典是独立窗口，仅在用户打开时启动独立引擎并读取词典索引。
        Window(languageManager.text("词典", "Dictionary"), id: "dictionary") {
            DictionaryView()
                .environmentObject(languageManager)
                .background(DictionaryInitialFocusAccessor())
        }
        .defaultSize(width: 1000, height: 680)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)

        // 词典来源设置使用独立原生窗口，和 macOS Dictionary 的参考源设置体验一致。
        Window(languageManager.text("词典设置", "Dictionary Settings"), id: "dictionary-settings") {
            DictionarySourceSettingsWindowView()
                .environmentObject(languageManager)
        }
        .defaultSize(width: 560, height: 520)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
    }

    private var navigationBookmarks: [SentenceSegment] {
        engine.segments.filter(\.isNavigationBookmarked)
    }

    private var activeSegment: SentenceSegment? {
        engine.activeSegment
    }

    private func ensureSentenceListVisible() {
        if !showSentenceList {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                showSentenceList = true
            }
        }
    }
    
    private func openFileAction() {
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
            openMediaInMain(url)
        }
    }

    /// 从欢迎页或文件关联打开媒体时，先把媒体交给主窗口的引擎，再创建独立的主窗口。
    /// 欢迎窗口由主窗口首帧出现时通过场景级 dismissWindow 销毁。
    private func openMediaInMain(_ url: URL) {
        engine.loadMedia(from: url)
        openWindow(id: "main")
    }

    private func handleIncomingURL(_ url: URL) {
        if url.pathExtension.lowercased() == "mablib" {
            MainStatusCenter.shared.showError(
                languageManager.text(
                    "句库仅支持从断句列表加入句子。",
                    "Sentence libraries only accept sentences added from the segment list."
                )
            )
        } else {
            openMediaInMain(url)
        }
    }

    private func dismissWelcomeWindow() {
        dismissWindow(id: "welcome")
    }

    private func closeCurrentMediaAction() {
        if engine.currentMedia != nil {
            NotificationCenter.default.post(name: .studyMateCloseCurrentMedia, object: nil)
        } else if let keyWindow = NSApp.keyWindow {
            keyWindow.performClose(nil)
        }
    }

    private func openDictionaryAction() {
        let coordinator = DictionaryInteractionCoordinator.shared
        _ = coordinator.captureCurrentSelectionForDictionary()
        if let query = coordinator.selectedText, !query.isEmpty {
            coordinator.bindPlaybackEngine(engine)
            coordinator.pausePlaybackForVideoSubtitleSelection()
        }
        // The menu can be invoked while only the welcome window exists, so
        // there may be no MainContentView subscriber for the notification.
        // Open the scene directly here; toolbar/popover callers still use the
        // notification path owned by the media window.
        coordinator.openDictionaryWindow(postNotification: false)
        openWindow(id: "dictionary")
    }
}

private struct MainWindowToolbarFullScreenVisibilityModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.windowToolbarFullScreenVisibility(.onHover)
    }
}

/// Gives the standalone dictionary window an immediately usable initial
/// focus. SwiftUI installs the searchable field lazily, so the accessor waits
/// briefly for the toolbar before assigning the first responder.
struct DictionaryInitialFocusAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DictionaryInitialFocusView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DictionaryInitialFocusView: NSView {
    private weak var observedWindow: NSWindow?
    private var keyWindowObserver: NSObjectProtocol?
    private var didFocusInitialSearch = false
    private var focusAttempt = 0

    deinit {
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
            self.keyWindowObserver = nil
        }
        guard let window else {
            observedWindow = nil
            didFocusInitialSearch = false
            focusAttempt = 0
            return
        }
        observedWindow = window
        didFocusInitialSearch = false
        focusAttempt = 0
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window, self.observedWindow === window else { return }
            self.focusAttempt = 0
            self.focusInitialSearch(on: window)
        }
        focusInitialSearch(on: window)
    }

    private func focusInitialSearch(on window: NSWindow) {
        guard !didFocusInitialSearch, focusAttempt < 50 else { return }
        focusAttempt += 1

        // SwiftUI may install the toolbar search field several run loops
        // after the content view is attached. The retry is short and bounded
        // so later user focus is never taken back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak window] in
            guard let self,
                  let window,
                  self.observedWindow === window,
                  !self.didFocusInitialSearch else { return }

            if let searchField = self.searchField(in: window) {
                window.initialFirstResponder = searchField
                if window.makeFirstResponder(searchField) || window.firstResponder === searchField {
                    self.didFocusInitialSearch = true
                } else {
                    self.focusInitialSearch(on: window)
                }
            } else {
                self.focusInitialSearch(on: window)
            }
        }
    }

    private func searchField(in window: NSWindow) -> NSSearchField? {
        let toolbarItems = window.toolbar?.items ?? []
        for item in toolbarItems {
            if let searchToolbarItem = item as? NSSearchToolbarItem {
                return searchToolbarItem.searchField
            }
        }

        var roots = toolbarItems.compactMap(\.view)
        if let contentView = window.contentView {
            roots.append(contentView)
        }
        return roots.lazy.compactMap { self.searchField(in: $0) }.first
    }

    private func searchField(in view: NSView) -> NSSearchField? {
        if let searchField = view as? NSSearchField {
            return searchField
        }
        for subview in view.subviews {
            if let searchField = searchField(in: subview) {
                return searchField
            }
        }
        return nil
    }
}

/// 主媒体窗口的原生配置。主窗口只在用户打开媒体后创建。
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowAccessorView {
        MainWindowAccessorView(frame: .zero)
    }

    func updateNSView(_ nsView: MainWindowAccessorView, context: Context) {
        Self.configureWindow(nsView.window)
    }

    static func configureWindow(_ window: NSWindow?) {
        guard let window = window else { return }

        // SwiftUI can update the representable while AppKit is animating a
        // native title-bar zoom.  Only assign a window property when its value
        // is actually different; repeatedly mutating style/toolbar state here
        // can trigger extra layout passes during every zoom frame.
        let appName = LanguageManager.shared.text("学伴", "StudyMate")
        if window.title != appName { window.title = appName }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = false }
        if window.styleMask.contains(.fullScreen) {
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
        } else {
            if window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.remove(.fullSizeContentView)
            }
        }
        for style in [NSWindow.StyleMask.titled, .closable, .miniaturizable, .resizable]
            where !window.styleMask.contains(style) {
            window.styleMask.insert(style)
        }
        if window.collectionBehavior.contains(.fullScreenNone)
            || window.collectionBehavior.contains(.fullScreenAuxiliary)
            || !window.collectionBehavior.contains(.fullScreenPrimary) {
            window.collectionBehavior.remove([.fullScreenNone, .fullScreenAuxiliary])
            window.collectionBehavior.insert([.fullScreenPrimary, .managed, .participatesInCycle])
        }
        if window.standardWindowButton(.zoomButton)?.isEnabled == false {
            window.standardWindowButton(.zoomButton)?.isEnabled = true
        }
        if window.tabbingMode != .disallowed { window.tabbingMode = .disallowed }
        let identifier = NSUserInterfaceItemIdentifier("studymate-main-window")
        if window.identifier != identifier { window.identifier = identifier }
        if window.minSize.width != 800 || window.minSize.height != 550 {
            window.minSize = NSSize(width: 800, height: 550)
        }
        if window.maxSize.width != 10000 || window.maxSize.height != 10000 {
            window.maxSize = NSSize(width: 10000, height: 10000)
        }
        if window.isMovableByWindowBackground { window.isMovableByWindowBackground = false }
        if window.toolbarStyle != .unifiedCompact { window.toolbarStyle = .unifiedCompact }
        // 全屏时由 AppKit/SwiftUI 的悬停策略接管工具栏可见性；如果这里
        // 强制设回 true，会抵消系统的隐藏动画。非全屏时保持工具栏可见。
        if !window.styleMask.contains(.fullScreen),
           let toolbar = window.toolbar,
           !toolbar.isVisible {
            toolbar.isVisible = true
        }

        if let appDelegate = NSApp.delegate as? AppDelegate,
           window.delegate !== appDelegate {
            window.delegate = appDelegate
        }
    }
}

/// Observes the main media window's native zoom/resize lifecycle.  The
/// observer does not alter the window frame; it only asks PlaybackEngine to
/// lower presentation refresh work while AppKit is animating the frame.
final class MainWindowAccessorView: NSView {
    private weak var observedWindow: NSWindow?
    private var notificationTokens: [NSObjectProtocol] = []
    private var resizeEndWorkItem: DispatchWorkItem?
    private var isResizeActive = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            attach(to: window)
            WindowAccessor.configureWindow(window)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let window, self?.observedWindow === window else { return }
                WindowAccessor.configureWindow(window)
            }
        } else {
            removeObservers()
        }
    }

    private func attach(to window: NSWindow) {
        guard observedWindow !== window else { return }
        removeObservers()
        observedWindow = window
        PlaybackEngine.shared.isFullScreen = window.styleMask.contains(.fullScreen)

        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                WindowAccessor.configureWindow(window)
            },
            center.addObserver(
                forName: NSWindow.didBecomeMainNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                WindowAccessor.configureWindow(window)
            },
            center.addObserver(
                forName: NSWindow.willStartLiveResizeNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let window, !window.styleMask.contains(.fullScreen) else { return }
                self?.beginResize()
            },
            center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                // Standard title-bar zoom does not consistently emit the live
                // resize pair on every macOS release. didResize is therefore
                // also treated as resize intent and debounced below.
                // 在全屏模式下工具栏自动显隐会微调内容安全区，不属于用户拉伸窗口，
                // 忽略全屏下的 didResize，避免误触发 isWindowResizing 导致动画被置空卡顿。
                guard let window, !window.styleMask.contains(.fullScreen) else { return }
                self?.beginResize()
            },
            center.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let window, !window.styleMask.contains(.fullScreen) else { return }
                self?.scheduleResizeEnd(after: 0.06)
            },
            center.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                WindowAccessor.configureWindow(window)
                Task { @MainActor in
                    PlaybackEngine.shared.isFullScreen = true
                }
            },
            center.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                WindowAccessor.configureWindow(window)
                Task { @MainActor in
                    PlaybackEngine.shared.isFullScreen = false
                }
            }
        ]
    }

    private func beginResize() {
        if !isResizeActive {
            isResizeActive = true
            PlaybackEngine.shared.setWindowResizing(true)
        }
        scheduleResizeEnd(after: 0.16)
    }

    private func scheduleResizeEnd(after delay: TimeInterval) {
        resizeEndWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resizeEndWorkItem = nil
            guard self.isResizeActive else { return }
            self.isResizeActive = false
            PlaybackEngine.shared.setWindowResizing(false)
        }
        resizeEndWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func removeObservers() {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll(keepingCapacity: true)
        resizeEndWorkItem?.cancel()
        resizeEndWorkItem = nil
        observedWindow = nil
        if isResizeActive {
            isResizeActive = false
            PlaybackEngine.shared.setWindowResizing(false)
        }
    }

    deinit {
        removeObservers()
    }
}

/// 欢迎窗口使用透明标题栏和 full-size content view，让左右两块背景颜色一直延伸到顶部；
/// 交通灯仍保留在标题栏位置。
struct WelcomeWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> WelcomeWindowAccessorView {
        WelcomeWindowAccessorView(frame: .zero)
    }

    func updateNSView(_ nsView: WelcomeWindowAccessorView, context: Context) {
        Self.configureWindow(nsView.window)
    }

    static func configureWindow(_ window: NSWindow?) {
        guard let window else { return }
        let fixedSize = NSSize(width: 800, height: 520)

        window.title = LanguageManager.shared.text("学伴", "StudyMate")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.styleMask.insert([.titled, .closable, .miniaturizable, .fullSizeContentView])
        window.styleMask.remove(.resizable)
        window.toolbar?.isVisible = false
        window.minSize = fixedSize
        window.maxSize = fixedSize
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.identifier = NSUserInterfaceItemIdentifier("studymate-welcome-window")
        window.standardWindowButton(.closeButton)?.isEnabled = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = true
        // 欢迎页尺寸固定，因此最大化按钮保留位置但不可执行。
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        if abs(window.contentRect(forFrameRect: window.frame).width - fixedSize.width) > 1
            || abs(window.contentRect(forFrameRect: window.frame).height - fixedSize.height) > 1 {
            window.setContentSize(fixedSize)
        }
    }
}

final class WelcomeWindowAccessorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            WelcomeWindowAccessor.configureWindow(window)
        }
    }
}

/// 设置窗口的原生窗口配置：保留标准三色按钮，但只允许关闭。
/// 不设置 floating level，设置窗口可以被其它窗口正常覆盖。
struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            configureWindow(view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(nsView.window)
    }

    private func configureWindow(_ window: NSWindow?) {
        guard let window else { return }

        window.titleVisibility = .visible
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        window.level = .normal
        window.minSize = NSSize(width: 880, height: 640)
        window.maxSize = NSSize(width: 1400, height: 1200)
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed

        window.standardWindowButton(.closeButton)?.isEnabled = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
    }
}
