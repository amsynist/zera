#!/usr/bin/env swift
import AppKit

// Renders the app icon: Zera on a violet squircle, matching the reference sheet.
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S: CGFloat = 1024

let image = NSImage(size: NSSize(width: S, height: S))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
ctx.setShouldAntialias(true)

// macOS icon grid: rounded square inset from the canvas edge.
let inset: CGFloat = 92
let rect = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let radius = rect.width * 0.2237
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34,
              color: NSColor.black.withAlphaComponent(0.28).cgColor)
NSColor.black.setFill()
squircle.fill()
ctx.restoreGState()

ctx.saveGState()
squircle.addClip()
let top = NSColor(calibratedRed: 0.62, green: 0.56, blue: 1.00, alpha: 1)
let bottom = NSColor(calibratedRed: 0.36, green: 0.29, blue: 0.86, alpha: 1)
NSGradient(colors: [bottom, top])?.draw(in: rect, angle: 90)
// Soft glow behind her.
NSGradient(colorsAndLocations: (NSColor.white.withAlphaComponent(0.28), 0), (NSColor.white.withAlphaComponent(0), 1))?
    .draw(in: NSBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12)),
          relativeCenterPosition: NSPoint(x: 0, y: 0.1))
ctx.restoreGState()

// Zera on the tile: the real artwork when the sprite folder is given, vectors otherwise.
let spriteDir = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil
let library = SpriteLibrary(directory: spriteDir)
ctx.saveGState()
squircle.addClip()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
              color: NSColor.black.withAlphaComponent(0.22).cgColor)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
if let s = library.sprite("hello") {
    ctx.interpolationQuality = .high
    let h = rect.height * 0.84
    let w = h * s.aspect
    s.image.draw(in: NSRect(x: rect.midX - w / 2, y: rect.minY + rect.height * 0.08, width: w, height: h),
                 from: .zero, operation: .sourceOver, fraction: 1)
} else {
    // No sprites: the placeholder puff, centred.
    let v = ZeraView(frame: NSRect(x: 0, y: 0, width: rect.width * 0.8, height: rect.height * 0.8))
    v.style = .standing
    ctx.translateBy(x: rect.minX + rect.width * 0.1, y: rect.minY + rect.height * 0.1)
    v.draw(v.bounds)
}
ctx.endTransparencyLayer()
ctx.restoreGState()

NSColor.white.withAlphaComponent(0.22).setStroke()
squircle.lineWidth = 3
squircle.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try? png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
