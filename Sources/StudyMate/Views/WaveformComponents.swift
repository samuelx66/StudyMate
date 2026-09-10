import SwiftUI
import AppKit
import Combine

/// Shared pixel mapping for sentence boundary lines and the playback marker.
/// Keeping the edge inset in one place prevents the marker and the orange end
/// line from drifting apart when the viewport is resized or panned.
enum WaveformBoundaryGeometry {
    static let startLineInset: CGFloat = 1
    static let endLineInset: CGFloat = -1
    static let playheadLineInset: CGFloat = -1
    static let playheadLineCenterOffset: CGFloat = 4

    static func timelineX(
        for time: Double,
        viewportStart: Double,
        viewportEnd: Double,
        width: CGFloat
    ) -> CGFloat {
        guard time.isFinite,
              viewportStart.isFinite,
              viewportEnd.isFinite,
              width.isFinite,
              width > 0 else { return 0 }
        let span = viewportEnd - viewportStart
        guard span.isFinite, span > 0 else { return 0 }
        return CGFloat((time - viewportStart) / span) * width
    }

    static func startLineX(
        for time: Double,
        viewportStart: Double,
        viewportEnd: Double,
        width: CGFloat
    ) -> CGFloat {
        timelineX(for: time, viewportStart: viewportStart, viewportEnd: viewportEnd, width: width)
            + startLineInset
    }

    static func endLineX(
        for time: Double,
        viewportStart: Double,
        viewportEnd: Double,
        width: CGFloat
    ) -> CGFloat {
        timelineX(for: time, viewportStart: viewportStart, viewportEnd: viewportEnd, width: width)
            + endLineInset
    }

    /// The center of the red playhead stroke, clamped to the drawable edge.
    /// The orange sentence-end line uses the same `-1pt` edge inset.
    static func playheadLineX(
        for time: Double,
        viewportStart: Double,
        viewportEnd: Double,
        width: CGFloat
    ) -> CGFloat {
        let rawX = timelineX(
            for: time,
            viewportStart: viewportStart,
            viewportEnd: viewportEnd,
            width: width
        ) + playheadLineInset
        return max(0, min(max(0, width - 1), rawX))
    }

    static func playheadMarkerOriginX(
        for time: Double,
        viewportStart: Double,
        viewportEnd: Double,
        width: CGFloat
    ) -> CGFloat {
        playheadLineX(
            for: time,
            viewportStart: viewportStart,
            viewportEnd: viewportEnd,
            width: width
        ) - playheadLineCenterOffset
    }
}

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

        // 使用 WaveformData 预计算的指纹特征直接建键，消除每帧 9 次字符串转换与拼接开销
        let key = "\(waveform.peakCount)|\(waveform.sampleRate)|\(waveform.duration)|\(waveform.signature)|\(grid.bitPattern)|\(startBucket)|\(endBucket)|\(count)" as NSString
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

/// 高性能现代圆角胶囊渐变柱波形绘制 Canvas（方案 2）
public struct WaveformCanvas: View, Equatable {
    let waveformData: WaveformData
    let startTime: Double
    let endTime: Double
    let width: CGFloat
    let height: CGFloat
    /// Window zoom changes the canvas width every animation frame.  Keeping a
    /// coarser sampling bucket during that short interval lets the existing
    /// waveform stretch with the window instead of synchronously resampling
    /// the PCM data for every pixel-sized width change.
    let isWindowResizing: Bool

    public static func == (lhs: WaveformCanvas, rhs: WaveformCanvas) -> Bool {
        lhs.startTime == rhs.startTime
            && lhs.endTime == rhs.endTime
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.isWindowResizing == rhs.isWindowResizing
            && lhs.waveformData == rhs.waveformData
    }
    
    public init(
        waveformData: WaveformData,
        startTime: Double,
        endTime: Double,
        width: CGFloat,
        height: CGFloat,
        isWindowResizing: Bool = false
    ) {
        self.waveformData = waveformData
        self.startTime = startTime
        self.endTime = endTime
        self.width = width
        self.height = height
        self.isWindowResizing = isWindowResizing
    }
    
    public var body: some View {
        Canvas { context, size in
            guard !waveformData.isEmpty, size.width > 0, size.height > 0 else { return }

            let barWidth: CGFloat = 2.4
            let spacing: CGFloat = 1.4
            let totalBarSlot = barWidth + spacing
            // During the native window zoom animation the available width
            // changes continuously.  Quantizing the sampling width to a
            // 32-point grid keeps the cache bucket stable across small frame
            // changes while the path is still drawn at the exact current
            // width.  The final non-resizing frame restores full resolution.
            let samplingWidth = isWindowResizing
                ? max(32, (size.width / 32).rounded() * 32)
                : size.width
            let barCount = max(10, Int(samplingWidth / totalBarSlot))
            
            let resampled = WaveformRenderCache.peaks(
                waveform: waveformData,
                start: startTime,
                end: endTime,
                count: barCount
            )
            guard !resampled.isEmpty else { return }
            
            let centerY = size.height / 2.0
            let maxBarHeight = (size.height / 2.0) * 0.92
            
            // 1. 中心零电平微细参考线
            var zeroLine = Path()
            zeroLine.move(to: CGPoint(x: 0, y: centerY))
            zeroLine.addLine(to: CGPoint(x: size.width, y: centerY))
            context.stroke(zeroLine, with: .color(Color.primary.opacity(0.10)), lineWidth: 0.8)
            
            // 2. 构造所有圆角胶囊柱的 Path
            var capsulePath = Path()
            let cornerRadius = barWidth / 2.0
            
            for (i, peak) in resampled.enumerated() {
                let x = CGFloat(i) * totalBarSlot
                let amplitude = CGFloat(max(0.04, min(1.0, max(abs(peak.min), abs(peak.max)))))
                let barH = max(cornerRadius, amplitude * maxBarHeight)
                
                let rect = CGRect(
                    x: x,
                    y: centerY - barH,
                    width: barWidth,
                    height: barH * 2.0
                )
                
                capsulePath.addRoundedRect(
                    in: rect,
                    cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
                )
            }
            
            // 3. 使用纵向现代渐变进行填充（两端活力强调色，中心微透，极具通透呼吸感）
            let capsuleGradient = Gradient(stops: [
                .init(color: Color.accentColor.opacity(0.85), location: 0.0),
                .init(color: Color.accentColor.opacity(0.48), location: 0.5),
                .init(color: Color.accentColor.opacity(0.85), location: 1.0)
            ])
            
            context.fill(
                capsulePath,
                with: .linearGradient(
                    capsuleGradient,
                    startPoint: CGPoint(x: 0, y: centerY - maxBarHeight),
                    endPoint: CGPoint(x: 0, y: centerY + maxBarHeight)
                )
            )
        }
    }
}

@MainActor
private enum WaveformSegmentsPathCache {
    final class Box: NSObject {
        let evenPath: Path
        let oddPath: Path
        let activePath: Path?
        init(evenPath: Path, oddPath: Path, activePath: Path?) {
            self.evenPath = evenPath
            self.oddPath = oddPath
            self.activePath = activePath
        }
    }

    static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 64
        return c
    }()
}

/// 断句切片背景覆盖层
public struct WaveformSentenceSegmentsOverlay: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject private var activeSegmentState: ActiveSegmentPresentationState
    let viewportStart: Double
    let viewportEnd: Double
    let width: CGFloat
    let height: CGFloat
    let isWindowResizing: Bool
    
    public init(
        engine: PlaybackEngine,
        viewportStart: Double,
        viewportEnd: Double,
        width: CGFloat,
        height: CGFloat,
        isWindowResizing: Bool = false
    ) {
        self.engine = engine
        self._activeSegmentState = ObservedObject(wrappedValue: engine.activeSegmentState)
        self.viewportStart = viewportStart
        self.viewportEnd = viewportEnd
        self.width = width
        self.height = height
        self.isWindowResizing = isWindowResizing
    }
    
    public var body: some View {
        let span = max(0.001, viewportEnd - viewportStart)
        let segments = Array(visibleSegments)
        let activeIndex = activeSegmentState.index

        Canvas { context, size in
            guard !segments.isEmpty, size.width > 0, size.height > 0 else { return }

            let firstId = segments.first?.id.uuidString ?? ""
            let lastId = segments.last?.id.uuidString ?? ""
            var boundaryHasher = Hasher()
            for segment in segments {
                boundaryHasher.combine(segment.id)
                boundaryHasher.combine(segment.startTime.bitPattern)
                boundaryHasher.combine(segment.endTime.bitPattern)
            }
            let boundarySignature = boundaryHasher.finalize()

            // 窗口缩放期间，按 16pt 分桶量化宽度，避免每一像素变动连续穿透缓存
            let quantizedWidth = isWindowResizing
                ? max(16, (size.width / 16).rounded() * 16)
                : size.width
            let cacheKey = "\(segments.count)|\(firstId)|\(lastId)|\(boundarySignature)|\(activeIndex ?? -1)|\(Int(viewportStart * 100))|\(Int(viewportEnd * 100))|\(Int(quantizedWidth))|\(Int(size.height))" as NSString

            let paths: WaveformSegmentsPathCache.Box
            if let cached = WaveformSegmentsPathCache.cache.object(forKey: cacheKey) {
                paths = cached
            } else {
                var evenSegmentsPath = Path()
                var oddSegmentsPath = Path()
                var activeSegmentPath: Path?

                for seg in segments {
                    let segX1 = max(0, (seg.startTime - viewportStart) / span * quantizedWidth)
                    let segX2 = min(quantizedWidth, (seg.endTime - viewportStart) / span * quantizedWidth)
                    let segW = max(2, segX2 - segX1)
                    let rect = CGRect(x: segX1, y: 0, width: segW, height: height)
                    let isActive = activeIndex == (seg.index - 1)

                    if isActive {
                        activeSegmentPath = Path(roundedRect: rect, cornerRadius: 4)
                    } else if seg.index % 2 == 0 {
                        evenSegmentsPath.addPath(Path(roundedRect: rect, cornerRadius: 4))
                    } else {
                        oddSegmentsPath.addPath(Path(roundedRect: rect, cornerRadius: 4))
                    }
                }
                paths = WaveformSegmentsPathCache.Box(
                    evenPath: evenSegmentsPath,
                    oddPath: oddSegmentsPath,
                    activePath: activeSegmentPath
                )
                WaveformSegmentsPathCache.cache.setObject(paths, forKey: cacheKey)
            }

            if isWindowResizing && quantizedWidth > 0 && abs(size.width - quantizedWidth) > 0.5 {
                context.scaleBy(x: size.width / quantizedWidth, y: 1.0)
            }

            if !paths.evenPath.isEmpty {
                context.fill(paths.evenPath, with: .color(Color.primary.opacity(0.025)))
            }
            if !paths.oddPath.isEmpty {
                context.fill(paths.oddPath, with: .color(Color.primary.opacity(0.05)))
            }
            if let activePath = paths.activePath {
                context.fill(activePath, with: .color(StudyMateMediaStyle.informational.opacity(0.24)))
                context.stroke(activePath, with: .color(StudyMateMediaStyle.informational.opacity(0.75)), lineWidth: 1.5)
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

/// A compositor-driven playhead. Decoder callbacks are intentionally allowed
/// to arrive at a lower rate than the display refresh; Core Animation fills the
/// short gaps between samples on the render server, so the marker does not
/// visibly step while SwiftUI is rebuilding the surrounding waveform.
@MainActor
public final class WaveformPlayheadNSView: NSView {
    enum Style: Equatable {
        case primary
        case secondary
    }

    private let clock: PlaybackClock
    private let style: Style
    private let markerLayer = CALayer()
    private let lineLayer = CALayer()
    private let arrowLayer: CAShapeLayer?
    private var clockCancellable: AnyCancellable?
    private var displayTimer: Timer?
    private var viewportStart = 0.0
    private var viewportEnd = 1.0
    private var isPlaying = false

    init(frame frameRect: NSRect, clock: PlaybackClock, style: Style) {
        self.clock = clock
        self.style = style
        if style == .primary {
            let arrow = CAShapeLayer()
            arrow.fillColor = NSColor.systemRed.cgColor
            arrow.strokeColor = nil
            arrowLayer = arrow
        } else {
            arrowLayer = nil
        }
        super.init(frame: frameRect)

        wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.isGeometryFlipped = true
        rootLayer.masksToBounds = true
        layer = rootLayer

        markerLayer.anchorPoint = CGPoint(x: 0, y: 0)
        markerLayer.zPosition = 10
        markerLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "hidden": NSNull()
        ]
        lineLayer.backgroundColor = NSColor.systemRed.cgColor
        lineLayer.shadowColor = NSColor.systemRed.withAlphaComponent(0.6).cgColor
        lineLayer.shadowOpacity = 1
        lineLayer.shadowRadius = 2
        lineLayer.shadowOffset = .zero
        markerLayer.addSublayer(lineLayer)
        if let arrowLayer {
            markerLayer.addSublayer(arrowLayer)
        }
        rootLayer.addSublayer(markerLayer)

        // The native view observes only the narrow clock publisher. No SwiftUI
        // body is invalidated by these ticks.
        clockCancellable = clock.$currentTime.sink { [weak self] _ in
            self?.refreshPosition(animated: false)
        }
        refreshPosition(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        clockCancellable?.cancel()
        displayTimer?.invalidate()
    }

    public override var acceptsFirstResponder: Bool { false }
    public override var canBecomeKeyView: Bool { false }

    /// Let the interaction layer below receive all pointer events.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func layout() {
        super.layout()
        layoutMarkerLayers()
        refreshPosition(animated: false)
    }

    func configure(
        viewportStart: Double,
        viewportEnd: Double,
        isPlaying: Bool
    ) {
        let viewportChanged = self.viewportStart != viewportStart || self.viewportEnd != viewportEnd
        let playingChanged = self.isPlaying != isPlaying
        self.viewportStart = viewportStart
        self.viewportEnd = viewportEnd
        self.isPlaying = isPlaying
        if viewportChanged || playingChanged {
            refreshPosition(animated: false)
        }
        updateDisplayTimer()
    }

    /// Drive only this marker at display cadence. Common modes include
    /// AppKit's menu tracking mode, so opening a menu never pauses the
    /// playback marker.
    private func updateDisplayTimer() {
        guard isPlaying else {
            displayTimer?.invalidate()
            displayTimer = nil
            return
        }
        guard displayTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPosition(animated: false)
            }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func layoutMarkerLayers() {
        let markerHeight = max(0, bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markerLayer.bounds = CGRect(x: 0, y: 0, width: 8, height: markerHeight)
        markerLayer.position = CGPoint(x: markerLayer.position.x, y: 0)
        lineLayer.frame = CGRect(x: 3, y: 0, width: 2, height: markerHeight)
        if let arrowLayer {
            arrowLayer.frame = CGRect(x: 0, y: 0, width: 8, height: 8)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 8, y: 0))
            path.addLine(to: CGPoint(x: 4, y: 7))
            path.closeSubpath()
            arrowLayer.path = path
        }
        CATransaction.commit()
    }

    private func refreshPosition(animated _: Bool) {
        guard layer != nil else { return }
        let span = viewportEnd - viewportStart
        guard span.isFinite, span > 0, bounds.width > 0, bounds.height > 0 else {
            markerLayer.isHidden = true
            markerLayer.removeAnimation(forKey: "waveform-playhead-position")
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let presentationTime = clock.presentationTime(at: now)
        let progress = (presentationTime - viewportStart) / span
        guard progress.isFinite, progress >= 0, progress <= 1 else {
            markerLayer.isHidden = true
            markerLayer.removeAnimation(forKey: "waveform-playhead-position")
            return
        }

        // `markerLayer.position` is the layer origin, while the visible red
        // stroke is four points inside that layer (x: 3, width: 2). Position
        // the origin so the stroke center lands on the same coordinate as the
        // orange sentence-end line instead of appearing to run past it.
        let markerOriginX = WaveformBoundaryGeometry.playheadMarkerOriginX(
            for: presentationTime,
            viewportStart: viewportStart,
            viewportEnd: viewportEnd,
            width: bounds.width
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markerLayer.isHidden = false
        markerLayer.position = CGPoint(x: markerOriginX, y: 0)
        markerLayer.removeAnimation(forKey: "waveform-playhead-position")
        CATransaction.commit()
    }
}

/// The representables keep a stable AppKit marker instance while the SwiftUI
/// waveform itself is allowed to update for viewport and sentence changes.
public struct PrimaryWaveformPlayhead: NSViewRepresentable {
    let clock: PlaybackClock
    let viewportStart: Double
    let viewportEnd: Double
    let width: CGFloat
    let height: CGFloat
    let isPlaying: Bool

    public func makeNSView(context: Context) -> WaveformPlayheadNSView {
        let view = WaveformPlayheadNSView(frame: NSRect(x: 0, y: 0, width: width, height: height), clock: clock, style: .primary)
        view.configure(viewportStart: viewportStart, viewportEnd: viewportEnd, isPlaying: isPlaying)
        return view
    }

    public func updateNSView(_ nsView: WaveformPlayheadNSView, context: Context) {
        nsView.configure(viewportStart: viewportStart, viewportEnd: viewportEnd, isPlaying: isPlaying)
    }
}

public struct SecondaryWaveformPlayhead: NSViewRepresentable {
    let clock: PlaybackClock
    let viewportStart: Double
    let viewportEnd: Double
    let width: CGFloat
    let height: CGFloat
    let isPlaying: Bool

    public func makeNSView(context: Context) -> WaveformPlayheadNSView {
        let view = WaveformPlayheadNSView(frame: NSRect(x: 0, y: 0, width: width, height: height), clock: clock, style: .secondary)
        view.configure(viewportStart: viewportStart, viewportEnd: viewportEnd, isPlaying: isPlaying)
        return view
    }

    public func updateNSView(_ nsView: WaveformPlayheadNSView, context: Context) {
        nsView.configure(viewportStart: viewportStart, viewportEnd: viewportEnd, isPlaying: isPlaying)
    }
}
