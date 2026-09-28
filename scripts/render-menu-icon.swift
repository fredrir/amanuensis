#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

let pointHeight: CGFloat = 18

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svg = root.appendingPathComponent("Assets/MenuBarIcon.svg")
let imageset = root.appendingPathComponent("Amanuensis/Assets.xcassets/MenuBarIcon.imageset")

let contents = """
    {
      "images" : [
        { "filename" : "menubar-1x.png", "idiom" : "mac", "scale" : "1x" },
        { "filename" : "menubar-2x.png", "idiom" : "mac", "scale" : "2x" }
      ],
      "info" : { "author" : "xcode", "version" : 1 },
      "properties" : { "template-rendering-intent" : "template" }
    }

    """

func rasterize(_ image: NSImage, width: Int, height: Int) -> CGImage {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero,
               operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { exit(1) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { exit(1) }
}

guard let master = NSImage(contentsOf: svg) else {
    FileHandle.standardError.write("cannot read \(svg.path)\n".data(using: .utf8)!)
    exit(1)
}

let aspect = master.size.width / master.size.height
try FileManager.default.createDirectory(at: imageset, withIntermediateDirectories: true)

for scale in 1...2 {
    let height = Int((pointHeight * CGFloat(scale)).rounded())
    let width = Int((pointHeight * CGFloat(scale) * aspect).rounded())
    let cg = rasterize(master, width: width, height: height)
    let name = "menubar-\(scale)x.png"
    write(cg, to: imageset.appendingPathComponent(name))
    print("rendered \(name) (\(width)x\(height)px)")
}

for stale in ["menubar-16.png", "menubar-32.png"] {
    let url = imageset.appendingPathComponent(stale)
    try? FileManager.default.removeItem(at: url)
}

try contents.write(
    to: imageset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")
