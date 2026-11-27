import AppKit

// The tunnel portal is shared with the application icon. All marks are drawn
// in points so AppKit can rasterize the template at the actual display scale.
enum MenuGlyph: CaseIterable {
    case active, blocked, inactive, attention, unknown, busy

    init(state: GuardState, busy: Bool) {
        if busy { self = .busy; return }
        switch state {
        case .active: self = .active
        case .blocked: self = .blocked
        case .inactive: self = .inactive
        case .attention: self = .attention
        case .unknown: self = .unknown
        }
    }

    private static let images = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.makeImage()) })
    var image: NSImage { Self.images[self]! }

    private static let dots = Dictionary(uniqueKeysWithValues: allCases.compactMap { glyph -> (MenuGlyph, NSImage)? in
        let color: NSColor
        switch glyph {
        case .active: color = .systemGreen
        case .blocked: color = .systemOrange
        case .attention: color = .systemRed
        case .inactive, .unknown: color = .systemGray
        case .busy: return nil
        }
        let dot = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
            color.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).fill()
            return true
        }
        return (glyph, dot)
    })
    var statusDot: NSImage? { Self.dots[self] }

    private func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let portal = NSBezierPath()
            portal.move(to: NSPoint(x: 2, y: 15.75))
            portal.line(to: NSPoint(x: 2, y: 8.75))
            portal.curve(to: NSPoint(x: 9, y: 1.75),
                         controlPoint1: NSPoint(x: 2, y: 4.88), controlPoint2: NSPoint(x: 5.13, y: 1.75))
            portal.curve(to: NSPoint(x: 16, y: 8.75),
                         controlPoint1: NSPoint(x: 12.87, y: 1.75), controlPoint2: NSPoint(x: 16, y: 4.88))
            portal.line(to: NSPoint(x: 16, y: 15.75))
            portal.lineWidth = 2
            portal.stroke()

            func line(_ points: [(CGFloat, CGFloat)], width: CGFloat = 2) {
                let p = NSBezierPath()
                for (index, pair) in points.enumerated() {
                    let pt = NSPoint(x: pair.0, y: pair.1)
                    if index == 0 { p.move(to: pt) } else { p.line(to: pt) }
                }
                p.lineWidth = width
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
                p.stroke()
            }
            func dot(_ x: CGFloat, _ y: CGFloat, radius: CGFloat = 1) {
                NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius,
                                            width: radius * 2, height: radius * 2)).fill()
            }
            switch self {
            case .active:
                line([(5.4, 10.4), (8, 13), (12.7, 7.9)])
            case .blocked:
                let shackle = NSBezierPath(roundedRect: NSRect(x: 6.5, y: 5.75, width: 5, height: 7),
                                           xRadius: 2.5, yRadius: 2.5)
                shackle.lineWidth = 1.5
                shackle.stroke()
                let body = NSBezierPath(roundedRect: NSRect(x: 4.5, y: 10, width: 9, height: 6),
                                        xRadius: 1.5, yRadius: 1.5)
                body.fill()
            case .inactive:
                let sign = NSBezierPath()
                sign.move(to: NSPoint(x: 7, y: 6))
                sign.line(to: NSPoint(x: 11, y: 6))
                sign.line(to: NSPoint(x: 13.5, y: 8.5))
                sign.line(to: NSPoint(x: 13.5, y: 12.5))
                sign.line(to: NSPoint(x: 11, y: 15))
                sign.line(to: NSPoint(x: 7, y: 15))
                sign.line(to: NSPoint(x: 4.5, y: 12.5))
                sign.line(to: NSPoint(x: 4.5, y: 8.5))
                sign.close()
                sign.append(NSBezierPath(roundedRect: NSRect(x: 6.5, y: 10, width: 5, height: 1.5),
                                         xRadius: 0.75, yRadius: 0.75))
                sign.windingRule = .evenOdd
                sign.fill()
            case .attention:
                line([(9, 6.5), (9, 10.2)])
                dot(9, 13.4)
            case .unknown:
                let p = NSBezierPath()
                p.move(to: NSPoint(x: 6.8, y: 7.9))
                p.curve(to: NSPoint(x: 11.2, y: 8.2),
                        controlPoint1: NSPoint(x: 7.2, y: 5.25), controlPoint2: NSPoint(x: 11.4, y: 5.3))
                p.curve(to: NSPoint(x: 9, y: 11),
                        controlPoint1: NSPoint(x: 11.1, y: 9.65), controlPoint2: NSPoint(x: 9, y: 9.6))
                p.lineWidth = 1.65
                p.lineCapStyle = .round
                p.stroke()
                dot(9, 13.5, radius: 0.9)
            case .busy:
                for x in [5.6, 9.0, 12.4] { dot(x, 10.75) }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
