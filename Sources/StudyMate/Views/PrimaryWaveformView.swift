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
                Label(lang.localized(.primaryWaveform), systemImage: "waveform.path.ecg")
                    .font(.subheadline.bold())
                    .foregroundColor(.primary)
                
                Spacer()
                
                // 视口缩放按钮
                HStack(spacing: 8) {
                    Button(action: {
                        zoomLevel = max(0.5, zoomLevel - 0.25)
                        engine.setPrimaryViewportZoom(zoomLevel: zoomLevel)
                    }) {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.caption)
                            .frame(width: 22, height: 22)
                    }
                    .studymateChromeButton(shape: .circle)
                    .focusable(false)
                    .accessibilityLabel(lang.localized(.zoomOut))
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
                            .frame(width: 22, height: 22)
                    }
                    .studymateChromeButton(shape: .circle)
                    .focusable(false)
                    .accessibilityLabel(lang.localized(.zoomIn))
                    .help(lang.localized(.zoomIn))
                    
                    Button(action: {
                        zoomLevel = 1.0
                        engine.setPrimaryViewportZoom(zoomLevel: 1.0)
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption)
                            .frame(width: 22, height: 22)
                    }
                    .studymateChromeButton(shape: .circle)
                    .focusable(false)
                    .disabled(zoomLevel == 1.0)
                    .accessibilityLabel(lang.localized(.resetZoom))
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
                        .fill(.regularMaterial)
                    
                    // 1. 断句区间背景底色
                    WaveformSentenceSegmentsOverlay(
                        engine: engine,
                        viewportStart: viewport.start,
                        viewportEnd: viewport.end,
                        width: width,
                        height: height,
                        isWindowResizing: engine.isWindowResizing
                    )
                    
                    // 2. 波形 Canvas (随拖拽平移实时渲染前后波形)
                    WaveformCanvas(
                        waveformData: waveformState.waveformData,
                        startTime: viewport.start,
                        endTime: viewport.end,
                        width: width,
                        height: height,
                        isWindowResizing: engine.isWindowResizing
                    )
                    .equatable()
                    
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
                        onSelectSegmentForBoundaryDrag: { id in
                            engine.playSegmentAfterBoundaryEditing(id: id)
                        },
                        onPanViewport: { deltaTime in
                            engine.panPrimaryViewport(by: deltaTime)
                        }
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(StudyMateMediaStyle.separator, lineWidth: 1)
                )
            }
            .frame(height: 77)
        }
        .padding(4)
        .studymateContentSurface(cornerRadius: 6)
    }
}

#Preview("主波形图") {
    PrimaryWaveformView(engine: PlaybackEngine.shared)
        .frame(width: 800)
        .padding()
}
