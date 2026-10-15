#!/usr/bin/env swift
// Generates a placeholder app icon set (a scissors symbol on a rounded green tile).
// usage: swift scripts/make-icon.swift App/LopperApp/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "App/LopperApp/Resources/Assets.xcassets/AppIcon.appiconset"

func render(pixels: Int) -> Data {
    let size = NSSize(width: pixels, height: pixels)
    let image = NSImage(size: size, flipped: false) { rect in
        let inset = rect.width * 0.08
        let tile = rect.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
        NSColor(calibratedRed: 0.18, green: 0.72, blue: 0.45, alpha: 1).setFill()
        path.fill()

        let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.5, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return true }
        let tinted = NSImage(size: symbol.size, flipped: false) { symbolRect in
            symbol.draw(in: symbolRect)
            NSColor.white.set()
            symbolRect.fill(using: .sourceAtop)
            return true
        }
        let target = NSRect(
            x: rect.midX - tinted.size.width / 2, y: rect.midY - tinted.size.height / 2,
            width: tinted.size.width, height: tinted.size.height)
        tinted.draw(in: target)
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

struct Slot { let points: Int; let scale: Int }
let slots = [16, 32, 128, 256, 512].flatMap { [Slot(points: $0, scale: 1), Slot(points: $0, scale: 2)] }

try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
var images: [String] = []
for slot in slots {
    let pixels = slot.points * slot.scale
    let name = "icon_\(slot.points)x\(slot.points)@\(slot.scale)x.png"
    try render(pixels: pixels).write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent(name))
    images.append("""
        { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(slot.scale)x", "size" : "\(slot.points)x\(slot.points)" }
    """)
}
let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try contents.write(toFile: outputDirectory + "/Contents.json", atomically: true, encoding: .utf8)
print("wrote \(slots.count) icons to \(outputDirectory)")
