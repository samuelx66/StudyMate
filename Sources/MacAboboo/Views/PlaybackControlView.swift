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
                }
            } label: {
                Label(engine.loopMode.localized(with: lang), systemImage: engine.loopMode.iconName)
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color(nsColor: .separatorColor)),
            alignment: .top
        )
    }
}

#Preview("播放控制栏") {
    PlaybackControlView(engine: PlaybackEngine.shared)
        .frame(width: 800)
}
