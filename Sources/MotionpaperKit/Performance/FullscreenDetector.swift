import AppKit
import CoreGraphics
import Foundation

/// Detects displays that are fully covered by another app's fullscreen window,
/// using only public window-list queries.
///
/// Heuristic: an on-screen, layer-0 window owned by another process whose
/// bounds exactly equal a display's frame is treated as fullscreen on that
/// display. Zoomed ("maximized") windows don't match because the menu bar
/// area stays visible. Edge cases (apps drawing exact-size borderless windows)
/// can produce false positives; that's why pausing on fullscreen coverage is
/// only applied in battery-saving modes.
public enum FullscreenDetector {
    /// Returns the display keys (by frame match) currently covered by fullscreen apps.
    @MainActor public static func coveredDisplays() -> Set<String> {
        var covered: Set<String> = []
        let displays = DisplayInfo.currentScreens()
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return covered
        }

        // Display frames in window-list coordinates (top-left origin, pixels).
        var displayFrames: [(key: String, rect: CGRect)] = []
        for display in displays {
            let scaleFactor = display.backingScaleFactor
            let pixelHeight = display.frame.height * scaleFactor
            let screenTopYInWindowCoords = pixelHeight + display.frame.minY * scaleFactor - pixelHeight
            // Window-list bounds use a top-left origin; a display's frame (bottom-left origin, points)
            // maps to: origin.y = (total desktop height - (frame.maxY)) * scaleFactor.
            let totalHeight = NSScreen.screens.reduce(0) { $0 + $1.frame.height } * scaleFactor
            let y = (totalHeight - display.frame.maxY * scaleFactor)
            let rect = CGRect(
                x: display.frame.minX * scaleFactor,
                y: y,
                width: display.frame.width * scaleFactor,
                height: display.frame.height * scaleFactor
            )
            displayFrames.append((display.id, rect))
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        for window in list {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32, ownerPID != selfPID else { continue }
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any] else { continue }
            let x = boundsDict["X"] as? Double ?? 0
            let y = boundsDict["Y"] as? Double ?? 0
            let w = boundsDict["Width"] as? Double ?? 0
            let h = boundsDict["Height"] as? Double ?? 0
            let bounds = CGRect(x: x, y: y, width: w, height: h)
            for display in displayFrames where bounds == display.rect {
                covered.insert(display.key)
            }
        }
        return covered
    }
}
