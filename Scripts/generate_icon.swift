import AppKit

func generateAppIcon(iconsetPath: String) {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)
    
    let sizes: [(name: String, size: CGFloat)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]
    
    for item in sizes {
        let size = item.size
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size),
            pixelsHigh: Int(size),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
        bitmap.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let ctx = graphicsContext.cgContext
        
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        
        // 1. macOS 标准连续圆角圆角矩形 (Squircle)
        let inset = size * 0.08
        let squircleRect = bounds.insetBy(dx: inset, dy: inset)
        let cornerRadius = size * 0.22
        let path = NSBezierPath(roundedRect: squircleRect, xRadius: cornerRadius, yRadius: cornerRadius)
        
        // 2. 阴影
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.03), blur: size * 0.06, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor.black.withAlphaComponent(0.2).setFill()
        path.fill()
        ctx.restoreGState()
        
        // 3. 背景渐变 (深海蓝到电光紫渐变)
        ctx.saveGState()
        path.addClip()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let gradientColors = [
            NSColor(red: 0.08, green: 0.12, blue: 0.28, alpha: 1.0).cgColor,
            NSColor(red: 0.15, green: 0.25, blue: 0.55, alpha: 1.0).cgColor,
            NSColor(red: 0.22, green: 0.40, blue: 0.85, alpha: 1.0).cgColor
        ] as CFArray
        let locations: [CGFloat] = [0.0, 0.5, 1.0]
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: locations) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX, y: bounds.maxY), end: CGPoint(x: bounds.midX, y: bounds.minY), options: [])
        }
        
        // 4. 内部高光层
        let glowPath = NSBezierPath(roundedRect: squircleRect.insetBy(dx: size * 0.015, dy: size * 0.015), xRadius: cornerRadius - 2, yRadius: cornerRadius - 2)
        glowPath.lineWidth = size * 0.015
        NSColor.white.withAlphaComponent(0.25).setStroke()
        glowPath.stroke()
        
        // 5. 绘制波形图 (Waveform Audio Bars)
        let barCount = 7
        let barWidth = size * 0.05
        let spacing = size * 0.035
        let totalBarsWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let startBarX = bounds.midX - totalBarsWidth / 2.0
        let centerY = bounds.midY
        
        let barHeights: [CGFloat] = [0.25, 0.48, 0.72, 0.90, 0.65, 0.42, 0.22]
        let barColors: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
            (0.2, 0.8, 0.6), // 绿色
            (0.3, 0.85, 0.7),
            (0.2, 0.7, 0.95), // 天蓝
            (0.3, 0.6, 1.0),
            (0.6, 0.4, 0.95), // 紫色
            (0.95, 0.5, 0.3), // 橙色
            (0.95, 0.4, 0.2)
        ]
        
        for i in 0..<barCount {
            let bh = size * 0.35 * barHeights[i]
            let bx = startBarX + CGFloat(i) * (barWidth + spacing)
            let by = centerY - bh / 2.0
            let barRect = CGRect(x: bx, y: by, width: barWidth, height: bh)
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2.0, yRadius: barWidth / 2.0)
            
            let col = barColors[i]
            NSColor(red: col.r, green: col.g, blue: col.b, alpha: 0.95).setFill()
            barPath.fill()
        }
        
        // 6. 顶部 Aboboo 风格 A-B 循环标识
        let badgeWidth = size * 0.36
        let badgeHeight = size * 0.12
        let badgeRect = CGRect(x: bounds.midX - badgeWidth / 2.0, y: bounds.midY - size * 0.28, width: badgeWidth, height: badgeHeight)
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: badgeHeight / 2.0, yRadius: badgeHeight / 2.0)
        NSColor.white.withAlphaComponent(0.2).setFill()
        badgePath.fill()
        
        // 文本 A ⇄ B
        let font = NSFont.systemFont(ofSize: size * 0.07, weight: .heavy)
        let text = "A ⇄ B"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let textPoint = CGPoint(x: bounds.midX - textSize.width / 2.0, y: badgeRect.midY - textSize.height / 2.0)
        (text as NSString).draw(at: textPoint, withAttributes: attrs)
        
        ctx.restoreGState()
        
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        if let png = bitmap.representation(using: .png, properties: [:]) {
            let outUrl = URL(fileURLWithPath: iconsetPath).appendingPathComponent(item.name)
            try? png.write(to: outUrl)
        }
    }
    
    print("All icons successfully generated in \(iconsetPath)")
}

let args = CommandLine.arguments
let targetDir = args.count > 1 ? args[1] : "AppIcon.iconset"
generateAppIcon(iconsetPath: targetDir)
