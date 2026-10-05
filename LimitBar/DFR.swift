import AppKit

// Private DFRFoundation / NSTouchBar bridge.
// Proven on MacBookPro17,1 + macOS 26: 2-arg present keeps the system control strip.

enum DFR {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)

    static func setControlStripPresence(_ identifier: NSTouchBarItem.Identifier, _ present: Bool) {
        guard let sym = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier") else { return }
        typealias F = @convention(c) (CFString, Bool) -> Void
        unsafeBitCast(sym, to: F.self)(identifier.rawValue as CFString, present)
    }

    static func setShowsCloseBox(_ show: Bool) {
        guard let sym = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") else { return }
        typealias F = @convention(c) (Bool) -> Void
        unsafeBitCast(sym, to: F.self)(show)
    }
}

func dismissSystemModal(_ touchBar: NSTouchBar) {
    let cls = NSTouchBar.self as AnyObject
    for name in ["dismissSystemModalTouchBar:", "dismissSystemModalFunctionBar:"] {
        let sel = NSSelectorFromString(name)
        if cls.responds(to: sel) { _ = cls.perform(sel, with: touchBar); return }
    }
}

/// 2-arg present, NO placement arg — placement:1 is full takeover and hides the control strip.
func presentSystemModalStrip(_ touchBar: NSTouchBar, identifier: NSTouchBarItem.Identifier) {
    let cls = NSTouchBar.self as AnyObject
    let candidates = ["presentSystemModalTouchBar:systemTrayItemIdentifier:",
                      "presentSystemModalFunctionBar:systemTrayItemIdentifier:"].map(NSSelectorFromString)
    guard let sel = candidates.first(where: { cls.responds(to: $0) }),
          let m = class_getClassMethod(NSTouchBar.self, sel) else {
        NSLog("[LimitBar] ERR no present selector"); return
    }
    typealias Fn = @convention(c) (AnyObject, Selector, NSTouchBar, NSString) -> Void
    unsafeBitCast(method_getImplementation(m), to: Fn.self)(NSTouchBar.self, sel, touchBar, identifier.rawValue as NSString)
}

/// Force the control strip to re-render (same trick Pock ships).
func reloadControlStrip() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    p.arguments = ["-x", "ControlStrip"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

/// Hide the system close (X) button the function row adds to system-modal bars.
func hideCloseButton() {
    let bgClass: AnyClass? = NSClassFromString("NSFunctionRowBackgroundColorView")
    var candidates: [NSView] = []
    if let fr = NSClassFromString("NSFunctionRow") as? NSObject.Type {
        for selName in ["_topLevelFunctionRowViews", "_topLevelViews"] {
            let sel = NSSelectorFromString(selName)
            if fr.responds(to: sel), let views = fr.perform(sel)?.takeUnretainedValue() as? [NSView] {
                candidates = views
            }
        }
    }
    for v in candidates where object_getClass(v) === bgClass {
        for case let stack as NSStackView in v.subviews {
            for case let btn as NSButton in stack.subviews {
                btn.isHidden = true
                return
            }
        }
    }
}
