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
                isSecondaryView: isSecondaryView
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
                isSecondaryView: isSecondaryView
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
                onBoundaryDragBegan: onBoundaryDragBegan,
                onBoundaryDragEnded: onBoundaryDragEnded,
                onPanViewport: onPanViewport,
                onSelectSegment: { id in
                    engine.jumpToSegment(id: id)
                },
                onUpdateStartAnchor: { id, newStart in
                    engine.updateSegmentAnchor(id: id, start: newStart)
                },
                onUpdateEndAnchor: { id, newEnd in
                    engine.updateSegmentAnchor(id: id, end: newEnd)
                },
                onSnapBoundary: { id, proposedTime, isStart in
                    engine.snappedBoundaryTime(id: id, proposed: proposedTime, isStart: isStart)
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

    var body: some View {
        let span = max(0.001, viewportEnd - viewportStart)
        Canvas { context, _ in
            for segment in segments {
                let isActive = activeSegmentIndex == (segment.index - 1)
                guard !isSecondaryView || isActive else { continue }
                let startX = CGFloat((segment.startTime - viewportStart) / span) * width + 1
                let endX = CGFloat((segment.endTime - viewportStart) / span) * width - 1

                var startPath = Path()
                startPath.move(to: CGPoint(x: startX, y: 0))
                startPath.addLine(to: CGPoint(x: startX, y: height))
                context.stroke(
                    startPath,
                    with: .color(Color(nsColor: .systemGreen)),
                    lineWidth: 2
                )

                var endPath = Path()
                endPath.move(to: CGPoint(x: endX, y: 0))
                endPath.addLine(to: CGPoint(x: endX, y: height))
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

    var body: some View {
        let span = max(0.001, viewportEnd - viewportStart)
        ZStack(alignment: .topLeading) {
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
    let onBoundaryDragBegan: () -> Void
    let onBoundaryDragEnded: () -> Void
    let onPanViewport: ((Double) -> Void)?
    
    let onSelectSegment: (UUID) -> Void
    let onUpdateStartAnchor: (UUID, Double) -> Void
    let onUpdateEndAnchor: (UUID, Double) -> Void
    let onSnapBoundary: ((UUID, Double, Bool) -> Double)?
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
        view.onBoundaryDragBegan = onBoundaryDragBegan
        view.onBoundaryDragEnded = onBoundaryDragEnded
        view.onPanViewport = onPanViewport
        view.onSelectSegment = onSelectSegment
        view.onUpdateStartAnchor = onUpdateStartAnchor
        view.onUpdateEndAnchor = onUpdateEndAnchor
        view.onSnapBoundary = onSnapBoundary
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
        var onBoundaryDragBegan: (() -> Void)?
        var onBoundaryDragEnded: (() -> Void)?
        var onPanViewport: ((Double) -> Void)?
        
        var onSelectSegment: ((UUID) -> Void)?
        var onUpdateStartAnchor: ((UUID, Double) -> Void)?
        var onUpdateEndAnchor: ((UUID, Double) -> Void)?
        var onSnapBoundary: ((UUID, Double, Bool) -> Double)?
        var onLeftClickEmpty: ((Double) -> Void)?
        var onRightClickEmpty: ((Double) -> Void)?
        
        private var trackingArea: NSTrackingArea?
        
        // 正在拖拽的目标类型
        enum ActiveDrag: Equatable {
            case start(id: UUID)
            case end(id: UUID)
            case emptyLeft
            case emptyRight
            case pan(lastX: CGFloat)
        }
        private var activeDrag: ActiveDrag? = nil
        private var isBoundaryDragging = false
        
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
                isBoundaryDragging = true
                onBoundaryDragBegan?()
                if case .start(let id) = hitHandle {
                    onSelectSegment?(id)
                } else if case .end(let id) = hitHandle {
                    onSelectSegment?(id)
                }
                NSCursor.resizeLeftRight.set()
                return
            }

            let clickTime = timeFromX(loc.x)
            
            // 2. 按住 Ctrl 键：设置断句起点
            if event.modifierFlags.contains(.control) {
                activeDrag = .emptyLeft
                onLeftClickEmpty?(clickTime)
            } else {
                // 3. 普通左键单击：智能查找命中或临近的断句并联动选中
                if let seg = findSegment(near: clickTime) {
                    onSelectSegment?(seg.id)
                }
                
                // 主波形图允许左右拖拽平移视口浏览附近断句
                if !isSecondaryView && onPanViewport != nil {
                    activeDrag = .pan(lastX: loc.x)
                    NSCursor.openHand.set()
                } else {
                    activeDrag = nil
                }
            }
        }
        
        public override func rightMouseDown(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            if let hitHandle = handle(at: loc), case .end(let id) = hitHandle {
                activeDrag = hitHandle
                isBoundaryDragging = true
                onBoundaryDragBegan?()
                onSelectSegment?(id)
                NSCursor.resizeLeftRight.set()
                return
            }

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
            let newTime = timeFromX(loc.x)
            updateActiveDrag(at: newTime, currentLocX: loc.x)
        }
        
        public override func rightMouseDragged(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            let newTime = timeFromX(loc.x)
            updateActiveDrag(at: newTime, currentLocX: loc.x)
        }
        
        // MARK: - 鼠标松开
        
        public override func mouseUp(with event: NSEvent) {
            if isBoundaryDragging {
                onBoundaryDragEnded?()
                isBoundaryDragging = false
            }
            activeDrag = nil
            NSCursor.arrow.set()
        }
        
        public override func rightMouseUp(with event: NSEvent) {
            if isBoundaryDragging {
                onBoundaryDragEnded?()
                isBoundaryDragging = false
            }
            activeDrag = nil
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
            // 1. 优先精确包含
            if let direct = segments.first(where: { $0.contains(time: time) }) {
                return direct
            }
            // 2. 如果在断句边缘或微小缝隙中（0.6秒内），智能匹配最近的一个断句
            let nearby = segments.filter { abs($0.startTime - time) <= 0.6 || abs($0.endTime - time) <= 0.6 }
            return nearby.min(by: { segA, segB in
                let distA = min(abs(segA.startTime - time), abs(segA.endTime - time))
                let distB = min(abs(segB.startTime - time), abs(segB.endTime - time))
                return distA < distB
            })
        }

        func handle(at loc: NSPoint) -> ActiveDrag? {
            let span = max(0.001, viewportEnd - viewportStart)
            let width = bounds.width
            let height = bounds.height
            let candidateSegments = segments.filter { seg in
                seg.endTime >= viewportStart && seg.startTime <= viewportEnd
            }

            // 1. 顶部区域 (y <= 24) -> 优先抓取绿色起始标线 (S#)
            if loc.y <= 24 {
                let candidates = candidateSegments.compactMap { seg -> (drag: ActiveDrag, distance: CGFloat)? in
                    guard !isSecondaryView || activeSegmentIndex == (seg.index - 1) else { return nil }
                    let startX = CGFloat((seg.startTime - viewportStart) / span) * width + 1.0
                    let distance = abs(loc.x - startX)
                    return distance <= 22 ? (.start(id: seg.id), distance) : nil
                }
                if let nearest = candidates.min(by: { $0.distance < $1.distance }) {
                    return nearest.drag
                }
            }

            // 2. 底部区域 (y >= height - 24) -> 优先抓取橙色结束标线 (E#)
            if loc.y >= (height - 24) {
                let candidates = candidateSegments.compactMap { seg -> (drag: ActiveDrag, distance: CGFloat)? in
                    guard !isSecondaryView || activeSegmentIndex == (seg.index - 1) else { return nil }
                    let endX = CGFloat((seg.endTime - viewportStart) / span) * width - 1.0
                    let distance = abs(loc.x - endX)
                    return distance <= 22 ? (.end(id: seg.id), distance) : nil
                }
                if let nearest = candidates.min(by: { $0.distance < $1.distance }) {
                    return nearest.drag
                }
            }

            // 3. 标线垂直中间区域
            let middleCandidates = candidateSegments.flatMap { seg -> [(drag: ActiveDrag, distance: CGFloat)] in
                guard !isSecondaryView || activeSegmentIndex == (seg.index - 1) else { return [] }
                let startX = CGFloat((seg.startTime - viewportStart) / span) * width + 1.0
                let endX = CGFloat((seg.endTime - viewportStart) / span) * width - 1.0
                let distStart = abs(loc.x - startX)
                let distEnd = abs(loc.x - endX)
                var result: [(drag: ActiveDrag, distance: CGFloat)] = []
                if distStart <= 10 { result.append((.start(id: seg.id), distStart)) }
                if distEnd <= 10 { result.append((.end(id: seg.id), distEnd)) }
                return result
            }
            if let nearest = middleCandidates.min(by: { $0.distance < $1.distance }) {
                return nearest.drag
            }

            return nil
        }

        private func updateActiveDrag(at newTime: Double, currentLocX: CGFloat) {
            guard let drag = activeDrag else { return }

            switch drag {
            case .start(let id):
                NSCursor.resizeLeftRight.set()
                if let seg = segments.first(where: { $0.id == id }) {
                    let clamped = max(0, min(newTime, seg.endTime - 0.05))
                    onUpdateStartAnchor?(id, onSnapBoundary?(id, clamped, true) ?? clamped)
                }
            case .end(let id):
                NSCursor.resizeLeftRight.set()
                if let seg = segments.first(where: { $0.id == id }) {
                    let maxBound = duration > 0 ? duration : 999999.0
                    let clamped = min(maxBound, max(seg.startTime + 0.05, newTime))
                    onUpdateEndAnchor?(id, onSnapBoundary?(id, clamped, false) ?? clamped)
                }
            case .emptyLeft:
                onLeftClickEmpty?(newTime)
            case .emptyRight:
                onRightClickEmpty?(newTime)
            case .pan(let lastX):
                let deltaX = currentLocX - lastX
                let span = max(0.001, viewportEnd - viewportStart)
                let deltaTime = -Double(deltaX / max(1, bounds.width)) * span
                activeDrag = .pan(lastX: currentLocX)
                NSCursor.closedHand.set()
                onPanViewport?(deltaTime)
            }
        }
    }
}
