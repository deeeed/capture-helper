import CoreGraphics

func recordingWindowFrame(_ frame: CGRect, displays: [CGRect]) -> CGRect? {
    guard let display = displays.max(by: { a, b in
        let aArea = frame.intersection(a)
        let bArea = frame.intersection(b)
        let aOverlap = aArea.isNull ? 0 : aArea.width * aArea.height
        let bOverlap = bArea.isNull ? 0 : bArea.width * bArea.height
        if aOverlap != bOverlap { return aOverlap < bOverlap }
        return hypot(frame.midX - a.midX, frame.midY - a.midY) >
            hypot(frame.midX - b.midX, frame.midY - b.midY)
    }) else {
        return nil
    }
    // Preserve the viewport, including windows larger than a display.
    return CGRect(
        x: min(max(frame.minX, display.minX), max(display.minX, display.maxX - frame.width)),
        y: min(max(frame.minY, display.minY), max(display.minY, display.maxY - frame.height)),
        width: frame.width, height: frame.height
    )
}

