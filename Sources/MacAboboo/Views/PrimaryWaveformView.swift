import SwiftUI
import AppKit

/// 主波形图视图（高度 77pt，鼠标按住左右拖移实时平移波形，点击断句原地选中并联动次波形放大，不强制居中跳跃）
public struct PrimaryWaveformView: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject private var waveformState: WaveformPresentationState
    @ObservedObject var lang = LanguageManager.shared
    
    @State private var zoomLevel: Double = 1.0
    
    public init(engine: PlaybackEngine) {
        self.engine = engine
        self.waveformState = engine.waveformState
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 头部标题与控制按钮
            HStack {
                HStack(spacing: 6) {
                    Label(lang.localized(.primaryWaveform), systemImage: "waveform.path.ecg")
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                    
                    Text(lang.text(
                        "按住拖动平移波形 • 点击选句 • 拖动绿[S]/橙[E]标线 • ⌃+单击设起止点",
                        "Drag to pan • Click a sentence • Drag green [S]/orange [E] • Control-click to set boundaries"
                    ))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                if waveformState.isExtracting {
                    ProgressView(value: waveformState.extractionProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                    Text(lang.localized(.extractingWaveform))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // 视口缩放按钮
                HStack(spacing: 8) {
                    Button(action: {
                        zoomLevel = max(0.5, zoomLevel - 0.25)
                        engine.setPrimaryViewportZoom(zoomLevel: zoomLevel)
                    }) {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help(lang.localized(.zoomOut))
                    
                    Text("\(Int(zoomLevel * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 36)
                    
                    Button(action: {
                        zoomLevel = min(4.0, zoomLevel + 0.25)
                        engine.setPrimaryViewportZoom(zoomLevel: zoomLevel)
                    }) {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help(lang.localized(.zoomIn))
                    
                    Button(action: {
                        zoomLevel = 1.0
                        engine.setPrimaryViewportZoom(zoomLevel: 1.0)
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption)
                            .foregroundColor(zoomLevel == 1.0 ? .secondary.opacity(0.4) : .secondary)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .disabled(zoomLevel == 1.0)
                    .help(lang.localized(.resetZoom))
                }
            }
            .padding(.horizontal, 6)
            
            // 波形图主体区域 (高度 77pt)
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                let viewport = waveformState.primaryViewport
                
                ZStack(alignment: .leading) {
                    // 背景
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    
                    // 1. 断句区间背景底色
                    WaveformSentenceSegmentsOverlay(
                        engine: engine,
                        viewportStart: viewport.start,
                        viewportEnd: viewport.end,
                        width: width,
                        height: height
                    )
                    
                    // 2. 波形 Canvas (随拖拽平移实时渲染前后波形)
                    WaveformCanvas(
                        waveformData: waveformState.waveformData,
                        startTime: viewport.start,
                        endTime: viewport.end,
                        width: width,
                        height: height
                    )
                    
                    // 3. 60fps 平滑播放游标
                    PrimaryWaveformPlayhead(
                        clock: engine.clock,
                        viewportStart: viewport.start,
                        viewportEnd: viewport.end,
                        width: width,
                        height: height
                    )
                    
                    // 4. 可左右自由拖拽的绿(顶)/橙(底)标线层 + 拖动波形平移浏览层
                    DraggableWaveformOverlay(
                        engine: engine,
                        viewportStart: viewport.start,
                        viewportEnd: viewport.end,
                        width: width,
                        height: height,
                        isSecondaryView: false,
                        onBoundaryDragBegan: {
                            engine.beginBoundaryDrag(from: .primary)
                        },
                        onBoundaryDragEnded: {
                            engine.endBoundaryDrag()
                        },
                        onPanViewport: { deltaTime in
                            engine.panPrimaryViewport(by: deltaTime)
                        }
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }
            .frame(height: 77)
        }
        .padding(4)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }
}

#Preview("主波形图") {
    PrimaryWaveformView(engine: PlaybackEngine.shared)
        .frame(width: 800)
        .padding()
}
