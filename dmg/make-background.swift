#!/usr/bin/env swift
//
// Renders the DMG installer-window background — a soft blue wash echoing the
// app icon, with a drag arrow pointing from the app toward Applications.
//
// Window is 660x400 *points*. We render at 1x (660x400) and 2x (1320x800);
// create-dmg picks up the `@2x` file automatically for Retina displays.
//
// Coordinates below are in points with a TOP-LEFT origin (we flip the context),
// so they line up 1:1 with the create-dmg `--icon`/`--app-drop-link` positions.

import AppKit

let W: CGFloat = 660
let H: CGFloat = 400

// Icon centers — must match build-dmg.sh.
let appX: CGFloat = 175
let dropX: CGFloat = 485
let iconY: CGFloat = 170

func render(scale: CGFloat, to url: URL) {
    let pxW = Int(W * scale)
    let pxH = Int(H * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("rep") }
    rep.size = NSSize(width: W, height: H)

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // Flip to a top-left origin so points map straight to Finder coordinates.
    cg.translateBy(x: 0, y: H)
    cg.scaleBy(x: 1, y: -1)

    // --- Background wash: very light blue, brand-tinted, top -> bottom. ---
    let top = NSColor(srgbRed: 0.97, green: 0.985, blue: 1.00, alpha: 1)
    let bot = NSColor(srgbRed: 0.90, green: 0.945, blue: 0.99, alpha: 1)
    let grad = NSGradient(colors: [top, bot])!
    cg.saveGState()
    // NSGradient draws in the current (flipped) space; that's fine for a vertical fill.
    grad.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
    cg.restoreGState()

    // --- Title + subtitle, centered up top. ---
    let titleColor = NSColor(srgbRed: 0.12, green: 0.18, blue: 0.30, alpha: 1)
    let subColor = NSColor(srgbRed: 0.32, green: 0.40, blue: 0.52, alpha: 1)

    func drawCentered(_ s: String, font: NSFont, color: NSColor, y: CGFloat) {
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: para
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let size = str.size()
        // Draw in flipped space: y is distance from top to the text's top edge.
        cg.saveGState()
        cg.translateBy(x: 0, y: y + size.height)
        cg.scaleBy(x: 1, y: -1)
        str.draw(with: NSRect(x: 0, y: 0, width: W, height: size.height),
                 options: [.usesLineFragmentOrigin])
        cg.restoreGState()
    }

    drawCentered("Install DeEsser",
                 font: .systemFont(ofSize: 22, weight: .semibold),
                 color: titleColor, y: 36)
    drawCentered("Drag the app into your Applications folder",
                 font: .systemFont(ofSize: 13, weight: .regular),
                 color: subColor, y: 70)

    // --- Drag arrow, brand blue, pointing right between the two icons. ---
    let mid = (appX + dropX) / 2          // ~330
    let half: CGFloat = 46                 // arrow half-length
    let y = iconY                          // align with icon centers
    let shaftH: CGFloat = 10
    let headW: CGFloat = 34
    let headH: CGFloat = 40
    let x0 = mid - half                    // shaft start
    let xHead = mid + half - headW         // where the head begins
    let xTip = mid + half

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: x0, y: y - shaftH / 2))
    arrow.line(to: NSPoint(x: xHead, y: y - shaftH / 2))
    arrow.line(to: NSPoint(x: xHead, y: y - headH / 2))
    arrow.line(to: NSPoint(x: xTip, y: y))
    arrow.line(to: NSPoint(x: xHead, y: y + headH / 2))
    arrow.line(to: NSPoint(x: xHead, y: y + shaftH / 2))
    arrow.line(to: NSPoint(x: x0, y: y + shaftH / 2))
    arrow.close()

    cg.saveGState()
    cg.setShadow(offset: .init(width: 0, height: -1), blur: 3,
                 color: NSColor(srgbRed: 0.18, green: 0.45, blue: 0.95, alpha: 0.35).cgColor)
    NSColor(srgbRed: 0.18, green: 0.50, blue: 0.96, alpha: 1).setFill()
    arrow.fill()
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode")
    }
    try! png.write(to: url)
    print("wrote \(url.path) (\(pxW)x\(pxH))")
}

let here = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
    .deletingLastPathComponent()
render(scale: 1, to: here.appendingPathComponent("background.png"))
render(scale: 2, to: here.appendingPathComponent("background@2x.png"))
