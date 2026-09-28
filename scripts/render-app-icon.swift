#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

enum AppIconRenderer {
    static let variants: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    static let contents = """
        {
          "images" : [
            { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
            { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
            { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
            { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
            { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
            { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
            { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
            { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
            { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
            { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
          ],
          "info" : { "author" : "xcode", "version" : 1 }
        }

        """

    static func render(_ image: NSImage, pixels: Int) -> CGImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero,
            operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard
            let dest = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil)
        else { throw RenderError.cannotWrite(url.path) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.cannotWrite(url.path) }
    }

    enum RenderError: Error, CustomStringConvertible {
        case cannotRead(String)
        case cannotWrite(String)

        var description: String {
            switch self {
            case .cannotRead(let path): return "cannot read \(path)"
            case .cannotWrite(let path): return "cannot write \(path)"
            }
        }
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svg = root.appendingPathComponent("Assets/AppIcon.svg")
let catalog = root.appendingPathComponent("Amanuensis/Assets.xcassets/AppIcon.appiconset")

guard let master = NSImage(contentsOf: svg) else {
    throw AppIconRenderer.RenderError.cannotRead(svg.path)
}

try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
for variant in AppIconRenderer.variants {
    let image = AppIconRenderer.render(master, pixels: variant.pixels)
    try AppIconRenderer.write(image, to: catalog.appendingPathComponent(variant.name))
    print("rendered \(variant.name) (\(variant.pixels)px)")
}
try AppIconRenderer.contents.write(
    to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")
