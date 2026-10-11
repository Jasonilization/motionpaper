import AppKit
import Foundation

/// Patches macOS 27.0-beta hit-testing to use the traditional NSView.hitTest(_:)
/// instead of the new context-based responder walk.
///
/// The crash: NSHostingView.hitTest(_:) → hitTest(context:) → SwiftUI's
/// PlatformHitTestingManager → MainActor.assumeIsolated → broken executor
/// check in the macOS 27.0-beta concurrency runtime → segfault.
///
/// The fix: after SwiftUI creates its window, get the contentView's actual
/// class (the generic NSHostingView<Content> metaclass), and replace its
/// hitTest(_:) implementation with the base NSView's traditional
/// point-based geometric walk — the implementation that predates the
/// broken responder machinery by decades and never touches it.
public enum ClickCrashFix {
    @MainActor
    public static func install() {
        patchPressureLatch()
        // The content-view patch needs the window to exist first — call
        // patchContentViewHitTest() after applicationDidFinishLaunching.
    }

    /// Call after the SwiftUI window exists. Finds the contentView's class
    /// and replaces its hitTest with the base NSView implementation.
    @MainActor
    public static func patchContentViewHitTest() {
        for window in NSApp.windows where window.canBecomeMain {
            guard let contentView = window.contentView else { continue }
            let cls = object_getClass(contentView)
            guard let cls else { continue }
            let className = String(cString: class_getName(cls))

            let hitTestSel = sel_registerName("hitTest:")
            guard let baseMethod = class_getInstanceMethod(NSView.self, hitTestSel) else { continue }
            let baseIMP = method_getImplementation(baseMethod)

            if let existing = class_getInstanceMethod(cls, hitTestSel) {
                // The class (or a superclass) overrides hitTest — replace it.
                method_setImplementation(existing, baseIMP)
                WallpaperEngine.appendOverlayLog("ClickCrashFix: hitTest replaced on \(className) — traditional walk active")
            } else {
                // No override found — add the base implementation directly.
                class_addMethod(cls, hitTestSel, baseIMP, "@@:{NSPoint=dd}")
                WallpaperEngine.appendOverlayLog("ClickCrashFix: hitTest added to \(className) — traditional walk active")
            }

            // Also patch the context-based hitTest if it exists on this class.
            let ctxSel = sel_registerName("hitTest:context:")
            if let ctxMethod = class_getInstanceMethod(cls, ctxSel) {
                // Replace the context variant with the point-based version.
                // The traditional hitTest ignores the context parameter.
                let ctxIMP: @convention(c) (AnyObject, Selector, NSPoint, AnyObject?) -> AnyObject? = { selfRef, sel, point, _ in
                    // Look up the base NSView hitTest fresh each time.
                    let hitSel = sel_registerName("hitTest:")
                    guard let m = class_getInstanceMethod(
                        unsafeBitCast(objc_getClass("NSView"), to: AnyClass.self), hitSel
                    ) else { return nil }
                    let imp = method_getImplementation(m)
                    typealias F = @convention(c) (AnyObject, Selector, NSPoint) -> AnyObject?
                    return unsafeBitCast(imp, to: F.self)(selfRef, hitSel, point)
                }
                method_setImplementation(ctxMethod, unsafeBitCast(ctxIMP, to: IMP.self))
                WallpaperEngine.appendOverlayLog("ClickCrashFix: hitTest:context: replaced on \(className)")
            }
        }
    }

    /// `_latchViewForPressureEvent:` on NSWindow — returns contentView
    /// without hit-testing.
    private static func patchPressureLatch() {
        let selector = sel_registerName("_latchViewForPressureEvent:")
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else {
            WallpaperEngine.appendOverlayLog("ClickCrashFix: pressure latch not found (skipped)")
            return
        }

        typealias LatchFunc = @convention(c) ( AnyObject, Selector, NSEvent ) -> AnyObject?
        let latch: LatchFunc = { selfRef, _, _ in
            let window = unsafeBitCast(selfRef, to: NSWindow.self)
            return window.contentView
        }

        method_setImplementation(method, unsafeBitCast(latch, to: IMP.self))
        WallpaperEngine.appendOverlayLog("ClickCrashFix: pressure latch PATCHED")
    }
}
