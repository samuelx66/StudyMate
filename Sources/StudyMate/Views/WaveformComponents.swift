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
        self.viewportStart = viewportStart
        self.viewportEnd = viewportEnd
        self.width = width
        self.height = height
        self.isWindowResizing = isWindowResizing
    }
    
    public var body: some View {
        let span = max(0.001, viewportEnd - viewportStart)
        let segments = Array(visibleSegments)
        let activeIndex = engine.activeSegmentIndex

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
                .fill(StudyMateMediaStyle.destructive)
                .frame(width: 2, height: height)
                .shadow(color: StudyMateMediaStyle.destructive.opacity(0.6), radius: 2)
            
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 7))
                .foregroundStyle(StudyMateMediaStyle.destructive)
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
                    .fill(StudyMateMediaStyle.destructive)
                    .frame(width: 2, height: height)
                    .position(x: CGFloat(progress) * width, y: height / 2)
            }
        }
    }
}
