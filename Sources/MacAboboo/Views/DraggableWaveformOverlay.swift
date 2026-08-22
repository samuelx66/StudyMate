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
        let span = max(0.001, viewportEnd - viewportStart)
        
        ZStack(alignment: .topLeading) {
            // 1. 经典视觉渲染层：绿色 S# 置顶、橙色 E# 置底，两端对齐绝不遮挡
            ZStack {
                ForEach(engine.segments) { seg in
                    if seg.endTime >= viewportStart && seg.startTime <= viewportEnd {
                        let isActive = (engine.activeSegmentIndex == (seg.index - 1))
                        
                        if !isSecondaryView || isActive {
                            let startX = CGFloat((seg.startTime - viewportStart) / span) * width
                            let endX = CGFloat((seg.endTime - viewportStart) / span) * width
                            let lineWidth: CGFloat = 2.0
                            
                            // 🟢 绿色起始线 + 【顶部】S# 胶囊徽章 (左边线紧靠在 startX，向右延伸，中心在 startX + lineWidth/2)
                            ZStack(alignment: .top) {
                                Rectangle()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color(nsColor: .systemGreen), Color(nsColor: .systemGreen).opacity(0.85)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(width: lineWidth, height: height)
                                    .shadow(color: Color(nsColor: .systemGreen).opacity(0.4), radius: 1)
                                
                                HStack(spacing: 2) {
                                    Image(systemName: "arrowtriangle.right.fill")
                                        .font(.system(size: 6))
                                    Text("S#\(seg.index)")
                                        .font(.system(size: 9, weight: .black, design: .rounded))
                                }
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color(nsColor: .systemGreen))
                                        .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)
                                )
                                .foregroundColor(.white)
                                .fixedSize()
                                .offset(y: 2)
                            }
                            .frame(width: 44, height: height)
                            .position(x: startX + lineWidth / 2.0, y: height / 2.0)
                            
                            // 🟠 橙色结束线 + 【底部】E# 胶囊徽章 (右边线紧靠在 endX，向左延伸，中心在 endX - lineWidth/2)
                            ZStack(alignment: .bottom) {
                                Rectangle()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color(nsColor: .systemOrange), Color(nsColor: .systemOrange).opacity(0.85)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(width: lineWidth, height: height)
                                    .shadow(color: Color(nsColor: .systemOrange).opacity(0.4), radius: 1)
                                
                                HStack(spacing: 2) {
                                    Text("E#\(seg.index)")
                                        .font(.system(size: 9, weight: .black, design: .rounded))
                                    Image(systemName: "arrowtriangle.left.fill")
                                        .font(.system(size: 6))
                                }
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color(nsColor: .systemOrange))
                                        .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)
                                )
                                .foregroundColor(.white)
                                .fixedSize()
                                .offset(y: -2)
                            }
                            .frame(width: 44, height: height)
                            .position(x: endX - lineWidth / 2.0, y: height / 2.0)
                        }
                    }
                }
            }
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
        var onLeftClickEmpty: ((Double) -> Void)?
        var onRightClickEmpty: ((Double) -> Void)?
        
        private var trackingArea: NSTrackingArea?
        
        // 正在拖拽的目标类型
        private enum ActiveDrag {
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

        private func handle(at loc: NSPoint) -> ActiveDrag? {
            let span = max(0.001, viewportEnd - viewportStart)
            let width = bounds.width
            let height = bounds.height
            let candidateSegments = segments.filter { seg in
                seg.endTime >= viewportStart && seg.startTime <= viewportEnd
            }

            // 1. 顶部区域 (y <= 24) -> 优先抓取绿色起始标线 (S#)
            if loc.y <= 24 {
                for seg in candidateSegments where !isSecondaryView || activeSegmentIndex == (seg.index - 1) {
                    let startX = CGFloat((seg.startTime - viewportStart) / span) * width + 1.0
                    if abs(loc.x - startX) <= 22 {
                        return .start(id: seg.id)
                    }
                }
            }

            // 2. 底部区域 (y >= height - 24) -> 优先抓取橙色结束标线 (E#)
            if loc.y >= (height - 24) {
                for seg in candidateSegments where !isSecondaryView || activeSegmentIndex == (seg.index - 1) {
                    let endX = CGFloat((seg.endTime - viewportStart) / span) * width - 1.0
                    if abs(loc.x - endX) <= 22 {
                        return .end(id: seg.id)
                    }
                }
            }

            // 3. 标线垂直中间区域
            for seg in candidateSegments where !isSecondaryView || activeSegmentIndex == (seg.index - 1) {
                let startX = CGFloat((seg.startTime - viewportStart) / span) * width + 1.0
                let endX = CGFloat((seg.endTime - viewportStart) / span) * width - 1.0
                
                let distStart = abs(loc.x - startX)
                let distEnd = abs(loc.x - endX)
                
                if distStart <= 10 && distStart <= distEnd {
                    return .start(id: seg.id)
                } else if distEnd <= 10 {
                    return .end(id: seg.id)
                }
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
                    onUpdateStartAnchor?(id, clamped)
                }
            case .end(let id):
                NSCursor.resizeLeftRight.set()
                if let seg = segments.first(where: { $0.id == id }) {
                    let maxBound = duration > 0 ? duration : 999999.0
                    let clamped = min(maxBound, max(seg.startTime + 0.05, newTime))
                    onUpdateEndAnchor?(id, clamped)
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
