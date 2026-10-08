import AppKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("usage: verify_icon_assets <master.png> <menu.svg> <app.icns>\n", stderr)
    exit(2)
}

let pngURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard
    let data = try? Data(contentsOf: pngURL),
    let bitmap = NSBitmapImageRep(data: data)
else {
    fputs("could not decode master PNG\n", stderr)
    exit(1)
}

var minX = bitmap.pixelsWide
var minY = bitmap.pixelsHigh
var maxX = -1
var maxY = -1
for y in 0..<bitmap.pixelsHigh {
    for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }
}
guard maxX >= minX, maxY >= minY else {
    fputs("master PNG has no nonzero alpha pixels\n", stderr)
    exit(1)
}

guard let menu = NSImage(contentsOfFile: CommandLine.arguments[2]), menu.isValid else {
    fputs("menu SVG does not load through NSImage\n", stderr)
    exit(1)
}
guard let icon = NSImage(contentsOfFile: CommandLine.arguments[3]), icon.isValid else {
    fputs("ICNS does not load through NSImage\n", stderr)
    exit(1)
}

print("alphaBounds=\(minX),\(minY),\(maxX),\(maxY)")
print("menuSVGSize=\(Int(menu.size.width))x\(Int(menu.size.height))")
print("icnsRepresentations=\(icon.representations.count)")
