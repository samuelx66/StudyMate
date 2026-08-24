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
            
            // 2. 定次复读与跟读状态标签
            if engine.repeatCountLimit > 1 || engine.repeatCountLimit == 0 {
                HStack(spacing: 3) {
                    Image(systemName: "repeat")
                        .font(.system(size: 9))
                    Text(engine.repeatCountLimit == 0 ? "[\(engine.currentRepeatCount)/∞]" : "[\(engine.currentRepeatCount)/\(engine.repeatCountLimit)]")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.15))
                .foregroundColor(.purple)
                .cornerRadius(4)
            }
            
            // 句末开口跟读倒计时指示
            if engine.isShadowingPaused {
                HStack(spacing: 4) {
                    Image(systemName: "mic.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 10))
                    Text(String(
                        format: lang.text("跟读中 %.1f 秒", "Shadowing %.1fs"),
                        engine.shadowingCountdownRemaining
                    ))
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
                .cornerRadius(4)
            }
            
            if engine.onlyPlayBookmarked {
                HStack(spacing: 2) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                    Text(lang.text("难句专练", "Bookmarks"))
                        .font(.system(size: 9, weight: .bold))
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.yellow.opacity(0.2))
                .foregroundColor(.orange)
                .cornerRadius(3)
            }
            
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
