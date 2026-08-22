import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(MacAbobooKit)
import MacAbobooKit
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
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
}

@main
struct MacAbobooApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var languageManager = LanguageManager.shared
    @StateObject private var engine = PlaybackEngine.shared
    
    init() {
        UserDefaults.standard.register(defaults: [
            "NSWindowTabbingShouldShowTabBar": false,
            "AppleWindowTabbingMode": "manual"
        ])
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    
    var body: some Scene {
        WindowGroup {
            MainContentView()
                .environmentObject(languageManager)
                .background(WindowAccessor())
                .onOpenURL { url in
                    PlaybackEngine.shared.loadMedia(from: url)
                }
        }
        .defaultSize(width: 1050, height: 720)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentMinSize)
        .commands {
            // 文件菜单
            CommandGroup(replacing: .newItem) {
                Button(languageManager.localized(.openFile)) {
                    openFileAction()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            
            // 播放与复读控制菜单
            CommandMenu(languageManager.text("播放控制", "Playback")) {
                Button(engine.isPlaying ? languageManager.localized(.pause) : languageManager.localized(.play)) {
                    engine.togglePlayPause()
                }
                
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
            
            // 解码引擎设置菜单
            CommandMenu(languageManager.localized(.decoderEngine)) {
                Button(action: {
                    engine.setDecoderMode(.system)
                }) {
                    HStack {
                        Text(languageManager.localized(.decoderModeSystem))
                        if engine.decoderMode == .system {
                            Text("✓")
                        }
                    }
                }
                .keyboardShortcut("1", modifiers: [.option, .command])
                
                Button(action: {
                    engine.setDecoderMode(.mpv)
                }) {
                    HStack {
                        Text(languageManager.localized(.decoderModeMPV))
                        if engine.decoderMode == .mpv {
                            Text("✓")
                        }
                    }
                }
                .keyboardShortcut("2", modifiers: [.option, .command])
                
                Button(action: {
                    engine.setDecoderMode(.hybrid)
                }) {
                    HStack {
                        Text(languageManager.localized(.decoderModeHybrid))
                        if engine.decoderMode == .hybrid {
                            Text("✓")
                        }
                    }
                }
                .keyboardShortcut("3", modifiers: [.option, .command])
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
            engine.loadMedia(from: url)
        }
    }
}

/// 原生 NSWindow 尺寸控制与配置注入器
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
        window.toolbarStyle = .unifiedCompact
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        window.minSize = NSSize(width: 800, height: 550)
        window.maxSize = NSSize(width: 10000, height: 10000)
        window.showsResizeIndicator = true
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed

    }
}
