#!/usr/bin/env swift
//
//  Rasterises Assets/MenuBarIcon.svg into the MenuBarIcon template imageset.
//  Run: xcrun swift design/tools/render-menu-icon.swift
//

import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svg = root.appendingPathComponent("Assets/MenuBarIcon.svg")
let imageset = root.appendingPathComponent("Amanuensis/Assets.xcassets/MenuBarIcon.imageset")

let variants: [(name: String, pixels: Int)] = [
    ("menubar-16.png", 16),
    ("menubar-32.png", 32),
]

let contents = """
    {
      "images" : [
        { "filename" : "menubar-16.png", "idiom" : "mac", "scale" : "1x" },
        { "filename" : "menubar-32.png", "idiom" : "mac", "scale" : "2x" }
      ],
      "info" : { "author" : "xcode", "version" : 1 },
      "properties" : { "template-rendering-intent" : "template" }
    }

    """

func rasterize(_ image: NSImage, pixels: Int) -> CGImage {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero,
               operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

guard let master = NSImage(contentsOf: svg) else {
    FileHandle.standardError.write("cannot read \(svg.path)\n".data(using: .utf8)!)
    exit(1)
}

try FileManager.default.createDirectory(at: imageset, withIntermediateDirectories: true)

for variant in variants {
    let cg = rasterize(master, pixels: variant.pixels)
    let url = imageset.appendingPathComponent(variant.name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        exit(1)
    }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else { exit(1) }
    print("rendered \(variant.name) (\(variant.pixels)px)")
}

try contents.write(
    to: imageset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")
