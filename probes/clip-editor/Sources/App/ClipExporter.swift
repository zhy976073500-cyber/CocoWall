import Foundation
import CoreGraphics

// MARK: - .tendies 导出器（剪辑工程 → 三状态壁纸包）
//
// 结构镜像两个已验证来源，不发明格式：
//  · 文件集合与打包：镜像 CocoWall 的 TendiesExporter / 验证包
//    build_spike.py（descriptor.identifier、role.identifier、
//    providerInfo 的 NSKeyedArchiver、userInfo、Wallpaper.plist、
//    每 .ca 的 index.xml / assetManifest.caml / main.caml / assets，
//    STORE zip + 目录条目）。验证包即以此集合真机刷入成功；
//    样本包多出的 suggestionMetadata、RuntimeSnapshotMetadata、
//    homescreen supplement 等属于图库/建议元数据，不在
//    「缺一不可」集合内，本探针不生成（如实记录在 README）。
//  · 状态结构：镜像样本包 33_1_lng7（重打包 7400）的 main.caml——
//    根 CALayer（__capRootLayer__）> Root Layer > 内容图层
//    （<contents><CGImage/></contents> + 可选 <animations>），
//    根层下 <modules/><states> 三个 LKState（Locked/Unlock/Sleep），
//    每图层每状态 5 条 LKStateSetValue（position.x / position.y /
//    bounds.size.width / bounds.size.height / opacity，值整数时
//    type="integer" 否则 type="real"，与样本一致）；
//    <stateTransitions> 6 条通配，每条含每图层一个
//    LKStateTransitionElement（key="opacity"，内嵌 CASpringAnimation
//    ——过渡只对 opacity 做，与样本一致，其余属性的状态切换由
//    PosterBoard 按同弹簧插值这一行为属待真机验证项，见 README）。
//  · 持续动画：镜像样本 Floating 的 CAKeyframeAnimation 写法
//    （<animation type="CAKeyframeAnimation" …><values><real/></values>），
//    只写 transform.*（分工不抢状态属性）。模板一圈 = 循环时长：
//    duration 写循环秒数、speed 写 2×速度，单程 = 循环/(2×速度)，
//    autoreverses=1 首尾回环。
//  · 熄屏 Sleep：不单独编辑，导出时 = 开屏摆位、透明度 ×0.5。
//  · 淡入/淡出帧数（clip 两头）v1 只在编辑器预览生效，不写入包：
//    opacity 已被状态/过渡占用，再叠一条 opacity 循环动画会与
//    状态机抢属性，样本无此形态；待真机验证共存后再加（README）。
//
// 坐标换算（2026-11-01 真机验证定案，全工程唯一换算点）：
// 编辑器画布坐标原点左上、y 向下；CAML 左下原点、y 向上：
// camlPoint = (x, 844 − y)。
enum ClipExporter {

    struct Output {
        var data: Data
        var identifier: String
        var descriptorUUID: String
    }

    enum ExportError: Error {
        case plistFailed
        case archiveFailed
        case missingBackground
        case renderFailed(String)
    }

    static let screenClass = "390w-844h@3x~iphone"
    static let family = "CocoClip"

    // MARK: 素材解析

    private struct ResolvedLayer {
        var layer: EditorLayer
        var camlID: String
        var assetName: String
        var assetData: Data
    }

    private static func resolve(_ project: ClipProject) throws -> (bg: ResolvedLayer, floating: [ResolvedLayer], foreground: [ResolvedLayer]) {
        guard let background = project.background,
              case .photo(let data, _) = background.content else {
            throw ExportError.missingBackground
        }
        let bg = ResolvedLayer(layer: background, camlID: "ceBg0",
                               assetName: "background." + ImageDataFormat.fileExtension(for: data),
                               assetData: data)

        var floating: [ResolvedLayer] = []
        for (i, layer) in project.floating.enumerated() {
            guard case .photo(let data, _) = layer.content else { continue }
            floating.append(ResolvedLayer(
                layer: layer, camlID: "ceFl\(i)",
                assetName: "layer-\(i + 1)." + ImageDataFormat.fileExtension(for: data),
                assetData: data))
        }

        var foreground: [ResolvedLayer] = []
        for (i, layer) in project.foreground.enumerated() {
            let data: Data
            let name: String
            switch layer.content {
            case .text(let string, let fontSize, let colorHex):
                guard let rendered = ForegroundRenderer.renderTextPNG(
                    string: string, fontSize: fontSize, colorHex: colorHex) else {
                    throw ExportError.renderFailed(layer.name)
                }
                data = rendered
                name = "text-\(i + 1).png"
            case .sweep:
                let layout = layer.layout(for: .locked)
                guard let rendered = ForegroundRenderer.renderSweepPNG(sizePt: layout.size) else {
                    throw ExportError.renderFailed(layer.name)
                }
                data = rendered
                name = "sweep-\(i + 1).png"
            case .photo:
                continue
            }
            foreground.append(ResolvedLayer(layer: layer, camlID: "ceFg\(i)",
                                            assetName: name, assetData: data))
        }
        return (bg, floating, foreground)
    }

    // MARK: 主入口

    static func build(project: ClipProject, identifier: String, descriptorUUID: String) throws -> Output {
        let resolved = try resolve(project)
        let wpDir = "\(identifier).\(family)-\(screenClass).wallpaper"
        let bgCA = "\(identifier).\(family)_Background-\(screenClass).ca"
        let flCA = "\(identifier).\(family)_Floating-\(screenClass).ca"
        let fgCA = "\(identifier).\(family)_Foreground-\(screenClass).ca"
        let base = "descriptors/\(descriptorUUID)"
        let contents = "\(base)/versions/1/contents"
        let wp = "\(contents)/\(wpDir)"

        var files: [(String, Data)] = [
            ("\(base)/com.apple.posterkit.provider.descriptor.identifier",
             Data(identifier.utf8)),
            ("\(base)/com.apple.posterkit.role.identifier",
             Data("PRPosterRoleLockScreen".utf8)),
            ("\(base)/providerInfo.plist", try providerInfo()),
            ("\(contents)/com.apple.posterkit.provider.contents.userInfo",
             try userInfo(wallpaperDir: wpDir, identifier: identifier)),
            ("\(wp)/Wallpaper.plist",
             try wallpaperPlist(identifier: identifier, name: project.name,
                                 bgCA: bgCA, flCA: flCA, fgCA: fgCA)),
            ("\(wp)/\(bgCA)/index.xml", Data(TendiesFormat.indexXML.utf8)),
            ("\(wp)/\(bgCA)/assetManifest.caml", Data(TendiesFormat.assetManifest.utf8)),
            ("\(wp)/\(bgCA)/main.caml",
             Data(caml(rootID: "ceBgRoot", layers: [resolved.bg], project: project).utf8)),
            ("\(wp)/\(bgCA)/assets/\(resolved.bg.assetName)", resolved.bg.assetData),
            ("\(wp)/\(flCA)/index.xml", Data(TendiesFormat.indexXML.utf8)),
            ("\(wp)/\(flCA)/assetManifest.caml", Data(TendiesFormat.assetManifest.utf8)),
            ("\(wp)/\(flCA)/main.caml",
             Data(caml(rootID: "ceFlRoot", layers: resolved.floating, project: project).utf8)),
        ]
        for layer in resolved.floating {
            files.append(("\(wp)/\(flCA)/assets/\(layer.assetName)", layer.assetData))
        }
        files += [
            ("\(wp)/\(fgCA)/index.xml", Data(TendiesFormat.indexXML.utf8)),
            ("\(wp)/\(fgCA)/assetManifest.caml", Data(TendiesFormat.assetManifest.utf8)),
            ("\(wp)/\(fgCA)/main.caml",
             Data(caml(rootID: "ceFgRoot", layers: resolved.foreground, project: project).utf8)),
        ]
        for layer in resolved.foreground {
            files.append(("\(wp)/\(fgCA)/assets/\(layer.assetName)", layer.assetData))
        }

        var dirs = Set<String>()
        for (name, _) in files {
            let parts = name.split(separator: "/")
            for i in 1..<parts.count {
                dirs.insert(parts[0..<i].joined(separator: "/") + "/")
            }
        }
        var entries: [(String, Data)] = dirs.sorted().map { ($0, Data()) }
        entries.append(contentsOf: files)

        return Output(data: TendiesFormat.zipStore(entries: entries),
                      identifier: identifier, descriptorUUID: descriptorUUID)
    }

    // MARK: CAML 生成

    /// 画布坐标 → CAML 坐标：(x, 844 − y)。全工程唯一换算点。
    static func camlPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: ClipProject.canvasSize.height - p.y)
    }

    private static func caml(rootID: String, layers: [ResolvedLayer], project: ClipProject) -> String {
        var contentLayers = ""
        for item in layers {
            let layout = item.layer.lockedLayout
            let model = camlPoint(layout.center)
            contentLayers += """
                      <CALayer id="\(item.camlID)" name="\(item.assetName)" bounds="0 0 \(fmt(Double(layout.size.width))) \(fmt(Double(layout.size.height)))" position="\(fmt(Double(model.x))) \(fmt(Double(model.y)))" zPosition="0" geometryFlipped="0" masksToBounds="0" opacity="\(fmt(layout.opacity))" transform.rotation.z="0" transform.rotation.x="0" transform.rotation.y="0" transform="rotate(0deg) rotate(0deg, 0, 1, 0) rotate(0deg, 1, 0, 0)" cornerRadius="0" allowsEdgeAntialiasing="1" allowsGroupOpacity="1" contentsFormat="RGBA8" cornerCurve="circular">
                        <contents>
                          <CGImage src="assets/\(item.assetName)"/>
                        </contents>\(animationsXML(for: item.layer, project: project))
                      </CALayer>

            """
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
          <CALayer id="__capRootLayer__" name="CocoClip Root Layer" bounds="0 0 390 844" position="195 422" \(TendiesFormat.layerAttrs)>
            <sublayers>
              <CALayer id="\(rootID)" name="Root Layer" bounds="0 0 390 844" position="195 422" \(TendiesFormat.layerAttrs)>
                <sublayers>
        \(contentLayers)        </sublayers>
              </CALayer>
            </sublayers>
        \(statesXML(layers: layers, project: project))
          </CALayer>
        </caml>
        """
    }

    // MARK: 模板动画（只写 transform.*）

    private struct KeyframeAnimation {
        var keyPath: String
        var values: [Double]
        var duration: Double
        var speed: Double
        var autoreverses: Bool
    }

    private static func keyframeAnimations(for layer: EditorLayer, project: ClipProject) -> [KeyframeAnimation] {
        var result: [KeyframeAnimation] = []
        let loop = project.loopSeconds

        func append(_ motion: MotionSetting) {
            let a = motion.amplitude
            let dur = loop
            let spd = 2 * motion.speed
            switch motion.kind {
            case .float:
                let amp = 4 + 26 * a
                result.append(KeyframeAnimation(
                    keyPath: "transform.translation.y", values: [-amp, amp],
                    duration: dur, speed: spd, autoreverses: true))
            case .sway:
                let amp = 0.03 + 0.12 * a
                result.append(KeyframeAnimation(
                    keyPath: "transform.rotation.z", values: [-amp, amp],
                    duration: dur, speed: spd, autoreverses: true))
            case .spinSway:
                let amp = 0.08 + 0.22 * a
                result.append(KeyframeAnimation(
                    keyPath: "transform.rotation.z", values: [-amp, amp],
                    duration: dur, speed: spd, autoreverses: true))
            case .breathe:
                result.append(KeyframeAnimation(
                    keyPath: "transform.scale", values: [1, 1 + (0.02 + 0.08 * a)],
                    duration: dur, speed: spd, autoreverses: true))
            case .kenburns:
                result.append(KeyframeAnimation(
                    keyPath: "transform.scale", values: [1, 1 + 0.07 * a],
                    duration: dur, speed: spd, autoreverses: true))
                result.append(KeyframeAnimation(
                    keyPath: "transform.translation.x", values: [0, -14 * a],
                    duration: dur, speed: spd, autoreverses: true))
                result.append(KeyframeAnimation(
                    keyPath: "transform.translation.y", values: [0, 8 * a],
                    duration: dur, speed: spd, autoreverses: true))
            case .sweep:
                result.append(KeyframeAnimation(
                    keyPath: "transform.translation.x", values: [-320, 320],
                    duration: loop, speed: 1, autoreverses: false))
            }
        }

        if let action = layer.actionMotion { append(action) }
        if let transform = layer.transformMotion { append(transform) }
        return result
    }

    private static func animationsXML(for layer: EditorLayer, project: ClipProject) -> String {
        let anims = keyframeAnimations(for: layer, project: project)
        guard !anims.isEmpty else { return "" }
        var body = ""
        for (i, anim) in anims.enumerated() {
            let values = anim.values
                .map { "                  <real value=\"\(fmt($0))\"/>" }
                .joined(separator: "\n")
            body += """
                      <animation key="animation-\(i)" type="CAKeyframeAnimation" keyPath="\(anim.keyPath)" autoreverses="\(anim.autoreverses ? 1 : 0)" beginTime="1e-100" duration="\(fmt(anim.duration))" speed="\(fmt(anim.speed))" removedOnCompletion="0" repeatCount="inf" repeatDuration="inf" calculationMode="linear">
                        <values>
            \(values)
                        </values>
                      </animation>

            """
        }
        return """

                        <animations>
            \(body)            </animations>
        """
    }

    // MARK: 状态与过渡

    /// 某图层在某状态下的五条属性值（Sleep = 开屏 × 0.5 透明度）。
    private static func stateValues(of layer: EditorLayer, state: String) -> LayerLayout {
        switch state {
        case "Unlock":
            return layer.unlockLayout
        case "Sleep":
            var sleep = layer.lockedLayout
            sleep.opacity *= 0.5
            return sleep
        default:
            return layer.lockedLayout
        }
    }

    private static func setValue(targetID: String, keyPath: String, value: Double) -> String {
        // 与样本一致：整数值写 type="integer"，其余 type="real"。
        if value == value.rounded() && abs(value) < 1e15 {
            return """
              <LKStateSetValue targetId="\(targetID)" keyPath="\(keyPath)">
                <value type="integer" value="\(Int(value))"/>
              </LKStateSetValue>
            """
        }
        return """
          <LKStateSetValue targetId="\(targetID)" keyPath="\(keyPath)">
            <value type="real" value="\(fmt(value))"/>
          </LKStateSetValue>
        """
    }

    private static func statesXML(layers: [ResolvedLayer], project: ClipProject) -> String {
        var states = ""
        for state in ["Locked", "Unlock", "Sleep"] {
            var elements = ""
            for item in layers {
                let layout = stateValues(of: item.layer, state: state)
                let pos = camlPoint(layout.center)
                elements += setValue(targetID: item.camlID, keyPath: "position.x", value: Double(pos.x)) + "\n"
                elements += setValue(targetID: item.camlID, keyPath: "position.y", value: Double(pos.y)) + "\n"
                elements += setValue(targetID: item.camlID, keyPath: "bounds.size.width", value: Double(layout.size.width)) + "\n"
                elements += setValue(targetID: item.camlID, keyPath: "bounds.size.height", value: Double(layout.size.height)) + "\n"
                elements += setValue(targetID: item.camlID, keyPath: "opacity", value: layout.opacity) + "\n"
            }
            states += """
              <LKState name="\(state)">
                <elements>
            \(elements)        </elements>
              </LKState>

            """
        }

        let spring = project.spring
        let duration = fmt(project.transitionSeconds)
        var transitions = ""
        let pairs: [(String, String)] = [
            ("*", "Locked"), ("Locked", "*"),
            ("*", "Unlock"), ("Unlock", "*"),
            ("*", "Sleep"), ("Sleep", "*"),
        ]
        for (from, to) in pairs {
            var elements = ""
            for item in layers {
                elements += """
                  <LKStateTransitionElement targetId="\(item.camlID)" key="opacity">
                    <animation type="CASpringAnimation" damping="\(fmt(spring.damping))" mass="\(fmt(spring.mass))" stiffness="\(fmt(spring.stiffness))" velocity="0" duration="\(duration)" fillMode="backwards" keyPath="opacity" mica_autorecalculatesDuration="1"/>
                  </LKStateTransitionElement>

                """
            }
            transitions += """
              <LKStateTransition fromState="\(from)" toState="\(to)">
                <elements>
            \(elements)        </elements>
              </LKStateTransition>

            """
        }

        return """
            <modules/>
            <states>
        \(states)    </states>
            <stateTransitions>
        \(transitions)    </stateTransitions>
        """
    }

    // MARK: Plists（字段与验证包一致，仅多 foregroundAnimationFileName——样本包同名字段）

    static func wallpaperPlist(identifier: String, name: String,
                               bgCA: String, flCA: String, fgCA: String) throws -> Data {
        let identifierInt = Int(identifier) ?? 0
        let plist: [String: Any] = [
            "appearanceAware": false,
            "assets": ["lockAndHome": ["default": [
                "backgroundAnimationFileName": bgCA,
                "floatingAnimationFileNameKey": flCA,
                "foregroundAnimationFileName": fgCA,
                "identifier": identifierInt,
                "name": name,
                "type": "LayeredAnimation",
            ] as [String: Any]] as [String: Any]] as [String: Any],
            "family": family,
            "identifier": identifierInt,
            "logicalScreenClass": screenClass,
            "name": name,
            "version": 1,
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0) else {
            throw ExportError.plistFailed
        }
        return data
    }

    static func userInfo(wallpaperDir: String, identifier: String) throws -> Data {
        let plist: [String: Any] = [
            "posterEnvironmentOverrides": Data("{}".utf8),
            "wallpaperRepresentingFileName": wallpaperDir,
            "wallpaperRepresentingIdentifier": identifier,
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0) else {
            throw ExportError.plistFailed
        }
        return data
    }

    /// providerInfo.plist：{kConfigurationLastUseDateKey: 当前时间}，
    /// NSKeyedArchiver 原生归档，与 TendiesExporter 同实现（已验证）。
    static func providerInfo() throws -> Data {
        let dict = NSMutableDictionary()
        dict["kConfigurationLastUseDateKey"] = Date()
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: dict, requiringSecureCoding: false) else {
            throw ExportError.archiveFailed
        }
        return data
    }

    // MARK: 数字格式化（与 TendiesExporter 同：整数不带小数，其余 ≤3 位去尾零）

    static func fmt(_ v: Double) -> String {
        TendiesFormat.fmt(v)
    }
}

// MARK: - 与 TendiesExporter 同构的格式原语（逐字改编自已验证实现）

enum TendiesFormat {

    static let layerAttrs =
        "zPosition=\"0\" geometryFlipped=\"0\" opacity=\"1\" " +
        "transform.rotation.z=\"0\" transform.rotation.x=\"0\" transform.rotation.y=\"0\" " +
        "transform=\"rotate(0deg) rotate(0deg, 0, 1, 0) rotate(0deg, 1, 0, 0)\" " +
        "allowsEdgeAntialiasing=\"1\" allowsGroupOpacity=\"1\" contentsFormat=\"RGBA8\" " +
        "cornerCurve=\"circular\""

    static let indexXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>rootDocument</key>
      <string>main.caml</string>
    </dict>
    </plist>
    """

    static let assetManifest = """
    <?xml version="1.0" encoding="UTF-8"?>

    <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
      <MicaAssetManifest>
        <modules type="NSArray"/>
      </MicaAssetManifest>
    </caml>

    """

    static func fmt(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 {
            return String(Int(v))
        }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: ZIP（STORE 无压缩，与 TendiesExporter 同实现）

    static func zipStore(entries: [(String, Data)]) -> Data {
        var zipData = Data()
        var centralDirectory = Data()
        var count: UInt16 = 0

        for (name, content) in entries {
            guard let nameData = name.data(using: .utf8) else { continue }
            let crc = crc32(content)
            let offset = UInt32(zipData.count)

            var local = Data()
            local.appendLE32(0x04034b50)
            local.appendLE16(20)
            local.appendLE16(0x0800)
            local.appendLE16(0)
            local.appendLE16(0)
            local.appendLE16(0)
            local.appendLE32(crc)
            local.appendLE32(UInt32(content.count))
            local.appendLE32(UInt32(content.count))
            local.appendLE16(UInt16(nameData.count))
            local.appendLE16(0)
            local.append(nameData)
            zipData.append(local)
            zipData.append(content)

            var central = Data()
            central.appendLE32(0x02014b50)
            central.appendLE16(20)
            central.appendLE16(20)
            central.appendLE16(0x0800)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE32(crc)
            central.appendLE32(UInt32(content.count))
            central.appendLE32(UInt32(content.count))
            central.appendLE16(UInt16(nameData.count))
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE32(0)
            central.appendLE32(offset)
            central.append(nameData)
            centralDirectory.append(central)
            count += 1
        }

        let cdOffset = UInt32(zipData.count)
        let cdSize = UInt32(centralDirectory.count)
        zipData.append(centralDirectory)
        var end = Data()
        end.appendLE32(0x06054b50)
        end.appendLE16(0)
        end.appendLE16(0)
        end.appendLE16(count)
        end.appendLE16(count)
        end.appendLE32(cdSize)
        end.appendLE32(cdOffset)
        end.appendLE16(0)
        zipData.append(end)
        return zipData
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table: [UInt32] = []
        table.reserveCapacity(256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table.append(c)
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE16(_ v: UInt16) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }

    mutating func appendLE32(_ v: UInt32) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
}
