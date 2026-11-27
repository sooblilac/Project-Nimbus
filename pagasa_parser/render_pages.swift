// Renders every page of a PAGASA bulletin PDF to p1.jpg, p2.jpg, ... (macOS, no installs).
// Usage: swift render_pages.swift bulletin.pdf out_dir    (Linux uses pdftoppm instead)
import AppKit
import PDFKit

let args = CommandLine.arguments
guard args.count >= 3, let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("usage: swift render_pages.swift file.pdf out_dir\n".data(using: .utf8)!)
    exit(1)
}
let outDir = args[2]
let width: CGFloat = 1100
for i in 0..<doc.pageCount {
    guard let page = doc.page(at: i) else { continue }
    let box = page.bounds(for: .mediaBox)
    let scale = width / box.width
    let size = NSSize(width: box.width * scale, height: box.height * scale)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.set()
    NSRect(origin: .zero, size: size).fill()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: ctx)
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])!
    try! jpeg.write(to: URL(fileURLWithPath: "\(outDir)/p\(i + 1).jpg"))
}
print(doc.pageCount)
