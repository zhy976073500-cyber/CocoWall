//
//  PrivateCALoader.swift
//  TendiesPreview (Phase 0 probe)
//
//  Loads ONE .ca package into a CALayer tree at runtime.
//
//  ROUND 2 (2026-11-03) — rewritten after Sage's first device test, in
//  which BOTH .ca packages of a known-good PosterBoard file failed on
//  every path. Root-cause work against the iOS 10/17 QuartzCore runtime
//  headers and Apple's own AVMicaPackage (decompiled, iOS 18.2) showed
//  round 1 had three independent defects:
//
//  1. CAPackage's real factory is
//       +packageWithContentsOfURL:type:options:error:
//     The two-argument forms round 1 tried do not exist — hence the
//     uniform "无结果或选择子不存在" lines.
//  2. The CAMLParser delegate protocol's selectors are
//       CAMLParser:didFailToFindClassWithName:   (returns a Class!)
//       CAMLParser:resourceForURL:
//       CAMLParser:formatErrorString:arguments:lineNumber:
//     etc. Round 1 implemented invented selectors
//     (parser:didFailWithError:, parser:resourceForURL:), so the parser
//     never called back: no substitution, no error text, silent false.
//  3. PosterBoard CAML spells its state classes LKState /
//     LKStateSetValue / LKStateTransition… — LayerKit-era names for
//     which NO class exists in a modern process (NSClassFromString
//     returns nil). When the parser meets one it asks the delegate's
//     didFailToFindClassWithName: for a substitute; Apple's own
//     AVMicaPackage answers with an LK* -> CA* table (LKState ->
//     CAState, LKStateSetValue -> CAStateSetValue, …). Without that
//     answer the parse aborts — the most likely cause of round 1's
//     parseContentsOfURL:/parseData: returning false on valid files.
//
//  Round 2 therefore tries, in order:
//  A. CAMLParser created via the +parser factory (AVMicaPackage's exact
//     pattern), delegate installed (class substitution + resource
//     vending + script registration + format error/warning capture),
//     baseURL set to the .ca directory, -parseContentsOfURL:, then
//     -result and the parser's -error are both read and logged.
//  B. Same delegate, fresh parser via alloc/init, -parseData:.
//  C. CAPackage via the real four-argument factory, type candidates
//     nil / "mica" / "caml", NSError captured from the out-pointer;
//     then -rootLayer. (_initWithContentsOfURL:type:options:error:
//     on a fresh allocation if the factory selector is absent.)
//
//  Every failure is returned as log lines — the caller writes them to
//  the diagnostics panel. A failed package must NEVER silently render
//  as a black canvas (SPEC rule).
//

import Foundation
import ObjectiveC
import QuartzCore
import UIKit

struct CALoadResult {
    let layer: CALayer?
    /// Which path produced the layer. nil when layer is nil.
    let method: String?
    let log: [String]
}

enum PrivateCALoader {

    static func load(info: CAPackageDiskInfo) -> CALoadResult {
        var log: [String] = []
        log.append("类存在性: \(classExistenceReport())")
        if let result = loadViaCAMLParser(info: info, log: &log) { return result }
        if let result = loadViaCAPackage(info: info, log: &log) { return result }
        log.append("✗ \(info.displayName): CAMLParser 与 CAPackage 均失败（见上）")
        return CALoadResult(layer: nil, method: nil, log: log)
    }

    /// One-line census of the state-class names that matter: if LK* are
    /// absent and CA* present, the substitution premise is confirmed on
    /// this OS build before parsing even starts.
    private static func classExistenceReport() -> String {
        let names = ["CAState", "LKState", "CAStateSetValue", "LKStateSetValue",
                     "CAStateTransition", "LKStateTransition",
                     "CAStateTransitionElement", "LKStateTransitionElement",
                     "CAEventHandler", "LKEventHandler",
                     "CAPackage", "CAMLParser", "CAStateController"]
        return names.map { "\($0)=\(NSClassFromString($0) != nil ? "有" : "无")" }
            .joined(separator: " ")
    }

    // MARK: - A/B. CAMLParser (AVMicaPackage pattern)

    private static func loadViaCAMLParser(info: CAPackageDiskInfo,
                                          log: inout [String]) -> CALoadResult? {
        guard let cls = Dyn.lookupClass("CAMLParser") else {
            log.append("CAMLParser: 类不存在 (NSClassFromString 返回 nil)")
            return nil
        }

        // A: +parser factory + -parseContentsOfURL:
        if let parser = makeParser(cls: cls, log: &log) {
            let delegate = installDelegate(on: parser, info: info, log: &log)
            if let ok = Dyn.callBool(parser, selector: "parseContentsOfURL:",
                                     arg: info.mainCAMLURL as NSURL) {
                log.append(contentsOf: delegate.events.map { "CAMLParser delegate: \($0)" })
                delegate.events.removeAll()
                log.append("CAMLParser(+parser)/-parseContentsOfURL: 返回 \(ok)")
                if ok, let layer = Dyn.getObject(parser, selector: "result") as? CALayer {
                    return CALoadResult(layer: layer,
                                        method: "CAMLParser/-parseContentsOfURL:", log: log)
                }
                if let err = parserError(parser) { log.append("CAMLParser -error: \(err)") }
                if ok { log.append("CAMLParser: parse 成功但 -result 不是 CALayer") }
            } else {
                log.append("CAMLParser/-parseContentsOfURL:: 选择子不存在")
            }
        }

        // B: fresh alloc/init parser + -parseData: (baseURL already set
        // by installDelegate, so relative assets can still resolve).
        if let parser = Dyn.instantiate(cls) {
            let delegate = installDelegate(on: parser, info: info, log: &log)
            if let data = try? Data(contentsOf: info.mainCAMLURL) {
                if let ok = Dyn.callBool(parser, selector: "parseData:", arg: data as NSData) {
                    log.append(contentsOf: delegate.events.map { "CAMLParser delegate: \($0)" })
                    delegate.events.removeAll()
                    log.append("CAMLParser(alloc/init)/-parseData: 返回 \(ok) (\(data.count) 字节)")
                    if ok, let layer = Dyn.getObject(parser, selector: "result") as? CALayer {
                        return CALoadResult(layer: layer,
                                            method: "CAMLParser/-parseData:", log: log)
                    }
                    if let err = parserError(parser) { log.append("CAMLParser -error: \(err)") }
                    if ok { log.append("CAMLParser: parse 成功但 -result 不是 CALayer") }
                } else {
                    log.append("CAMLParser/-parseData:: 选择子不存在")
                }
            } else {
                log.append("CAMLParser: 读取 \(info.rootDocumentName) 失败，跳过 -parseData:")
            }
        }
        return nil
    }

    /// Create a parser the way AVMicaPackage does: the +parser class
    /// factory. Falls back to alloc/init when the factory is absent.
    private static func makeParser(cls: AnyClass, log: inout [String]) -> NSObject? {
        let classObject = cls as AnyObject
        let sel = NSSelectorFromString("parser")
        if classObject.responds(to: sel),
           let parser = classObject.perform(sel)?.takeUnretainedValue() as? NSObject {
            return parser
        }
        log.append("CAMLParser: +parser 工厂不可用，退回 alloc/init")
        return Dyn.instantiate(cls)
    }

    /// Install the (correctly-spelled) delegate and set baseURL to the
    /// package directory. The delegate is retained via an associated
    /// object for the parser's lifetime; the caller also holds it for
    /// the duration of the synchronous parse to read its events.
    private static func installDelegate(on parser: NSObject,
                                        info: CAPackageDiskInfo,
                                        log: inout [String]) -> CAMLDelegate {
        let delegate = CAMLDelegate(packageDir: info.dir)
        objc_setAssociatedObject(parser, &delegateAssociationKey, delegate,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if Dyn.callVoid(parser, selector: "setDelegate:", arg: delegate) {
            log.append("CAMLParser: delegate 已安装 (类替换 + 资源 + 错误捕获)")
        } else {
            log.append("CAMLParser: -setDelegate: 不存在，delegate 未安装")
        }
        if Dyn.callVoid(parser, selector: "setBaseURL:", arg: info.dir as NSURL) {
            log.append("CAMLParser: baseURL 已设为 .ca 目录")
        }
        return delegate
    }

    /// The parser's readonly -error, when it has one.
    private static func parserError(_ parser: NSObject) -> String? {
        guard let err = Dyn.getObject(parser, selector: "error") as? NSError else { return nil }
        return "\(err.domain) \(err.code): \(err.localizedDescription) userInfo=\(err.userInfo)"
    }

    // MARK: - C. CAPackage (real four-argument factory)

    private static func loadViaCAPackage(info: CAPackageDiskInfo,
                                         log: inout [String]) -> CALoadResult? {
        guard let cls = Dyn.lookupClass("CAPackage") else {
            log.append("CAPackage: 类不存在 (NSClassFromString 返回 nil)")
            return nil
        }
        let classObject = cls as AnyObject
        let typeCandidates: [String?] = [nil, "mica", "caml"]
        for type in typeCandidates {
            let label = type ?? "nil"
            let (pkgObj, errText, exists) = Dyn.callPackageFactory(
                classObject, selector: "packageWithContentsOfURL:type:options:error:",
                url: info.dir, type: type)
            if !exists {
                log.append("CAPackage/+packageWithContentsOfURL:type:options:error:: 选择子不存在")
                break
            }
            if let pkg = pkgObj as? NSObject, let layer = rootLayer(of: pkg) {
                log.append("✓ CAPackage/+packageWithContentsOfURL:type:options:error: (type=\(label)) -> rootLayer")
                return CALoadResult(layer: layer,
                                    method: "CAPackage(type=\(label))", log: log)
            }
            log.append("CAPackage(type=\(label)): 无 rootLayer\(errText.map { "；error: \($0)" } ?? "")")
        }

        // Fallback: the underscored designated initialiser on a fresh
        // allocation, type nil only.
        if let allocated = Dyn.allocate(cls) {
            let (pkgObj, errText, exists) = Dyn.callPackageFactory(
                allocated, selector: "_initWithContentsOfURL:type:options:error:",
                url: info.dir, type: nil)
            if exists, let pkg = pkgObj as? NSObject, let layer = rootLayer(of: pkg) {
                log.append("✓ CAPackage/-_initWithContentsOfURL:type:options:error: -> rootLayer")
                return CALoadResult(layer: layer,
                                    method: "CAPackage/_initWithContentsOfURL:", log: log)
            }
            if exists {
                log.append("CAPackage/_init...: 无 rootLayer\(errText.map { "；error: \($0)" } ?? "")")
            }
        }
        return nil
    }

    /// -rootLayer is the documented CAPackage outlet for the layer tree.
    /// A package object that yields no rootLayer counts as a failure of
    /// that attempt, not as a (useless) success.
    private static func rootLayer(of package: NSObject) -> CALayer? {
        Dyn.getObject(package, selector: "rootLayer") as? CALayer
    }
}

private var delegateAssociationKey: UInt8 = 0

/// CAMLParser delegate with the REAL protocol selectors (iOS 10–17
/// runtime headers, protocols/CAMLParserDelegate.h):
///
///   - (Class)CAMLParser:(id) didFailToFindClassWithName:(id)
///   - (id)   CAMLParser:(id) resourceForURL:(id)
///   - (id)   CAMLParser:(id) didFailToLoadResourceFromURL:(id)
///   - (void) CAMLParser:(id) didLoadResource:(id) fromURL:(id)
///   - (void) CAMLParser:(id) evaluateScriptElement:(id) sourceURL:(id) lineNumber:(unsigned)
///   - (id)   CAMLParser:(id) evaluateScriptValue:(id) sourceURL:(id) lineNumber:(unsigned)
///   - (void) CAMLParser:(id) formatErrorString:(const char*) arguments:(char*) lineNumber:(unsigned long long)
///   - (void) CAMLParser:(id) formatWarningString:(const char*) arguments:(char*) lineNumber:(unsigned long long)
///
/// Selectors are pinned with explicit @objc names so Swift's naming
/// inference cannot drift from the protocol's spelling. Every callback
/// records a line in `events`, which the loader flushes into the
/// diagnostics log after each parse — a silent parser is a failed
/// probe, so the callbacks themselves are part of the measurement.
///
/// Class substitution follows Apple's AVMicaPackage +classSubstitions
/// table (LK* -> CA*), generalised: exact table first, then the
/// LK->CA prefix rule for anything else the parser asks about.
final class CAMLDelegate: NSObject {
    let packageDir: URL
    var events: [String] = []

    init(packageDir: URL) {
        self.packageDir = packageDir
        super.init()
    }

    // MARK: Class substitution (the round-1 root cause)

    private static let substitutionTable: [String: String] = [
        "LKState": "CAState",
        "LKStateSetValue": "CAStateSetValue",
        "LKStateSetProperty": "CAStateSetProperty",
        "LKStateAddAnimation": "CAStateAddAnimation",
        "LKStateAddElement": "CAStateAddElement",
        "LKStateRemoveAnimation": "CAStateRemoveAnimation",
        "LKStateRemoveElement": "CAStateRemoveElement",
        "LKStateElement": "CAStateElement",
        "LKStateTransition": "CAStateTransition",
        "LKStateTransitionElement": "CAStateTransitionElement",
        "LKEventHandler": "CAEventHandler",
    ]

    @objc(CAMLParser:didFailToFindClassWithName:)
    func camlParser(_ parser: AnyObject,
                    didFailToFindClassWithName name: String) -> AnyClass? {
        var cls: AnyClass? = nil
        if let mapped = Self.substitutionTable[name] {
            cls = NSClassFromString(mapped)
        }
        if cls == nil, name.hasPrefix("LK") {
            cls = NSClassFromString("CA" + String(name.dropFirst(2)))
        }
        if cls == nil { cls = NSClassFromString(name) }
        events.append("didFailToFindClassWithName: \(name) -> \(cls.map { String(describing: $0) } ?? "无替换(nil)")")
        return cls
    }

    // MARK: Resources (vend images from the .ca directory; never JS)

    @objc(CAMLParser:resourceForURL:)
    func camlParser(_ parser: AnyObject, resourceForURL url: NSURL) -> AnyObject? {
        vend(url: url, via: "resourceForURL")
    }

    @objc(CAMLParser:didFailToLoadResourceFromURL:)
    func camlParser(_ parser: AnyObject,
                    didFailToLoadResourceFromURL url: NSURL) -> AnyObject? {
        events.append("didFailToLoadResourceFromURL: \(url.absoluteString ?? "?")")
        return vend(url: url, via: "didFailToLoadResourceFromURL 兜底")
    }

    @objc(CAMLParser:didLoadResource:fromURL:)
    func camlParser(_ parser: AnyObject, didLoadResource resource: AnyObject,
                    fromURL url: NSURL) {
        events.append("didLoadResource: \(url.lastPathComponent ?? url.absoluteString ?? "?")")
    }

    private func vend(url: NSURL, via: String) -> AnyObject? {
        guard let path = url.path, !path.isEmpty else {
            events.append("\(via): URL 无 path，返回 nil")
            return nil
        }
        let candidate: URL
        if url.isFileURL {
            candidate = URL(fileURLWithPath: path)
        } else {
            candidate = packageDir.appendingPathComponent(path)
        }
        if candidate.pathExtension.lowercased() == "js" {
            events.append("\(via): 拒绝执行 JS 资源 \(candidate.lastPathComponent)（只登记）")
            return nil
        }
        guard let image = UIImage(contentsOfFile: candidate.path),
              let cg = image.cgImage else {
            events.append("\(via): 无法加载 \(candidate.lastPathComponent)")
            return nil
        }
        events.append("\(via): 已提供 \(candidate.lastPathComponent)")
        return cg as AnyObject
    }

    // MARK: Script elements (registered, NEVER executed — SPEC)

    @objc(CAMLParser:evaluateScriptElement:sourceURL:lineNumber:)
    func camlParser(_ parser: AnyObject, evaluateScriptElement script: String,
                    sourceURL url: NSURL?, lineNumber: UInt32) {
        events.append("evaluateScriptElement: 已登记不执行 (\(script.count) 字符, \(url?.lastPathComponent ?? "内联"), line \(lineNumber))")
    }

    @objc(CAMLParser:evaluateScriptValue:sourceURL:lineNumber:)
    func camlParser(_ parser: AnyObject, evaluateScriptValue script: String,
                    sourceURL url: NSURL?, lineNumber: UInt32) -> AnyObject? {
        events.append("evaluateScriptValue: 已登记不执行 -> 返回 nil (\(script.count) 字符, line \(lineNumber))")
        return nil
    }

    // MARK: Error / warning channel (the round-1 silence, fixed)
    //
    // The `arguments` parameter is the parser's va_list (char* on
    // arm64 per the class-dump headers). It is deliberately NOT
    // dereferenced: the raw format string plus line number already
    // identify the failing construct, and misreading a va_list from
    // Swift would risk a crash inside the probe's own diagnostics.

    @objc(CAMLParser:formatErrorString:arguments:lineNumber:)
    func camlParser(_ parser: AnyObject,
                    formatErrorString format: UnsafePointer<CChar>?,
                    arguments: UnsafeMutablePointer<CChar>?,
                    lineNumber: UInt64) {
        let text = format.map { String(cString: $0) } ?? "(无格式串)"
        events.append("formatErrorString @line \(lineNumber): \(text)")
    }

    @objc(CAMLParser:formatWarningString:arguments:lineNumber:)
    func camlParser(_ parser: AnyObject,
                    formatWarningString format: UnsafePointer<CChar>?,
                    arguments: UnsafeMutablePointer<CChar>?,
                    lineNumber: UInt64) {
        let text = format.map { String(cString: $0) } ?? "(无格式串)"
        events.append("formatWarningString @line \(lineNumber): \(text)")
    }
}
