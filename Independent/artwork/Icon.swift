// Run with swift Icon.swift output.png to regenerate the app's 1024-point mark.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmap = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                       bytesPerRow: 4096, space: rgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}
bitmap.drawLinearGradient(CGGradient(colorsSpace: rgb,
    colors: [color(12, 30, 46), color(11, 56, 64)] as CFArray, locations: [0, 1])!,
    start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 870, y: 0), options: [])
// A single terminal prompt bent into a 3. The shorter mint stroke is its cursor.
bitmap.setStrokeColor(color(236, 248, 235))
bitmap.setLineWidth(64)
bitmap.setLineCap(.round)
bitmap.setLineJoin(.round)
let mark = CGMutablePath()
mark.move(to: CGPoint(x: 243, y: 760))
mark.addLine(to: CGPoint(x: 664, y: 760))
mark.addLine(to: CGPoint(x: 476, y: 527))
mark.addLine(to: CGPoint(x: 654, y: 527))
mark.addLine(to: CGPoint(x: 426, y: 252))
bitmap.addPath(mark)
bitmap.strokePath()
bitmap.setStrokeColor(color(78, 234, 185))
bitmap.setLineWidth(52)
bitmap.move(to: CGPoint(x: 620, y: 256))
bitmap.addLine(to: CGPoint(x: 803, y: 256))
bitmap.strokePath()
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let target = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(target, bitmap.makeImage()!, nil)
precondition(CGImageDestinationFinalize(target))
