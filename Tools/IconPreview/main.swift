import AppKit
let w = 528, h = 138
let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w*2, pixelsHigh: h*2, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
canvas.size = NSSize(width: w, height: h)
let context = NSGraphicsContext(bitmapImageRep: canvas)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let names = ["VPN active", "Blocked", "Off", "Check tunnel", "Unknown", "Working"]
for row in 0..<2 {
    let dark = row == 0
    let y = CGFloat(row*69)
    let fg = dark ? NSColor.white : NSColor.black
    NSColor(white: dark ? 0.15 : 0.96, alpha: 1).setFill()
    NSRect(x: 0,y:y,width:CGFloat(w),height:69).fill()
    for (i,glyph) in MenuGlyph.allCases.enumerated() {
        let x = CGFloat(44+i*88)
        let rect = NSRect(x: x-9,y:y+34,width:18,height:18)
        let cg = context.cgContext
        cg.beginTransparencyLayer(auxiliaryInfo:nil)
        glyph.image.draw(in:rect)
        cg.setBlendMode(.sourceIn)
        fg.setFill()
        rect.fill()
        cg.endTransparencyLayer()
        let label = NSAttributedString(string:names[i], attributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:fg])
        label.draw(at:NSPoint(x:x-label.size().width/2,y:y+12))
    }
}
NSGraphicsContext.restoreGraphicsState()
try canvas.representation(using:.png, properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
