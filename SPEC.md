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

## 改动登记 · 检测暂存校验诊断版（run #110，2026-11-01）

背景：#109 真机检测两变体（relative-depth / absolute）均死于
同一句 stage verification「extracted symlink not present in
Media」；而 #108 同设备同路径暂存校验是通过的（死在下一步
rename）。属 #109 引入的回退。

代码对照取证（ac16bfc → b9c7676 逐行 diff）：暂存段唯一功能
差异是 zip 内 symlink 的目标字符串——#108 为
`../../../<tail>`，在暂存深度恰好解析回暂存目录内
build_delete_archive 镜像出的同名目录树（故 lstat 型校验通
过）；#109 两变体目标都解析到暂存目录之外。vendored AFC
`get_file_info` 是 lstat 语义（回 st_ifmt/st_link_target、不
跟随链接），目标字符串本身不影响校验结果——除非 conduit
在提取时就把「目标逃出提取根」的 symlink 条目丢弃。该机制
代码对照无法确证，故本版不盲改，只加诊断：

- `plant_store_link` 校验失败分支（poster_store.rs 一处）：
  清理暂存前，逐级 list 暂存 source、p0、p1、p0/p1/p2 四级
  目录并打 `stage.diag list` 日志；再对链接本体打
  `stage.diag link_info`（ifmt/link_target 或原始错误）、对
  payload 普通文件打 `stage.diag payload_info` 作对照。
  下一份真机日志即可判明：链接是没被提取（p2 列表无 link）、
  还是提取了但条目形态异常。
- 行为不变：成功路径、双变体顺序、错误文本、清理动作、
  注入与删除 ATC 链均未动。

未动：poster_refresh 信号段、注入全链、Swift 侧、受保护
文件、.github/workflows。

未验证项：诊断结论待 Sage 真机跑 #110 检测后看 stage.diag
日志行定案；确证机制后再出修复版。

## 改动登记 · 信号 aux 归档编码 + already_stopped 复读 + 检测暂存对齐 exploit（run #111，2026-11-01）

真机新事实（Sage 2026-11-01 14:44–14:48，#110）：

(1) 检测 stage.diag 定案方向：两变体多轮重复，暂存目录
每一级 list 均为 Afc(ObjectNotFound)——整个 cocowall-src
目录在 AFC 视角不存在，不是 symlink 单条被丢；同机注入
侧暂存校验（exploit 路径）每次必过。

(2) 刷 Zenitsu-DS 的 poster_refresh：identity 验证过
pid=20512，signal.begin 后当场 BrokenPipe（服务端掐断
连接）→ killFailed。结合 #108 同调用回 UnexpectedResponse，
信号消息形态被服务端拒已两度坐实；identity 与信号的差异
只在 aux 数值编码。

(3) #110 刷入的壁纸在 Sage 手动注销后出现——注入数据
完好、系统可读，唯一缺步是 PosterBoard 实时重读。信号
修复由此成为唯一主线，aux 整数类型为既定裁决变量。

### 改动一（主线）：send_signal 的 aux 改为归档 NSNumber

先查 pymobiledevice3 源码定型（doronz88/pymobiledevice3
master @ 5234545，2026-11-01 联网回读）：

- `pymobiledevice3/services/dvt/instruments/process_control.py`
  第 53–54 行：`@dtx_method("sendSignal:toPid:")` 的
  `send_signal_to_pid_(self, sig: int, pid: int)` 参数为裸
  `int`；同文件第 57 行的
  `request_disable_memory_limits_for_pid_(self, pid: PInt32)`
  则显式用 PInt32（原始 32 位 primitive，wire type 3）——
  两者区别是作者有意为之。
- `pymobiledevice3/dtx/message_aux.py` 的
  `MessageAux.build`：非 primitive 参数一律译为
  NSKeyedArchiver 编码的 blob（`PBuf(archiver.archive(arg))`）。
  故 sendSignal 的 sig/pid 在 pymobiledevice3 中的确切
  形态 = 各自一个归档 NSNumber，装在 type-0x02 buffer
  aux 条目里；不存在「裸 int 即 U64 primitive」的写法
  （裸 int 不走 primitive 通道）。primitive 常量对照在
  `pymobiledevice3/dtx/primitives.py`：Int32 = type 3
  （i32）、Int64 = type 6（i64）。

据此改 vendored `process_control.rs` 的 `send_signal`
一处：aux 由 `[U32 signal, U32 pid]` 改为
`[archived_value(Integer signal), archived_value(Integer pid)]`
（`AuxValue::archived_value`，仓内先例
`energy_monitor::archive_pids`）。selector、参数序
(signal, pid)、带回执调用（call_method_with_reply）、
poster_refresh 的回执三分类与验活段全部不动。方法注释
已补记出处与两度被拒的真机证据。

### 改动二（连带核查）：already_stopped 判定加一次复读

起因：#109 poster_refresh 遇 already_stopped 返回
confirmed，事后壁纸并未在选择器出现（直到手动注销才
有，见事实 (3)）。代码核查结论：already_stopped 的判定
依据是 identity 阶段唯一一次 running_processes 快照——
若 PosterBoard 恰在该瞬间处于被系统拉起/终止的中间态
（如被刚跑完的同步牵连重启），单次快照会把「正在重启」
误读为「已停止」，其后它带着旧缓存回来，confirmed 即
落空。改法（只动 poster_refresh.rs identity 阶段）：
首次名单无 PosterBoard 时，打
`already_stopped.recheck attempt=1`，隔 500ms 复读一次
名单；复读找到 pid 则走正常信号路径；复读失败保留首读
结论并打日志；两次都无才按 already_stopped confirmed
返回。验活主体逻辑（杀后新连接轮询等）未动。

### 改动三（次线）：poster_store 暂存与 exploit 逐项对齐

逐行对照结论（poster_store vs exploit.rs，两版远端原文
ac16bfc/b9c7676 与本地 exploit）：conduit 回执读法
（4 字节头 + body 全读后才 drop）、MediaSubdir 键值
格式、会话关闭时机、connect_service_rsd 实现、AFC 校验
客户端（RSD handshake AfcClient）——全部与 exploit 已
验证路径一致，逐一证伪；#108→#109 抽 helper 无参数
丢失。唯一功能差异只剩暂存包内 symlink 的目标字符串：
exploit 与 #108 恒为 `../../../<tail>`（在暂存目录内
自洽解析），#109 两变体都逃出提取根。结合事实 (1)
（整目录各级 ObjectNotFound、payload 普通文件亦不在），
机制定案为：conduit 提取对「symlink 目标逃出提取根」
的归档整体不落盘（拒绝或回滚），非单条丢弃。

改法（只动 poster_store.rs）：

- 暂存校验对齐 exploit 三件验：scratch 目录 + link +
  payload 三者 AFC 回读通过才算落地（原为两件）。
- 变体顺序改为 exploit 几何优先：(1) `exploit-geometry`
  = `../../../<tail>`（唯一已证能提取落地的目标形）；
  (2) `relative-depth`、(3) `absolute` 两变体保留为后备，
  顺序与目标字符串不变。
- 穿通验收加非空判定：列得出 Extensions 且条目非空才
  记 `link.traversable=true variant=… extensions=N`。
  exploit 几何在暂存深度解析进包内镜像目录树，其
  Extensions 层为空——空列表是镜像、不是数据仓，不得
  据此枚举（真实数据仓恒有系统扩展，Walllive 审计计数
  22）。空穿通记 traversable=false 并继续下一变体、
  清理该暂存目录。
- stage.diag 日志保留（已证明有用）；模块头文档同步
  更正机制定案。

### 未动清单

exploit.rs（只读对照）、注入全链、delete_operation 的
ATC 搬移链与删除审计、poster_refresh 的信号三分类与
验活主体、#95 不自动注销、Swift 侧、lib.rs、airlift.h、
受保护文件、.github/workflows。

### 未验证项（诚实标注）

(1) 归档 NSNumber 形态的 sendSignal 是否被服务端接受
并真正杀掉 PosterBoard——看真机 `signal.reply` 行 +
`old_process.gone` / `refresh_confirmed=true`，且壁纸
不经手动注销即出现在选择器。这是本版裁决项。
(2) already_stopped 复读是否捕获到 #109 式的中间态——
看真机日志有无 recheck 后转入 signal.begin 的实例。
(3) 检测：exploit-geometry 变体应首次出现暂存落地
（stage.diag 不再整树 ObjectNotFound / link.staged），
但其穿通按设计会被判镜像空列表而拒绝——即本版检测
预期仍报 stageFailed，但失败点从「整目录不可见」推进
到「穿通几何」：真正的仓内穿通需把链接落到 Media 根
（ATC 同步落位，delete 链已有同款机制），属下一版
议题，本版不夹带。cargo check 主机目标通过仅证编译
（airlift_ffi 既有 3 条 dead_code 警告不变）。

## 改动登记 · 克隆 Walllive 安装事务序列（run #112，2026-11-01）

真机裁决现状（Sage 2026-11-01，#111）：信号已通——归档
NSNumber aux 的 sendSignal 拿到干净回执（signal.reply
data=none）→ old_process.gone → refresh_confirmed=true、
1081ms、免注销。但 Sage 目视壁纸仍未进系统选择器；手动
注销（整栈重启）后则能出现（Zenitsu 实证）。即：descriptor
落盘可读、杀进程可达，差的是 PosterBoard 被杀重生后不列
新 descriptor。本版不再动协议参数，转而克隆 Walllive 成功
安装（2026-11-01 00:46，descriptor ECC3168C，其日志
WallpaperImport-D01634B1….txt）与我方 #111 刷入之间的
**事务形态**差异——五项逐项状态如下。

### 五项差异逐项克隆状态

1. **单事务只装主落点 —— 已克隆。** 他单事务只装
   com.apple.WallpaperKit.CollectionsPoster（comparison
   mode=primary_only、mirror_deferred=1、install.result
   paths=1）；我方原为双落点背靠背各走完整周期。现
   TendiesEngine.flashTendies 只走主落点事务，镜像落点
   （com.apple.Posters.CollectionsPosterApp /
   MercuryPosterApp）跳过并打日志
   `comparison mode=primary_only mirror_deferred=1 target=…`。
   镜像后续如何补装由主线另行决定，本版不实现。
2. **偏好合并写 —— 已克隆。** 他 preferences.combined
   targets=2、staging_sessions=1、sync_sessions=1，一次
   同步 4 个资产（FileComplete 1/4..4/4、asset.confirmed
   index 0..3），同事务内、Books 还原之前；其归档内第二
   条链接名为同目录下的 link_1（WallLive 二进制字符串
   实证：.../link、.../payload_0、.../link_1、
   .../payload_1）。现新增 build_archive_two_links 按此
   形状建包（同 p0/p1/p2 目录内 link + link_1、payload_0/
   payload_1 同内容），事务第二阶段一次暂存、一次同步
   写完两个偏好目标（容器 Preferences +
   /var/mobile/Library/Preferences）。我方原为注入后另起
   两次独立 batch 写（各一次快照/还原）。
3. **单 Books 快照/还原周期 + 还原后立刻 refresh ——
   前半已克隆、后半未克隆（结构不可达）。** 新 FFI
   al_exploit_flash_transaction 在一条隧道连接内完成：
   快照一次 → 主落点注入 → 合并偏好 → 还原一次，且还原
   后回读校验（新增 afc.books.restore.end verified= 日志，
   对齐他的 books.restore.end verified=true；失败时也先
   还原再报错，不留暂存 Books.plist）。但他的 refresh
   骑同一连接（connection=reused after_restore=true）：
   al_poster_refresh 从配对文件自建隧道，现有 FFI 面没有
   可跨调用交接的持久会话句柄，Swift 侧仍在事务结束后
   以新连接调用 refresh（AppViewModel 调用点未动）——
   维持 connection=new，明说未克隆。
4. **atc.move.settle 等待 —— 已克隆（观测机制为推断）。**
   他每次 FileComplete 后有 atc.move.settle confirmed
   （约 300ms、fallback 5000ms）。新增 wait_move_settle：
   每次 FileComplete 后经 AFC 轮询目标路径（100ms 间隔、
   5000ms 上限）直至可见，打同名日志
   `atc.move.settle confirmed=true/false duration_ms=…
   fallback_ms=5000`，超时不致命、继续流程。他内部的确认
   通道从日志不可见，本版克隆的是「等待本身」；若 AFC
   不解析中间 symlink，最坏表现为每次多等 5s 并记
   confirmed=false，真机日志可判。
5. **审计 control 标记 —— 未克隆（所指未明，只记录）。**
   他的装前/删除审计在 extensions 枚举后有一项
   `*.audit.control present=true`（日志与 WallLive 二进制
   格式串均实证存在）。字符串层面核查：二进制内两处裸
   "control" 均为无关框架的 ObjC 属性名；审计代码所在
   posterboard_delete.rs / posterboard_configuration.rs
   附近字符串未给出该检查指向的文件/目录名。故无法确定
   它是数据仓根部还是 Extensions 层的某个条目。该检查
   属其只读审计路径（preflight/delete audit），不在安装
   写入序列内，本版不臆造、不纳入。

### 改动清单

- rust-core/src/exploit.rs（纯新增，既有函数零改动）：
  wait_move_settle、stage_via_conduit、write_books_plist、
  restore_books_state、run_atc_asset_session、
  flash_transaction_phases、exploit_flash_transaction、
  build_archive_two_links、FFI 包装 flash_transaction。
- rust-core/src/lib.rs：新增导出 al_exploit_flash_transaction。
- rust-core/include/airlift.h：新增上述声明。
- Sources/App/TendiesEngine.swift（受保护编排文件，最小
  改动逐项登记）：偏好 plist 暂存前移到描述符循环之前
  （内容逐字不变）；主落点改走 injectPrimaryTransaction
  （新增私有辅助，调用新 FFI）；镜像落点改为跳过 + 打
  mirror_deferred 日志；删除循环后独立偏好阶段（两次
  writeDirectoryTree 调用）。writeDirectoryTree 与
  injectDescriptorFolder 保留原样（暂无调用方，零风险）。
  已知行为差：全部 item 解包/定位失败时旧流程仍会写
  一次偏好、新流程不写（无成功注入时该写入无意义）；
  多描述符时偏好随每笔事务重复写（内容幂等，与他
  per-wallpaper 事务同形）。

### 未动清单

信号代码全部（#111 归档 aux、回执三分类、验活、
already_stopped 复读）、poster_store 检测全链、
exploit_inject_folder / exploit_write_dir /
exploit_write_batch / exploit_run 既有实现、
AppViewModel 的 refresh 调用点与未确认提示逻辑、
UI 文案（仍显示应用成功）、受保护文件其余部分、
.github/workflows。

### 未验证项（诚实标注）

唯一裁决项：真机刷一张 → **不注销** → 系统选择器里
出现新壁纸。日志应出现的新形态关键行：
install.transaction.begin descriptors=1 targets=2 →
FileComplete [1/2]/[2/2] 各随一条 atc.move.settle →
preferences.combined.begin → FileComplete [1/4]..[4/4]
（各随 settle 与 preferences.asset.confirmed index
0..3）→ afc.books.restore.end verified=true →
install.result paths=1 mirror_deferred=1 → 随后既有
poster_refresh 链 signal.reply + old_process.gone +
refresh_confirmed=true。move.settle 的 AFC 轮询在真机
是否解析中间 symlink、耗时几何，看首轮日志的
confirmed 与 duration_ms。cargo check 主机目标通过
（airlift_ffi 既有 3 条 dead_code 警告不变）。

## 改动登记 · 合并偏好归档目录条目去重（run #113，2026-11-01，#112 真机日志定点修）

#112 真机（Sage 15:48 刷 EVA出现）：事务前半全通——
主落点注入 FileComplete [1/2][2/2]、atc.move.settle
confirmed=true 各约 103ms、descriptor.completed、
preferences.combined.begin——随即死在合并偏好建包：
`build_archive_two_links: invalid Zip archive:
Duplicate filename`（本地建包阶段，未及上传；失败
路径已先还原 Books 并 verified=true 才报错）。

根因：build_archive_two_links 的「两 tail 目录组件」
循环对两个偏好目标各写一遍完整目录链，共享前缀被
重复添加，zip 2.4.2 对重复条目名直接报错。两个真实
目标 tail 为
`var/mobile/Containers/Data/Application/<容器>/Library/Preferences`
与 `var/mobile/Library/Preferences`，共享条目为
`var/`、`var/mobile/`。本地抽取函数原文 + 真实参数
复现：报错 `Duplicate filename: var/`，与真机一致。

修法（单点）：该循环加 HashSet 去重，共享目录条目
只写一次；link/link_1、payload_0/payload_1 与各自
独有镜像条目、symlink 目标字符串
（`../../../<tail>`）保持 #112 布局逐字不变，归档
其余形状不动，事务其余部分与信号/检测代码不动。

本地回归自检（抽取修复后函数原文，真实调用参数）：
构建成功 2973 字节；条目共 19 个、去重后 19 个
（全唯一）；link、link_1、payload_0、payload_1
均在位；两 symlink 目标与修复前一致。cargo check
主机目标通过（既有警告不变，无新增）。

未验证项：与 #112 同一裁决项——真机刷一张 →
move.settle ×6 全 confirmed → preferences
FileComplete [1/4]..[4/4] + asset.confirmed ×4 →
restore verified → refresh_confirmed → 不注销进
选择器。

## 改动登记 · poster_store 列表/审计改走 DVT directoryListing（run #114，2026-11-01，Walllive 二进制定案）

### 三变体分歧的统一解释（代码与路径几何逐项坐实）

暂存几何：conduit 把归档提取到 Media/<src>/，链接位于
<src>/p0/p1/p2/link，其所在目录深度为
/var/mobile/Media/<src>/p0/p1/p2。

- 变体1 exploit-geometry（目标 `../../../<tail>`）：从 p2
  上溯三级恰回 <src> 目录内侧，再拼 tail 得到
  /var/mobile/Media/<src>/var/mobile/Containers/… ——即包内
  镜像树（build 侧把 tail 每一级都镜像成真实目录条目，
  含最后一级 Extensions 空目录）。词法不逃出提取根 →
  整包落盘、校验通过；AFC 跟随链接解析优先命中这棵镜像
  树 → `link.traversable=false`（空 Extensions）。这不是
  深度算错：该几何的标定位置是 ATC 同步把链接落位到
  Media 根之后（见下），在暂存深度它必然指向镜像。
- 变体2 relative-depth（`../../../../../../<tail>`）：词法
  终点是真仓，但上溯第 4 级即越过提取根 <src>（继续到
  Media、mobile、var）→ conduit 整包不落盘 → stage.diag
  每一级（含 payload）Afc(ObjectNotFound)。
- 变体3 absolute（绝对目标）：绝对目标即提取根逃逸的
  极端形式 → 同样整包不落盘。

统一机制：同一相对目标下「包内自洽（可落盘）」与「穿出
到真仓」互斥——落盘要求目标解析终点不越提取根，真仓
要求终点越过提取根到达 /var/mobile/Containers。唯一被
实证能跨越这条界线的是 ATC 同步落位：链接被 FileComplete
搬到 Media 根成为 /var/mobile/Media/airlift-link-<token>
（所在目录深度 3 级：var/mobile/Media），此时
`../../../<tail>` 三级上溯恰到 / 再拼 tail = 真仓——注入
侧与删除侧的链接都只在这个位置被使用。纯 list 会话不做
同步，无落位步骤，故任何链接字符串变体都无解，方向应
为换传输层。

list 与 install 的逐项 diff（同为 conduit 暂存的部分）：
MediaSubdir/提取落点相同、链接在包内深度相同（p0/p1/p2）、
归档条目形状相同（META-INF + p0/p1/p2/link + tail 镜像
目录 + payload，list 侧 build_delete_archive 有 payload
条目，非缺失）；唯一差异是 install 在暂存后还有 ATC 同步
把链接搬到 Media 根这一步，list 没有——分歧不在暂存包，
在落位。

AirCard 上游核查（research/repos/AirCard-iOS）：rust-core
仅有 exploit/ffi_util/grappa/lib/logging/pairing，无任何
列表/移除实现，也未调用 vendored idevice 的
directory_listing；无可借鉴的上游读仓路径。

### Walllive 对照（二进制取证，WallLive-1.1.1.ipa / IosWallpaperAppIntegrated）

符号表完整保留（126,506 条）。Walllive 的同源 Rust crate
为 airlift_ffi，清理实现在模块 posterboard_clear_audit
（类型 DvtDirectorySession / CachedDirectorySession，
函数 audit_on_tunnel_many / audit_on_tunnel /
audit_hierarchy / children / audit_path_for /
exact_children / verify_delete_absent），删除在
posterboard_delete（DeleteSession::remove /
NativeDeleteMove::relocate_link / relocate_descriptor）。
children 函数体内的字符串引用坐实通道与选择子：
`com.apple.instruments.server.services.deviceinfo` 通道
+ `directoryListingForPath:` 选择子；audit_on_tunnel_many
闭包引用 com.apple.instruments.dtservicehub（RSD 握手
advertised 检查）及其自有日志
`airlift.clear.audit.session query_only=true batched=true`、
`airlift.clear.audit.retry attempt=2 max_attempts=2
fresh_service=true query_only=true`、
`airlift.clear.inventory.complete`。

逐项对照：

| 项 | Walllive（跑通） | 我方三变体（失败） | 本版改法 |
|---|---|---|---|
| 列表传输 | DVT RemoteServer（dtservicehub） | AFC + conduit 暂存植链 | 改 DVT，与 Walllive 同 |
| 路径形态 | 绝对路径逐级 list | 相对 symlink 目标三变体 | 绝对路径（extensions_abs）逐级 list |
| 暂存包 | 列表无暂存（无归档、无 Books） | 每变体一份 StreamingZip | 列表零暂存 |
| 穿通判定 | 目录 list 直接返回真仓条目；审计按级计数（extensions/providers/descriptors）+ present/absent 精确路径判定 | 非空 Extensions 启发式（被镜像空树击穿） | DVT list 即真仓，无需穿通判定 |
| 失败重试 | fresh_service 全新服务重试 1 次（attempt=2） | 同会话内换变体 | 全新隧道+服务重试 1 次 |
| 删除搬移 | ATC 两书同步搬移（relocate_link/descriptor）+ DVT 审计 | 同机制（本就按其日志克隆），审计走 AFC 链接 | 搬移不动；预审/提交审计改 DVT |
| 删除暂存前缀 | wallpaper-delete-src- | airlift-src- | 不改（仅命名差异，无功能影响） |

时序对照：无日志可对照——Sage 已确认 Walllive 只给导入
日志、移除/清理无任何日志可导，此路关闭；以上结论全部
来自二进制符号与字符串引用。

### 改法（只动 rust-core/src/poster_store.rs）

- 新增 connect_device_info：复用既有 connect_rsd，再查
  dtservicehub advertised 并 connect::<RemoteServerClient>
  （与 poster_refresh 同范式），DeviceInfoClient 由
  device_info_client 小助手创建。
- store_list 改为 list_attempt（DVT 枚举）+ 失败一次全新
  会话重试；enumerate_descriptors 改以绝对路径逐级 DVT
  list，包名取自 versions/<v>/contents/ 的 *.wallpaper
  条目；identifier 文件 DVT 不可读，JSON identifier 留空
  （字段保留，Swift 结构不变）。
- audit_target 改 DVT 签名（DeviceInfoClient + store_root
  绝对路径）；store_delete 的 Phase A 预审与 Phase C 新鲜
  提交审计改走 connect_device_info 各开一条新连接。
- 删除：open_store_session / plant_store_link /
  upload_stage_archive / StoreSession / random_token /
  read_small_file / visible_entries / AFC_SERVICE 常量 /
  三变体数组。build_delete_archive 与 delete_operation
  （ATC 搬移本体）逐字未动；#112/#113 事务与信号代码
  未动；lib.rs / airlift.h / Swift 侧无改动（FFI 签名与
  JSON 形状不变）。

本地验证：cargo check 通过（仅既有 dead_code 警告；
StageFailed 变体因暂存路径删除而成未构造变体，作状态
契约保留）。路径几何手算表见上「统一解释」。结构自检：
list_attempt/enumerate 路径内 archive/conduit 引用为 0
（grep 断言）；build_delete_archive 函数原文与改前
一致（锚点外未触碰）。

未验证项（真机验收标准）：点「检测本机已导入的壁纸」
→ 日志出现 service advertised=true
（com.apple.instruments.dtservicehub）、
audit.session query_only=true transport=dvt-deviceinfo、
extensions.found 列出真实 provider（含
com.apple.WallpaperKit.CollectionsPoster）、
descriptors.found 列出此前刷入的全部 descriptor（含
7400 包的 descriptor 及其余已装）；UI 列表与之一致。
再选其中一条删除 → Phase B 搬移完成、Phase C 新鲜审计
absent、复检 list 该条消失。本版为该功能第一次在 DVT
传输上的真机验证，directoryListingForPath: 对数据仓
绝对路径的返回内容（条目名形态）以真机日志为准。
