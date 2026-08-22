import SwiftUI
import AppKit

/// 视频画面与音频可视化视图（纯原生 GPU 硬件直通加速渲染，0 延迟、0 窗口干扰）
public struct VideoPlayerView: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject private var lang = LanguageManager.shared
    
    public init(engine: PlaybackEngine) {
        self.engine = engine
    }
    
    public var body: some View {
        ZStack {
            Color.black
            
            if let media = engine.currentMedia {
                if media.isVideo {
                    // 智能多媒体双引擎硬件加速视频渲染视图（AVFoundation / libmpv 无缝直通）
                    NativeVideoPlayerRepresentable(playerView: engine.activeBackend.playerView)
                        .id("\(ObjectIdentifier(engine.activeBackend))_\(media.id)")
                        .onTapGesture {
                            engine.togglePlayPause()
                        }
                } else {
                    // 纯音频模式下的视觉占位
                    AudioVisualPlaceholder(
                        title: media.title,
                        isPlaying: engine.isPlaying,
                        duration: media.formattedDuration
                    )
                    .onTapGesture {
                        engine.togglePlayPause()
                    }
                }
            } else {
                // 未打开媒体文件时的空状态
                EmptyMediaPlaceholder()
            }

            if engine.isMediaLoading {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(lang.text("正在加载媒体…", "Loading media…"))
                        .font(.caption)
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(minHeight: 200)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

/// 纯原生 AppKit 视频渲染容器宿主
public struct NativeVideoPlayerRepresentable: NSViewRepresentable {
    let playerView: NSView
    
    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        embed(playerView, in: container)
        return container
    }
    
    public func updateNSView(_ nsView: NSView, context: Context) {
        embed(playerView, in: nsView)
    }
    
    private func embed(_ view: NSView, in container: NSView) {
        if view.superview != container {
            container.subviews.forEach { $0.removeFromSuperview() }
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
    }
}

/// 纯音频模式占位图
struct AudioVisualPlaceholder: View {
    let title: String
    let isPlaying: Bool
    let duration: String
    
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.7), Color.purple.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)
                    .shadow(color: Color.blue.opacity(isPlaying ? 0.5 : 0.2), radius: isPlaying ? 16 : 8)
                    .scaleEffect(isPlaying ? 1.05 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPlaying)
                
                Image(systemName: isPlaying ? "waveform" : "music.note")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white)
            }
            
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Text(duration)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .padding()
    }
}

/// 空媒体状态视图
struct EmptyMediaPlaceholder: View {
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            
            Text(lang.localized(.noFileLoaded))
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text(lang.text(
                "支持 MP4、MKV、WebM、AVI、MOV、FLV、MP3、WAV 等格式及字幕导入",
                "Supports MP4, MKV, WebM, AVI, MOV, FLV, MP3, WAV, and subtitle import"
            ))
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
        }
        .padding()
    }
}

#Preview("视频/音频视窗 (空状态)") {
    VideoPlayerView(engine: PlaybackEngine.shared)
        .frame(width: 600, height: 400)
}
