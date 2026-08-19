#!/bin/bash
set -euo pipefail

# NOTE: output is not bit-for-bit reproducible (NSBitmapImageRep embeds varying
# PNG metadata), so re-running may show a ~10-byte git diff on AppIcon.icns even
# though the icon is visually identical. The committed Resources/AppIcon.icns is
# the source of truth; only re-run + commit when the icon DESIGN changes.

cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
SWIFT=$(mktemp /tmp/mkicon.XXXX.swift)
trap 'rm -rf "$WORK" "$SWIFT"' EXIT   # clean up on all exit paths (success or failure)
cat > "$SWIFT" <<'EOF'
import AppKit
// Render the brand icon: green disc + white brain.fill, at one size.
func render(_ px: CGFloat, to url: URL) {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    NSColor.systemGreen.setFill()
    NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: px, height: px)).fill()
    let brainPt = px * 0.72
    let cfg = NSImage.SymbolConfiguration(pointSize: brainPt, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let base = NSImage(systemSymbolName: "brain.fill", accessibilityDescription: nil),
       let brain = base.withSymbolConfiguration(cfg) {
        brain.isTemplate = false
        let bs = brain.size, s = min(brainPt/bs.width, brainPt/bs.height)
        let w = bs.width*s, h = bs.height*s
        brain.draw(in: NSRect(x: (px-w)/2, y: (px-h)/2, width: w, height: h))
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    rep.size = NSSize(width: px, height: px)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    render(px, to: dir.appendingPathComponent("\(name).png"))
}
print("rendered \(sizes.count) pngs")
EOF
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
swift "$SWIFT" "$ICONSET"
mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
