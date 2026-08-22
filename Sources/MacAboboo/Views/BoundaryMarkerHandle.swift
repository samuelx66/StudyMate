import SwiftUI
import AppKit

/// 醒目美观的可拖拽断句起止标识线组件
public struct BoundaryMarkerHandle: View {
    public enum MarkerType {
        case start
        case end
    }
    
    let type: MarkerType
    let time: Double
    let viewportStart: Double
    let viewportEnd: Double
    let width: CGFloat
    let height: CGFloat
    let segmentIndex: Int
    let isActive: Bool
    let onDragTime: (Double) -> Void
    
    @State private var isHovering: Bool = false
    @State private var isDragging: Bool = false
    @State private var dragOffsetTime: Double = 0
    
    public init(
        type: MarkerType,
        time: Double,
        viewportStart: Double,
        viewportEnd: Double,
        width: CGFloat,
        height: CGFloat,
        segmentIndex: Int,
        isActive: Bool,
        onDragTime: @escaping (Double) -> Void
    ) {
        self.type = type
        self.time = time
        self.viewportStart = viewportStart
        self.viewportEnd = viewportEnd
        self.width = width
        self.height = height
        self.segmentIndex = segmentIndex
        self.isActive = isActive
        self.onDragTime = onDragTime
    }
    
    private var color: Color {
        switch type {
        case .start:
            return Color(nsColor: .systemGreen)
        case .end:
            return Color(nsColor: .systemOrange)
        }
    }
    
    private var label: String {
        switch type {
        case .start:
            return "S#\(segmentIndex)"
        case .end:
            return "E#\(segmentIndex)"
        }
    }
    
    public var body: some View {
        let span = max(0.001, viewportEnd - viewportStart)
        let effectiveTime = isDragging ? dragOffsetTime : time
        let posX = CGFloat((effectiveTime - viewportStart) / span) * width
        
        ZStack(alignment: .top) {
            // 1. 加粗加亮垂直指示线 (宽度 3.5px，悬停/拖拽时增加发光与对比度)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [color, color.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: isHovering || isDragging ? 4 : 3, height: height)
                .shadow(color: color.opacity(isHovering || isDragging ? 0.8 : 0.4), radius: isHovering || isDragging ? 4 : 2)
            
            // 2. 顶部专业手柄药丸徽章 (易于识别和抓取)
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    Image(systemName: type == .start ? "arrowtriangle.right.fill" : "arrowtriangle.left.fill")
                        .font(.system(size: 6))
                    Text(label)
                        .font(.system(size: 8, weight: .black, design: .rounded))
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .shadow(color: Color.black.opacity(0.3), radius: 2, y: 1)
                )
                .foregroundColor(.white)
                
                // 拖拽时浮现的毫秒级高亮时间码
                if isDragging || isHovering {
                    Text(SentenceSegment.formatTimecode(effectiveTime))
                        .font(.system(size: 7, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.85))
                        .foregroundColor(.white)
                        .cornerRadius(3)
                        .offset(y: 1)
                }
            }
            .offset(y: -4)
            
            // 3. 宽阔透明命中区域 (18px)，确保鼠标轻松精准抓取拖动
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: 20, height: height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                dragOffsetTime = time
                            }
                            let deltaX = value.translation.width
                            let deltaTime = Double(deltaX / width) * span
                            let targetTime = max(0, time + deltaTime)
                            dragOffsetTime = targetTime
                            onDragTime(targetTime)
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
                .onHover { inside in
                    isHovering = inside
                    if inside {
                        NSCursor.resizeLeftRight.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
        }
        .offset(x: posX - 10)
    }
}
