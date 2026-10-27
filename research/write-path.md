# CocoWall 写入路径调研

更新：2026-10-28。证据等级分三档：= 在 Sage 提供的 Vellum_v1.0.ipa 主二进制 strings/符号里直接看到；= 开源项目可查；= 由前两类拼出、未经真机验证，文中明确标注。

## 结论先行

Vellum 的隧道写入**不是** HouseArrest 直写 PosterBoard 容器，也不是 SparseRestore 备份还原。它自带一个 Rust 库（内部名 `airlift_ffi`，模块 `grappa` + `exploit`），走的是 **AirTraffic（com.apple.atc）同步 + AFC Media 暂存 + 符号链接** 这条路：文件先经隧道落进 AFC 的 Media 区并放好指向 PosterBoard 容器的 symlink，再伪装成 Books 数据类同步触发系统 AirTraffic 守护进程替它把文件夹「注入」目标容器，最后用 diagnostics_relay 重启 SpringBoard/设备刷新。这解释了它为什么不需要越狱、也不依赖 bad_query，且隧道路径覆盖面比直写广。

## 流水线（按二进制日志串还原）

1. **建隧道**
- 优先 RSD 路线：`attempting RSD tunnel on port 49152`，服务以 shim 形式发现：`com.apple.afc.shim.remote`、`com.apple.mobile.installation_proxy.shim.remote`、`com.apple.mobile.lockdown.remote.trusted`。
- 失败回退 Lockdown 路线：`attempting Lockdown connection on port 62078`，再不行回退 raw RPPairing。日志有 cached route / fast-reconnect 逻辑。
- 配对文件校验：必须同时兼容 Lockdown record 与 Remote Pairing credentials，缺一报 invalid。
2. **定位 PosterBoard 容器**
- Swift 层 `PosterBoardContainer`：多候选合并——LaunchServices 查询、metadata 扫描（读 `.com.apple.mobile_container_manager.metadata.plist`）、appDataRoots、缓存路径；含共享系统组路径 `/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.PosterBoard`。
- Rust 层 `airlift: looking up container for 'com.apple.PosterBoard'`经 installation_proxy shim 查该系统 App 的容器路径。
- 目标根：`<容器>/Library/Application Support/PRBPosterExtensionDataStore/`，其下 `<store版本>/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors/<UUID>/…`。store 版本 iOS 17+ 为 `61`（iOS 16 为 `59`）。
3. **AFC 暂存**
- 经 AFC（RSD shim）把 descriptor 文件夹批量写入 Media 区：`batch staging`、`folder archive size`、`successfully batch-wrote`；写后回读校验：`staged folder verified in AFC`，失败文案 `Stage verification failed: source symlink or payload not present in Media`——即暂存区里同时要有 payload 和一条 symlink。
4. **AirTraffic 注入**
- 改写 Books.plist 发起同步（结束恢复原文件：`restored original Books.plist`；`AFC open/write Books.plist`）。
- 同步握手需要 **Grappa token**：运行时从系统私有框架 `/System/Library/PrivateFrameworks/AirTrafficHost.framework` dlsym `ALGetGrappaToken`（ObjC 辅助类 GrappaHelper，抓 GrappaSupportInfo 的 version/deviceType/protocolVersion），生成 authentic token 存入同步请求（字段含 SyncHostName、airliftLibraryID、DataclassesRequestingSync、GrappaLocalCloudSupport 等，伪装 iTunes 13.7 / Mac 同步主机）。
- 协议节奏：等 `ReadyForSync` → 收到 `AssetManifest` → 逐批 `FileComplete`。两处超时文案都提示「ensure Apple Books is installed」——同步数据类借的是 Books。
- 守护进程（系统权限）在同步时跟随暂存区 symlink，把文件夹落进 PosterBoard 容器。
5. **刷新与校验**
- `com.apple.mobile.diagnostics_relay` 发 Restart（重启设备/SpringBoard）。
- Swift 侧 `galleryDescriptorCount(at:generation:)` 回读描述符计数确认收录。

Rust 侧入口符号：`exploit_run`、`exploit_inject_folder`、`exploit_write_batch`、`exploit_write_single_file`、`generate_grappa_token`——即注入/批量写/单文件写是三个独立原语，CocoWall 的 DeviceService 接口按这个粒度切。

## 直写路径（v1 不做，仅备查）

`DirectWallpaperStore.isPosterBoardContainer` + bad_query 沙盒扩展：Mak5er 的 Pocket-Poster（开源，leminlimez 原作的 iOS 27 移植）验证口径 iOS 26–27.0b4、需本机检测容器 hash、写后 full respring。Sage 的 27.0.1 正式版不在其验证列，v1 仍以隧道路径为主，与 SPEC 一致。

## 对 CocoWall 的实现拆分（M1/M2 落点）

- M1a 隧道与配对：PacketTunnel 包交换泵 + idevice FFI（RSD shim 服务发现、Lockdown 回退）、PIN 配对与配对文件导入——StikDebug/SideStore 同生态有可参照。
- M1b 容器定位：installation_proxy 查 PosterBoard 容器 + Swift 多候选校验（照 Vellum 的 candidates 思路自写），输出 descriptors 目标路径与当前计数。
- M1c AFC 暂存 PoC：先只验证「经隧道 AFC 写 Media + 建 symlink + 回读」成立，不触发同步——这是整条链最便宜的真机验证点。
- M2a GrappaHelper：ObjC 运行时加载 AirTrafficHost、取 token（私有框架、侧载环境可用，App Store 不可能过审——与分发渠道为公众号自取一致）。
- M2b ATC 同步状态机：Books.plist 暂存/恢复、ReadyForSync→AssetManifest→FileComplete、超时与 Books 未装提示。
- M2c 注入后 diagnostics_relay 重启 + gallery 计数回读校验；移除 = 同路径删 descriptors 对应 UUID 后重启。

## 未决问题

1. ATC 批量资产清单的确切消息格式（DataclassAssetPath 等字段已见名，完整字典结构需真机抓 Vellum 同步日志或进一步逆向 airlift_ffi）。
2. Media 暂存区 symlink 的确切相对路径与目标写法（校验文案只证实「symlink + payload 同在 Media」）。
3. 容器定位在隧道侧走 installation_proxy 的返回结构（系统 App 是否给完整容器路径，未验证）。
4. iOS 27.0.1 上 Grappa token 生成与 ATC 同步是否仍被接受——只能真机验，Vellum 自身在该版本走的也是隧道路径（其直写未验证 27.0 正式版），侧面说明隧道链在 27.0.1 上是作者押注的主路。

---

# 补充：公开来源调研（2026-10-28，web/GitHub）

以下为公开来源可查的部分，与上文二进制证据互相印证；每条关键结论附链接。凡公开来源无法证实的，明确写入文末未决清单，不与二进制证据混淆。

## A. idevice 库：Swift 如何消费、可写文件的服务与沙盒边界

- 仓库：jkcoxson/idevice，纯 Rust，**MIT** 许可，自述被 StikDebug、CrossCode、Protokolle 等 App 使用。README 的 feature 表即服务清单：`afc`、`house_arrest`、`installation_proxy`、`mobilebackup2`、`core_device_proxy`、`xpc`（RSD）、`tunnel_tcp_stack`、`springboardservices`、`diagnostics_relay`、`misagent` 等，按 cargo feature 开关裁剪。
  https://github.com/jkcoxson/idevice
- Swift 消费方式：仓库自带三层绑定——`ffi/`（C FFI 小 crate，示例在 `ffi/examples`）、`cpp/`（C++ 封装，供 C++/Swift 工程）、`swift/`（SPM 包，`Package.swift` 以 binaryTarget 引用预编译的 `IDevice.xcframework` 与 `plist.xcframework`，上层是 `IDeviceSwift` Swift target）。xcframework 由 justfile 的 `just apple-build` + `just xcframework`（lipo 合并 + xcodebuild 打包）产出；`cpp/xcode_build_rust.sh` 可作 Xcode Run Script 阶段按目标架构跑 cargo。社区另有 khcrysalis/IDeviceKit 在同一 xcframework 上再包一层 Swift API。
  https://deepwiki.com/jkcoxson/idevice/7.1-build-system
  https://deepwiki.com/jkcoxson/idevice/9.1-cross-platform-compilation
  https://deepwiki.com/khcrysalis/IDeviceKit/8-development-guide
- 服务名路由：AFC 在 lockdown 下叫 `com.apple.afc`，经 RSD 时叫 `com.apple.afc.shim.remote`，客户端按连接类型自动切换（pymobiledevice3 与 Netimobiledevice 实现一致）。RSD 在设备 58783 端口做服务经纪，iOS 17+ 开发者服务都以 `.shim.remote` 形式经隧道发现。
  https://deepwiki.com/doronz88/pymobiledevice3/5.1-file-system-access-(afc)
  https://deepwiki.com/doronz88/pymobiledevice3/3-remote-access-and-tunneling-(ios-17+)
- 沙盒边界（为什么最终写入不能靠 AFC/HouseArrest 直达）：
  - `AfcClient` 只能访问 **media 分区**（/var/mobile/Media 狱笼），pymobiledevice3 对 `afc shell` 的定位就是「Manage the media directory」。
    https://deepwiki.com/jkcoxson/idevice/4-device-services
    https://pypi.org/project/pymobiledevice3/4.11.7/
  - `HouseArrestClient` 用 `vend_container` / `vend_documents` 只能打开**单个 App 的容器**，且目标 App 需具备文档共享类条件；系统 App 的共享容器不在其可达范围（公开实现均如此描述）。
    https://deepwiki.com/jkcoxson/idevice/4-device-services
  - `installation_proxy` 只管 App 的安装/枚举/归档，不提供任意文件写入。
  - 这与上文二进制结论自洽：Vellum 用 AFC 只做 Media **暂存**（狱笼内可写），最终落盘由系统守护进程 atc 完成——AFC 狱笼不是障碍，因为它从不要求 AFC 跨狱笼。
- 另一个候选（未被 Vellum 采用、列为备查）：CoreDevice 文件服务 `com.apple.coredevice.fileservice.control` / `.data`，按 domain + identifier（bundle id）寻址，domain 枚举为 1=AppDataContainer、2=AppGroupDataContainer、3=Temporary、4=RootStaging、5=SystemCrashLogs（go-ios 实现）。这些 domain 都是「某个 App 的域」，公开资料没有证明第三方侧载 App 能借此寻址 PosterBoard 的系统组容器；idevice 的 README feature 表里也没有 fileservice 条目。
  https://pkg.go.dev/github.com/danielpaulus/go-ios/ios/fileservice

## B. 回环隧道与机内配对：开源实现与流程

- StikDebug（StikDebug/StikDebug）：「An on-device debugger/JIT enabler for iOS versions 17.4+, powered by idevice」，运行要求三件套——idevice 生成的配对文件、侧载工具、以及「a loopback VPN such as LocalDevVPN」。即隧道本身是独立组件（LocalDevVPN 为 App Store 上的独立 App，非 StikDebug 内置），CocoWall 规格里把隧道做进自有 PacketTunnel 扩展，等价于 Vellum 的做法、不同于 StikDebug 的外挂做法。
  https://github.com/StikDebug/StikDebug
- SideStore 生态同构：现行安装指南统一用 LocalDevVPN 做回环（早期为 WireGuard/StosVPN）；SideStore issue #1623 的实测记录对隧道实现有硬要求——设备在 **10.7.0.1** 的 RSD 端口应答，但每次隧道协商开的是**新的高位端口**，只转发单端口的代理永远覆盖不了，VPN 必须对 RSD 子网做全量转发（这正是包交换回环而非端口代理的原因）。该 issue 同时记录 iOS 26.7 与 27.2 beta 上 DeviceEndpointNotInitialized 的失效报告。
  https://github.com/SideStore/SideStore/issues/1623
  https://iphonecaptain.com/how-to-sideload-iphone-ipad-2026/
- 机内 PIN 配对流程（多处独立记录一致）：App 侧以 Bonjour 广播 `_remotepairing-pairable-host._tcp` 并显示 PIN → 用户到 设置 › 隐私与安全性 › 开发者模式 › 点「与 <App> 配对」输入 PIN → 设备生成 RemotePairing 凭据（.mobiledevicepairing）。每次重新配对会**替换**旧配对记录。idevice 的 `remote_pairing` 模块即主机/应答方实现（responder、rp_pairing_file、TLS-PSK、TLV8），jkcoxson 另有 rppairing 协议 spec（README 链到 jkcoxson.com）。
  https://nextjailbreak.com/enable-jit-husk-stikjit-stikdebug-guide/
  https://deepwiki.com/jkcoxson/idevice/3.4-remote-pairing-(ios-17+-network-pairing)
- 配对文件导入路径：桌面工具 idevice_pair 可把生成的配对文件按各 App 约定路径直接装入（SideStore 为 `ALTPairingFile.mobiledevicepairing`、StikDebug 为 `pairingFile.plist` 等），与 Vellum 支持导入 SideStore/iLoader/AltStore/Jitterbug 导出文件的口径一致。配对文件须同时含 Lockdown record 与 RemotePairing 凭据（上文二进制校验逻辑），旧式纯 Lockdown 配对文件在 26.4 后不可用（见 D 节）。
  https://deepwiki.com/jkcoxson/idevice_pair
- 常见失效模式（builds.io 的 StikDebug 排障汇总，可作 CocoWall 的错误文案参考）：Heartbeat(-9) = 配对文件被设备拒绝、只能重配；隧道要求 Wi-Fi 环境（蜂窝下 -1）；iOS 26.5.2 曾有配对文件导入后自删的系统侧 bug。
  https://builds.io/blog/technologies/ios-technologies/stikdebug-not-working-fix/

## C. PosterBoard 容器：公开来源印证

- 备份域证据：iMazing 教程（社区 gist）显示 PosterBoard 数据在备份中以 `AppDomain-com.apple.PosterBoard` 域出现，桌面端「还原 App 数据」即可整包替换其容器内容——这是 Nugget/Pocket Poster 一代工具走 SparseRestore/还原路线的依据，也证明 PosterBoard 容器在备份体系里被当作一个 App 域管理。与上文二进制定位到的系统组路径 `systemgroup.com.apple.PosterBoard` 是同一容器的两种寻址面。
  https://gist.github.com/lunginspector/e276b1de10e7dd1c89d703c58ab90fbd
- Pocket Poster（LeminLimez，Nugget 5.2.3+ 的配套 App）：机内应用 .tendies，但初始化要靠桌面 Nugget 的「Pocket Poster Helper」Detect 按钮先取 App Hash/UUID——即桌面侧先完成一次容器寻址/写入准备，机内 App 才能独立工作；应用后的壁纸在系统原生壁纸界面里选取，只支持 .tendies。
  https://www.idownloadblog.com/2025/06/08/pocket-poster/
- 目录命名印证：iOS 27 模拟器运行时 PosterBoard.framework 字符串里出现 `PRBPosterExtensionDataStore`、`GalleryCache`、`SnapshotCache.cachedb` 及各官方扩展 ID，与上文二进制给出的 `PRBPosterExtensionDataStore/61/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors/` 结构同名同构（注意：此为模拟器证据，非真机路径实证）。
  https://storageradar.app/blog/inside-xcode-simulator-device-data/
- 索引层提示（弱证据）：GoldenNugget 的 issue #71 记录 iOS 27.0.1 上 PosterBoard「Complete Reset」因 SQLite（sqlite_sequence 保留名）失败、且旧注入壁纸残留在 Collections 中删不掉——说明注入条目的收录/索引带 SQLite 状态，粗暴删目录不等于系统除名，与上文「回读 gallery 计数校验」互相印证；但该报错出自该工具自身的重置代码，不能直接推论系统 GalleryCache 的内部格式。
  https://github.com/GoldenNugget-Team/GoldenNugget/issues/71
- 背景：备份域名的 `SysSharedContainerDomain-` 扩展机制正是 SparseRestore 当年写入共享系统容器的原理，而 domains.plist 已在 iOS 17 被移除、还原路线逐版本收窄——这是新一代工具转向隧道 + ATC 的大背景。
  https://gist.github.com/leminlimez/c602c067349140fe979410ef69d39c28

## D. 隧道路径的版本约束（公开记录）

| 系统 | 约束 | 来源 |
| --- | --- | --- |
| iOS 17.0 | CoreDevice/RSD 引入：开发者服务必须经隧道，服务名加 `.shim.remote`，RSD 端口 58783；传统 lockdown 直连开发者服务失效 | pymobiledevice3 DeepWiki |
| iOS 17.4 | idevice 系机内工具的实际下限（StikDebug 标注 17.4+；17.0–17.3 的隧道行为不同，桌面端亦有驱动限制注记） | StikDebug 仓库 / builds.io |
| iOS 18.x | 全面支持期，无重大配对变更公开记录 | builds.io |
| iOS 26.4 | **配对协议变更**：旧 Lockdown 配对流程断裂（BrokenPipe/code 32），全生态改用 **RPPairing** 生成新配对文件，jkcoxson 同步更新 idevice_pair | builds.io / onejailbreak |
| iOS 26.5.2 | 配对文件导入后自删的系统侧 bug（工具侧 3.1.8/3.1.9 修复口径） | builds.io |
| iOS 26.7 / 27.x beta | 隧道可用但有个案失效报告（DeviceEndpointNotInitialized）；维护者称 StikDebug 在最新 27 beta 可用；对 VPN 的要求是 RSD 子网全量转发 | SideStore #1623 / builds.io |

对 CocoWall 的直接含义：配对实现从第一天就按 RPPairing 做、不兼容旧 Lockdown-only 配对文件；iOS 下限按 SPEC 的 17.0 写、但测试矩阵要把 17.4 设为实际支持下限（17.0–17.3 列为未验证）；27.x 的风险点不在壁纸写入本身，而在隧道协商与配对凭据的代际差异，M1 真机验证应优先覆盖 Sage 的 27.0.1。

## E. 推荐写入路径（汇总版，供实现直接引用）

1. 隧道：自有 PacketTunnel 扩展装 /32 路由（接口 10.7.0.2、设备 10.7.0.1），包交换回环，不接管默认路由。
2. 配对：idevice `remote_pairing` 应答方广播 + 机内 PIN（设置 › 开发者模式），或导入含双份凭据的 .mobiledevicepairing；凭据校验失败即引导重配。
3. 连接：idevice provider 优先 RSD shim 服务发现（`com.apple.afc.shim.remote`、`com.apple.mobile.installation_proxy.shim.remote`、`com.apple.mobile.lockdown.remote.trusted`），回退 lockdown TCP 62078。
4. 定位：installation_proxy 查 com.apple.PosterBoard 容器 + Swift 多候选校验 → 目标目录 `<容器>/Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors/<UUID>/`（store 版本 61 = iOS 17+）。
5. 暂存：AFC（shim）把 descriptor 文件夹整夹写进 Media 区，同置指向目标 descriptors 目录的 symlink，回读校验 payload 与 symlink 并存。
6. 注入：备份 Books.plist → 改写触发 Books 数据类 ATC 同步；Grappa token 运行时从 AirTrafficHost 私有框架 `ALGetGrappaToken` 生成；同步状态机 ReadyForSync → AssetManifest → FileComplete；atc 守护进程跟随 symlink 把文件夹落入容器；同步后恢复原 Books.plist。
7. 刷新校验：`com.apple.mobile.diagnostics_relay` 发重启；回读 gallery 描述符计数确认收录 +1（或同名覆盖计数不变但条目在库）。
8. 移除：同路径删除对应 UUID 描述符并重启、回读计数确认除名（删除在 ATC 语义下的确切实现见未决清单第 5 条）。

所涉服务清单：`com.apple.afc.shim.remote`、`com.apple.mobile.installation_proxy.shim.remote`、`com.apple.mobile.lockdown.remote.trusted`、`com.apple.atc`（AirTraffic 同步）、`com.apple.mobile.diagnostics_relay`。

## F. 未决清单（公开来源 + 本轮调研仍未证实）

5. ATC 删除语义：移除壁纸时是「同步一个删除清单」还是「先删容器内文件再同步」，二进制只证实移除后重启刷新，未区分。
6. ATC 同步的传输面：App 与 atc 的同步协议经隧道哪条服务/端口承载（com.apple.atc 经 lockdown 启动还是 RSD shim），公开来源无记载，二进制字段只能证明协议内容。
7. CoreDevice fileservice（fileservice.control/.data）能否被第三方侧载 App 用来寻址系统组容器——无公开实证，当前按「不可行」处理、不进实现计划。
8. StikDebug 与 LocalDevVPN 的确切许可/可复用边界未逐一核对（LocalDevVPN 为独立 App，CocoWall 不依赖它，此项仅影响参照范围，不影响自研路线）。
9. iOS 17.0–17.3 与 26.0–26.3 的隧道 + ATC 全链未见公开实测记录；版本矩阵中这两段按「理论可行、未验证」标注。
10. 本轮三路并行调研中有两路（idevice 服务细节、隧道实现细节）返回空结果，上述 A/B 两节由主调研者自 DeepWiki（仓库代码索引）与仓库 README 一手页面补齐，个别行号级引用未逐条复核到源码行。
11. AirCard-iOS 仓库（Mak5er/AirCard-iOS）代码未逐行核对；其 AirliftFFI 与 Vellum 的 airlift_ffi 命名相同、机制描述一致，高度暗示同源或同生态，但「同源」本身未证实，不作为实现依据、只作为参照入口。
12. configurations/SQLite 路线（见 G.2）是否为 Vellum 的行为之一未证实：二进制只出现 descriptors 与 gallery 计数，按「v1 只写 descriptors」处理。

---

# 附录 G：PosterBoard 布局深挖（第三轮调研补入，含对上文的更正）

## G.1 容器根路径：公开证据的主路径是 Data/Application 容器

公开来源一致地把 PosterBoard 当作一个内部 App（`com.apple.PosterBoard`），其数据容器在：

```
/var/mobile/Containers/Data/Application/<PosterBoard-UUID（pbHash）>/
  Library/Application Support/PRBPosterExtensionDataStore/
    <store 版本（17+ 为 61）>/
      Extensions/<provider>/descriptors|configurations/…
```

- 越狱/备份教程给出的原文路径与备份域 `AppDomain-com.apple.PosterBoard` 映射：https://gist.github.com/MWRevamped/9161837f2bda90d13c7d24e285226691
- Pocket Poster 的 symlink 目标构造（同一路径 + `{appHash}`）：https://deepwiki.com/leminlimez/Pocket-Poster/4.4-file-system-operations
- 2026 年的 iMazing 备份改法仍用同一树：https://gist.github.com/pdfux/da1ca51123c59239a9712e5af9372191/raw/b1c3924cc89120026f0ed9838b563444614dfe80/Mercury_Collections.md

**对上文 §2 的精化**：二进制候选里的 `Shared/SystemGroup/systemgroup.com.apple.PosterBoard` 在公开来源中**没有**被证实为 PosterBoard 的家目录——SystemGroup 路径的公开记录只见于 MobileGestalt 缓存目标与 bad_query 的可达路径列表。实现含义：容器定位以 installation_proxy 查到的 App 数据容器（Data/Application/<pbHash>）为第一优先，SystemGroup 候选保留为兜底校验，不作为默认落点。
https://deepwiki.com/leminlimez/Nugget/3.5-posterboard-customization
https://github.com/forcequitOS/bad_query

## G.2 descriptors/ 与 configurations/ 是两棵不同的树，收录机制不同

- `descriptors/` = 「添加新壁纸」菜单里的预设池。.tendies 注入写这里；**无需编辑任何索引**，文件夹落盘后由 PosterBoard 守护进程收录（各公开流程均无索引编辑步）。
  https://deepwiki.com/leminlimez/Pocket-Poster/4.1-tendies-file-format
- `configurations/` = 已在锁屏轮播（quick-switch）里的条目。走备份改法写这里时**必须同时改 SQLite 库** `PRBPosterExtensionDataStore/<版本>/PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3`：向 `poster`（UUID, providerId）、`posterRoleMembership`（posterUUID, roleId='PRPosterRoleLockScreen', roleSortKey）、`posterAttributes`（posterUUID, roleId, 'PRPosterRoleAttributeTypeUsageMetadata', payload）三表插入，且这类条目只进轮播、不进图库，UI 里删掉无法再添加。
  https://gist.github.com/pdfux/da1ca51123c59239a9712e5af9372191/raw/b1c3924cc89120026f0ed9838b563444614dfe80/Mercury_Collections.md
- CocoWall v1 只写 descriptors/（与 Vellum 二进制的 gallery 计数校验口径一致），configurations/SQLite 路线不进 v1。

## G.3 对 §C「GalleryCache」的更正

公开证据里 GalleryCache 是**快照缓存**（内含 Composite/Background/Foreground/Floating `.atx` 快照），不是标识符索引；§C 中 GoldenNugget 的 SQLite 线索对应的应是 G.2 的 configurations 库，而非 GalleryCache。任何公开流程都没有「删除/编辑 GalleryCache 使壁纸出现」这一步。
https://storageradar.app/blog/inside-xcode-simulator-device-data/

## G.4 标识符三件套一致性（写入端必须处理）

同一个 ID 必须在三处一致：`com.apple.posterkit.provider.descriptor.identifier`（纯文本全文）、contents.userInfo 的 `wallpaperRepresentingIdentifier`、`Wallpaper.plist` 的 `identifier`。Pocket Poster 的做法是随机化为 9999–99999 并同步改三处（Nugget 5.2 后只随机 descriptor 本级、不动子标识）；**重复 ID 的公开记录后果是覆盖/不收录，未见导致 PosterBoard 崩溃的记录**。SPEC 样本的 identifier 为固定值 9998——导入时是否随机化是 CocoWall 的实现决策（二进制的「同名覆盖」计数文案说明 Vellum 至少处理了覆盖情形）。
https://deepwiki.com/leminlimez/Pocket-Poster/4.2-posterboardmanager
https://www.idownloadblog.com/2025/05/01/nugget-v5-2-update/

## G.5 supplements/ 的证据状态

公开来源**无任何记载** supplements/ 子目录；但 Sage 提供的真样本 .tendies 中存在 `supplements/0/…`。以样本为准：导入与写入时整棵 descriptors 树原样搬运，不按公开教程的简化结构裁剪。

## G.6 bad_query 的公开出处与确切版本口

- 原始仓库 forcequitOS/bad_query 自述为「iOS 26.0 – 26.6.1 / 27.0b4 的 sandbox escape PoC」，可达路径含 `/var/mobile/Containers/Data/Application/*` 与（27 上）`/var/containers/Shared/SystemGroup/*`；消费级工具（Pocket Poster/Ketamine）口径为 26.6.2 封顶，**26.6.1 vs 26.6.2 的差异未决**，实现文档按更保守的 26.6.1 标注。
  https://github.com/forcequitOS/bad_query
- Ketamine 2.0 发布说明明确：bad_query/MobileGestalt 路线在 **27.0 Beta 5 起**（含 RC/正式版）够不到系统容器，该版本段改走 **AirLift（配对隧道）**——与 Vellum「27.0 正式版直写未验证、主走隧道」逐字吻合，是隧道路线在 27.x 的独立生态印证。
  https://withered.live/blog/keta-2-0b1
- 3105（YangJiiii）是另一条独立血统（MobileHouseArrest/ContainerManager 等 PoC + 内核利用），且明确要求**企业证书签名**、SideStore/AltStore 不在其支持安装路径内——与 CocoWall 的分发方式不兼容，仅作生态参照。
  https://github.com/YangJiiii/3105

## G.7 AirLift 有公开实现可参照（对 M2 影响最大）

- Mak5er 的 **AirCard-iOS** 是开源实现，公开描述即：AirliftFFI + AirTraffic 协议、经 LocalDevVPN 本地隧道（10.7.0.1）、机内开发者模式配对生成配对记录、直接导入 .tendies。Ketamine 的 AirLift 为第二条独立印证。含义：ATC 注入这条链不必从零逆向 Vellum 二进制，M2 前应先逐行核对该仓库的同步实现再定自研边界（其许可与代码细节待核，见未决 11）。
  https://gittrend.io/repo/Mak5er/AirCard-iOS （二手汇总，细节以仓库为准）
  https://withered.live/blog/keta-2-0b1 （一手发布说明）

## G.8 写入后刷新：按路线对照（无统一「删缓存」步）

| 路线 | 落盘后必需步 |
| --- | --- |
| Nugget 还原（SparseRestore/BookRestore） | 整机重启（Apply 的一部分） |
| Pocket Poster `.Trash` symlink | 无——trashItem 移动本身即触发 PosterBoard 导入 |
| Pocket Poster bad_query | full respring（Frontboard+Backboard） |
| 备份改 configurations | 还原整份改过的备份 |
| Vellum/CocoWall 隧道 ATC | diagnostics_relay 重启 + gallery 计数回读（二进制证据） |

另：Pocket Poster 的「切换系统语言触发刷新」是其**移除/重置**手段，不是安装必需步，不要混入安装流水线。
https://deepwiki.com/leminlimez/Pocket-Poster/8.3-cache-and-collection-management

---

# 附录 H：仓库级核实与更正（第四轮调研补入，逐条对应上文）

以下结论来自直接读仓库源码（jkcoxson/idevice @ master 8970209、StikDebug、StosVPN、idevice_pair、Locus），证据等级高于 §A/§B 的 DeepWiki 转述；与上文冲突处以本附录为准。

## H.1 【更正·产品级】机内 PIN 配对是 iOS 27 独占，17–26 只能导入配对文件

idevice 的 responder 实现文件头注释原文：设备发起的配对（pairable host / responder）**自 iOS 27 起**才有——设备在 设置 › 隐私与安全性 › 开发者模式 里出现「与 <主机名> 配对」、输 6 位 PIN；idevice_pair 的 README 与 Locus、AirCard 指南三处独立印证同一口径：「iOS 18–26 不可用，改为导入配对文件」。

- https://github.com/jkcoxson/idevice/blob/master/idevice/src/remote_pairing/responder.rs
- https://github.com/jkcoxson/idevice_pair
- https://github.com/ChrisMack32/Locus
- https://aircards.org/en/guide/

对 CocoWall 的直接影响：SPEC 的配对设计要按版本分岔——**iOS 27+：机内 PIN 配对（PairableHost 应答方）为主路；iOS 17–26：导入 RPPairing 文件（idevice_pair/iloader/jitterbugpair 生成）为主路**。Sage 的 27.0.1 在 PIN 主路内。Vellum 二进制里的「与 Vellum 配对」文案与此一致（它同样受此版本门限制，导入是它的低版本路径）。设置菜单里显示的名字来自主机广播的 name 字段（idevice 默认 name="idevice-rs"、model="Mac17,7"——系统把主机当作一台 Mac），CocoWall 需把 name 设为自己的产品名。

## H.2 【更正】隧道地址：上游默认是接口 10.7.0.0 / 设备 10.7.0.1，10.7.0.2 无公开出处

StosVPN/LocalDevVPN 的 `PacketTunnelProvider.swift` 全文（约 72 行）给出的默认：接口地址 `10.7.0.0`（/24 子网掩码）、对端假地址 `10.7.0.1`（App 拨这个地址找本机）；只装 10.7.0.0/24 的 includedRoutes 并排除默认路由。包交换逻辑逐行：`dst == 10.7.0.1` 时改写为 `10.7.0.0`；`src == 10.7.0.0` 时改写为 `10.7.0.1`；**不做校验和修正**。两个地址都是可配置项（TunnelDeviceIP/TunnelFakeIP）。

- https://github.com/SideStore/StosVPN/blob/main/TunnelProv/PacketTunnelProvider.swift
- https://deepwiki.com/jkcoxson/LocalDevVPN/9.2-packettunnelprovider

含义：Vellum 的 10.7.0.2（接口）/10.7.0.1（设备）是它自己的配置取值，不是生态默认。CocoWall 骨架现用 10.7.0.2/10.7.0.1 与 Vellum 一致、可用，但实现时应把两个地址做成常量配置而非写死语义——关键不变量是「App 拨的假地址」与「接口自身地址」在交换中互换、且 /32（或 /24）路由只覆盖这对地址。

许可（复用边界，逐个核对后）：StikDebug 与 SideStore 为 **AGPL-3.0**（只能参照、不能抄码）；StosVPN/LocalDevVPN 为类 MIT 自定义许可（强制署名 + 禁止以同名/近似名整包再分发），其 PacketTunnelProvider 是可复用单元但须署名；idevice、idevice_pair、Locus（MIT）为干净参照，其中 **Locus 是最小完整参考应用**（idevice FFI + LocalDevVPN + 文件导入 + iOS 27 机内配对，两条路都有）。
https://github.com/StikDebug/StikDebug
https://github.com/SideStore/StosVPN/blob/main/LICENSE

## H.3 【升级】idevice 的 FFI 细节（仓库实证，替代 §A 的转述）

- FFI 是 **cbindgen 生成的原始 C FFI**（crate 名 `idevice-ffi`，staticlib/cdylib），全仓无 UniFFI。`idevice.h` 由 `ffi/build.rs` 在构建时生成（再拼入 vendored 的 plist.h 并复制到 cpp/include），**不入库**；FFI 版本 0.1.68。
- StikDebug 的实际接法：把构建产物（`libidevice_ffi.a` + `idevice.h` + modulemap）直接 vendored 进 App target，Swift 侧 `import idevice` 调 C API——不是 SPM 依赖。
- IDeviceKit 的接法：SPM **远程** binaryTarget 指向 idevice 官方 Release 的 `IDevice.xcframework.zip`（其 pin 的是 v0.1.57，与 FFI 0.1.68 已有版本漂移，接入时须锁定并记录 checksum 来源）。idevice 仓内的 `swift/Package.swift` 是本地路径版且 xcframework 不入库，必须先在 Mac 上跑 `just xcframework`（iOS 设备构建参数含 `IPHONEOS_DEPLOYMENT_TARGET=17.0` 与 `--features obfuscate`）。
  https://github.com/jkcoxson/idevice/blob/master/ffi/build.rs
  https://github.com/jkcoxson/idevice/blob/master/justfile
  https://github.com/khcrysalis/IDeviceKit

## H.4 【升级】服务清单的仓库实证与两个结论修正

- 服务名（含 RSD 名）逐个在 `idevice/src/services/` 源码中核实，与 §A 的表格一致，补三个：house_arrest 的 RSD 名为 `com.apple.mobile.house_arrest.shim.remote`；diagnostics_relay 的 RSD 名为 `com.apple.mobile.diagnostics_relay.shim.remote`；AFC 另有 `AfcClient::new_afc2`（`com.apple.afc2`，越狱变体，仓库未声称其在正版系统可用）。
  https://github.com/jkcoxson/idevice/blob/master/idevice/src/services/mod.rs
- **修正 §A 的 fileservice 表述**：idevice 代码里**有** CoreDevice file service 客户端（`idevice/src/services/core_device/file_service.rs`，`com.apple.coredevice.fileservice.control`）——README feature 表未列而已。其 Domain 枚举只有 AppDataContainer(1)/AppGroupDataContainer(2)/Temporary(3)/SystemCrashLogs(5)（无 go-ios 的 RootStaging(4)），且命令面只有 CreateSession / RetrieveDirectoryList / RetrieveFile / ProposeEmptyFile（建空文件），**没有上传文件内容的命令**——结论不变：写不了 descriptor 树，排除出实现计划的理由从「未证实」升级为「协议面不支持」。
  https://github.com/jkcoxson/idevice/blob/master/idevice/src/services/core_device/file_service.rs
- **PosterBoard 终局确认**：对 idevice 全仓文本搜索 `posterboard`、`tendies` 均为 **0 命中**；`wallpaper` 只出现在 springboardservices 的**预览图读取**（getWallpaperPreviewImage，无任何 set 方法）。即 idevice 只提供传输层（隧道 + RSD 服务 + mobilebackup2），PosterBoard 写入永远来自传输之上的机制（ATC/还原域/沙盒逃逸），不存在「某个 idevice 服务能直写 PosterBoard」这回事。
  https://github.com/jkcoxson/idevice/blob/master/idevice/src/services/springboardservices.rs

## H.5 【补】两条隧道的区分与 49152 的印证

生态里有两条不同的「隧道」，实现时不要混：①回环 VPN（§B/H.2）只解决「App 在本机拨通自己的 lockdownd（网络端口 62078）」；②CoreDeviceProxy CDTunnel 是经 lockdown 服务协商的 L3 协议隧道（帧魔数 `CDTunnel`，握手返回 serverRSDPort，之后承载原始 IPv6 到 RSD；无线场景外包 TLS-PSK），idevice 用进程内 jktcp 软件栈把它桥成 TCP 流。「回环 → 62078 → CoreDeviceProxy → RSD 握手」这条**机内完整链**在公开资料里是组件级文档拼合的推论、没有单一文档逐字写全（StikDebug 3.1.1 的「Added support for mounting the DDI over RSD」是其在机内走 RSD 的旁证）。

另：有二手来源记录 RemotePairing 的 Bonjour 前门 `_remotepairing._tcp` 在 TCP **49152**——与 Vellum 二进制日志 `attempting RSD tunnel on port 49152` 对上，49152 应是配对/RSD 前门端口而非普通服务端口。
https://deepwiki.com/jkcoxson/idevice/3.3-coredeviceproxy-and-software-tunneling
https://dev.to/kvnpt/how-to-remotely-iterate-deploy-your-sideloaded-ios-apps-over-tailnet-jak （二手，端口一点为其个案观察）

## H.6 【补】版本矩阵的两处精化

- SparseRestore 的 backpath 逃逸在 **iOS 18.1 beta 5** 先被限（域名不得含 `/`、只剩一层回退），**18.2 dev beta 3** 完全封堵——比 §C/§D 的「18.2 起」更精确，BookRestore 的 18.2–26.1 窗口不变。
  https://gist.github.com/leminlimez/c602c067349140fe979410ef69d39c28
- StikDebug 官方兼容表：17.4–18.x「Fully supported」；26.0+「Supported | Limited App Availability」（限制来自 TXM/SPTM 后 JIT 需各 App 适配，与隧道无关）；iOS 27 beta 未见隧道层失效报告（DDI 挂载有个案 issue，未结）。
  https://github.com/StikDebug/StikDebug
  https://github.com/jkcoxson/idevice/issues/130

## G.9 iOS 26 的 provider 分叉（备查）

iPhone 17 Pro 一代的新机型模板壁纸改走 `com.apple.MercuryPoster` provider（configurations/ 下，标识形如 `v5x`、`v6x.colorB`），资产由系统扩展渲染、不在容器里放 .ca 包。CocoWall v1 的目标 provider 仍是 `com.apple.WallpaperKit.CollectionsPoster`（社区 .tendies 的通用面），Mercury 不进 v1。
https://gist.github.com/pdfux/da1ca51123c59239a9712e5af9372191/raw/b1c3924cc89120026f0ed9838b563444614dfe80/Mercury_Collections.md
