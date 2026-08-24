import SwiftUI
import AppKit

@MainActor
private enum WaveformRenderCache {
    final class Box: NSObject {
        let peaks: [(min: Float, max: Float)]
        init(_ peaks: [(min: Float, max: Float)]) { self.peaks = peaks }
    }

    static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 64
        return cache
    }()

    static func peaks(
        waveform: WaveformData,
        start: Double,
        end: Double,
        count: Int
    ) -> [(min: Float, max: Float)] {
        guard count > 0,
              start.isFinite,
              end.isFinite,
              waveform.duration.isFinite,
              waveform.duration > 0 else { return [] }

        let clampedStart = max(0, min(start, waveform.duration))
        let clampedEnd = max(clampedStart, min(end, waveform.duration))
        let visibleSpan = max(0.001, clampedEnd - clampedStart)
        // One cache bucket corresponds to roughly one rendered bar.  Playback
        // and dragging can move a viewport by fractions of a bar; reusing the
        // same bucket avoids resampling for visually indistinguishable ranges.
        let timePerBar = visibleSpan / Double(count)
        let grid = max(timePerBar, 1.0 / max(waveform.sampleRate, 1.0))
        let startBucket = Int64(floor(clampedStart / grid))
        let endBucket = Int64(ceil(clampedEnd / grid))
        let quantizedStart = Double(startBucket) * grid
        let quantizedEnd = min(
            waveform.duration,
            max(quantizedStart, Double(endBucket) * grid)
        )

        let middle = waveform.peaks.isEmpty ? 0 : waveform.peaks[waveform.peaks.count / 2]
        let signature = "\(waveform.peaks.first ?? 0)|\(middle)|\(waveform.peaks.last ?? 0)"
        let key = "\(waveform.peaks.count)|\(waveform.sampleRate)|\(waveform.duration)|\(signature)|\(grid.bitPattern)|\(startBucket)|\(endBucket)|\(count)" as NSString
        if let cached = cache.object(forKey: key) { return cached.peaks }
        let result = waveform.resample(
            startTime: quantizedStart,
            endTime: quantizedEnd,
            targetCount: count
        )
        cache.setObject(Box(result), forKey: key)
        return result
    }
}

/// 高性能连续实心双层包络波形绘制 Canvas
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
            guard !waveformData.isEmpty, size.width > 0, size.height > 0 else { return }

            let count = max(20, Int(size.width))
            let resampled = WaveformRenderCache.peaks(
                waveform: waveformData,
                start: startTime,
                end: endTime,
                count: count
            )
            guard !resampled.isEmpty else { return }
            
            let centerY = size.height / 2.0
            let maxBarHeight = (size.height / 2.0) * 0.90
            let stepX = size.width / CGFloat(max(1, resampled.count - 1))
            
            // 1. 中心零电平参考细线
            var zeroLine = Path()
            zeroLine.move(to: CGPoint(x: 0, y: centerY))
            zeroLine.addLine(to: CGPoint(x: size.width, y: centerY))
            context.stroke(zeroLine, with: .color(Color.primary.opacity(0.12)), lineWidth: 0.8)
            
            // 2. 构造外层峰值包络轮廓路径 (Peak Envelope)
            var peakPath = Path()
            peakPath.move(to: CGPoint(x: 0, y: centerY))
            
            // 顶部外轮廓（左 -> 右）
            for (i, peak) in resampled.enumerated() {
                let x = CGFloat(i) * stepX
                let ampMax = CGFloat(max(0.015, min(1.0, max(abs(peak.min), abs(peak.max)))))
                let y = centerY - ampMax * maxBarHeight
                peakPath.addLine(to: CGPoint(x: x, y: y))
            }
            
            // 底部外轮廓（右 -> 左）
            for (i, peak) in resampled.enumerated().reversed() {
                let x = CGFloat(i) * stepX
                let ampMax = CGFloat(max(0.015, min(1.0, max(abs(peak.min), abs(peak.max)))))
                let y = centerY + ampMax * maxBarHeight
                peakPath.addLine(to: CGPoint(x: x, y: y))
            }
            peakPath.closeSubpath()
            
            // 填充外层包络（带有上下轻微通透渐变）
            let outerGradient = Gradient(colors: [
                Color.accentColor.opacity(0.30),
                Color.accentColor.opacity(0.16),
                Color.accentColor.opacity(0.30)
            ])
            context.fill(
                peakPath,
                with: .linearGradient(
                    outerGradient,
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            // 外轮廓精细描边（增强轻辅音和峰值轮廓边缘的清晰锐利度）
            context.stroke(
                peakPath,
                with: .color(Color.accentColor.opacity(0.48)),
                lineWidth: 1.0
            )
            
            // 3. 构造内层能量核心路径 (RMS / Core Energy Envelope)
            var corePath = Path()
            corePath.move(to: CGPoint(x: 0, y: centerY))
            
            for (i, peak) in resampled.enumerated() {
                let x = CGFloat(i) * stepX
                let ampMax = CGFloat(max(0.008, min(1.0, max(abs(peak.min), abs(peak.max)))))
                let coreAmp = ampMax * 0.52
                let y = centerY - coreAmp * maxBarHeight
                corePath.addLine(to: CGPoint(x: x, y: y))
            }
            
            for (i, peak) in resampled.enumerated().reversed() {
                let x = CGFloat(i) * stepX
                let ampMax = CGFloat(max(0.008, min(1.0, max(abs(peak.min), abs(peak.max)))))
                let coreAmp = ampMax * 0.52
                let y = centerY + coreAmp * maxBarHeight
                corePath.addLine(to: CGPoint(x: x, y: y))
            }
            corePath.closeSubpath()
            
            // 填充内层能量核心
            context.fill(
                corePath,
                with: .color(Color.accentColor.opacity(0.24))
            )
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

        let segments = Array(visibleSegments)
        Canvas { context, size in
            for seg in segments {
                let segX1 = max(0, (seg.startTime - viewportStart) / span * width)
                let segX2 = min(width, (seg.endTime - viewportStart) / span * width)
                let segW = max(2, segX2 - segX1)
                let rect = CGRect(x: segX1, y: 0, width: segW, height: height)
                let isActive = engine.activeSegmentIndex == (seg.index - 1)
                let fillColor = isActive
                    ? Color.blue.opacity(0.24)
                    : (seg.index % 2 == 0 ? Color.primary.opacity(0.025) : Color.primary.opacity(0.05))

                context.fill(
                    Path(roundedRect: rect, cornerRadius: 4),
                    with: .color(fillColor)
                )
                if isActive {
                    context.stroke(
                        Path(roundedRect: rect, cornerRadius: 4),
                        with: .color(Color.blue.opacity(0.75)),
                        lineWidth: 1.5
                    )
                }
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }

    private var visibleSegments: ArraySlice<SentenceSegment> {
        let segments = engine.segments
        guard !segments.isEmpty else { return [] }
        var lower = 0
        var upper = segments.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if segments[middle].endTime >= viewportStart {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        let start = lower
        var end = start
        while end < segments.count, segments[end].startTime <= viewportEnd {
            end += 1
        }
        return segments[start..<end]
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
