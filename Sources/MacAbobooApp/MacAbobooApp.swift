import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(MacAbobooKit)
import MacAbobooKit
#endif

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var keyMonitor: Any?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard event.keyCode == 49, modifiers.isEmpty else { return event }
            // 输入字幕时空格必须留给文本编辑器，不能误触播放。
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
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
        guard sender.identifier == NSUserInterfaceItemIdentifier("macaboboo-main-window"),
              PlaybackEngine.shared.currentMedia != nil else {
            return true
        }
        NotificationCenter.default.post(name: .macAbobooCloseCurrentMedia, object: nil)
        return false
    }
}

@main
struct MacAbobooApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var languageManager = LanguageManager.shared
    @StateObject private var engine = PlaybackEngine.shared
    @StateObject private var sentenceLibraryManager = SentenceLibraryManager.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("MacAboboo.ShowStatusBar") private var showStatusBar = false
    
    init() {
        UserDefaults.standard.register(defaults: [
            "NSWindowTabbingShouldShowTabBar": false,
            "AppleWindowTabbingMode": "manual"
        ])
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    
    var body: some Scene {
        // 欢迎页是应用定义的第一个窗口场景，因此 macOS 启动时只创建它；
        // 主媒体窗口作为第二个场景，仅在用户打开文件时按需创建。
        WindowGroup(id: "welcome") {
            WelcomeScreenView(
                historyStore: PlaybackHistoryStore.shared,
                onOpen: openFileAction,
                onOpenLibrary: { openWindow(id: "sentence-library") },
                onContinue: openMediaInMain,
                onOpenHistoryItem: openMediaInMain
            )
            .background(WelcomeWindowAccessor())
            .onOpenURL { handleIncomingURL($0) }
        }
        .defaultSize(width: 800, height: 520)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        WindowGroup(id: "main") {
            MainContentView()
                .environmentObject(languageManager)
                .background(WindowAccessor())
                .onOpenURL { handleIncomingURL($0) }
        }
        .defaultSize(width: 1050, height: 720)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentMinSize)
        .commands {
            // 应用菜单：将设置放在 MacAboboo 菜单下，并使用 macOS 标准快捷键 ⌘,
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

            // 文件菜单
            CommandGroup(replacing: .newItem) {
                Button(languageManager.localized(.openFile)) {
                    openFileAction()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            // 显示菜单：控制主窗口底部的紧凑状态栏。
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

            // 移除系统默认的“进入全屏幕”命令，保留最小化和缩放命令。
            CommandGroup(replacing: .sidebar) {
                EmptyView()
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
                    engine.volume = engine.volume > 0 ? 0 : 1.0
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

        Window(languageManager.text("句库", "Sentence Library"), id: "sentence-library") {
            SentenceLibraryView(manager: sentenceLibraryManager)
                .environmentObject(languageManager)
        }
        .defaultSize(width: 980, height: 680)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)

        Window(languageManager.text("快捷键", "Keyboard Shortcuts"), id: "shortcuts") {
            ShortcutHelpView()
        }
        .defaultSize(width: 560, height: 600)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
    }

    private var navigationBookmarks: [SentenceSegment] {
        engine.segments.filter(\.isNavigationBookmarked)
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

    /// 从欢迎页或文件关联打开媒体时，先创建独立的主窗口，再把媒体交给主窗口的引擎。
    private func openMediaInMain(_ url: URL) {
        closeWelcomeWindow()
        openWindow(id: "main")
        DispatchQueue.main.async {
            engine.loadMedia(from: url)
        }
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

    private func closeWelcomeWindow() {
        guard let welcomeWindow = NSApp.windows.first(where: {
            $0.identifier == NSUserInterfaceItemIdentifier("macaboboo-welcome-window")
        }) else { return }
        welcomeWindow.close()
    }
}

/// 主媒体窗口的原生配置。主窗口只在用户打开媒体后创建。
struct WindowAccessor: NSViewRepresentable {
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
        guard let window = window else { return }

        window.title = "MacAboboo"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        window.tabbingMode = .disallowed
        window.identifier = NSUserInterfaceItemIdentifier("macaboboo-main-window")
        window.minSize = NSSize(width: 800, height: 550)
        window.maxSize = NSSize(width: 10000, height: 10000)
        window.showsResizeIndicator = true
        window.isMovableByWindowBackground = false
        window.toolbarStyle = .unifiedCompact
        window.toolbar?.isVisible = true

        // SwiftUI 可能在首帧后重新安装窗口代理，因此每次更新都重新绑定，
        // 保证“文件 > 关闭”和红色关闭按钮都能回到欢迎窗口。
        if let appDelegate = NSApp.delegate as? AppDelegate {
            window.delegate = appDelegate
        }
    }
}

/// 欢迎窗口使用透明标题栏和 full-size content view，让左右两块背景颜色一直延伸到顶部；
/// 交通灯仍保留在标题栏位置。
struct WelcomeWindowAccessor: NSViewRepresentable {
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
        let fixedSize = NSSize(width: 800, height: 520)

        window.title = "MacAboboo"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = true
        window.backgroundColor = NSColor(red: 233.0 / 255.0, green: 233.0 / 255.0, blue: 233.0 / 255.0, alpha: 1.0)
        window.styleMask.insert([.titled, .closable, .miniaturizable, .fullSizeContentView])
        window.styleMask.remove(.resizable)
        window.toolbar?.isVisible = false
        window.minSize = fixedSize
        window.maxSize = fixedSize
        window.showsResizeIndicator = false
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.identifier = NSUserInterfaceItemIdentifier("macaboboo-welcome-window")
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
        window.showsResizeIndicator = true
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed

        window.standardWindowButton(.closeButton)?.isEnabled = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
    }
}
