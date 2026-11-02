//
//  StateControllerBridge.swift
//  TendiesPreview (Phase 0 probe)
//
//  Runtime bridge to CAStateController / CAState (private QuartzCore).
//
//  Public write-ups of these private classes (Aditya Vaidyam,
//  "CAStateController & Friends", 2018) document the shape:
//    let ctrl = CAStateController(layer: layer)
//    ctrl.setInitialStatesOfLayer(layer, transitionSpeed: 0.5)
//    ctrl.setState(state, ofLayer: layer, transitionSpeed: 0.5)
//  and CALayer carries -states / -stateTransitions arrays whose
//  elements respond to -name. PosterBoard packages spell the CAML tags
//  <LKState>/<LKStateTransition> — LK is LayerKit, Core Animation's old
//  name; whether the parser materialises them as CAState objects (or an
//  LK-prefixed twin) is one of the things this probe exists to learn,
//  so state objects are treated as opaque NSObject throughout and BOTH
//  class names are tried when a state object must be constructed.
//
//  Everything is responds(to:)-guarded; a missing class/method degrades
//  to a log line, never a crash. Controllers must be RETAINED by the
//  caller for as long as state switching is wanted (the layer does not
//  keep the controller alive).
//

import Foundation
import QuartzCore

enum StateBridge {

    struct StateInfo {
        let name: String
        /// The state object from the layer's -states array (opaque).
        let object: NSObject
    }

    /// -states of the layer, as (name, object) pairs, in array order.
    /// Returns [] when the getter is absent or yields nothing — the
    /// caller then falls back to state names mined from the CAML text.
    static func states(of layer: CALayer) -> [StateInfo] {
        guard let raw = Dyn.getObject(layer, selector: "states") as? [AnyObject]
        else { return [] }
        var out: [StateInfo] = []
        for item in raw {
            guard let obj = item as? NSObject else { continue }
            let name = (Dyn.getObject(obj, selector: "name") as? String) ?? ""
            out.append(StateInfo(name: name, object: obj))
        }
        return out
    }

    /// Number of entries in the layer's -stateTransitions, if readable.
    static func transitionCount(of layer: CALayer) -> Int? {
        (Dyn.getObject(layer, selector: "stateTransitions") as? [AnyObject])?.count
    }

    /// Create a CAStateController bound to `layer` via -initWithLayer:.
    /// Returns nil (with the reason in the log) when the class or the
    /// initialiser is unavailable, or the initialiser returns nil.
    static func makeController(for layer: CALayer) -> (controller: NSObject?, log: String) {
        guard let cls = Dyn.lookupClass("CAStateController") else {
            return (nil, "CAStateController: 类不存在")
        }
        guard let allocated = Dyn.allocate(cls) else {
            return (nil, "CAStateController: alloc 失败")
        }
        guard let controller = Dyn.callInitWithLayer(allocated,
                                                     selector: "initWithLayer:",
                                                     layer: layer) as? NSObject else {
            return (nil, "CAStateController/-initWithLayer:: 无结果（选择子不存在或返回 nil）")
        }
        return (controller, "CAStateController/-initWithLayer: 已创建")
    }

    /// Apply the layer's initial states: -setInitialStatesOfLayer:,
    /// falling back to the transitionSpeed: variant. Failure meaning:
    /// the controller exists but refuses initial-state setup for this
    /// layer (e.g. its states are LK-flavoured and not CAState) — the
    /// exact distinction the probe's diagnostics are meant to surface.
    static func setInitialStates(controller: NSObject, layer: CALayer) -> String {
        if Dyn.callVoid(controller, selector: "setInitialStatesOfLayer:", arg: layer) {
            return "setInitialStatesOfLayer: 已调用"
        }
        if Dyn.callVoidLayerDouble(controller,
                                   selector: "setInitialStatesOfLayer:transitionSpeed:",
                                   layer: layer, value: 1.0) {
            return "setInitialStatesOfLayer:transitionSpeed: 已调用"
        }
        return "setInitialStates*: 两种形态的选择子都不存在"
    }

    /// Switch `layer` to `state`: -setState:ofLayer:, falling back to
    /// the transitionSpeed: variant (IMP, because of the Double arg).
    /// The state transition's own animations (CASpringAnimation in the
    /// real packages) are attached by the controller itself.
    static func setState(controller: NSObject, layer: CALayer, state: NSObject) -> String? {
        if Dyn.callVoid2(controller, selector: "setState:ofLayer:", arg1: state, arg2: layer) {
            return "setState:ofLayer:"
        }
        let sel = NSSelectorFromString("setState:ofLayer:transitionSpeed:")
        if controller.responds(to: sel) {
            typealias Fn = @convention(c) (AnyObject, Selector, NSObject, NSObject, Double) -> Void
            let fn = unsafeBitCast(controller.method(for: sel), to: Fn.self)
            fn(controller, sel, state, layer, 1.0)
            return "setState:ofLayer:transitionSpeed:"
        }
        return nil
    }

    /// Construct a bare state object carrying only a name, for use when
    /// the layer's -states array could not be read but the state NAME is
    /// known (from CAML text). Tries CAState first, then LKState.
    /// Whether CAStateController matches states by identity or by name
    /// is unknown — if identity is required this fallback will visibly
    /// do nothing, which is itself a probe finding (logged by caller).
    static func makeStateObject(named name: String) -> NSObject? {
        for className in ["CAState", "LKState"] {
            guard let cls = Dyn.lookupClass(className),
                  let obj = Dyn.instantiate(cls) else { continue }
            if Dyn.callVoid(obj, selector: "setName:", arg: name as NSString) {
                return obj
            }
        }
        return nil
    }
}
