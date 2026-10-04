import AppKit
import CoreGraphics
import Foundation

/// A connected display, identified by a composite key designed to survive
/// reconnection and app restarts: localized name + native pixel resolution +
/// IOKit vendor/model/serial numbers.
///
/// Known limitation: two *identical* monitors that don't report a serial
/// number get an index suffix (e.g. "#2") whose ordering isn't guaranteed
/// across reconnects — an inherent limitation of display identity on macOS.
public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public let id: String          // stable key — used for assignment persistence
    public let name: String
    public let nativeWidth: Int
    public let nativeHeight: Int
    public let frame: CGRect      // NSScreen frame (points, global coordinates)
    public let isPrimary: Bool
    public let backingScaleFactor: Double

    public var summary: String { "\(name) — \(nativeWidth)×\(nativeHeight)" }

    /// Maps the currently connected NSScreens into DisplayInfo entries.
    @MainActor public static func currentScreens() -> [DisplayInfo] {
        var infos: [DisplayInfo] = []
        var usedKeys: Set<String> = []

        for screen in NSScreen.screens {
            let description = screen.deviceDescription
            let displayID = (description[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0

            let name = screen.localizedName
            let mode = displayID != 0 ? CGDisplayCopyDisplayMode(displayID) : nil
            let nativeWidth = mode.map { Int($0.pixelWidth) } ?? Int(screen.frame.width)
            let nativeHeight = mode.map { Int($0.pixelHeight) } ?? Int(screen.frame.height)

            var keyComponents = [name, "\(nativeWidth)x\(nativeHeight)"]
            let vendor = CGDisplayVendorNumber(displayID)
            let serial = CGDisplaySerialNumber(displayID)
            if vendor != 0 || serial != 0 {
                keyComponents.append("v\(vendor)s\(serial)")
            }
            var key = keyComponents.joined(separator: "_")

            // De-duplicate identical monitors that don't report unique serials.
            if usedKeys.contains(key) {
                var suffix = 2
                while usedKeys.contains("\(key)#\(suffix)") { suffix += 1 }
                key = "\(key)#\(suffix)"
            }
            usedKeys.insert(key)

            infos.append(DisplayInfo(
                id: key,
                name: name,
                nativeWidth: nativeWidth,
                nativeHeight: nativeHeight,
                frame: screen.frame,
                isPrimary: displayID == CGMainDisplayID(),
                backingScaleFactor: screen.backingScaleFactor
            ))
        }
        return infos
    }
}
