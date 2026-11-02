//
//  PreviewViewModel.swift
//  TendiesPreview (Phase 0 probe)
//
//  Orchestrates the probe's four jobs (SPEC):
//    1. import a .tendies (zip) and locate its .ca packages;
//    2. load each package via PrivateCALoader and stack the roots on
//       the canvas (Background -> Floating -> Foreground);
//    3. drive states through CAStateController — full state list as
//       buttons, plus the "开屏→解锁" script (Locked 1.5 s -> Unlock);
//    4. keep a scrolling diagnostics log: load path & outcome per
//       package, layer counts, state names + their source, transition
//       counts, asset inventory, JS assets (registered, never run),
//       missing resources.
//
//  All entry points are called from the UI (main thread); layer work
//  stays on the main thread by construction.
//

import Foundation
import QuartzCore
import UIKit

/// One successfully loaded .ca package on the canvas.
final class LoadedPackage {
    let info: CAPackageDiskInfo
    let rootLayer: CALayer
    let loadMethod: String
    /// Wrapper that scales/centres the root (whose own bounds can be
    /// e.g. 3176x3176 for the iPad Cubes package) into the canvas
    /// WITHOUT touching the root's own transform or position semantics:
    /// the fit layer carries the scale, the root keeps its model values
    /// (states may setValue on sublayers, and poster packages expect
    /// the root at the centre of its own bounds).
    let fitLayer = CALayer()
    /// Retained CAStateController (opaque NSObject); the layer does not
    /// retain it, so the probe must.
    var controller: NSObject?
    /// States read from the layer's -states array (may be empty).
    var states: [StateBridge.StateInfo] = []
    /// Where the displayed state names for this package came from.
    var stateNameSource = "无"

    init(info: CAPackageDiskInfo, rootLayer: CALayer, loadMethod: String) {
        self.info = info
        self.rootLayer = rootLayer
        self.loadMethod = loadMethod
        fitLayer.masksToBounds = true
        fitLayer.addSublayer(rootLayer)
    }

    /// State names for display: live layer states preferred, CAML text
    /// mining as the fallback (SPEC diagnostics must say which).
    var displayStateNames: [String] {
        let live = states.map(\.name).filter { !$0.isEmpty }
        return live.isEmpty ? info.stateNamesFromCAML : live
    }

    func stateObject(for name: String) -> NSObject? {
        states.first { $0.name == name }?.object
    }
}

final class PreviewViewModel: ObservableObject {

    @Published private(set) var diagnosticText = "壁纸预览探针就绪。导入一个 .tendies 开始。\n"
    @Published private(set) var stateNames: [String] = []
    @Published private(set) var currentStateName: String?
    @Published private(set) var packageSummary = "未导入"
    @Published private(set) var canvasSize = CGSize(width: 390, height: 844)
    @Published private(set) var isBusy = false

    private var logLines: [String] = []
    private let startTime = Date()
    private weak var host: LayerHostView?
    private var loaded: [LoadedPackage] = []
    private var extractDir: URL?

    // MARK: - Logging

    func log(_ line: String) {
        let t = String(format: "%6.2f", Date().timeIntervalSince(startTime))
        logLines.append("[\(t)] \(line)")
        if logLines.count > 800 { logLines.removeFirst(logLines.count - 800) }
        diagnosticText = logLines.joined(separator: "\n") + "\n"
    }

    // MARK: - Canvas hosting

    func attachHost(_ view: LayerHostView) {
        host = view
        rebuildCanvas()
    }

    func hostDidLayout() { refitCanvas() }

    private func rebuildCanvas() {
        guard let host else { return }
        for sub in host.canvasLayer.sublayers ?? [] { sub.removeFromSuperlayer() }
        for pkg in loaded { host.canvasLayer.addSublayer(pkg.fitLayer) }
        refitCanvas()
    }

    /// Scale each package root into the canvas: fit layer bounds = root
    /// bounds, positioned at canvas centre, scaled by the fit factor.
    /// The root itself is only re-centred inside its own bounds (the
    /// value poster packages already carry: position == bounds centre).
    private func refitCanvas() {
        guard let host, host.bounds.width > 0, host.bounds.height > 0 else { return }
        let canvas = host.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for pkg in loaded {
            let rb = pkg.rootLayer.bounds
            guard rb.width > 0, rb.height > 0 else { continue }
            let scale = min(canvas.width / rb.width, canvas.height / rb.height)
            pkg.fitLayer.bounds = rb
            pkg.fitLayer.position = CGPoint(x: canvas.midX, y: canvas.midY)
            pkg.fitLayer.transform = CATransform3DMakeScale(scale, scale, 1)
            pkg.rootLayer.position = CGPoint(x: rb.midX, y: rb.midY)
        }
        CATransaction.commit()
    }

    // MARK: - Import (SPEC job 1)

    func importFrom(url: URL) {
        clearCanvas()
        isBusy = true
        defer { isBusy = false }
        log("—— 导入 \(url.lastPathComponent) ——")
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tendies_preview_\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let (files, notes) = try ZipExtractor.extract(zipURL: url, to: dir)
            log("解包完成: \(files.count) 个文件")
            for note in notes { log("解包注: \(note)") }
            extractDir = dir

            let infos = TendiesScanner.scan(extractedRoot: dir)
            guard !infos.isEmpty else {
                log("✗ 解包内未找到任何 .ca 包 — 不是可预览的 .tendies")
                packageSummary = "未找到 .ca 包"
                return
            }
            log("定位到 \(infos.count) 个 .ca 包")
            if let first = infos.first { canvasSize = first.logicalSize }

            for info in infos { loadOne(info) }
            finishLoad(fileName: url.lastPathComponent)
        } catch {
            log("✗ 导入失败: \(error)")
            packageSummary = "导入失败"
        }
    }

    private func clearCanvas() {
        for pkg in loaded { pkg.fitLayer.removeFromSuperlayer() }
        loaded = []
        stateNames = []
        currentStateName = nil
        if let dir = extractDir { try? FileManager.default.removeItem(at: dir) }
        extractDir = nil
    }

    // MARK: - Loading (SPEC job 2) + per-package diagnostics (job 4)

    private func loadOne(_ info: CAPackageDiskInfo) {
        log("—— \(info.kind.label): \(info.displayName) ——")
        log("路径: \(info.dir.path)")
        log("index.xml rootDocument: \(info.rootDocumentName)；壁纸包: \(info.wallpaperName.isEmpty ? "(无)" : info.wallpaperName)；逻辑尺寸: \(Int(info.logicalSize.width))×\(Int(info.logicalSize.height))")

        let result = PrivateCALoader.load(info: info)
        for line in result.log { log(line) }

        guard let layer = result.layer else {
            log("✗ \(info.kind.label) 加载失败 — 该层在画布上缺席（不静默黑屏，原因见上）")
            return
        }
        let pkg = LoadedPackage(info: info, rootLayer: layer,
                                loadMethod: result.method ?? "未知路径")
        loaded.append(pkg)
        log("✓ \(info.kind.label) 加载成功 via \(pkg.loadMethod)")
        log("图层计数: root 子树共 \(Self.countLayers(layer)) 层（含 root）")

        // States: live enumeration first, CAML text as fallback.
        pkg.states = StateBridge.states(of: layer)
        let liveNames = pkg.states.map(\.name).filter { !$0.isEmpty }
        if !liveNames.isEmpty {
            pkg.stateNameSource = "layer.states"
            log("状态(layer.states, \(liveNames.count)): \(liveNames.joined(separator: " | "))")
        } else {
            pkg.stateNameSource = info.stateNamesFromCAML.isEmpty ? "无" : "CAML 文本兜底"
            log("状态(layer.states 读不到) → CAML 文本兜底 (\(info.stateNamesFromCAML.count)): \(info.stateNamesFromCAML.joined(separator: " | "))")
        }
        let liveTransitions = StateBridge.transitionCount(of: layer)
        log("过渡条数: layer.stateTransitions=\(liveTransitions.map(String.init) ?? "读不到") / CAML 文本计数≈\(info.transitionCountFromCAML)")

        // Assets inventory.
        log("assets(\(info.assetFiles.count)): \(info.assetFiles.isEmpty ? "无" : info.assetFiles.joined(separator: ", "))")
        if !info.jsAssets.isEmpty {
            log("JS 资产(只登记不执行): \(info.jsAssets.joined(separator: ", "))")
        }
        log("CAML 引用 src(\(info.referencedSrcs.count)): \(info.referencedSrcs.isEmpty ? "无" : info.referencedSrcs.joined(separator: ", "))")
        log("缺失资源: \(info.missingSrcs.isEmpty ? "无" : info.missingSrcs.joined(separator: ", "))")

        // State controller + initial states.
        let (controller, controllerLog) = StateBridge.makeController(for: layer)
        log(controllerLog)
        if let controller {
            pkg.controller = controller
            log(StateBridge.setInitialStates(controller: controller, layer: layer))
        } else {
            log("⚠ \(info.kind.label) 无 CAStateController — 状态切换对该层不可用")
        }

        rebuildCanvas()
    }

    private func finishLoad(fileName: String) {
        // Union of state names across packages, Background first.
        var union: [String] = []
        for pkg in loaded {
            for name in pkg.displayStateNames where !union.contains(name) { union.append(name) }
        }
        stateNames = union
        let okCount = loaded.count
        packageSummary = "\(fileName)：\(okCount) 层已加载，\(union.count) 个状态"
        log("汇总: \(okCount) 个 .ca 已上画布；状态并集 \(union.count) 个")
        log("图层自带动画应已自动播放（未暂停 layer 时间）。点状态按钮或「开屏→解锁」验证切换。")
        // Show the initial (locked-family) state name as current if known.
        currentStateName = preferredStateName(family: "lock") ?? union.first
    }

    static func countLayers(_ layer: CALayer) -> Int {
        1 + (layer.sublayers ?? []).reduce(0) { $0 + countLayers($1) }
    }

    // MARK: - State switching (SPEC job 3)

    /// Family key of a state name: Locked/Lock* -> lock, Unlock* ->
    /// unlock, Home* -> home, Sleep* -> sleep. Cubes has no "Unlock"
    /// family (unlock lands on Home), 7400 has no "Home".
    static func family(of name: String) -> String {
        let n = name.lowercased()
        if n.hasPrefix("unlock") { return "unlock" }
        if n.hasPrefix("lock") { return "lock" }
        if n.hasPrefix("home") { return "home" }
        if n.hasPrefix("sleep") { return "sleep" }
        return n
    }

    /// Pick the variant of `family` matching the canvas traits
    /// (PortraitUp + current Light/Dark appearance) when the package
    /// uses Cubes-style composite names; plain names match directly.
    func preferredStateName(family: String, among names: [String]? = nil) -> String? {
        let pool = names ?? stateNames
        let inFamily = pool.filter { Self.family(of: $0) == family }
        guard !inFamily.isEmpty else { return nil }
        if inFamily.count == 1 { return inFamily[0] }
        let dark = host?.traitCollection.userInterfaceStyle == .dark
        let scored = inFamily.map { name -> (name: String, score: Int) in
            var s = 0
            if name.contains("PortraitUp") { s += 2 }
            if name.contains(dark ? "Dark" : "Light") { s += 1 }
            return (name, s)
        }
        return scored.max { $0.score < $1.score }?.name
    }

    /// Resolve which state of THIS package a union-level button press
    /// means: exact name -> same-family variant -> (if the name is only
    /// known from CAML text) a freshly constructed state object.
    private func resolveState(in pkg: LoadedPackage, requested: String)
        -> (name: String, object: NSObject, how: String)? {
        if let obj = pkg.stateObject(for: requested) {
            return (requested, obj, "layer.states 精确匹配")
        }
        let family = Self.family(of: requested)
        if let variant = preferredStateName(family: family, among: pkg.displayStateNames),
           let obj = pkg.stateObject(for: variant) {
            return (variant, obj, "同族变体")
        }
        if pkg.displayStateNames.contains(requested),
           let obj = StateBridge.makeStateObject(named: requested) {
            return (requested, obj, "按名构造状态对象（未经 layer.states 验证）")
        }
        return nil
    }

    func applyState(named name: String, note: String = "手动") {
        guard !loaded.isEmpty else { log("切状态: 尚未导入任何包"); return }
        var applied = 0
        for pkg in loaded {
            guard let controller = pkg.controller else {
                log("切状态[\(note)] \(pkg.info.kind.label): 无 controller，跳过")
                continue
            }
            guard let resolved = resolveState(in: pkg, requested: name) else {
                log("切状态[\(note)] \(pkg.info.kind.label): 无匹配状态「\(name)」")
                continue
            }
            if let how = StateBridge.setState(controller: controller,
                                              layer: pkg.rootLayer,
                                              state: resolved.object) {
                log("切状态[\(note)] \(pkg.info.kind.label) -> 「\(resolved.name)」(\(resolved.how), \(how))")
                applied += 1
            } else {
                log("切状态[\(note)] \(pkg.info.kind.label): setState* 选择子不存在")
            }
        }
        if applied > 0 { currentStateName = name }
    }

    // MARK: - "开屏→解锁" script

    /// Locked for 1.5 s, then Unlock (falling back to Home for
    /// Cubes-style packages, which model the unlocked screen as Home).
    func playUnlockScript() {
        guard !loaded.isEmpty else { log("剧本: 尚未导入任何包"); return }
        guard let lockName = preferredStateName(family: "lock") else {
            log("剧本: 找不到 Lock 族状态，无法开屏")
            return
        }
        applyState(named: lockName, note: "剧本-开屏")
        log("剧本: 「\(lockName)」停留 1.5s 后解锁…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let target = self.preferredStateName(family: "unlock")
                ?? self.preferredStateName(family: "home")
            guard let target else {
                self.log("剧本: 找不到 Unlock/Home 族状态，停留在锁定态")
                return
            }
            self.applyState(named: target, note: "剧本-解锁")
            self.log("剧本完成: 已切到「\(target)」")
        }
    }

    // MARK: - Stability self-test (acceptance gate 6)

    /// Alternate between the lock-family and unlock/home-family states
    /// 20 times. Reaching the end of the loop in a live process IS the
    /// pass signal for "no crash"; visual residue is judged by eye on
    /// the canvas (noted in the log line).
    func runSwitchSelfTest() {
        guard stateNames.count >= 2, !loaded.isEmpty else {
            log("自检: 状态不足 2 个，无法连切")
            return
        }
        let a = preferredStateName(family: "lock") ?? stateNames[0]
        var b = preferredStateName(family: "unlock") ?? preferredStateName(family: "home") ?? stateNames[1]
        if b == a { b = stateNames.first { $0 != a } ?? b }
        log("自检: 在「\(a)」/「\(b)」间连切 20 次开始")
        runSwitchStep(index: 1, total: 20, a: a, b: b)
    }

    private func runSwitchStep(index: Int, total: Int, a: String, b: String) {
        guard index <= total else {
            log("自检完成: \(total) 次切换后进程存活、无异常抛出 ⇒ 稳定性门本轮通过（画布残影请肉眼确认）")
            return
        }
        applyState(named: index % 2 == 1 ? a : b, note: "自检 \(index)/\(total)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.runSwitchStep(index: index + 1, total: total, a: a, b: b)
        }
    }
}
