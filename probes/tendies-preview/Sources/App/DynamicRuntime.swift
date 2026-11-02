//
//  DynamicRuntime.swift
//  TendiesPreview (Phase 0 probe)
//
//  Tiny helpers for calling PRIVATE QuartzCore classes (CAPackage,
//  CAMLParser, CAStateController, CAState/LKState) purely at runtime.
//
//  Design rules (SPEC: never hard-link a private symbol):
//  - Every class is looked up with NSClassFromString; a missing class is
//    a logged failure, never a crash or a link error.
//  - Every selector is guarded with responds(to:) before it is sent.
//  - Object-returning no-arg getters go through perform(_:) and
//    takeUnretainedValue (+0 convention).
//  - Methods whose return type perform(_:) cannot carry (BOOL) or whose
//    arguments it cannot pass (NSError**, Double) go through the IMP
//    directly with an @convention(c) signature — the standard pattern
//    for private-API bridging.
//  - Retain semantics are deliberately biased toward LEAKING (probe
//    process, short-lived objects): an over-retained object is harmless
//    here, an over-released one is a crash.
//

import Foundation

enum Dyn {

    /// Class lookup that never fails hard.
    static func lookupClass(_ name: String) -> AnyClass? {
        NSClassFromString(name)
    }

    /// [[cls alloc] init] via perform, without any metatype casts.
    /// Returns a retained instance (owned by the caller).
    static func instantiate(_ cls: AnyClass) -> NSObject? {
        let classObject = cls as AnyObject
        let allocSel = NSSelectorFromString("alloc")
        guard classObject.responds(to: allocSel),
              let allocated = classObject.perform(allocSel)?.takeRetainedValue() as? NSObject
        else { return nil }
        let initSel = NSSelectorFromString("init")
        guard allocated.responds(to: initSel) else { return allocated }
        // init returns the (possibly different) self at +1 in the init
        // family; takeUnretainedValue keeps the alloc's +1 as the owning
        // reference and simply leaks if init added another. Safe bias.
        return allocated.perform(initSel)?.takeUnretainedValue() as? NSObject ?? allocated
    }

    /// [[cls alloc] without init — for the designated-initializer calls
    /// (initWithContentsOfURL:error:, initWithLayer:) that must be sent
    /// to a fresh, uninitialised instance exactly like ObjC code does.
    static func allocate(_ cls: AnyClass) -> NSObject? {
        let classObject = cls as AnyObject
        let allocSel = NSSelectorFromString("alloc")
        guard classObject.responds(to: allocSel),
              let allocated = classObject.perform(allocSel)?.takeRetainedValue() as? NSObject
        else { return nil }
        return allocated
    }

    /// No-arg, object-returning getter (e.g. -rootLayer, -result,
    /// -states, -name). Guarded by responds(to:); +0 via takeUnretained.
    static func getObject(_ obj: NSObject, selector name: String) -> AnyObject? {
        let sel = NSSelectorFromString(name)
        guard obj.responds(to: sel) else { return nil }
        return obj.perform(sel)?.takeUnretainedValue()
    }

    /// Void setter/call with one object argument (e.g. -setDelegate:,
    /// -setInitialStatesOfLayer:). The Unmanaged result of a void
    /// method is meaningless and is intentionally not touched.
    @discardableResult
    static func callVoid(_ obj: NSObject, selector name: String, arg: AnyObject) -> Bool {
        let sel = NSSelectorFromString(name)
        guard obj.responds(to: sel) else { return false }
        _ = obj.perform(sel, with: arg)
        return true
    }

    /// Void call with two object arguments (e.g. -setState:ofLayer:).
    @discardableResult
    static func callVoid2(_ obj: NSObject, selector name: String,
                          arg1: AnyObject, arg2: AnyObject) -> Bool {
        let sel = NSSelectorFromString(name)
        guard obj.responds(to: sel) else { return false }
        _ = obj.perform(sel, with: arg1, with: arg2)
        return true
    }

    // MARK: IMP-based calls (signatures perform(_:) cannot express)

    /// - (BOOL)parseData:(NSData *) / - (BOOL)parseContentsOfURL:(NSURL *)
    /// on CAMLParser. Failure meaning: the parser rejected the document
    /// (unknown class tags such as LKState are the prime suspect — that
    /// is exactly what this probe exists to find out).
    static func callBool(_ obj: NSObject, selector name: String, arg: NSObject) -> Bool? {
        let sel = NSSelectorFromString(name)
        guard obj.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, NSObject) -> Bool
        let imp = obj.method(for: sel)
        let fn = unsafeBitCast(imp, to: Fn.self)
        return fn(obj, sel, arg)
    }

    /// + (id)packageWithContentsOfURL:(NSURL *)error:(NSError **) and
    /// - (id)initWithContentsOfURL:(NSURL *)error:(NSError **) on
    /// CAPackage. The error out-pointer is passed as nil (explicitly
    /// allowed by the API contract). Returns the raw object pointer so
    /// the caller controls the Unmanaged conversion.
    static func callFactoryURL(_ receiver: AnyObject, selector name: String,
                               url: URL) -> AnyObject? {
        let sel = NSSelectorFromString(name)
        guard receiver.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, NSURL, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
        let imp = receiver.method(for: sel)
        let fn = unsafeBitCast(imp, to: Fn.self)
        guard let raw = fn(receiver, sel, url as NSURL, nil) else { return nil }
        // Factory (+packageWith...) returns +0; designated init returns
        // +1 and consumed the alloc's +1. takeUnretained is correct for
        // the factory and merely leaks for init. Safe bias, see header.
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
    }

    /// - (id)initWithLayer:(CALayer *) for CAStateController.
    /// A nil return is possible (the Swift overlay in the wild shows a
    /// failable initialiser), so nil is a first-class outcome here.
    static func callInitWithLayer(_ receiver: NSObject, selector name: String,
                                  layer: NSObject) -> AnyObject? {
        let sel = NSSelectorFromString(name)
        guard receiver.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, NSObject) -> UnsafeMutableRawPointer?
        let imp = receiver.method(for: sel)
        let fn = unsafeBitCast(imp, to: Fn.self)
        guard let raw = fn(receiver, sel, layer) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
    }

    /// - (void)setInitialStatesOfLayer:(CALayer *)transitionSpeed:(double)
    /// fallback for CAStateController when the one-argument form is absent.
    @discardableResult
    static func callVoidLayerDouble(_ obj: NSObject, selector name: String,
                                    layer: NSObject, value: Double) -> Bool {
        let sel = NSSelectorFromString(name)
        guard obj.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, NSObject, Double) -> Void
        let imp = obj.method(for: sel)
        let fn = unsafeBitCast(imp, to: Fn.self)
        fn(obj, sel, layer, value)
        return true
    }
}
