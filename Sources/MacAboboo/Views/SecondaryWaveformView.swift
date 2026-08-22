import SwiftUI
import AppKit

/// 次波形图视图（高度 70pt，当前句放大，固定基准视口，拖动标线时波形图保持绝对静止，仅绿[S]/橙[E]标线左右平滑移动）
public struct SecondaryWaveformView: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject private var waveformState: WaveformPresentationState
    @ObservedObject var lang = LanguageManager.shared
    
    public init(engine: PlaybackEngine) {
        self.engine = engine
        self.waveformState = engine.waveformState
    }
    
    // 当前选中的断句
    private var activeSegment: SentenceSegment? {
        guard let idx = engine.activeSegmentIndex, idx >= 0, idx < engine.segments.count else {
            return nil
        }
        return engine.segments[idx]
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 顶部操作与微调状态栏
            HStack {
                HStack(spacing: 6) {
                    Label(lang.localized(.secondaryWaveform), systemImage: "waveform.badge.magnifyingglass")
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                    
                    if let seg = activeSegment {
                        Text("#\(seg.index)")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(3)
                        
                        Text(lang.localized(.duration(seg.formattedDuration)))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    
                    Text(lang.text(
                        "当前句放大：拖动绿标[S]/橙标[E] • ⌃+左键设起点 • ⌃+右键设终点",
                        "Current sentence: drag green [S]/orange [E] • Control-left/right click to set boundaries"
                    ))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                
                Spacer()
                
                if let seg = activeSegment {
                    // 微调快捷工具栏
                    HStack(spacing: 8) {
                        // 起始点微调
                        HStack(spacing: 2) {
                            Text("S:")
                                .font(.caption2.bold())
                                .foregroundColor(.green)
                            
                            Button(action: { nudgeStart(by: -0.05) }) {
                                Text("-50ms").font(.system(size: 8))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            
                            Text(seg.formattedStartTime)
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundColor(.green)
                            
                            Button(action: { nudgeStart(by: 0.05) }) {
                                Text("+50ms").font(.system(size: 8))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        
                        Divider().frame(height: 10)
                        
                        // 结束点微调
                        HStack(spacing: 2) {
                            Text("E:")
                                .font(.caption2.bold())
                                .foregroundColor(.orange)
                            
                            Button(action: { nudgeEnd(by: -0.05) }) {
                                Text("-50ms").font(.system(size: 8))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            
                            Text(seg.formattedEndTime)
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundColor(.orange)
                            
                            Button(action: { nudgeEnd(by: 0.05) }) {
                                Text("+50ms").font(.system(size: 8))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        
                        // 试听微调区间按钮
                        Button(action: {
                            engine.previewInterval(start: seg.startTime, end: seg.endTime)
                        }) {
                            Label(lang.text("试听", "Preview"), systemImage: "headphones")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }
                }
            }
            .padding(.horizontal, 6)
            
            // 次波形图主体 Canvas 区域 (高度 70pt)
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                
                if let seg = activeSegment {
                    // 使用由 PlaybackEngine 统一锁定的基准视口（拖动标线时视口 100% 保持固定，底图波形绝对静止）
                    let viewport = waveformState.secondaryViewport
                    let totalSpan = max(0.001, viewport.end - viewport.start)
                    
                    let startX = CGFloat((seg.startTime - viewport.start) / totalSpan) * width
                    let endX = CGFloat((seg.endTime - viewport.start) / totalSpan) * width
                    
                    ZStack(alignment: .leading) {
                        // 背景底板
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                        
                        // 选中区间高亮底色 (居中于 (startX + endX)/2)
                        let selectionW = max(2, endX - startX)
                        Rectangle()
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: selectionW, height: height)
                            .position(x: startX + selectionW / 2.0, y: height / 2.0)
                        
                        // 静态高清波形 Canvas (拖动标线时完全静止，绝不移动或抖动)
                        WaveformCanvas(
                            waveformData: waveformState.waveformData,
                            startTime: viewport.start,
                            endTime: viewport.end,
                            width: width,
                            height: height
                        )
                        
                        // 60fps 平滑游标
                        SecondaryWaveformPlayhead(
                            clock: engine.clock,
                            viewportStart: viewport.start,
                            viewportEnd: viewport.end,
                            width: width,
                            height: height
                        )
                        
                        // 可左右自由拖拽的绿(顶)/橙(底)标线交互层
                        DraggableWaveformOverlay(
                            engine: engine,
                            viewportStart: viewport.start,
                            viewportEnd: viewport.end,
                            width: width,
                            height: height,
                            isSecondaryView: true,
                            onBoundaryDragBegan: {
                                engine.beginBoundaryDrag(from: .secondary)
                            },
                            onBoundaryDragEnded: {
                                engine.endBoundaryDrag()
                            }
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                } else {
                    // 无断句选中时的占位
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        
                        Text(lang.text("在列表中选择断句以微调波形", "Select a sentence in the list to fine-tune it"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(height: 70)
        }
        .padding(4)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }
    
    private func nudgeStart(by delta: Double) {
        guard let seg = activeSegment else { return }
        engine.updateSegmentAnchor(id: seg.id, start: seg.startTime + delta)
    }
    
    private func nudgeEnd(by delta: Double) {
        guard let seg = activeSegment else { return }
        engine.updateSegmentAnchor(id: seg.id, end: seg.endTime + delta)
    }
}

#Preview("次波形图 (单句微调)") {
    SecondaryWaveformView(engine: PlaybackEngine.shared)
        .frame(width: 800)
        .padding()
}
