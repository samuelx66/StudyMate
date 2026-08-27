import SwiftUI
import AppKit

/// 底部精听与复读状态控制栏（精简高质设计）
public struct PlaybackControlView: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var lang = LanguageManager.shared
    
    public init(engine: PlaybackEngine) {
        self.engine = engine
    }
    
    public var body: some View {
        HStack(spacing: 12) {
            // 1. 复读模式选择器
            Menu {
                ForEach(PlaybackLoopMode.allCases) { mode in
                    Button(action: { engine.loopMode = mode }) {
                        Label(mode.localized(with: lang), systemImage: mode.iconName)
                    }
                    .help(MacAbobooShortcutCatalog.help(
                        mode.localized(with: lang),
                        shortcut: mode.shortcutID
                    ))
                }
            } label: {
                Label(engine.loopMode.localized(with: lang), systemImage: engine.loopMode.iconName)
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(lang.text(
                "播放模式：连续播放 / 单句重复 / 句后停顿 / 全篇循环（⌘1 / ⌘2 / ⌘3 / ⌘4）",
                "Playback mode: Continuous Play / Repeat Sentence / Pause After Sentence / Loop Entire File (⌘1 / ⌘2 / ⌘3 / ⌘4)"
            ))
            
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .macabobooContentSurface(cornerRadius: 0)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(MacAbobooMediaStyle.separator),
            alignment: .top
        )
    }
}

#Preview("播放控制栏") {
    PlaybackControlView(engine: PlaybackEngine.shared)
        .frame(width: 800)
}
