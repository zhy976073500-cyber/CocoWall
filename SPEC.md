# CocoWall 规格（v1）

立项：2026-10-28。对标对象 Vellum（com.vellum.studio，Sage 提供 IPA 解包分析），功能等价、代码自有、品牌自有（cc 拟名 CocoWall，bundle id 拟 com.coco.cocowall）。

## v1 范围（Sage 2026-10-28 锁定）

只做交互壁纸一条线：

1. 导入 .tendies 文件（文件 App 选取 / 其他 App 分享打开，支持文稿目录扫描）
2. 写入 PosterBoard 壁纸库（主路径：回环隧道 + 配对 + AirLift 式同步写入，机制见 research/write-path.md；直写路径为 iOS 26 附赠，不进 v1 必交范围）
3. App 内列出本 App 已注入的壁纸，可移除（删系统内描述符 + 刷新 PosterBoard）
4. 设置：配对（机内 PIN 配对 / 导入配对文件）、回环隧道连接状态

明确不做（后续版本）：钱包卡面、密码键盘 .passthm、MobileGestalt 系统调整、在线壁纸库。

## Vellum 解包结论（2026-10-28）

- 原生 SwiftUI，iOS 17.0 起、仅 iPhone、arm64；主体 + PacketTunnel 扩展（回环隧道，接口 10.7.0.2、设备地址 10.7.0.1，包交换回环，不接管默认路由）。
- 底层用 Rust `idevice` 库（remote_pairing / RPPairing / RSD / lockdown / AFC shim 等 crate 痕迹确凿），与 SideStore、StikDebug 同一开源生态。
- 配对：机内 RemotePairing（设置 › 隐私与安全性 › 开发者模式 › 与 Vellum 配对，输 PIN）生成 .mobiledevicepairing；或导入 SideStore/iLoader/AltStore/Jitterbug/电脑导出的配对文件。注意（调研修正，2026-10-28）：机内 PIN 配对是 iOS 27 才有的流程；17–26 只能导入配对文件。且 iOS 26.4 起 lockdown 旧配对失效，配对文件必须是 RPPairing 型。CocoWall 的配对设计按版本分叉。
- 壁纸写入两条路径：①隧道路径（lockdown 服务写入 PosterBoard 容器，新旧两套容器都写 + 刷新缓存）；②本机直写（container query 沙盒扩展，bad_query 路径，自标验证 iOS 26.0–26.6.2、27.0 Beta 在列、27.0 正式版未验证）。
- 支持范围总口径：iOS 17.0 起；直写验证到 26.6.2。

## .tendies 格式（Sage 2026-10-28 提供真样本，已坐实）

.tendies = zip（store），解开就是一棵 PosterBoard 描述符目录树（样本混有 __MACOSX 与 .DS_Store，导入时要过滤）：

```
descriptors/<UUID>/
  com.apple.posterkit.provider.descriptor.identifier   纯文本，如 "9998"
  com.apple.posterkit.role.identifier                   如 "PRPosterRoleLockScreen"
  providerInfo.plist                                    NSKeyedArchiver（配置/最后使用时间）
  versions/1/
    contents/
      com.apple.posterkit.provider.contents.userInfo    plist：wallpaperRepresentingFileName / Identifier、posterEnvironmentOverrides
      <id>.Custom-<logicalScreenClass>.wallpaper/
        Wallpaper.plist                                 name、family、identifier、logicalScreenClass、contentVersion、
                                                        assets.lockAndHome.default.{backgroundAnimationFileName,
                                                        floatingAnimationFileNameKey,type=LayeredAnimation}、
                                                        preferredProminentColor
        <...>.Custom_Background-<class>.ca/             main.caml + index.xml + assets/
        <...>.Custom_Floating-<class>.ca/               main.caml + index.xml (+assets/)
    supplements/0/…
```

样本为苹果自带 "Cubes" 分层动画改打包（identifier 9998，iPad 810w-1080h@2x 规格）。iPhone 规格同理，logicalScreenClass 不同。写入端要做的核心动作：把 descriptors/<UUID> 树落进 PosterBoard 容器对应目录，并让系统收录（GalleryCache/描述符索引），写后回读校验条目数。

## 架构（自有实现）

- SwiftUI 主 App（iOS 17+）：壁纸列表/导入/注入/移除、配对与隧道状态、日志。
- PacketTunnel 扩展：回环包交换（10.7.0.2 ↔ 10.7.0.1），只装 /32 路由，不接管默认流量；App 退后台自动断开为可选策略。
- 设备层：Rust `idevice`（开源）经 FFI 供 Swift 调用，负责 RemotePairing、RSD 隧道、lockdown 会话与文件写入服务。具体写入服务与目标路径见 research/write-path.md（调研中）。
- 打包：GitHub Actions macOS 流水线出未签名 IPA（需 Sage 在网页端建仓 zhy976073500-cyber/CocoWall，cc 无建仓权限）；工程用 XcodeGen 的 project.yml 描述，避免手写 pbxproj。

## 里程碑

- M1 地基：工程骨架 + 隧道可连 + 配对成功（机内 PIN 与导入文件两路）→ 可装机验证的空壳 IPA。
- M2 壁纸写入：导入 .tendies → 隧道路径写入 → 锁屏编辑里能选中 → 回读校验。
- M3 管理面：已注入列表、移除、坏条目清理、日志与诊断摘要。
- M4（可选）iOS 26 直写路径。

## 改动登记 · poster_refresh 免注销刷新（2026-11-01，Sage 拍板）

行为：刷入同步成功后，先经现有 RSD 隧道用 DVT 进程控制只杀 PosterBoard
进程并验活（约 1–2 秒），确认即免注销生效；任一步未确认则原样回退
NeoSpring 注销整机，功能不回退于此前。手动「注销（NeoSpring）」按钮
同路：先试免注销刷新，未确认才真的注销。证据基线为 Walllive 应用日志
（airlift.poster_refresh：advertised → handshake → identity.verified →
signal=9 → old_process.gone → refresh_confirmed，约 1.4s）与其二进制
协议对位（DTServiceHub / processcontrol 通道）。

改动清单（增量最小化；受保护文件既有函数体一律未改）：

- rust-core 新增 `src/poster_refresh.rs`：自建 RSD 连接（镜像
  al_device_respring 的建连形状：上次成功路线优先 + 已知回环网关默认
  候选，RemoteXPC → 原始 RPPairing 回退）→ 查 handshake 广告
  com.apple.instruments.dtservicehub → RemoteServerClient 握手 →
  deviceinfo.runningProcesses 按进程名 PosterBoard 锁定 pid 并以
  execname_for_pid 验明 → ProcessControlClient::kill_app（通道方法
  killPid:）→ is_running_pid 轮询（250ms / 6s）确认旧 pid 消失。
  返回状态：confirmed / connectFailed / serviceUnavailable /
  pidNotFound / killFailed / verifyTimeout；全程以
  airlift.poster_refresh.* 阶段名打日志（经现有日志回调）。
- rust-core `src/lib.rs`：纯增行——`pub mod poster_refresh;` 与新 FFI
  导出 `al_poster_refresh`（catch_unwind 包装，形状同 al_device_respring）。
- rust-core `include/airlift.h`：纯增行——`al_poster_refresh` 声明。
- rust-core `VENDORED.md`：登记上述三处为 vendored 树首次源内改动
  （此前为「NONE in source」）；其余文件仍逐字上游。
- rust-core 树哈希（find rust-core -type f 排除 target/，排序后逐文件
  sha256 再聚合）：改前 d606d8c28cbc75d313c7639961d91767136c157198bc9ca87f6088e31fa64bd6
  → 改后 1f88be4ca9288965518b5c2428d0bb04d15ff4ceed4d8233a9f137ebda402cb7。
- Swift 新增 `Sources/App/PosterRefreshHelper.swift`：后台线程调
  al_poster_refresh、桥接日志回调、主队列回 (confirmed, status)。
- Swift `Sources/App/AppViewModel.swift`：仅 flashSelectedTendies 成功
  分支一处——「🎉 壁纸应用成功！」后改走「正在刷新系统壁纸…」→
  PosterRefreshHelper；confirmed 记「✅ 系统壁纸已刷新，免注销生效。」，
  未确认才记回退文案并触发原 NeoSpring 路径（isNeoSpringing 语义不变）。
- Swift `Sources/App/TendiesView.swift`：注销按钮动作改为先刷新后回退；
  页脚说明文案一行同步更新。

未动：TendiesEngine.swift、PairingController.swift、RespringHelper.swift、
GrappaHelper、Live Activity、.github/workflows、配对/导入/壁纸库/制作页/
设置页。

## 改动登记 · 摘除刷入后自动注销（2026-11-01，Sage 实测 #94 后拍板）

背景：#94 真机首验，刷入后 poster_refresh 未确认、按当时逻辑自动回退
NeoSpring 注销整机。Sage 明确要求：刷入完成后不要再自动注销，先出本版。

行为变更（仅此一处）：flashSelectedTendies 成功分支——poster refresh
照常尝试；confirmed → 原成功文案不变；未确认 → 只在刷入日志里如实记
「⚠️ 壁纸已写入，自动刷新未确认（本版不自动注销；如未生效可手动点注销）。」
后流程正常结束，不再置 isNeoSpringing、不再调用
RespringHelper.triggerNeoSpring。

注销调用点盘点与处置：

- AppViewModel.flashSelectedTendies 成功分支的未确认回退（自动触发）
  ——本版摘除（即上条）。
- TendiesView「注销（NeoSpring）」按钮（用户手动入口；含 #94 的
  「先试 poster refresh、未确认才注销」逻辑）——保留原样，未动。
- AppViewModel.respringDevice()——全仓无调用方（闲置函数），未动。
- TendiesView onAppear 的 isNeoSpringing 复位与 overlay 呈现——保留，
  仍服务于手动注销路径。

改动清单：

- Sources/App/AppViewModel.swift：仅上述成功分支一处（注释 + else 分支）。
- Sources/App/TendiesView.swift：仅页脚说明一行，改为与新行为一致
  （刷入后先试免注销刷新；本版不会自动注销，如未生效可手动点注销）。

未动：rust-core/src/poster_refresh.rs、FFI、PosterRefreshHelper.swift、
RespringHelper.swift、TendiesEngine.swift、PairingController.swift、
GrappaHelper、Live Activity、.github/workflows、配对/导入/壁纸库/
制作页/设置页。

## 改动登记 · poster_refresh 验活修复（2026-11-01，#95 真机日志定点修）

背景：#95 真机刷入日志显示杀链全通（advertised → handshake →
identity.verified pid=15736 → signal.begin signal=9 →
signal.acknowledged），唯独验活收尾报错：杀后复用同一条 RemoteServer
连接开 deviceinfo 验活通道时 BrokenPipe（"remote server connection
closed"），误报 verifyTimeout。Walllive 二进制里早有
`poster_refresh.verification.connection=new readonly=true` 路径——它杀后
本就换新连接只读验活。

改动（仅 rust-core/src/poster_refresh.rs 的验活段与状态码）：

- signal.acknowledged 后主动 drop 掉原 RemoteServer 连接与隧道，
  打日志 `airlift.poster_refresh.verification.connection=new
  readonly=true`（与 Walllive 对齐），按既有建连路径（connect_rsd：
  上次成功路线优先 + 网关默认候选）新建一条连接做验活。
- 验活轮询在新连接的 deviceinfo 通道上每 250ms 查 is_running_pid
  （失败回退 running_processes，与原实现一致），总时限约 6s；旧 pid
  不在即 confirmed。中途连接再断，允许在总时限内重连一次继续查。
- 状态码拆分：新增 verifyConnectFailed（验活连接建不起来、或重连后
  仍断且从未成功读到进程状态）；verifyTimeout 收窄为「状态可读但
  6s 内旧 pid 始终在」（含读到过状态后连接丢失、始终未见旧 pid
  消失）。out_status / out_error 与 poster_refresh.end 日志行同步。

未动：建连/服务发现/握手/锁 pid/验明/kill 的既有实现与阶段日志名、
Swift 侧（含 #95 不自动注销行为）、受保护文件、.github/workflows。

## 改动登记 · 壁纸库页签摘除 + 获取更多壁纸入口 + 设备壁纸检测/清理（2026-11-01，Sage 03:13 拍板）

三项产品改动：

1. **删除「壁纸库」页签**：底栏 5 页签变 4（壁纸｜制作｜密码盘｜设置）。
   ContentView 摘除 LibraryView 挂载，Models 的 AppTab 删 library
   case。壁纸库专属代码无其他引用，一并移除：LibraryView.swift、
   LibraryCatalog.swift、三张封面图 b64（library-hero/star/stitch）
   与对应 imageset、project.yml 里解码这三张图的 preBuildScript。
   **壁纸页（TendiesView）自带的「已导入壁纸」列表未动**（那是本地
   导入库，不是被删的页签）。

2. **壁纸页顶部「获取更多壁纸」**：TendiesView 在刷入区上方新增
   Section 0 入口行（图标 + 标题 + 说明 + chevron，与页面既有
   Form 语言一致），点击用 `UIApplication.shared.open` 系统浏览器
   打开飞书 wiki（Oi6pwrRp9i8wd2kBl0Lc4bn9nTb），不用 App 内 WebView。

3. **「检测本机已导入的壁纸」+ 可选清理**：壁纸页已导入列表区下方
   新增入口按钮，点击弹 DevicePosterCleanupView：列出**设备**
   PosterBoard 数据仓里实际存在的 descriptor（不是 App 本地库），
   每项显示可读名 + 扩展目录 + UUID 短码，可勾选；「清理所选」先弹
   确认，确认后删设备数据仓中的所选 descriptor，刷新列表并反馈
   成功/失败数，之后自动走一次 poster_refresh 免注销刷新使删除
   生效（未确认只提示，不自动注销，与 #95 规则一致）。

检测/清理通道（侦察结论 + Walllive 删除日志实证，见下节修订）：
数据仓本体是 PosterBoard 容器内的普通目录树
（PRBPosterExtensionDataStore/<版本 61>/Extensions/<扩展>/descriptors/
<UUID>）。AFC（com.apple.afc）被关在 /var/mobile/Media 内，但会跟随
狱内符号链接——刷入暂存正是这么进数据仓的。据此新增 Rust 模块
`rust-core/src/poster_store.rs`（增量新增，按 poster_refresh 先例
登记于 VENDORED.md）：RSD 隧道 → AFC 服务 → 用 AFC MakeLink 在
Media 根临时植入指向数据仓 Extensions 目录的符号链接
`cocowall-store-<token>`，经链接 list_dir 枚举 Extensions 下全部
扩展目录（任务所指两个目标扩展含在其中）与其 descriptor，读
identifier 文本文件与
versions/<v>/contents/<名>.wallpaper 解析可读名（优先级：包名 >
identifier > UUID 短码）；临时链接用完即删。**删除不走 AFC 直删**
（机制见下节：ATC 同步搬移）。新 FFI：`al_poster_store_list` /
`al_poster_store_delete`（lib.rs + airlift.h 纯新增），Swift 侧新增
PosterStoreHelper.swift，AppViewModel 只增新状态与两方法
（detectDevicePosters / cleanupSelectedDevicePosters +
posterStoreContext 前置）。

诚实边界：AFC MakeLink 植入链接 + 经链接遍历数据仓，未经真机
验证（桌面仅 cargo check 主机目标通过）；若真机上 afcd 拒绝建链或
遍历，检测会如实报 stageFailed/listFailed 并显示原因，不会拿本地
库条目冒充。providerInfo.plist（NSKeyedArchiver）未解析，可读名
来源为包名/identifier/UUID 短码。连接走 RSD 路线（与
poster_refresh 同），Lockdown 路线设备暂不支持本功能。

未动：TendiesEngine / PairingController / RespringHelper /
GrappaHelper / Live Activity 既有函数体、#93 制作页、
#94–96 poster_refresh 与不自动注销行为、.github/workflows。

## 改动登记 · 删除机制改走 ATC 搬移 + poster_refresh already_stopped（2026-11-01，Walllive 完整删除日志实证后修订）

证据：Sage 提供的 Walllive 完整删除日志
（WallpaperImport-29E5799D-….txt，删除段 2026-10-31T19:30–19:31Z）。
其删除不是 AFC 直删，而是与注入同路的 ATC 同步搬移，逐条对应：

- 审计枚举可行：`delete.audit.listing stage=extensions count=22 →
  stage=provider count=5 → stage=descriptors count=13`，逐级列数据仓，
  `delete.audit.result status=present/absent level=descriptor`。
  本实现检测/审计同口径（AFC 经临时链接逐级 list，日志同名）。
- 删除 = 同步搬出：每 descriptor 一个 operation——暂存 zip（链接指向
  其 descriptors 目录）+ Books.plist 恰 2 条 book（链接 + descriptor，
  后者以相对 Airlock 的逃逸路径标识，与 vendored canary 的 target
  book 同形）；`delete.manifest book_entries=2`，设备 manifest 两条
  均 `download=true ready=true`；随后分两 phase 发 FileComplete：
  phase=link（`delete.link.confirmed destination_verified=true`）、
  phase=descriptor（`delete.quarantine.confirmed=true`），设备侧
  ATAirlock 把 descriptor 下载/移出数据仓落到 Media 隔离区；
  `delete.descriptor.confirmed`、`delete.stage.retained
  no_read=true no_remove=true`（隔离副本保留不删）、Books.plist
  恢复（`afc.books.restore.end verified=true`）。
- 验收 = 新连接复审：全部 operation 后 `delete.commit.connection=
  fresh after_restore=true`，逐个路径复审 absent，
  `delete.commit.audit paths=3`（该批 3 个落点）、descriptors 计数
  13→10，全 absent 才 `delete.receipts.committed
  restoration_verified=true`。

本实现（poster_store.rs 的 store_delete）：预审（present 才动手）
→ 每目标一个 ATC operation（会话逐段镜像 exploit::run 的已验证线
协议：zip 暂存 → Books.plist → ATC 握手/Grappa → ReadyForSync →
FinishedSyncingMetadata → AssetManifest 校验 download 标记 →
phase=link FileComplete 并验 Media 链接落点 → phase=descriptor
FileComplete → quarantine 落点确认）→ 还原 Books.plist、清暂存与
链接、保留 `airlift-quarantine-<token>` 隔离副本（Media 根，用户
数据的唯一剩余副本，故不删）→ **新连接 commit 审计**：每个所选
落点逐个复审 absent 才计成功，计数与逐项结果回 JSON
（deleted/failed/commitAudit/results[].quarantine）。一只壁纸在
双写扩展下有两个落点（WallpaperKit.CollectionsPoster 与
Posters.CollectionsPosterApp），列表里逐项呈现、逐项勾选删除、
逐项审计，不合并报成功。

poster_refresh 补 already_stopped 分支（同一日志末尾实证：
`poster_refresh.already_stopped confirmed=true` → `refresh_
confirmed=true`）：identity 阶段进程列表读取成功但无 PosterBoard
条目 → 打 already_stopped 日志并按 confirmed 返回（守护进程没在跑，
下次启动自然读新数据仓），不再报 pidNotFound；列表读取本身失败
仍按原错误（pidNotFound）处理。#95 不自动注销、#96 杀后新连接
验活均未动。

未验证项（诚实标注）：删除 ATC 会话为桌面镜像复刻 vendored
exploit::run 线协议（cargo check 主机目标通过），未真机验证；
manifest 中 Download 标记的字段路径若与真机结构不符，代码只在
明确读到 download=false 时拒绝 FileComplete，其余情况以
quarantine 落点 + commit 审计 absent 为最终判据，不会假报成功。

## 改动登记 · poster_refresh 杀进程改走 sendSignal:toPid:（2026-11-01，#106 真机日志定点修）

背景：#106 真机刷入日志的刷新段全程绿到 signal.acknowledged，
且 #96 的新连接验活正常工作、状态诚实——结论是
`refresh_confirmed=false status=verifyTimeout error=pid 16414
still running 6s after kill signal (state readable on fresh verify
connection)`：信号发出后 6 秒进程仍然活着。我们 vendored 的
`kill_app` 走 ProcessControl 的 `killPid:`，服务端回了确认但
PosterBoard 没死。#94 侦察时记录过差异（Walllive 用
`sendSignal:toPid:` 带参数 9），当时假设「服务端效果等价」——
现已被真机证伪：`killPid:` 疑仅对 instruments 自行拉起的进程
有效，对系统守护进程不生效。本轮复核 Walllive 1.1.1 二进制
字符串：`sendSignal:toPid:` 恰与
`com.apple.instruments.server.services.processcontrol`、
`execnameForPid:`、`processIdentifierForBundleIdentifier:` 同串
簇出现，`killPid:` 在另一处孤立出现——Walllive 的 poster_refresh
走 sendSignal 一路无误。

改动：

- `rust-core/vendor/idevice/src/services/dvt/process_control.rs`
  （vendored 上游文件，首次动它，增量登记见 VENDORED.md 第三节）：
  在 `kill_app` 后新增 `ProcessControlClient::send_signal(pid,
  signal)`，经既有 Channel 发 selector `sendSignal:toPid:`，
  aux 参数顺序为信号在前、pid 在后（与 selector 名对齐），编码
  形态与相邻的 `kill_app` 一致（AuxValue::U32、expect_reply=false）。
  既有 `kill_app` 一字未改。选落点于此的原因：ProcessControlClient
  的 Channel 是 idevice crate 私有，poster_refresh.rs 在 crate 外
  拿不到任意 selector 的发送口，vendored client 是唯一干净落点。
- `rust-core/src/poster_refresh.rs`：signal 阶段改调
  `pc.send_signal(pid, 9)`；调用本身失败 → 状态 killFailed 并带
  原始错误，不吞。头部文档同步更正（原写 killPid: 的两处）。

未动：identity 验明、already_stopped 分支、#96 新连接验活 +
重连一次、状态码诚实化、#95 不自动注销、signal.begin /
signal.acknowledged 日志阶段名、Swift 侧、受保护文件、
.github/workflows。

未验证项（诚实标注）：sendSignal:toPid: 在 Sage 真机上的实际
效果待首验——预期日志 signal.acknowledged 后新连接验活读到
old_process.gone、refresh_confirmed=true、不注销、锁屏 1–2 秒
内换壁纸；cargo check 主机目标通过仅证编译。

同版附带修复（Sage 03:56 补发检测日志后并入本版）：
poster_store.list 真机失败——`airlift.poster_store.service
advertised=false service=com.apple.afc` →
`serviceUnavailable: com.apple.afc not advertised by RSD
handshake`。病根：open_store_session 建 AFC 前的 advertised
检查用了 lockdown 服务名 `com.apple.afc`，而 RSD 握手里 AFC 的
广告名是 `com.apple.afc.shim.remote`（刷入日志每个会话的
'found RSD shim service com.apple.afc.shim.remote' 为证；
vendored AfcClient 的 RSD 实现用的亦是 shim 名）。exploit.rs 在
RSD 路线上打开 AFC 是直接 `handshake.connect::<AfcClient>()`、
从不查 lockdown 名，所以刷入一直通、只有检测被自己的预检误杀。
改法：`rust-core/src/poster_store.rs` 的 AFC_SERVICE 常量改
`com.apple.afc.shim.remote`（含注释说明），log 的 service= 字段
如实打 shim 名；客户端构造本就与 exploit 同款
（handshake.connect::<AfcClient>），未动；状态码与日志形状
不变，枚举/解析/删除逻辑未动。（未开回环工具时那段
connectFailed 属环境问题，不处理。）

## 改动登记 · poster_refresh 信号改带回执 + poster_store 植链改走 conduit 暂存（2026-11-01，#107 真机日志双定点修）

背景一（信号）：#107 真机日志刷新段 identity.verified pid=16812
→ signal.begin → signal.acknowledged →
verification.connection=new →
`verifyTimeout error=pid 16812 still running 6s after kill
signal`。换 sendSignal:toPid: 后 PosterBoard 仍未死。关键疑点
坐实：#107 的 send_signal 是 expect_reply=false 的单向发送，
所谓 acknowledged 只是本地发送完成，服务端从未确认过任何事，
参数编码错了也会静默无声。

上游对照结论：克隆 jkcoxson/idevice master @ 8970209 逐行读
`idevice/src/services/dvt/process_control.rs`——**上游根本没有
sendSignal 对应方法**，全文件只有 `killPid:`（第 289 行）；
vendored 文件除本地 send_signal 增量外与上游 master 逐字
一致。故无「上游实现」可移植，改走诊断路线，并以另一份维护中
的 DTX 实现 pymobiledevice3 为旁证定形态：其
ProcessControlService 把 `sendSignal:toPid:` 声明为**不带
expects_reply=False**（它的 `killPid:` 才显式声明单向），参数
顺序 (sig, pid)；其 `kill()` 文档原文写明改用 sendSignal 的
理由正是「round-trip 保证设备已执行请求，裸 killPid: 在通道
随即关闭时会被静默丢弃、目标进程存活（在默认 userspace 隧道
上观察到）」——与 #106/#107 两次真机现象逐字吻合。

改动一：

- `rust-core/vendor/idevice/src/services/dvt/process_control.rs`
  的本地增量 `send_signal` 改为请求-应答形态：
  `call_method_with_reply` 发同一 selector、同一 aux 编码
  （[U32 signal, U32 pid] 不变），返回回执 payload
  `Result<Option<Value>, IdeviceError>`。VENDORED.md 第三节已
  同步修订登记（首次登记写的是与上游对齐——上游无此方法，
  在此更正为「本地增量、形态对齐 pymobiledevice3」）。
- `rust-core/src/poster_refresh.rs` 信号段：10 秒超时内等
  回执，原文打日志 `airlift.poster_refresh.signal.reply
  data=…`（无 payload 打 none），然后才打
  signal.acknowledged；通道级错误仍报 killFailed 带原始错误；
  10 秒无回执只打 `signal.reply timeout=true` 一行并继续走新
  连接验活裁决，不冒判 killFailed（信号可能已落地，验活是
  地面真相）。下一份真机日志由此能一锤定音：服务端到底回了
  什么（空回执 / 数值 / NSError 字典）。

背景二（检测植链）：#107 检测日志
`poster_store.service advertised=true
service=com.apple.afc.shim.remote` → `afc connected=true` →
`list.end status=stageFailed error=AFC MakeLink (symlink ->
…/PRBPosterExtensionDataStore/61/Extensions) failed:
Afc(OpNotSupported)`。RSD 的 AFC 服务拒绝 MakeLink 操作码。

植链侦察结论：通读 exploit.rs 暂存段（STEP 1）——注入流程
**从不用 AFC MakeLink**：它把 symlink 做成 StreamingZip
压缩包里的一个 symlink 条目（`p0/p1/p2/link` →
`../../../<target_tail>`，mode 0o120777），经
`com.apple.streaming_zip_conduit` 服务（先发
`{MediaSubdir: <source>}` 二进制 plist、再发原始 zip 字节）
解压进 Media，链接作为真实 symlink 独立存在于暂存目录中
（解压后 AFC get_file_info 逐项验在），ATC 同步只是后续消费
者、不是植链者——故该机制可独立复用，无需整次同步。又：
`../../../` 的相对目标是按链接**最终位于 Media 根**校准的
（同步把链接落到 Media 根的 airlift-link-<token>，刷入的
payload 正是穿过这个根级链接写进容器的）；链接若留在暂存
目录深处，该相对目标并不解析。故 poster_store 的植链分三步
与刷入完全同构：conduit 解压 → AFC rename 把链接挪到 Media
根 → 穿过它枚举。

改动二（全部在 `rust-core/src/poster_store.rs`）：

- `open_store_session` 删去 `afc.link(...MakeLink...)` 一段，
  改为：以 Extensions 绝对路径为目标调既有
  `build_delete_archive` 建同形暂存包（删除暂存已在用、形状
  与 exploit::build_archive 一致；包内 payload 在检测流程中
  无人引用，属惰性内容）→ 经本文件既有 `connect_service_rsd`
  连 conduit、MediaSubdir=`cocowall-src-<token>` 上传并读
  回执 → AFC get_file_info 验暂存目录与
  `<source>/p0/p1/p2/link` 均在 → `afc.rename` 把链接挪到
  Media 根改名 `cocowall-store-<token>` → 原有的
  list_dir 穿通校验（link.traversable）不变。
- `StoreSession` 增加 `source_name` 字段，`close()` 在删根级
  链接之外再 `remove_all` 暂存目录；穿通校验失败路径同样
  清理两者。import 删去不再使用的 `LinkType`。
- 列表/删除审计/提交审计三处都经 open_store_session，本改动
  一并修复；delete_operation 自身的 ATC 搬移链未动。

未动：注入全链、验活新连接 + 重连一次、already_stopped、
状态码诚实化、不自动注销、删页签、获取更多入口、Swift 侧、
受保护文件、.github/workflows。

未验证项（诚实标注）：两处均为真机首验——(1) 信号回执的
实际内容与 PosterBoard 是否随之死去，看 signal.reply 一行与
验活结果；若回执是参数类 NSError，下一轮变量是 aux 整数
类型标记（现 U32=0x03）。(2) conduit 解压 + AFC rename 挪
symlink 在 RSD AFC 上的实际行为（rename 为标准 AFC 操作码、
预期保留链接本体）；若 rename 被拒，日志会带原始错误，
次优路线是按链接落点深度重算相对目标的根级条目包。
cargo check 主机目标通过仅证编译。

## 改动登记 · 信号回执分类处理 + 检测链接留暂存深度双变体（2026-11-01，#108 真机日志双定点修）

背景一（信号）：#108 写入日志刷新段 `identity.verified
pid=18279 → signal.begin →
poster_refresh.end status=killFailed error=sendSignal 9 to
pid 18279 failed: UnexpectedResponse("unexpected
response")`。带回执改造生效的证据：服务端**回了东西**——
消息已被处理，不再是单向静默丢弃。但 idevice 的 DTX 回执
解析把该回执归类为 UnexpectedResponse，#108 代码据此直接
判 killFailed 并**跳过了验活**，地面真相从未查。若该回执
只是 void 形确认，信号很可能已经生效。

改动一（`rust-core/src/poster_refresh.rs` 信号段一处语义；
vendored `send_signal` 本体不动，其错误变体
`IdeviceError::UnexpectedResponse` 本就在类型里）：带回执
调用的结果分三类——(a) 正常回执 payload：照旧打
`signal.reply data=…` 并继续；(b) **UnexpectedResponse 类**
（回执到达但形状不合解析预期）：打
`signal.reply unexpected_response=true (dispatch confirmed
by response; deferring to verification)`，按已送达处理、
照常进入新连接验活裁决，不判 killFailed；(c) 通道/连接级
硬错误（消息根本没发出去）：维持 killFailed 带原文。验活
段一字未动，最终结论只由验活给：pid 消失 = confirmed；
6s 仍在 = verifyTimeout。aux 整数类型（现 U32）不在本版
动——那是验活判 verifyTimeout 之后才轮到的下一变量。

背景二（检测植链）：#108 清理日志
`poster_store.stage uploaded=true source=cocowall-src-…`
（conduit 植链成功）→ `list.end status=stageFailed
error=AFC rename of staged symlink to Media root failed:
Afc(InvalidArg)`。注入流程从不 AFC rename 链接——根级
airlift-link 是 ATC 同步落位的，rename 硬挪是多余变量；
且 #108 登记里预告的次优路线正是本版采用的路线。

改动二（全部在 `rust-core/src/poster_store.rs`）：

- `build_delete_archive` 参数化：新增 `link_target: &str`
  入参，包内 symlink 目标由调用方给。删除流程
  （delete_operation）传根级几何 `../../../<tail>`，与
  改前逐字一致、行为不变；注入侧 exploit::build_archive
  未动。
- `open_store_session` 删去 rename 一步，链接留在暂存目录
  `<source>/p0/p1/p2/link` 处使用，试两个目标变体：
  (1) `relative-depth`：链接目录位于
  Media/<source>/p0/p1/p2，自该处 6 级 ../ 到 /var，再接
  目标 tail（去掉 /var/ 前缀）；穿通成功打
  `link.traversable=true variant=relative-depth`。(2) 若
  相对穿通失败（原始错误入日志），同会话内自动重建暂存
  包重试 `absolute` 变体：链接目标写 Extensions 绝对路径，
  成功打 `variant=absolute`。两变体都败才报 stageFailed，
  错误文本附两段原始错误。
- conduit 上传段抽成 `upload_stage_archive` helper，单次
  植链抽成 `plant_store_link` helper（建包 → 上传 → 验在
  → list_dir 穿通校验；失败自清暂存目录）。`close()` 相应
  简化：无根级链接可删，只 `remove_all` 暂存目录（链接在
  其内），`link.removed` 日志形状不变。
- 枚举/删除审计/提交审计仍全部经 open_store_session，
  一并受益；delete_operation 的 ATC 搬移链未动。

未动：注入全链、验活段（新连接轮询 + 重连一次 + 状态码
诚实化）、already_stopped、不自动注销、删页签、获取更多
入口、Swift 侧、受保护文件、.github/workflows。

未验证项（诚实标注）：(1) UnexpectedResponse 回执下信号
是否真已生效——看本版验活裁决：old_process.gone /
refresh_confirmed=true 即闭环；若仍 verifyTimeout，下一
变量为 aux 整数类型。(2) 深度相对链接在 RSD AFC 上的
实际穿通行为，以及相对失败时绝对变体的表现——看
variant= 日志行落在哪一支。cargo check 主机目标通过仅
证编译。
