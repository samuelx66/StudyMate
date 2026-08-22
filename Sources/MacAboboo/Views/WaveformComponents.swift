import SwiftUI
import AppKit

/// 高性能波形绘制 Canvas
public struct WaveformCanvas: View {
    let waveformData: WaveformData
    let startTime: Double
    let endTime: Double
    let width: CGFloat
    let height: CGFloat
    
    public init(
        waveformData: WaveformData,
        startTime: Double,
        endTime: Double,
        width: CGFloat,
        height: CGFloat
    ) {
        self.waveformData = waveformData
        self.startTime = startTime
        self.endTime = endTime
        self.width = width
        self.height = height
    }
    
    public var body: some View {
        Canvas { context, size in
            guard !waveformData.isEmpty, width > 0, height > 0 else { return }
            
            let barWidth: CGFloat = 2.0
            let spacing: CGFloat = 1.0
            let totalBarSlot = barWidth + spacing
            let barCount = Int(size.width / totalBarSlot)
            
            let resampled = waveformData.resample(
                startTime: startTime,
                endTime: endTime,
                targetCount: barCount
            )
            
            let centerY = size.height / 2.0
            let maxBarHeight = (size.height / 2.0) * 0.92
            
            for (i, peak) in resampled.enumerated() {
                let x = CGFloat(i) * totalBarSlot
                let amplitude = CGFloat(max(0.03, max(abs(peak.min), abs(peak.max))))
                let barH = amplitude * maxBarHeight
                
                let rect = CGRect(
                    x: x,
                    y: centerY - barH,
                    width: barWidth,
                    height: max(2, barH * 2)
                )
                
                let path = Path(roundedRect: rect, cornerRadius: 1)
                context.fill(path, with: .color(Color.primary.opacity(0.35)))
            }
        }
    }
}

/// 断句切片背景覆盖层
public struct WaveformSentenceSegmentsOverlay: View {
    @ObservedObject var engine: PlaybackEngine
    let viewportStart: Double
    let viewportEnd: Double
    let width: CGFloat
    let height: CGFloat
    
    public init(
        engine: PlaybackEngine,
        viewportStart: Double,
        viewportEnd: Double,
        width: CGFloat,
        height: CGFloat
    ) {
        self.engine = engine
        self.viewportStart = viewportStart
        self.viewportEnd = viewportEnd
        self.width = width
        self.height = height
    }
    
    public var body: some View {
        let span = max(0.001, viewportEnd - viewportStart)
        
        ForEach(engine.segments) { seg in
            if seg.endTime >= viewportStart && seg.startTime <= viewportEnd {
                let segX1 = max(0, (seg.startTime - viewportStart) / span * width)
                let segX2 = min(width, (seg.endTime - viewportStart) / span * width)
                let segW = max(2, segX2 - segX1)
                let isActive = engine.activeSegmentIndex == (seg.index - 1)
                
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            isActive
                                ? Color.blue.opacity(0.24)
                                : (seg.index % 2 == 0 ? Color.primary.opacity(0.025) : Color.primary.opacity(0.05))
                        )
                    
                    if isActive {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.blue.opacity(0.75), lineWidth: 1.5)
                    }
                }
                .frame(width: segW, height: height)
                .position(x: segX1 + segW / 2.0, y: height / 2.0)
            }
        }
    }
}

/// 播放游标指示线与时间指示器
public struct PrimaryPlayhead: View {
    let playheadX: CGFloat
    let height: CGFloat
    let currentTime: Double
    
    public init(playheadX: CGFloat, height: CGFloat, currentTime: Double) {
        self.playheadX = playheadX
        self.height = height
        self.currentTime = currentTime
    }
    
    public var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: height)
                .shadow(color: Color.red.opacity(0.6), radius: 2)
            
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 7))
                .foregroundColor(.red)
                .offset(y: -2)
        }
        .frame(width: 2, height: height)
        .position(x: playheadX, y: height / 2.0)
    }
}

/// 只有这一小层订阅 60fps 播放时钟，波形、标线和工具栏不会随每一帧重建。
public struct PrimaryWaveformPlayhead: View {
    @ObservedObject var clock: PlaybackClock
    let viewportStart: Double
    let viewportEnd: Double
    let width: CGFloat
    let height: CGFloat

    public var body: some View {
        Group {
            if clock.currentTime >= viewportStart, clock.currentTime <= viewportEnd {
                let progress = (clock.currentTime - viewportStart) / max(0.001, viewportEnd - viewportStart)
                PrimaryPlayhead(
                    playheadX: CGFloat(progress) * width,
                    height: height,
                    currentTime: clock.currentTime
                )
            }
        }
    }
}

public struct SecondaryWaveformPlayhead: View {
    @ObservedObject var clock: PlaybackClock
    let viewportStart: Double
    let viewportEnd: Double
    let width: CGFloat
    let height: CGFloat

    public var body: some View {
        Group {
            if clock.currentTime >= viewportStart, clock.currentTime <= viewportEnd {
                let progress = (clock.currentTime - viewportStart) / max(0.001, viewportEnd - viewportStart)
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2, height: height)
                    .position(x: CGFloat(progress) * width, y: height / 2)
            }
        }
    }
}

/// 鼠标左右键与悬停原生事件拦截视图（仅修改断句起止，不触发播放）
public struct WaveformMouseInteractionOverlay: NSViewRepresentable {
    let viewportStart: Double
    let viewportEnd: Double
    let onLeftClick: (Double) -> Void
    let onRightClick: (Double) -> Void
    let onHover: (Double?) -> Void
    
    public init(
        viewportStart: Double,
        viewportEnd: Double,
        onLeftClick: @escaping (Double) -> Void,
        onRightClick: @escaping (Double) -> Void,
        onHover: @escaping (Double?) -> Void
    ) {
        self.viewportStart = viewportStart
        self.viewportEnd = viewportEnd
        self.onLeftClick = onLeftClick
        self.onRightClick = onRightClick
        self.onHover = onHover
    }
    
    public func makeNSView(context: Context) -> MouseCaptureNSView {
        let view = MouseCaptureNSView()
        view.viewportStart = viewportStart
        view.viewportEnd = viewportEnd
        view.onLeftClick = onLeftClick
        view.onRightClick = onRightClick
        view.onHover = onHover
        return view
    }
    
    public func updateNSView(_ nsView: MouseCaptureNSView, context: Context) {
        nsView.viewportStart = viewportStart
        nsView.viewportEnd = viewportEnd
        nsView.onLeftClick = onLeftClick
        nsView.onRightClick = onRightClick
        nsView.onHover = onHover
    }
    
    public class MouseCaptureNSView: NSView {
        var viewportStart: Double = 0
        var viewportEnd: Double = 1
        var onLeftClick: ((Double) -> Void)?
        var onRightClick: ((Double) -> Void)?
        var onHover: ((Double?) -> Void)?
        
        private var trackingArea: NSTrackingArea?
        
        public override var mouseDownCanMoveWindow: Bool {
            return false
        }
        
        public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            return true
        }
        
        public override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea = trackingArea {
                removeTrackingArea(trackingArea)
            }
            let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited]
            trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
            addTrackingArea(trackingArea!)
        }
        
        private func calculateTime(from event: NSEvent) -> Double {
            let location = convert(event.locationInWindow, from: nil)
            let ratio = max(0, min(1, location.x / max(1, bounds.width)))
            return viewportStart + Double(ratio) * (viewportEnd - viewportStart)
        }
        
        public override func mouseDown(with event: NSEvent) {
            let t = calculateTime(from: event)
            onLeftClick?(t)
        }
        
        public override func mouseDragged(with event: NSEvent) {
            let t = calculateTime(from: event)
            onLeftClick?(t)
        }
        
        public override func rightMouseDown(with event: NSEvent) {
            let t = calculateTime(from: event)
            onRightClick?(t)
        }
        
        public override func rightMouseDragged(with event: NSEvent) {
            let t = calculateTime(from: event)
            onRightClick?(t)
        }
        
        public override func mouseMoved(with event: NSEvent) {
            let t = calculateTime(from: event)
            onHover?(t)
        }
        
        public override func mouseExited(with event: NSEvent) {
            onHover?(nil)
        }
    }
}
