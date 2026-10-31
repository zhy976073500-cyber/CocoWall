import Foundation

// MARK: - .tendies 导出器（关键帧工程 → 壁纸包）
//
// 结构与 CAML 写法逐项镜像已自检通过的验证包
// （~/workspace/tendies-maker-spike/build_spike.py + notes.md）：
// descriptor 布局、providerInfo 的 NSKeyedArchiver 结构、
// Background.ca / Floating.ca 骨架、CAAnimationGroup + CABasicAnimation
// 的字段形态全部照抄，只把单条往返动画换成关键帧段的编译结果：
//   · Group：duration = 时间轴总时长、repeatCount = inf、beginTime = 1e-100；
//   · 每段一条 CABasicAnimation（keyPath = "position"、beginTime = 段起始、
//     duration = 段长、fromValue/toValue 用 type="CGPoint" value="x y"、
//     timingFunction = 该段缓动预设名）；
//   · 浮动图层的模型 position = 首帧位置（首帧时刻之前图层停在那里，
//     与编辑器预览的 position(at:) 语义一致）；
//   · 只有 1 个关键帧时不写动画（静态浮动层），0 帧由界面层拦下不导出。
// 坐标换算（2026-11-01 真机验证定案，全工程唯一换算点）：
// 编辑器内部用画布坐标（原点左上、y 向下），CAML 是左下原点、y 向上，
// 故每个写入 CAML 的位置统一换算 camlPoint = (x, 844 − y)，x 不变。
// fromValue/toValue 的 type="CGPoint" value="x y" 写法已获真机实证
// （验证包橙点沿对角线往返与参数一致），不需要 position.x/.y 双标量备选。
enum TendiesExporter {

    struct Input {
        var name: String
        var project: KeyframeProject
        var backgroundPNG: Data
        var floatingPNG: Data
        /// 浮动图层 bounds 尺寸（pt）。
        var floatingSizePt: CGSize
    }

    struct Output {
        var data: Data
        var identifier: String
        var descriptorUUID: String
    }

    enum ExportError: Error {
        case plistFailed
        case archiveFailed
    }

    // MARK: 常量（与验证包一致）

    static let screenClass = "390w-844h@3x~iphone"
    static let family = "CocoWallKeyframe"

    /// 纯数字、每次导出唯一（毫秒时间戳派生），避开验证包用过的 9901。
    static func makeIdentifier() -> String {
        var value = Int(Date().timeIntervalSince1970 * 1000) % 900_000 + 10_000
        if value == 9901 { value += 1 }
        return String(value)
    }

    // MARK: 主入口（纯函数：同样的输入永远产出同样的包，UUID/编号除外）

    static func build(input: Input, identifier: String, descriptorUUID: String) throws -> Output {
        let wpDir = "\(identifier).\(family)-\(screenClass).wallpaper"
        let bgCA = "\(identifier).\(family)_Background-\(screenClass).ca"
        let flCA = "\(identifier).\(family)_Floating-\(screenClass).ca"
        let base = "descriptors/\(descriptorUUID)"
        let contents = "\(base)/versions/1/contents"
        let wp = "\(contents)/\(wpDir)"

        let files: [(String, Data)] = [
            ("\(base)/com.apple.posterkit.provider.descriptor.identifier",
             Data(identifier.utf8)),
            ("\(base)/com.apple.posterkit.role.identifier",
             Data("PRPosterRoleLockScreen".utf8)),
            ("\(base)/providerInfo.plist",
             try providerInfo()),
            ("\(contents)/com.apple.posterkit.provider.contents.userInfo",
             try userInfo(wallpaperDir: wpDir, identifier: identifier)),
            ("\(wp)/Wallpaper.plist",
             try wallpaperPlist(identifier: identifier, name: input.name, bgCA: bgCA, flCA: flCA)),
            ("\(wp)/\(bgCA)/index.xml", Data(indexXML.utf8)),
            ("\(wp)/\(bgCA)/assetManifest.caml", Data(assetManifest.utf8)),
            ("\(wp)/\(bgCA)/main.caml", Data(backgroundCAML().utf8)),
            ("\(wp)/\(bgCA)/assets/background.png", input.backgroundPNG),
            ("\(wp)/\(flCA)/index.xml", Data(indexXML.utf8)),
            ("\(wp)/\(flCA)/assetManifest.caml", Data(assetManifest.utf8)),
            ("\(wp)/\(flCA)/main.caml", Data(floatingCAML(input: input).utf8)),
            ("\(wp)/\(flCA)/assets/floating.png", input.floatingPNG),
        ]

        // 目录条目与验证包一致：所有祖先目录先以 "/" 结尾的空条目写入。
        var dirs = Set<String>()
        for (name, _) in files {
            let parts = name.split(separator: "/")
            for i in 1..<parts.count {
                dirs.insert(parts[0..<i].joined(separator: "/") + "/")
            }
        }
        var entries: [(String, Data)] = dirs.sorted().map { ($0, Data()) }
        entries.append(contentsOf: files)

        return Output(data: zipStore(entries: entries),
                      identifier: identifier,
                      descriptorUUID: descriptorUUID)
    }

    // MARK: CAML（模板逐字对照 build_spike.py）

    private static let layerAttrs =
        "zPosition=\"0\" geometryFlipped=\"0\" opacity=\"1\" " +
        "transform.rotation.z=\"0\" transform.rotation.x=\"0\" transform.rotation.y=\"0\" " +
        "transform=\"rotate(0deg) rotate(0deg, 0, 1, 0) rotate(0deg, 1, 0, 0)\" " +
        "allowsEdgeAntialiasing=\"1\" allowsGroupOpacity=\"1\" contentsFormat=\"RGBA8\" " +
        "cornerCurve=\"circular\""

    private static let statesSkeleton = """
        <modules/>
        <states>
          <LKState name="Locked">
            <elements/>
          </LKState>
          <LKState name="Unlock">
            <elements/>
          </LKState>
          <LKState name="Sleep">
            <elements/>
          </LKState>
        </states>
        <stateTransitions>
          <LKStateTransition fromState="*" toState="Locked">
            <elements/>
          </LKStateTransition>
          <LKStateTransition fromState="Locked" toState="*">
            <elements/>
          </LKStateTransition>
          <LKStateTransition fromState="*" toState="Unlock">
            <elements/>
          </LKStateTransition>
          <LKStateTransition fromState="Unlock" toState="*">
            <elements/>
          </LKStateTransition>
          <LKStateTransition fromState="*" toState="Sleep">
            <elements/>
          </LKStateTransition>
          <LKStateTransition fromState="Sleep" toState="*">
            <elements/>
          </LKStateTransition>
        </stateTransitions>
    """

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

    static func backgroundCAML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
          <CALayer id="__capRootLayer__" name="CocoWallKeyframe Root Layer" bounds="0 0 390 844" position="195 422" \(layerAttrs) backgroundColor="0.027 0.035 0.07">
            <sublayers>
              <CALayer id="kfBgRoot" name="Root Layer" bounds="0 0 390 844" position="195 422" \(layerAttrs)>
                <sublayers>
                  <CALayer id="kfBgImage" name="background.png" bounds="0 0 390 844" position="195 422" zPosition="0" geometryFlipped="0" masksToBounds="0" opacity="1" transform.rotation.z="0" transform.rotation.x="0" transform.rotation.y="0" transform="rotate(0deg) rotate(0deg, 0, 1, 0) rotate(0deg, 1, 0, 0)" cornerRadius="0" allowsEdgeAntialiasing="1" allowsGroupOpacity="1" contentsFormat="RGBA8" cornerCurve="circular">
                    <contents>
                      <CGImage src="assets/background.png"/>
                    </contents>
                  </CALayer>
                </sublayers>
              </CALayer>
            </sublayers>
        \(statesSkeleton)
          </CALayer>
        </caml>
        """
    }

    /// 画布坐标 → CAML 坐标：(x, 844 − y)。全工程唯一换算点。
    static func camlPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: KeyframeProject.canvasSize.height - p.y)
    }

    static func floatingCAML(input: Input) -> String {
        let project = input.project
        // 模型位置 = 首帧位置；无帧时退回画布中心（界面层保证导出时至少 1 帧）。
        let model = camlPoint(project.keyframes.first?.position ?? CGPoint(x: 195, y: 422))
        let w = fmt(Double(input.floatingSizePt.width))
        let h = fmt(Double(input.floatingSizePt.height))

        var animations = ""
        let segs = project.segments()
        if !segs.isEmpty {
            var children = ""
            for seg in segs {
                let from = camlPoint(seg.from)
                let to = camlPoint(seg.to)
                let begin = seg.startTime > 0.0001 ? " beginTime=\"\(fmt(seg.startTime))\"" : ""
                children += """
                      <CABasicAnimation keyPath="position"\(begin) duration="\(fmt(seg.duration))" timingFunction="\(seg.easing.camlName)">
                        <fromValue type="CGPoint" value="\(fmt(Double(from.x))) \(fmt(Double(from.y)))"/>
                        <toValue type="CGPoint" value="\(fmt(Double(to.x))) \(fmt(Double(to.y)))"/>
                      </CABasicAnimation>

                """
            }
            animations = """

                        <animations>
                          <move type="CAAnimationGroup" autoreverses="0" beginTime="1e-100" duration="\(fmt(project.duration))" removedOnCompletion="0" repeatCount="inf" timeOffset="0" timingFunction="linear">
                            <animations>
            \(children)              </animations>
                          </move>
                        </animations>
            """
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
          <CALayer id="__capRootLayer__" name="CocoWallKeyframe Root Layer" bounds="0 0 390 844" position="195 422" \(layerAttrs)>
            <sublayers>
              <CALayer id="kfFlRoot" name="Root Layer" bounds="0 0 390 844" position="195 422" \(layerAttrs)>
                <sublayers>
                  <CALayer id="kfFloatLayer" name="floating.png" bounds="0 0 \(w) \(h)" position="\(fmt(Double(model.x))) \(fmt(Double(model.y)))" zPosition="0" geometryFlipped="0" masksToBounds="0" opacity="1" transform.rotation.z="0" transform.rotation.x="0" transform.rotation.y="0" transform="rotate(0deg) rotate(0deg, 0, 1, 0) rotate(0deg, 1, 0, 0)" cornerRadius="0" allowsEdgeAntialiasing="1" allowsGroupOpacity="1" contentsFormat="RGBA8" cornerCurve="circular">
                    <contents>
                      <CGImage src="assets/floating.png"/>
                    </contents>\(animations)
                  </CALayer>
                </sublayers>
              </CALayer>
            </sublayers>
        \(statesSkeleton)
          </CALayer>
        </caml>
        """
    }

    // MARK: Plists（字段与验证包一致）

    static func wallpaperPlist(identifier: String, name: String, bgCA: String, flCA: String) throws -> Data {
        let identifierInt = Int(identifier) ?? 0
        let plist: [String: Any] = [
            "appearanceAware": false,
            "assets": ["lockAndHome": ["default": [
                "backgroundAnimationFileName": bgCA,
                "floatingAnimationFileNameKey": flCA,
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
    /// 用 NSKeyedArchiver 原生归档，结构与验证包（NSMutableDictionary 根）一致。
    static func providerInfo() throws -> Data {
        let dict = NSMutableDictionary()
        dict["kConfigurationLastUseDateKey"] = Date()
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: dict, requiringSecureCoding: false) else {
            throw ExportError.archiveFailed
        }
        return data
    }

    // MARK: 数字格式化（整数不带小数点，其余最多 3 位小数去尾零）

    static func fmt(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 {
            return String(Int(v))
        }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: ZIP（STORE 无压缩，与 PasscodeThemePackager 同构的自带原语）

    static func zipStore(entries: [(String, Data)]) -> Data {
        var zipData = Data()
        var centralDirectory = Data()
        var count: UInt16 = 0

        for (name, content) in entries {
            guard let nameData = name.data(using: .utf8) else { continue }
            let crc = crc32(content)
            let offset = UInt32(zipData.count)

            var local = Data()
            local.appendLE32(0x04034b50)  // Local file header signature
            local.appendLE16(20)          // Version needed: 2.0
            local.appendLE16(0x0800)      // Flags: UTF-8 file names
            local.appendLE16(0)           // Compression: stored
            local.appendLE16(0)           // Last mod time
            local.appendLE16(0)           // Last mod date
            local.appendLE32(crc)
            local.appendLE32(UInt32(content.count))
            local.appendLE32(UInt32(content.count))
            local.appendLE16(UInt16(nameData.count))
            local.appendLE16(0)           // Extra field length
            local.append(nameData)
            zipData.append(local)
            zipData.append(content)

            var central = Data()
            central.appendLE32(0x02014b50)  // Central dir file header signature
            central.appendLE16(20)          // Version made by
            central.appendLE16(20)          // Version needed
            central.appendLE16(0x0800)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE32(crc)
            central.appendLE32(UInt32(content.count))
            central.appendLE32(UInt32(content.count))
            central.appendLE16(UInt16(nameData.count))
            central.appendLE16(0)  // Extra field length
            central.appendLE16(0)  // File comment length
            central.appendLE16(0)  // Disk number start
            central.appendLE16(0)  // Internal file attributes
            central.appendLE32(0)  // External file attributes
            central.appendLE32(offset)
            central.append(nameData)
            centralDirectory.append(central)
            count += 1
        }

        let cdOffset = UInt32(zipData.count)
        let cdSize = UInt32(centralDirectory.count)
        zipData.append(centralDirectory)
        var end = Data()
        end.appendLE32(0x06054b50)  // End of central directory signature
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

    /// 表驱动 CRC-32（ISO 3309，与 Models.swift 中的位运算版本结果一致）。
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
