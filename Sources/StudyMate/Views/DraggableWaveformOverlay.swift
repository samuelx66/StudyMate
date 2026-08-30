import SwiftUI
import AppKit

/// 专业波形断句起止拖拽与交互层（绿色 S# 徽章置顶、橙色 E# 徽章置底，两端对齐零遮挡，精准像素对齐）
public struct DraggableWaveformOverlay: View {
    @ObservedObject var engine: PlaybackEngine
    let viewportStart: Double
    let viewportEnd: Double
    let width: CGFloat
    let height: CGFloat
    let isSecondaryView: Bool
    let onBoundaryDragBegan: () -> Void
    let onBoundaryDragEnded: () -> Void
    /// 选中标线所属句子时只更新编辑目标，不执行 Seek/播放。
    /// 普通波形点击仍使用 `onSelectSegment`，两者的行为必须分开。
    let onSelectSegmentForBoundaryDrag: (UUID) -> Void
    let onPanViewport: ((Double) -> Void)?
    
    public init(
        engine: PlaybackEngine,
        viewportStart: Double,
        viewportEnd: Double,
        width: CGFloat,
        height: CGFloat,
        isSecondaryView: Bool = false,
        onBoundaryDragBegan: @escaping () -> Void = {},
        onBoundaryDragEnded: @escaping () -> Void = {},
        onSelectSegmentForBoundaryDrag: @escaping (UUID) -> Void,
        onPanViewport: ((Double) -> Void)? = nil
    ) {
        self.engine = engine
        self.viewportStart = viewportStart
        self.viewportEnd = viewportEnd
        self.width = width
        self.height = height
        self.isSecondaryView = isSecondaryView
        self.onBoundaryDragBegan = onBoundaryDragBegan
        self.onBoundaryDragEnded = onBoundaryDragEnded
        self.onSelectSegmentForBoundaryDrag = onSelectSegmentForBoundaryDrag
        self.onPanViewport = onPanViewport
    }
    
    public var body: some View {
        let visible = Array(visibleSegments)
        
        ZStack(alignment: .topLeading) {
            // 静态标线一次性批量绘制；只有 S#/E# 徽章保留 SwiftUI 视图。
            WaveformBoundaryCanvas(
                segments: visible,
                activeSegmentIndex: engine.activeSegmentIndex,
                viewportStart: viewportStart,
                viewportEnd: viewportEnd,
                width: width,
                height: height,
                isSecondaryView: isSecondaryView,
                isBoundaryDragging: engine.isBoundaryDragging
            )
            .frame(width: width, height: height)
            .allowsHitTesting(false)

            WaveformBoundaryLabels(
                segments: visible,
                activeSegmentIndex: engine.activeSegmentIndex,
                viewportStart: viewportStart,
                viewportEnd: viewportEnd,
                width: width,
                height: height,
                isSecondaryView: isSecondaryView,
                isBoundaryDragging: engine.isBoundaryDragging
            )
            .frame(width: width, height: height)
            .allowsHitTesting(false)
            
            // 2. 底层统一 AppKit 鼠标事件响应与手势驱动层
            WaveformInteractionNSViewRepresentable(
                segments: engine.segments,
                activeSegmentIndex: engine.activeSegmentIndex,
                viewportStart: viewportStart,
                viewportEnd: viewportEnd,
                duration: engine.duration,
                isSecondaryView: isSecondaryView,
                isBoundaryDragging: engine.isBoundaryDragging,
                onBoundaryDragBegan: onBoundaryDragBegan,
                onBoundaryDragEnded: onBoundaryDragEnded,
                onSelectSegmentForBoundaryDrag: onSelectSegmentForBoundaryDrag,
                onPanViewport: onPanViewport,
                onSelectSegment: { id in
                    engine.jumpToSegment(id: id)
                },
                onUpdateStartAnchor: { id, newStart in
                    engine.updateSegmentBoundaryFromDrag(id: id, proposed: newStart, isStart: true)
                },
                onUpdateEndAnchor: { id, newEnd in
                    engine.updateSegmentBoundaryFromDrag(id: id, proposed: newEnd, isStart: false)
                },
                onLeftClickEmpty: { time in
                    handleCtrlLeftClick(at: time)
                },
                onRightClickEmpty: { time in
                    handleCtrlRightClick(at: time)
                }
            )
            .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
    }

    private var visibleSegments: ArraySlice<SentenceSegment> {
        let segments = engine.segments
        guard !segments.isEmpty else { return [] }
        var lower = 0
        var upper = segments.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if segments[middle].endTime >= viewportStart { upper = middle }
            else { lower = middle + 1 }
        }
        var end = lower
        while end < segments.count, segments[end].startTime <= viewportEnd { end += 1 }
        return segments[lower..<end]
    }
    
    // 按住 Ctrl + 鼠标左键：设置断句起点
    private func handleCtrlLeftClick(at targetTime: Double) {
        if let idx = engine.activeSegmentIndex, idx < engine.segments.count {
            let seg = engine.segments[idx]
            let clamped = max(0, min(targetTime, seg.endTime - 0.05))
            engine.updateSegmentAnchor(id: seg.id, start: clamped)
        } else {
            engine.updateActiveSegment(for: targetTime)
        }
    }
    
    // 按住 Ctrl + 鼠标右键：设置断句终点
    private func handleCtrlRightClick(at targetTime: Double) {
        if let idx = engine.activeSegmentIndex, idx < engine.segments.count {
            let seg = engine.segments[idx]
            let maxBound = engine.duration > 0 ? engine.duration : 999999.0
            let clamped = min(maxBound, max(targetTime, seg.startTime + 0.05))
            engine.updateSegmentAnchor(id: seg.id, end: clamped)
        }
    }
}

/// The non-interactive marker lines are drawn in one Canvas pass.  This keeps
/// panning inexpensive while the AppKit layer below still owns hit testing.
private struct WaveformBoundaryCanvas: View {
    let segments: [SentenceSegment]
    let activeSegmentIndex: Int?
    let viewportStart: Double
    let viewportEnd: Double
    let width: CGFloat
    let height: CGFloat
    let isSecondaryView: Bool
    let isBoundaryDragging: Bool

    var body: some View {
        let span = max(0.001, viewportEnd - viewportStart)
        Canvas { context, _ in
            // The AppKit interaction layer draws the active marker directly
            // from the mouse event while dragging. Do not leave a coalesced
            // SwiftUI line underneath it.
            guard !isBoundaryDragging else { return }

            var startPath = Path()
            var endPath = Path()

            for segment in segments {
                let isActive = activeSegmentIndex == (segment.index - 1)
                guard !isSecondaryView || isActive else { continue }
                let startX = CGFloat((segment.startTime - viewportStart) / span) * width + 1
                let endX = CGFloat((segment.endTime - viewportStart) / span) * width - 1

                startPath.move(to: CGPoint(x: startX, y: 0))
                startPath.addLine(to: CGPoint(x: startX, y: height))

                endPath.move(to: CGPoint(x: endX, y: 0))
                endPath.addLine(to: CGPoint(x: endX, y: height))
            }

            if !startPath.isEmpty {
                context.stroke(
                    startPath,
                    with: .color(Color(nsColor: .systemGreen)),
                    lineWidth: 2
                )
            }
            if !endPath.isEmpty {
                context.stroke(
                    endPath,
                    with: .color(Color(nsColor: .systemOrange)),
                    lineWidth: 2
                )
            }
        }
    }
}

/// Text badges remain native SwiftUI views for crisp text and accessibility;
/// they are not part of the hit-testing path.
private struct WaveformBoundaryLabels: View {
    let segments: [SentenceSegment]
    let activeSegmentIndex: Int?
    let viewportStart: Double
    let viewportEnd: Double
    let width: CGFloat
    let height: CGFloat
    let isSecondaryView: Bool
    let isBoundaryDragging: Bool

    var body: some View {
        let span = max(0.001, viewportEnd - viewportStart)
        ZStack(alignment: .topLeading) {
            if !isBoundaryDragging {
                ForEach(segments) { segment in
                let isActive = activeSegmentIndex == (segment.index - 1)
                if !isSecondaryView || isActive {
                    let startX = CGFloat((segment.startTime - viewportStart) / span) * width
                    let endX = CGFloat((segment.endTime - viewportStart) / span) * width
                    BoundaryBadge(
                        label: "S#\(segment.index)",
                        icon: "arrowtriangle.right.fill",
                        color: Color(nsColor: .systemGreen)
                    )
                    .position(x: startX + 22, y: 11)

                    BoundaryBadge(
                        label: "E#\(segment.index)",
                        icon: "arrowtriangle.left.fill",
                        color: Color(nsColor: .systemOrange)
                    )
                    .position(x: endX - 22, y: max(11, height - 11))
                }
                }
            }
        }
    }
}

private struct BoundaryBadge: View {
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            if icon == "arrowtriangle.left.fill" {
                Text(label)
            }
            Image(systemName: icon)
                .font(.system(size: 6))
            if icon == "arrowtriangle.right.fill" {
                Text(label)
            }
        }
        .font(.system(size: 9, weight: .black, design: .rounded))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(color)
                .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)
        )
        .foregroundColor(.white)
        .fixedSize()
    }
}

// MARK: - AppKit 原生高性能手势与拖拽交互控制器

public struct WaveformInteractionNSViewRepresentable: NSViewRepresentable {
    let segments: [SentenceSegment]
    let activeSegmentIndex: Int?
    let viewportStart: Double
    let viewportEnd: Double
    let duration: Double
    let isSecondaryView: Bool
    let isBoundaryDragging: Bool
    let onBoundaryDragBegan: () -> Void
    let onBoundaryDragEnded: () -> Void
        let onSelectSegmentForBoundaryDrag: (UUID) -> Void
    let onPanViewport: ((Double) -> Void)?
    
    let onSelectSegment: (UUID) -> Void
    let onUpdateStartAnchor: (UUID, Double) -> Void
    let onUpdateEndAnchor: (UUID, Double) -> Void
    let onLeftClickEmpty: (Double) -> Void
    let onRightClickEmpty: (Double) -> Void
    
    public func makeNSView(context: Context) -> InteractiveWaveformNSView {
        let view = InteractiveWaveformNSView()
        updateNSViewProps(view)
        return view
    }
    
    public func updateNSView(_ nsView: InteractiveWaveformNSView, context: Context) {
        updateNSViewProps(nsView)
    }
    
    private func updateNSViewProps(_ view: InteractiveWaveformNSView) {
        view.segments = segments
        view.activeSegmentIndex = activeSegmentIndex
        view.viewportStart = viewportStart
        view.viewportEnd = viewportEnd
        view.duration = duration
        view.isSecondaryView = isSecondaryView
        view.updateBoundaryDragState(isBoundaryDragging)
        view.onBoundaryDragBegan = onBoundaryDragBegan
        view.onBoundaryDragEnded = onBoundaryDragEnded
        view.onSelectSegmentForBoundaryDrag = onSelectSegmentForBoundaryDrag
        view.onPanViewport = onPanViewport
        view.onSelectSegment = onSelectSegment
        view.onUpdateStartAnchor = onUpdateStartAnchor
        view.onUpdateEndAnchor = onUpdateEndAnchor
        view.onLeftClickEmpty = onLeftClickEmpty
        view.onRightClickEmpty = onRightClickEmpty
    }
    
    public class InteractiveWaveformNSView: NSView {
        var segments: [SentenceSegment] = []
        var activeSegmentIndex: Int?
        var viewportStart: Double = 0
        var viewportEnd: Double = 1
        var duration: Double = 0
        var isSecondaryView: Bool = false
        /// Mirrors the engine's published drag state. The local flag remains
        /// separate so the final real-time frame survives until SwiftUI has
        /// committed the released boundaries.
        private var modelIsBoundaryDragging = false
        var onBoundaryDragBegan: (() -> Void)?
        var onBoundaryDragEnded: (() -> Void)?
        var onSelectSegmentForBoundaryDrag: ((UUID) -> Void)?
        var onPanViewport: ((Double) -> Void)?
        
        var onSelectSegment: ((UUID) -> Void)?
        var onUpdateStartAnchor: ((UUID, Double) -> Void)?
        var onUpdateEndAnchor: ((UUID, Double) -> Void)?
        var onLeftClickEmpty: ((Double) -> Void)?
        var onRightClickEmpty: ((Double) -> Void)?
        
        private var trackingArea: NSTrackingArea?
        
        // 正在拖拽的目标类型
        enum ActiveDrag: Equatable {
            case start(id: UUID)
            case end(id: UUID)
            case emptyLeft
            case emptyRight
            case pan(lastX: CGFloat, didMove: Bool, pendingSegmentID: UUID?)
            case tap(lastX: CGFloat, didMove: Bool, pendingSegmentID: UUID?)
        }
        private var activeDrag: ActiveDrag? = nil
        private var isBoundaryDragging = false
        /// Latest pointer-aligned marker position rendered directly by
        /// AppKit, avoiding a SwiftUI body update for every mouse event.
        private var boundaryVisualX: CGFloat?
        private var boundaryVisualDrag: ActiveDrag?
        /// The pointer-to-marker offset at mouseDown.  Keeping this offset
        /// makes the marker follow the exact point grabbed instead of jumping
        /// when the user starts on the wider hit target.
        private var boundaryGrabOffsetX: CGFloat = 0
        
        public override var isFlipped: Bool {
            return true // 坐标原点设置在左上角 (0, 0)
        }
        
        // 彻底禁止 AppKit 将波形拖拽识别为窗口拖拽移动
        public override var mouseDownCanMoveWindow: Bool {
            return false
        }
        
        public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            return true
        }

        func updateBoundaryDragState(_ dragging: Bool) {
            if modelIsBoundaryDragging && !dragging {
                boundaryVisualX = nil
                boundaryVisualDrag = nil
                needsDisplay = true
            }
            modelIsBoundaryDragging = dragging
            if dragging {
                needsDisplay = true
            }
        }

        public override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard modelIsBoundaryDragging || isBoundaryDragging else { return }

            let span = max(0.001, viewportEnd - viewportStart)
            let active = boundaryVisualDrag ?? activeDrag
            let coupledIndex: Int? = active.flatMap { drag in
                guard let x = boundaryVisualX else { return nil }
                return coupledAdjacentIndex(for: drag, visualX: x)
            }

            // During a drag, draw the stable markers in AppKit as well. The
            // SwiftUI Canvas is disabled for this frame, so a coalesced old
            // line cannot remain underneath the pointer-synchronous line.
            for (index, segment) in segments.enumerated() {
                guard segment.endTime >= viewportStart,
                      segment.startTime <= viewportEnd,
                      !isSecondaryView || activeSegmentIndex == (segment.index - 1) else { continue }

                let startX = CGFloat((segment.startTime - viewportStart) / span) * bounds.width + 1
                let endX = CGFloat((segment.endTime - viewportStart) / span) * bounds.width - 1
                let skipStart = active.map {
                    shouldSkipStartMarker(segment, index: index, drag: $0, coupledIndex: coupledIndex)
                } ?? false
                let skipEnd = active.map {
                    shouldSkipEndMarker(segment, index: index, drag: $0, coupledIndex: coupledIndex)
                } ?? false
                if !skipStart {
                    drawBoundaryLine(at: startX, color: .systemGreen)
                }
                if !skipEnd {
                    drawBoundaryLine(at: endX, color: .systemOrange)
                }

                if !isSecondaryView || activeSegmentIndex == (segment.index - 1) {
                    if !skipStart {
                        drawBoundaryBadge(label: "S#\(segment.index)", at: CGPoint(x: startX - 1 + 22, y: 11), color: .systemGreen, pointsRight: true)
                    }
                    if !skipEnd {
                        drawBoundaryBadge(label: "E#\(segment.index)", at: CGPoint(x: endX + 1 - 22, y: max(11, bounds.height - 11)), color: .systemOrange, pointsRight: false)
                    }
                }
            }

            guard let drag = active,
                  let x = boundaryVisualX else { return }
            switch drag {
            case .start(let id):
                drawBoundaryLine(at: x, color: .systemGreen)
                if let segment = segments.first(where: { $0.id == id }) {
                    drawBoundaryBadge(label: "S#\(segment.index)", at: CGPoint(x: x + 22, y: 11), color: .systemGreen, pointsRight: true)
                }
                if coupledIndex != nil {
                    drawBoundaryLine(at: x, color: .systemOrange)
                    if let index = coupledIndex, segments.indices.contains(index) {
                        let segment = segments[index]
                        drawBoundaryBadge(label: "E#\(segment.index)", at: CGPoint(x: x - 22, y: max(11, bounds.height - 11)), color: .systemOrange, pointsRight: false)
                    }
                }
            case .end(let id):
                drawBoundaryLine(at: x, color: .systemOrange)
                if let segment = segments.first(where: { $0.id == id }) {
                    drawBoundaryBadge(label: "E#\(segment.index)", at: CGPoint(x: x - 22, y: max(11, bounds.height - 11)), color: .systemOrange, pointsRight: false)
                }
                if coupledIndex != nil {
                    drawBoundaryLine(at: x, color: .systemGreen)
                    if let index = coupledIndex, segments.indices.contains(index) {
                        let segment = segments[index]
                        drawBoundaryBadge(label: "S#\(segment.index)", at: CGPoint(x: x + 22, y: 11), color: .systemGreen, pointsRight: true)
                    }
                }
            default:
                break
            }
        }

        private func drawBoundaryLine(at x: CGFloat, color: NSColor) {
            guard x.isFinite, x >= -2, x <= bounds.width + 2 else { return }
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            context.setLineWidth(2)
            context.setStrokeColor(color.cgColor)
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: bounds.height))
            context.strokePath()
            context.restoreGState()
        }

        private func shouldSkipStartMarker(
            _ segment: SentenceSegment,
            index: Int,
            drag: ActiveDrag,
            coupledIndex: Int?
        ) -> Bool {
            switch drag {
            case .start(let id):
                return segment.id == id
            case .end:
                return coupledIndex == index
            default:
                return false
            }
        }

        private func shouldSkipEndMarker(
            _ segment: SentenceSegment,
            index: Int,
            drag: ActiveDrag,
            coupledIndex: Int?
        ) -> Bool {
            switch drag {
            case .end(let id):
                return segment.id == id
            case .start:
                return coupledIndex == index
            default:
                return false
            }
        }

        private func drawBoundaryBadge(
            label: String,
            at center: CGPoint,
            color: NSColor,
            pointsRight: Bool
        ) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let font = NSFont.systemFont(ofSize: 9, weight: .black)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white
            ]
            let textSize = (label as NSString).size(withAttributes: attributes)
            let triangleWidth: CGFloat = 6
            let spacing: CGFloat = 2
            let horizontalPadding: CGFloat = 5
            let verticalPadding: CGFloat = 2
            let badgeSize = CGSize(
                width: textSize.width + triangleWidth + spacing + horizontalPadding * 2,
                height: max(15, textSize.height + verticalPadding * 2)
            )
            let rect = CGRect(
                x: center.x - badgeSize.width / 2,
                y: center.y - badgeSize.height / 2,
                width: badgeSize.width,
                height: badgeSize.height
            )

            context.saveGState()
            context.setFillColor(color.cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: badgeSize.height / 2, cornerHeight: badgeSize.height / 2, transform: nil))
            context.fillPath()

            let textX: CGFloat = pointsRight
                ? rect.minX + horizontalPadding + triangleWidth + spacing
                : rect.minX + horizontalPadding
            let textY = rect.minY + (badgeSize.height - textSize.height) / 2
            (label as NSString).draw(at: CGPoint(x: textX, y: textY), withAttributes: attributes)

            let triangleCenterX: CGFloat = pointsRight
                ? rect.minX + horizontalPadding + triangleWidth / 2
                : rect.maxX - horizontalPadding - triangleWidth / 2
            let triangleCenterY = rect.midY
            let triangle = CGMutablePath()
            if pointsRight {
                triangle.move(to: CGPoint(x: triangleCenterX - 2.5, y: triangleCenterY - 3))
                triangle.addLine(to: CGPoint(x: triangleCenterX - 2.5, y: triangleCenterY + 3))
                triangle.addLine(to: CGPoint(x: triangleCenterX + 2.5, y: triangleCenterY))
            } else {
                triangle.move(to: CGPoint(x: triangleCenterX + 2.5, y: triangleCenterY - 3))
                triangle.addLine(to: CGPoint(x: triangleCenterX + 2.5, y: triangleCenterY + 3))
                triangle.addLine(to: CGPoint(x: triangleCenterX - 2.5, y: triangleCenterY))
            }
            triangle.closeSubpath()
            context.setFillColor(NSColor.white.cgColor)
            context.addPath(triangle)
            context.fillPath()
            context.restoreGState()
        }

        private func coupledAdjacentIndex(for drag: ActiveDrag, visualX: CGFloat) -> Int? {
            let visualTime = timeFromX(visualX)
            switch drag {
            case .end(let id):
                guard let index = segments.firstIndex(where: { $0.id == id }),
                      index + 1 < segments.count,
                      visualTime >= segments[index + 1].startTime else { return nil }
                return index + 1
            case .start(let id):
                guard let index = segments.firstIndex(where: { $0.id == id }),
                      index > 0,
                      visualTime <= segments[index - 1].endTime else { return nil }
                return index - 1
            default:
                return nil
            }
        }
        
        public override var acceptsFirstResponder: Bool {
            return true
        }
        
        public override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea {
                removeTrackingArea(existing)
            }
            let options: NSTrackingArea.Options = [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]
            trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
            addTrackingArea(trackingArea!)
        }
        
        private func timeFromX(_ x: CGFloat) -> Double {
            let ratio = max(0, min(1, Double(x / max(1, bounds.width))))
            return viewportStart + ratio * (viewportEnd - viewportStart)
        }
        
        // MARK: - 鼠标按下 (命中判断与拖拽启动)
        
        public override func mouseDown(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            
            // 1. 优先命中绿/橙标线抓手
            if let hitHandle = handle(at: loc) {
                activeDrag = hitHandle
                boundaryVisualDrag = hitHandle
                boundaryVisualX = markerX(for: hitHandle) ?? loc.x
                boundaryGrabOffsetX = loc.x - (markerX(for: hitHandle) ?? loc.x)
                isBoundaryDragging = true
                needsDisplay = true
                onBoundaryDragBegan?()
                NSCursor.resizeLeftRight.set()
                return
            }

            boundaryGrabOffsetX = 0

            let clickTime = timeFromX(loc.x)
            
            // 2. 按住 Ctrl 键：设置断句起点
            if event.modifierFlags.contains(.control) {
                activeDrag = .emptyLeft
                onLeftClickEmpty?(clickTime)
            } else {
                // 3. 普通左键：主波形图先等待是否真的发生平移。
                // 如果一按下就立即选句并 Seek，用户只要稍微偏离标线几像素，
                // 拖动就会被误判成“点击下一句”，随后触发播放和自动推进。
                let pendingSegmentID = findSegment(near: clickTime)?.id
                if !isSecondaryView && onPanViewport != nil {
                    activeDrag = .pan(
                        lastX: loc.x,
                        didMove: false,
                        pendingSegmentID: pendingSegmentID
                    )
                    NSCursor.openHand.set()
                } else {
                    // 次波形没有平移手势，但同样要等 mouseUp 才确认这是
                    // 点击。否则在标线命中容差外按住拖动会立即跳句播放。
                    activeDrag = .tap(
                        lastX: loc.x,
                        didMove: false,
                        pendingSegmentID: pendingSegmentID
                    )
                }
            }
        }
        
        public override func rightMouseDown(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            if let hitHandle = handle(at: loc), case .end = hitHandle {
                activeDrag = hitHandle
                boundaryVisualDrag = hitHandle
                boundaryVisualX = markerX(for: hitHandle) ?? loc.x
                boundaryGrabOffsetX = loc.x - (markerX(for: hitHandle) ?? loc.x)
                isBoundaryDragging = true
                needsDisplay = true
                onBoundaryDragBegan?()
                NSCursor.resizeLeftRight.set()
                return
            }

            boundaryGrabOffsetX = 0

            let clickTime = timeFromX(loc.x)
            
            if event.modifierFlags.contains(.control) {
                if event.buttonNumber == 0 {
                    activeDrag = .emptyLeft
                    onLeftClickEmpty?(clickTime)
                } else {
                    activeDrag = .emptyRight
                    onRightClickEmpty?(clickTime)
                }
            } else {
                activeDrag = nil
            }
        }
        
        // MARK: - 鼠标拖拽 (平滑实时移动标线或平移主波形视口)
        
        public override func mouseDragged(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            let effectiveX = isBoundaryDragging ? loc.x - boundaryGrabOffsetX : loc.x
            let newTime = timeFromX(effectiveX)
            if isBoundaryDragging {
                boundaryVisualX = max(0, min(bounds.width, effectiveX))
                needsDisplay = true
            }
            updateActiveDrag(at: newTime, currentLocX: loc.x)
        }
        
        public override func rightMouseDragged(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            let effectiveX = isBoundaryDragging ? loc.x - boundaryGrabOffsetX : loc.x
            let newTime = timeFromX(effectiveX)
            if isBoundaryDragging {
                boundaryVisualX = max(0, min(bounds.width, effectiveX))
                needsDisplay = true
            }
            updateActiveDrag(at: newTime, currentLocX: loc.x)
        }
        
        // MARK: - 鼠标松开
        
        public override func mouseUp(with event: NSEvent) {
            selectBoundarySegmentAfterDragIfNeeded()
            switch activeDrag {
            case .pan(_, let didMove, let pendingSegmentID),
                 .tap(_, let didMove, let pendingSegmentID):
                if !didMove, let pendingSegmentID {
                    onSelectSegment?(pendingSegmentID)
                }
            default:
                break
            }
            if isBoundaryDragging {
                onBoundaryDragEnded?()
                isBoundaryDragging = false
            }
            activeDrag = nil
            boundaryGrabOffsetX = 0
            NSCursor.arrow.set()
        }
        
        public override func rightMouseUp(with event: NSEvent) {
            selectBoundarySegmentAfterDragIfNeeded()
            if isBoundaryDragging {
                onBoundaryDragEnded?()
                isBoundaryDragging = false
            }
            activeDrag = nil
            boundaryGrabOffsetX = 0
            NSCursor.arrow.set()
        }
        
        // MARK: - 鼠标悬停光标变化
        
        public override func mouseMoved(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            if handle(at: loc) != nil {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }

        public override func mouseEntered(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            if handle(at: loc) != nil {
                NSCursor.resizeLeftRight.set()
            }
        }

        public override func cursorUpdate(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            if handle(at: loc) != nil {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        
        public override func mouseExited(with event: NSEvent) {
            if activeDrag == nil {
                NSCursor.arrow.set()
            }
        }
        
        private func findSegment(near time: Double) -> SentenceSegment? {
            guard !segments.isEmpty else { return nil }
            // The timeline is ordered. Locate the insertion point once instead
            // of filtering the complete segment array for every mouse event.
            var low = 0
            var high = segments.count
            while low < high {
                let middle = (low + high) / 2
                if segments[middle].startTime <= time {
                    low = middle + 1
                } else {
                    high = middle
                }
            }

            let insertion = low
            if insertion > 0, segments[insertion - 1].contains(time: time) {
                return segments[insertion - 1]
            }
            if insertion < segments.count, segments[insertion].contains(time: time) {
                return segments[insertion]
            }

            var nearest: SentenceSegment?
            var nearestDistance = Double.greatestFiniteMagnitude
            for index in [insertion - 1, insertion] where segments.indices.contains(index) {
                let segment = segments[index]
                let distance = min(abs(segment.startTime - time), abs(segment.endTime - time))
                if distance <= 0.6, distance < nearestDistance {
                    nearest = segment
                    nearestDistance = distance
                }
            }
            return nearest
        }

        private func visibleSegmentRange() -> Range<Int> {
            guard !segments.isEmpty else { return 0..<0 }
            var lower = 0
            var upper = segments.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if segments[middle].endTime < viewportStart {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            let first = lower
            lower = first
            upper = segments.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if segments[middle].startTime <= viewportEnd {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return first..<lower
        }

        func handle(at loc: NSPoint) -> ActiveDrag? {
            let span = max(0.001, viewportEnd - viewportStart)
            let width = bounds.width
            let height = bounds.height
            let candidateRange = visibleSegmentRange()

            // 顶部/底部保留更宽的垂直抓取区，避免触控板在徽章边缘丢失
            // mouseDown；中间区域也放宽，但仍始终选择最近的标线。
            let edgeZoneHeight = min(30, max(0, height / 2 - 1))
            let edgeHitTolerance: CGFloat = 30
            let middleHitTolerance: CGFloat = 18

            // 1. 顶部区域 -> 优先抓取绿色起始标线 (S#)
            if loc.y <= edgeZoneHeight {
                var nearest: (drag: ActiveDrag, distance: CGFloat)?
                for index in candidateRange {
                    let seg = segments[index]
                    guard !isSecondaryView || activeSegmentIndex == (seg.index - 1) else { continue }
                    let startX = CGFloat((seg.startTime - viewportStart) / span) * width + 1.0
                    let distance = abs(loc.x - startX)
                    if distance <= edgeHitTolerance, nearest == nil || distance < nearest!.distance {
                        nearest = (.start(id: seg.id), distance)
                    }
                }
                if let nearest {
                    return nearest.drag
                }
            }

            // 2. 底部区域 -> 优先抓取橙色结束标线 (E#)
            if loc.y >= (height - edgeZoneHeight) {
                var nearest: (drag: ActiveDrag, distance: CGFloat)?
                for index in candidateRange {
                    let seg = segments[index]
                    guard !isSecondaryView || activeSegmentIndex == (seg.index - 1) else { continue }
                    let endX = CGFloat((seg.endTime - viewportStart) / span) * width - 1.0
                    let distance = abs(loc.x - endX)
                    if distance <= edgeHitTolerance, nearest == nil || distance < nearest!.distance {
                        nearest = (.end(id: seg.id), distance)
                    }
                }
                if let nearest {
                    return nearest.drag
                }
            }

            // 3. 标线垂直中间区域
            var nearestMiddle: (drag: ActiveDrag, distance: CGFloat)?
            for index in candidateRange {
                let seg = segments[index]
                guard !isSecondaryView || activeSegmentIndex == (seg.index - 1) else { continue }
                let startX = CGFloat((seg.startTime - viewportStart) / span) * width + 1.0
                let endX = CGFloat((seg.endTime - viewportStart) / span) * width - 1.0
                let distStart = abs(loc.x - startX)
                let distEnd = abs(loc.x - endX)
                if distStart <= middleHitTolerance,
                   nearestMiddle == nil || distStart < nearestMiddle!.distance {
                    nearestMiddle = (.start(id: seg.id), distStart)
                }
                if distEnd <= middleHitTolerance,
                   nearestMiddle == nil || distEnd < nearestMiddle!.distance {
                    nearestMiddle = (.end(id: seg.id), distEnd)
                }
            }
            if let nearest = nearestMiddle {
                return nearest.drag
            }

            return nil
        }

        private func updateActiveDrag(at newTime: Double, currentLocX: CGFloat) {
            guard let drag = activeDrag else { return }

            switch drag {
            case .start(let id):
                NSCursor.resizeLeftRight.set()
                // Keep the pointer's raw time.  The engine owns only the
                // minimum-duration and adjacent-boundary constraints against
                // its latest segment array; no acoustic snap is applied.
                onUpdateStartAnchor?(id, max(0, min(newTime, duration > 0 ? duration : newTime)))
            case .end(let id):
                NSCursor.resizeLeftRight.set()
                let maxBound = duration > 0 ? duration : max(0, newTime)
                onUpdateEndAnchor?(id, min(maxBound, max(0, newTime)))
            case .emptyLeft:
                onLeftClickEmpty?(newTime)
            case .emptyRight:
                onRightClickEmpty?(newTime)
            case .pan(let lastX, let didMove, _):
                let deltaX = currentLocX - lastX
                let hasMoved = didMove || abs(deltaX) > 2
                guard hasMoved else { return }
                let span = max(0.001, viewportEnd - viewportStart)
                let deltaTime = -Double(deltaX / max(1, bounds.width)) * span
                activeDrag = .pan(lastX: currentLocX, didMove: true, pendingSegmentID: nil)
                NSCursor.closedHand.set()
                onPanViewport?(deltaTime)
            case .tap(let lastX, let didMove, _):
                guard didMove || abs(currentLocX - lastX) > 2 else { return }
                activeDrag = .tap(lastX: currentLocX, didMove: true, pendingSegmentID: nil)
            }
        }

        private func markerX(for drag: ActiveDrag) -> CGFloat? {
            let span = max(0.001, viewportEnd - viewportStart)
            let width = bounds.width
            switch drag {
            case .start(let id):
                guard let segment = segments.first(where: { $0.id == id }) else { return nil }
                return CGFloat((segment.startTime - viewportStart) / span) * width + 1.0
            case .end(let id):
                guard let segment = segments.first(where: { $0.id == id }) else { return nil }
                return CGFloat((segment.endTime - viewportStart) / span) * width - 1.0
            default:
                return nil
            }
        }

        private func selectSegmentForBoundaryDrag(_ id: UUID) {
            onSelectSegmentForBoundaryDrag?(id)
        }

        private func selectBoundarySegmentAfterDragIfNeeded() {
            guard isBoundaryDragging else { return }
            switch activeDrag {
            case .start(let id), .end(let id):
                selectSegmentForBoundaryDrag(id)
            default:
                break
            }
        }
    }
}
