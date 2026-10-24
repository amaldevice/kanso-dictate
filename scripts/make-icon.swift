#!/usr/bin/env swift
// Reproducible app-icon pipeline for Kanso Dictate.
//
//   swift scripts/make-icon.swift docs/assets/kanso-dictate-icon-simplified.png \
//        Sources/KansoDictate/Resources/AppIcon.icns
//
// The source art ships a soft glow that escapes past the rounded-square tile
// to the canvas edge; macOS renders .icns art as-is, so the glow would show
// as a smudge around the Dock icon. Alpha thresholding cannot separate it
// (the glow is high-alpha near the tile border), so this script applies a
// geometric mask: an analytic rounded-rect coverage test measured from the
// tile's own corner curve (~118px radius on a 1024 canvas), then emits the
// full iconset and packs it with iconutil.

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: swift scripts/make-icon.swift <source-1024.png> <output.icns>")
    exit(64)
}
let srcPath = args[1]
let outPath = args[2]

guard let img = NSImage(contentsOfFile: srcPath),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("error: cannot load \(srcPath)")
    exit(1)
}
let w = cg.width, h = cg.height
guard w == h else {
    print("error: source must be square, got \(w)x\(h)")
    exit(1)
}

guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("error: context")
    exit(1)
}
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
guard let buf = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else {
    print("error: buffer")
    exit(1)
}

// Tile geometry on a 1024 canvas; scale proportionally for other sizes.
let scale = Double(w) / 1024
let inset = 4.0 * scale
let cornerRadius = 118.0 * scale
let half = Double(w) / 2 - inset
func coverage(_ xf: Double, _ yf: Double) -> Double {
    let dx = abs(xf - Double(w) / 2) - (half - cornerRadius)
    let dy = abs(yf - Double(h) / 2) - (half - cornerRadius)
    let ax = max(dx, 0), ay = max(dy, 0)
    // Signed distance to the rounded-rect border (negative inside).
    let sd = sqrt(ax * ax + ay * ay) - cornerRadius + min(max(dx, dy), 0)
    return min(max(0.5 - sd / (1.5 * scale), 0), 1)
}

for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        let a = Double(buf[i + 3]) / 255
        let newA = a * coverage(Double(x) + 0.5, Double(y) + 0.5)
        let ratio = a > 0.001 ? newA / a : 0
        for c in 0..<3 { buf[i + c] = UInt8(min(Double(buf[i + c]) * ratio, 255)) }
        buf[i + 3] = UInt8(newA * 255)
    }
}
guard let masked = ctx.makeImage() else { exit(1) }

func writePNG(_ path: String, _ size: Int) {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(masked, in: CGRect(x: 0, y: 0, width: size, height: size))
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("kanso-iconset")
let iconset = tmp + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: tmp)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for s in sizes { writePNG("\(iconset)/\(s.0)", s.1) }

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", "-o", outPath, iconset]
try! proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else { print("error: iconutil failed"); exit(1) }
print("wrote \(outPath)")
