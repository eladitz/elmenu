// "Match Window Colours": the strip takes the colour of the window's own title bar. Apps don't share their
// colours, so Elmenu looks: a tiny capture of the title bar (needs the Screen Recording permission; without
// it the strip keeps the standard Mac look). Only that strip of pixels is read, and only to average its colour.

import AppKit
import ScreenCaptureKit

enum WindowColour {
    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    /// The average colour across the title bar of the app's window at `frame` (Accessibility coordinates),
    /// skipping the traffic-light buttons on the left.
    static func sample(pid: pid_t, frame: CGRect) async -> NSColor? {
        guard allowed,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows
                .filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 })
                .min(by: { distance($0.frame, frame) < distance($1.frame, frame) }),
              distance(window.frame, frame) < 40 else { return nil }
        let config = SCStreamConfiguration()
        let band = CGRect(x: window.frame.width * 0.35, y: 4, width: window.frame.width * 0.5, height: 20)
        config.sourceRect = band
        config.width = 64
        config.height = 8
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        else { return nil }
        return average(image)
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    private static func average(_ image: CGImage) -> NSColor? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The middle value of each channel, so a title or icon in the band doesn't shift the colour.
        func median(_ c: Int) -> CGFloat {
            let values = stride(from: c, to: pixels.count, by: 4).map { pixels[$0] }.sorted()
            return CGFloat(values[values.count / 2]) / 255
        }
        return NSColor(srgbRed: median(0), green: median(1), blue: median(2), alpha: 1)
    }
}
