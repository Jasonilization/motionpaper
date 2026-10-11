import AppKit
import Foundation

/// Targeted fix for the macOS-beta click crash.
///
/// Every trackpad mouseDown on this macOS 27.0 beta (26A5406e) routes through
/// NSWindow's private _latchViewForPressureEvent: → _hitTestForContext: →
/// SwiftUI's responder hitTest → MainActor.assumeIsolated — which segfaults in
/// the concurrency runtime (the SDK-26.5-binary ↔ OS-27-runtime mismatch).
/// The result: every click on the library window crashes the app.
///
/// This patch replaces the private method with one that returns the window's
/// content view directly — no responder hit-test, no SwiftUI, no executor
/// check. Pressure/force-click events deliver to the window root instead of
/// the precise subview; this app has no force-click interactions, so the
/// functional loss is zero. If the method doesn't exist on a future macOS,
/// the patch silently does nothing and the original behavior returns.
public enum ClickCrashFix {
    public static func install() {
        // Patch 1: _latchViewForPressureEvent: — returns contentView without hit-testing.
        let latchSelector = sel_registerName("_latchViewForPressureEvent:")
        if let latchMethod = class_getInstanceMethod(NSWindow.self, latchSelector) {
            typealias LatchFunc = @convention(c) ( AnyObject, Selector, NSEvent ) -> AnyObject?
            let latch: LatchFunc = { selfRef, _, _ in
                let window = unsafeBitCast(selfRef, to: NSWindow.self)
                return window.contentView
            }
            method_setImplementation(latchMethod, unsafeBitCast(latch, to: IMP.self))
            AppLog.app.info("ClickCrashFix: pressure latch patched")
        }

        // Patch 2: NSHostingView.hitTest(_:) — replace SwiftUI's responder-walk
        // with the traditional NSView geometric hitTest. SwiftUI's version calls
        // containsGlobalPoints → MainActor.assumeIsolated, which segfaults in
        // the concurrency runtime on this macOS build. The traditional walk
        // finds real AppKit subviews (NSButton, etc.) which handle clicks fine;
        // pure-SwiftUI hit zones route to the hosting view itself.
        guard let hostingClass = NSClassFromString("NSHostingView"),
              let hostingMethod = class_getInstanceMethod(hostingClass, #selector(NSView.hitTest(_:))),
              let baseMethod = class_getInstanceMethod(NSView.self, #selector(NSView.hitTest(_:))) else {
            AppLog.app.warning("ClickCrashFix: NSHostingView class not found — hitTest patch skipped")
            WallpaperEngine.appendOverlayLog("ClickCrashFix: hitTest patch SKIPPED")
            return
        }
        do {
            let baseImpl = method_getImplementation(baseMethod)
            try method_setImplementation(hostingMethod, baseImpl)
            AppLog.app.info("ClickCrashFix: NSHostingView.hitTest replaced with traditional NSView walk")
        } catch {
            AppLog.app.warning("ClickCrashFix: hitTest patch failed")
        }

        WallpaperEngine.appendOverlayLog("ClickCrashFix installed (latch + hitTest)")
    }
}
