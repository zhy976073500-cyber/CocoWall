//
//  PrivateCALoader.swift
//  TendiesPreview (Phase 0 probe)
//
//  Loads ONE .ca package into a CALayer tree at runtime, trying in order:
//
//  A. CAPackage (QuartzCore) — the class Apple built exactly for .ca
//     package directories; it knows the index.xml -> rootDocument
//     indirection and resolves assets/ relative references itself.
//     Attempts: +packageWithContentsOfURL:error:, +packageWithContentsOfURL:,
//     -initWithContentsOfURL:error:, -initWithContentsOfURL: — then the
//     -rootLayer getter. Which of these exist on iOS 27's QuartzCore is
//     unknown; every attempt is responds(to:)-guarded and logged.
//
//  B. CAMLParser (QuartzCore, private) — parses a single CAML document:
//     -parseContentsOfURL: on the package's main.caml (keeps the file
//     URL as the base for relative src="assets/..." references), else
//     -parseData:. The result comes from the -result getter. A resource
//     delegate is installed first: if the parser asks for a resource by
//     URL it is vended from the .ca directory on disk, and parse errors
//     reported through the delegate are captured into the log.
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
    /// Which path produced the layer ("CAPackage/+packageWithContentsOfURL:error:",
    /// "CAMLParser/-parseData:", ...). nil when layer is nil.
    let method: String?
    let log: [String]
}

enum PrivateCALoader {

    static func load(info: CAPackageDiskInfo) -> CALoadResult {
        var log: [String] = []
        if let result = loadViaCAPackage(info: info, log: &log) { return result }
        if let result = loadViaCAMLParser(info: info, log: &log) { return result }
        log.append("✗ \(info.displayName): CAPackage 与 CAMLParser 两路均失败（见上）")
        return CALoadResult(layer: nil, method: nil, log: log)
    }

    // MARK: - A. CAPackage

    private static func loadViaCAPackage(info: CAPackageDiskInfo,
                                         log: inout [String]) -> CALoadResult? {
        guard let cls = Dyn.lookupClass("CAPackage") else {
            log.append("CAPackage: 类不存在 (NSClassFromString 返回 nil)")
            return nil
        }
        let dirURL = info.dir

        // A1: +packageWithContentsOfURL:error: — the documented factory.
        if let pkg = Dyn.callFactoryURL(cls as AnyObject,
                                        selector: "packageWithContentsOfURL:error:",
                                        url: dirURL) as? NSObject,
           let layer = rootLayer(of: pkg) {
            log.append("✓ CAPackage/+packageWithContentsOfURL:error: -> rootLayer")
            return CALoadResult(layer: layer, method: "CAPackage/+packageWithContentsOfURL:error:", log: log)
        }
        log.append("CAPackage/+packageWithContentsOfURL:error:: 无结果")

        // A2: +packageWithContentsOfURL: (single-argument variant, if any).
        let factorySel = NSSelectorFromString("packageWithContentsOfURL:")
        let classObject = cls as AnyObject
        if classObject.responds(to: factorySel),
           let pkg = classObject.perform(factorySel, with: dirURL)?.takeUnretainedValue() as? NSObject,
           let layer = rootLayer(of: pkg) {
            log.append("✓ CAPackage/+packageWithContentsOfURL: -> rootLayer")
            return CALoadResult(layer: layer, method: "CAPackage/+packageWithContentsOfURL:", log: log)
        }
        log.append("CAPackage/+packageWithContentsOfURL:: 无结果或选择子不存在")

        // A3: -initWithContentsOfURL:error: on a fresh allocation.
        if let allocated = Dyn.allocate(cls),
           let pkg = Dyn.callFactoryURL(allocated,
                                        selector: "initWithContentsOfURL:error:",
                                        url: dirURL) as? NSObject,
           let layer = rootLayer(of: pkg) {
            log.append("✓ CAPackage/-initWithContentsOfURL:error: -> rootLayer")
            return CALoadResult(layer: layer, method: "CAPackage/-initWithContentsOfURL:error:", log: log)
        }
        log.append("CAPackage/-initWithContentsOfURL:error:: 无结果")

        // A4: -initWithContentsOfURL: on a fresh allocation, IMP bool-style
        // reuse: this initialiser returns id and takes one object arg, so
        // it can ride the callBool-shaped trampoline with a pointer return.
        if let allocated = Dyn.allocate(cls) {
            let sel = NSSelectorFromString("initWithContentsOfURL:")
            if allocated.responds(to: sel) {
                typealias Fn = @convention(c) (AnyObject, Selector, NSURL) -> UnsafeMutableRawPointer?
                let fn = unsafeBitCast(allocated.method(for: sel), to: Fn.self)
                if let raw = fn(allocated, sel, dirURL as NSURL),
                   let pkg = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? NSObject,
                   let layer = rootLayer(of: pkg) {
                    log.append("✓ CAPackage/-initWithContentsOfURL: -> rootLayer")
                    return CALoadResult(layer: layer, method: "CAPackage/-initWithContentsOfURL:", log: log)
                }
            }
        }
        log.append("CAPackage/-initWithContentsOfURL:: 无结果")
        return nil
    }

    /// -rootLayer is the documented CAPackage outlet for the layer tree.
    /// A package object that yields no rootLayer counts as a failure of
    /// that attempt, not as a (useless) success.
    private static func rootLayer(of package: NSObject) -> CALayer? {
        Dyn.getObject(package, selector: "rootLayer") as? CALayer
    }

    // MARK: - B. CAMLParser

    private static func loadViaCAMLParser(info: CAPackageDiskInfo,
                                          log: inout [String]) -> CALoadResult? {
        guard let cls = Dyn.lookupClass("CAMLParser") else {
            log.append("CAMLParser: 类不存在 (NSClassFromString 返回 nil)")
            return nil
        }
        guard let parser = Dyn.instantiate(cls) else {
            log.append("CAMLParser: alloc/init 失败")
            return nil
        }

        // Install the resource delegate before parsing: the parser asks
        // it for asset resources and reports failures through it.
        // -setDelegate: is the documented CAMLParser outlet. If the
        // parser has no delegate outlet this is a soft miss — parsing
        // continues without resource vending.
        let delegate = CAMLResourceDelegate(packageDir: info.dir)
        delegate.onEvent = { log.append("CAMLParser delegate: \($0)") }
        // Keep the delegate alive for the whole parse (the parser holds
        // delegates weakly, like most Cocoa parsers).
        objc_setAssociatedObject(parser, &delegateAssociationKey, delegate,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if Dyn.callVoid(parser, selector: "setDelegate:", arg: delegate) {
            log.append("CAMLParser: delegate 已安装 (资源回退 + 错误捕获)")
        }

        let camlURL = info.mainCAMLURL

        // B1: -parseContentsOfURL: — preferred because the document URL
        // anchors relative src="assets/..." resolution to the .ca dir.
        if let ok = Dyn.callBool(parser, selector: "parseContentsOfURL:", arg: camlURL as NSURL) {
            log.append("CAMLParser/-parseContentsOfURL: 返回 \(ok)")
            if ok, let layer = Dyn.getObject(parser, selector: "result") as? CALayer {
                return CALoadResult(layer: layer, method: "CAMLParser/-parseContentsOfURL:", log: log)
            }
            if ok { log.append("CAMLParser: parse 成功但 -result 不是 CALayer") }
        } else {
            log.append("CAMLParser/-parseContentsOfURL:: 选择子不存在")
        }

        // B2: -parseData: — no base URL, so relative assets may not
        // resolve; the delegate above is the safety net, and the
        // diagnostics panel will show any contents that stayed empty.
        if let data = try? Data(contentsOf: camlURL) {
            if let ok = Dyn.callBool(parser, selector: "parseData:", arg: data as NSData) {
                log.append("CAMLParser/-parseData: 返回 \(ok) (\(data.count) 字节)")
                if ok, let layer = Dyn.getObject(parser, selector: "result") as? CALayer {
                    return CALoadResult(layer: layer, method: "CAMLParser/-parseData:", log: log)
                }
                if ok { log.append("CAMLParser: parse 成功但 -result 不是 CALayer") }
            } else {
                log.append("CAMLParser/-parseData:: 选择子不存在")
            }
        } else {
            log.append("CAMLParser: 读取 \(info.rootDocumentName) 失败，跳过 -parseData:")
        }
        return nil
    }
}

private var delegateAssociationKey: UInt8 = 0

/// CAMLParser delegate (private protocol, matched by selector).
///
/// QuartzCore's CAMLParserDelegate (from runtime headers) includes:
///   - parser:didFailWithError:      — parse failure reporting
///   - parser:resourceForURL:        — vend a resource (image) for a URL
///   - parser:shouldLoadResourceForURL: / parser:didLoadResource:fromURL:
/// Only the first two are implemented; both are best-effort: if the
/// parser's delegate protocol differs on this OS build, these methods
/// are simply never called and parsing proceeds without them.
/// Resources are vended as CGImage loaded from the .ca directory —
/// relative URLs are resolved against the package dir, absolute file
/// URLs are used as-is. JS resources are NEVER vended as code and are
/// never executed (SPEC); an image is the only thing returned.
final class CAMLResourceDelegate: NSObject {
    let packageDir: URL
    var onEvent: ((String) -> Void)?

    init(packageDir: URL) {
        self.packageDir = packageDir
        super.init()
    }

    @objc func parser(_ parser: AnyObject, didFailWithError error: NSError) {
        onEvent?("didFailWithError: \(error.domain) \(error.code) \(error.localizedDescription)")
    }

    @objc func parser(_ parser: AnyObject, resourceForURL url: NSURL) -> AnyObject? {
        guard let path = url.path, !path.isEmpty else { return nil }
        let candidate: URL
        if url.isFileURL {
            candidate = URL(fileURLWithPath: path)
        } else {
            candidate = packageDir.appendingPathComponent(path)
        }
        if candidate.pathExtension.lowercased() == "js" {
            onEvent?("resourceForURL: 拒绝执行 JS 资源 \(candidate.lastPathComponent)（只登记）")
            return nil
        }
        guard let image = UIImage(contentsOfFile: candidate.path),
              let cg = image.cgImage else {
            onEvent?("resourceForURL: 无法加载 \(candidate.lastPathComponent)")
            return nil
        }
        onEvent?("resourceForURL: 已提供 \(candidate.lastPathComponent)")
        return cg as AnyObject
    }
}
