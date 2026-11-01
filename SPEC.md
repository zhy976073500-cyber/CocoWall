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

## 改动登记 · 清理限域 + 隔离区恢复 + 偏好 settle 顺修（run #115，2026-11-01，#114 真机事故定点修）

#114 真机（Sage 17:32）：双包连刷全通、合并偏好 FileComplete×4
首跑完、refresh_confirmed 901ms、壁纸免注销进选择器（#112
克隆路线裁决通过）；检测（DVT）列出 descriptor 21 个
（CollectionsPoster 5 + GradientPoster 16），Sage 全选删除
21/21 成功（均搬入 Media 的 airlift-quarantine-<token> 隔离
夹保留、非销毁），复检 count=0。事故与新问题共四项，本版
逐项处置：

### A — 清理限域（安全边界，已实装）

根源：list 未按 provider 限域，系统自带/自建的 16 张
GradientPoster 渐变壁纸被一并列出并全选删除。
- rust-core/src/poster_store.rs 新增 CLEANUP_SCOPE_PROVIDERS
  （com.apple.WallpaperKit.CollectionsPoster、
  com.apple.Posters.CollectionsPosterApp）与
  provider_in_cleanup_scope 精确匹配判定。
- enumerate_descriptors 对范围外 provider 整段跳过（日志
  descriptors.filtered extension=… reason=provider_scope），
  UI 天然只剩自家壁纸，全选不再能触及系统数据。
- store_delete 在驱动层（FFI 正下方）硬拦截范围外 target：
  记 delete.blocked 日志、以明确 error 计入 failed，Phase A
  审计、Phase B ATC、Phase C 审计全部跳过——不依赖 UI 行为。
- 断言级自检：poster_store.rs 内 #[cfg(test)]
  cleanup_scope_tests 两组（两 provider 放行；GradientPoster/
  ClockPoster/Photos/Mercury/空串/近似串拒绝），cargo test
  --lib cleanup_scope 通过（见构建报告）。
- 注意：恢复（B）刻意不限域——GradientPoster 正是首要恢复
  对象，恢复与删除限域是两回事。

### B — 隔离区恢复（已实装）

可行性调查结论：
(1) AFC 可列 Media 根（路径 ""，"."、"/" 兜底，日志
quarantine.root 注明实际命中形态），airlift-quarantine-*
文件夹可枚举；其内部 descriptor 根形态运行时判定：文件夹
本身带 descriptor 标记（versions/、providerInfo.plist、
descriptor.identifier、Wallpaper.plist 之一）→ 根即文件夹、
原 UUID 不可知；或单个子目录带标记 → 根为子目录、子目录名
即原 UUID。AFC 在 Media 内可自由 list/读小文件，故包名
（versions/*/contents/*.wallpaper）、descriptor.identifier
文本、suggestionMetadata 均可读出。
(2) 反向搬回用删除同款 ATC 机制的镜像：暂存归档复用
build_delete_archive（链接落 Media 根、指向目标 provider 的
descriptors 目录）；book2 以 Airlock 相对路径标识隔离区内的
descriptor（../../airlift-quarantine-<token>[/<UUID>]，与
install 的 payload book 同形），FileComplete 目的地为
<落位链接>/<UUID>，守护进程经链接把 descriptor 搬进数据仓
——与 install 已验证的 payload 搬运同向。删除的
delete_operation 逐字未动，restore_operation 为其镜像副本
（代码库内 ATC 会话多处复制为既有风格）。
(3) 流程：store_restore 先逐条扫描隔离夹定 root 与最终
UUID（调用方传入的回执 UUID > 子目录名 > 新生成 UUID——
数据仓目录名只是唯一名，PosterBoard 按内容认 descriptor）；
Phase A DVT 预审（已在仓则幂等成功）；Phase B 逐条 ATC
搬回；Phase C 新连接 DVT 审计 present 才计恢复成功；仅对
审计通过的条目才经 AFC 删除隔离夹（审计门控清理）。
(4) 出处判定优先级：Swift 侧删除回执（UserDefaults 持久化，
PosterStoreReceipts，本版起 deleteImported 回传完整结果并
落盘 quarantine→provider+UUID）> 子目录名（UUID）> 内容
启发式（suggestionMetadata $objects 中 com.apple.*Poster*
串、descriptor.identifier 前缀，与 TendiesEngine
.determineExtension 同规则）。#114 那批 21 个隔离夹没有
回执：GradientPoster 条目将依赖内容启发式——其 descriptor
多半无 suggestionMetadata，provider_guess 可能为空、UI 显示
「来源未知，暂不可恢复」；这是已知缺口（见未验证项），不
伪造出处。
(5) 新 FFI：al_poster_store_quarantine_list /
al_poster_store_restore（lib.rs 包装 + airlift.h 声明同步）；
Swift：PosterStoreHelper 新增 listQuarantine /
restoreQuarantine + DeleteResponse 解码 quarantine 字段；
AppViewModel 新增 loadQuarantine / restoreQuarantineEntry
（恢复后 re-detect + 免注销 refresh，与清理同范式）；
清理页新增「隔离区（可恢复）」区，逐条恢复；清理确认文案
改实话（移入隔离区、可恢复）。

### C — 同批刷 2 张只显示 1 张（只交调查结论，未盲改）

证据链：
- 17:29 截图（刷后删前）：「添加新墙纸」页 iPhone 15 Pro
  Max 专属区只有一张卡片；Sage 17:35 确认画面云朵是最后刷
  的 HarmonyOSEmoji——「同批多张、末刷者独占选择器」坐实。
- 但「偏好 plist 整份覆盖」不是载体：我方每刷写入的
  unprotectedUserDefaults.plist 是固定字典（PBF_RESET_FILE_
  PROTECTIONS、PBF_LOCALE_DID_CHANGE、PersistedPoster
  ContainerBundleIdentifiers=5 个 provider id、
  CompletedPosterBundleIdentifierMigrations=6 个 id），
  两刷归档同为 4457 字节、内容逐字相同，根本不含任何
  descriptor 条目——覆盖一份相同字节不可能丢掉先刷的壁纸。
  Walllive 二进制字符串核查：其偏好 payload 键集与我方
  一致（PBF_*、PersistedPosterContainerBundleIdentifiers），
  同样无 descriptor 集合键。故原计划「DVT 枚举 descriptor
  全集、合并进偏好再写」在 schema 上无落点，未实装（按
  #115 任务 C 原定的 schema 门控：不是列表形态则只交调查）。
- 替代解释（首要嫌疑）：descriptor 内部身份撞车。
  PosterBoard 按 descriptor 的内部标识认「同一张壁纸」：
  descriptor 根目录的 com.apple.posterkit.provider
  .descriptor.identifier 文本、suggestionMetadata 里的
  descriptorIdentifier（与 contents 的 wallpaper
  identifiers 成套，如 7400.DYNAMIC <-> 7400）、
  Wallpaper.plist 的 identifier。两个 descriptor 文件夹名
  （UUID）不同、但内部标识相同 → 在 PosterBoard 眼里是同一
  collection 的两个版本，只展示最新一个——与「末刷胜出」
  严丝合缝；且出问题的是「专为 iPhone 设计」区，正是
  suggestion 驱动的展示面。我方 updatePlistIdentifiers
  只在无 suggestionMetadata 时才随机化标识（有 metadata 时
  为保配对关系整段跳过）——若 EVA 与 HarmonyOS 两包都带
  suggestionMetadata 且出自同一导出管线、共用同一套标识，
  正好绕过随机化而撞车。次要嫌疑：两包 contents 内
  .wallpaper 包名相同（同管线默认名）。
- 定案路径（零额外成本）：B 的隔离区列表会读出每个隔离
  descriptor 的 descriptorIdentifier 与 packageName——EVA
  与 HarmonyOS 的 descriptor 此时都在隔离夹里。真机跑一次
  隔离区列表，两相对照：descriptorIdentifier 相同即定案，
  修复方向随之为「刷入时对 suggestionMetadata 包做整套
  标识一致性重写（descriptorIdentifier 与其下属 wallpaper
  identifiers 同步换新前缀）」，而非动偏好。此修复涉及
  受保护的 TendiesEngine.updatePlistIdentifiers，待定案后
  单独一版做，不在本版盲改。

### D — 偏好文件资产 settle 轮询顺修（已实装）

现象：#114 两刷中，偏好段 FileComplete [2/4][4/4]（plist
文件资产）的 atc.move.settle 每次超时 5000ms
confirmed=false；链接资产 [1/4][3/4] 约 103ms 命中；同刷
Phase 1 的文件夹 payload 在同一轮询下约 105ms 命中。偏好
本身生效（壁纸正常进选择器），即文件搬运落地、观测点错
位：AFC GetFileInfo 对「经 Media 根链接指向的目录内文件」
这一形态恒不可见。
- exploit.rs：SettleOutcome 三态（Confirmed/TimedOut/
  Skipped）；run_atc_asset_session 在合并偏好会话
  （log_asset_confirmed 标记）中，奇数位文件资产改走
  wait_file_asset_settle：轮询落位链接的目录列表（ReadDir，
  与 GetFileInfo 不同的 AFC 操作）看 leaf 是否出现，预算
  1500ms；命中记 confirmed=true，未命中记
  skipped=true reason=file_asset_unobserved（诚实标注未观测，
  不冒充 false 的失败），由 FileComplete 回执 + 会话结论
  承载该资产。asset.confirmed 日志相应输出 true/false/
  skipped。
- Phase 1（descriptor 会话）与其余资产的轮询逐字未变；
  #111 信号编码、#112/#113 事务骨架未动。
- 预期：每刷省掉约 7–10 秒白等（2×(5000−~实际命中/1500)）。

### 改动清单

- rust-core/src/poster_store.rs：A（限域常量/判定 + 列表
  过滤 + 删除硬拦截 + 单元测试）；B（隔离区扫描/列表、
  restore_operation、store_restore、两新 FFI 入口）。
- rust-core/src/lib.rs：两新 FFI 包装；delete 文档补限域。
- rust-core/include/airlift.h：两新声明；poster_store 注释
  更新为 #114 DVT 传输 + #115 限域/恢复实情。
- rust-core/src/exploit.rs：D（SettleOutcome 三态 +
  wait_file_asset_settle + 会话内文件资产分流）。
- Sources/App/PosterStoreHelper.swift：DeleteResponse 补
  quarantine 解码并回传完整结果；listQuarantine /
  restoreQuarantine；PosterStoreReceipts 持久化；
  QuarantineDisplayItem。
- Sources/App/AppViewModel.swift：清理后落盘回执；隔离区
  状态 + loadQuarantine / restoreQuarantineEntry。
- Sources/App/TendiesView.swift：清理页加隔离区恢复区；
  刷新按钮兼刷隔离区；清理确认文案改实话。

### 未动清单

#111 sendSignal 编码、#112/#113 事务骨架（flash_transaction
的 identifiers/destinations/归档构造）、delete_operation 与
build_delete_archive（ATC 搬移本体）、poster_refresh、
TendiesEngine（C 的修复方向待定案后单独处理）、工作流文件。

### 未验证项（真机验收标准）

- A：点检测 → 日志 descriptors.filtered 出现且
  GradientPoster 等系统 provider 不再进 UI 列表，只剩
  CollectionsPoster 双 provider 的壁纸；全选清理不再可能
  触及系统壁纸。（构造范围外 delete target 的 FFI 级拦截
  只能由日志 delete.blocked 在异常调用时观察，正常 UI 路径
  不应出现。）
- B：清理页出现「隔离区（可恢复）」区并列出 #114 留下的
  21 个隔离夹（日志 quarantine.entry 逐条打出 root 形态、
  identifier、package、provider_guess——此日志同时是 C 的
  定案材料）；选一条已判定 provider 的条目恢复 → DVT 审计
  present、隔离夹被清、刷新后选择器可见。已知风险点：
  (i) 隔离夹内部形态（文件夹自身为根 vs UUID 子目录）以
  首跑日志为准，若两种都不是，restore 会以 root_found=false
  明确失败、不硬搬；(ii) 无回执条目的 provider 判定靠内容
  启发式，GradientPoster 可能判不出而暂不可恢复——若如此，
  下一版补「手动指定 provider 恢复」入口，不在本版伪造；
  (iii) ATC 反向搬运的 manifest download 标记以真机日志为
  准（delete 同款守卫：显式 false 才拒绝）。
- C：见上定案路径——隔离区列表日志中 EVA 与 HarmonyOS 两
  条的 descriptorIdentifier / packageName 是否相同。
- D：单刷日志中偏好段 asset index=1/3 不再出现
  settle confirmed=false 的 5000ms 超时（应为 confirmed=true
  或 skipped=true），Phase 2 总时长从 ~12700ms 明显回落；
  index=0/2 维持 ~103ms confirmed=true；合并偏好结论与壁纸
  进选择器不受影响。

## Run #122（2026-11-01）：删除恢复功能 + 标识整套重写 + 清理列表缩略图

Sage 2026-11-01 20:23 拍板三项：#121 的隔离区恢复功能整面
删除（「恢复功能不需要了」）；修「连刷多张只显示一张」；
清理列表加缩略图识别。

### 项一：恢复功能删除（功能面整删，删除机制不动）

- 删除：清理页「隔离区（可恢复）」区、刷新兼刷隔离区、
  PosterStoreHelper 的 listQuarantine / restoreQuarantine /
  QuarantineItem / QuarantineListResponse / RestoreResponse /
  QuarantineDisplayItem / PosterStoreReceipts、AppViewModel 的
  隔离区状态与 loadQuarantine / restoreQuarantineEntry / 清理后
  回执、Rust 的 store_quarantine_list / store_restore /
  restore_operation（poster_store.rs）、FFI
  al_poster_store_quarantine_list / al_poster_store_restore
  （lib.rs + airlift.h + poster_store.rs 三处）。清理确认文案
  回到不承诺恢复的实话。
- **不动**：delete_operation 与 build_delete_archive 逐字保留
  ——删除时搬入 Media 隔离夹是删除机制本身的安全属性（搬移
  而非销毁），不是恢复功能。DeleteResponse.quarantine 字段
  （删除结果报告）保留。
- 删后本地校验：cargo check 通过、cleanup_scope 单测 2 过；
  swiftc -typecheck（airlift.h modulemap）PosterStoreHelper
  零错误；四个被改 Swift 文件 swiftc -parse 零错误；全树无
  已删符号悬空引用。

### 项二：标识整套一致性重写（TendiesEngine.swift 受保护文件最小改动）

理由：Sage 点名要修的功能，改动点即刷入预处理既有的标识
处理处。旧 updatePlistIdentifiers 仅在包无 suggestionMetadata
时才随机化（且只改两处字符串），有 suggestionMetadata 的包
整套标识原样进仓——#115 C 项的首要嫌疑（descriptor 内部标
识撞车，后刷覆盖先刷的呈现）。

样本枚举的标识落点（upload.tendies 标识 9998 /
upload-2.tendies 标识 7400，两样本互证）：
1. descriptor 根目录 `com.apple.posterkit.provider.descriptor.identifier`
   纯文本 = 数字基底本身；
2. suggestionMetadata.plist（$archiver 键控归档，$objects）：
   descriptorIdentifier = 基底+"."后缀（如 7400.DYNAMIC）；
   图库条目 identifier = UUID 串（仅此文件出现）；
3. versions/*/contents/<包名>.wallpaper/Wallpaper.plist：
   identifier 为 **Int**（顶层与 assets.lockAndHome.default
   各一），及 *AnimationFileName* 命名的 .ca 目录名字符串；
4. provider.contents.userInfo：wallpaperRepresentingIdentifier
   （String=基底）、wallpaperRepresentingFileName（.wallpaper
   目录名）；
5. 路径组件：<基底>.….wallpaper/ 与
   <基底>.…_Background/Floating/Foreground-….ca/ 目录名前缀。
无标识文件：providerInfo.plist、role.identifier（扩展自身
标识）、RuntimeSnapshot/instance/configurableOptions/
otherMetadata/supplements 各 plist——逐字不动。

新实现 rewriteDescriptorIdentifiers（取代 updatePlistIdentifiers，
调用点与旧函数相同）：发现数字基底（descriptor.identifier →
Wallpaper.plist identifier → userInfo → suggestion 基底串，
四路互证）→ 同位数随机新基底 → 字符串规则（全等或「基底.」
前缀，后缀保留）+ 整数规则（仅 identifier /
wallpaperRepresentingIdentifier 键）整树重写；普通 plist 按
原格式结构化重写；$archiver 键控归档**不做对象图 round-trip**，
改走等长字节替换（UTF-8 + UTF-16BE 双编码）保 UID 图完整；
suggestion 图库 UUID 一并重掷（仅该文件）；包内 .DS_Store
（记录旧目录名的 Finder 元数据、唯一真残留）预处理时删除；
路径组件自深向浅改名。无数字基底的包（系统扩展符号标识，
如 Mercury 的 v6x.colorA）保持跳过并打日志——重写那种标识
会断扩展查找（MercuryPoster 扩展符号标识保持原样）。每包打
取证日志 airlift.identifiers.rewritten
package=… old=<原标识集> new=<新标识集>。

离线自检（函数原文抽出、本地 swiftc 编译，对两样本副本执行
+ python plistlib 断言）：PASS——旧基底字节级零残留（文本/
UTF-16BE/文件名，词边界检索；唯一形似命中为 contentVersion
2.01 的浮点字面量，非标识）、新标识各落点一致、suggestion
$objects 计数与非字符串对象不变、providerInfo.plist 逐字
未动、全部 plist 仍可解析且格式（XML/二进制）保持、
.ca/.wallpaper 改名与引用对齐、.DS_Store 已清。

### 项三：清理列表缩略图（匹配键 = packageName）

- 匹配键：DevicePosterItem.packageName（#114 DVT 枚举时从数
  据仓 versions/*/contents/*.wallpaper 读得的包内目录名）为主
  键，与本地库 .tendies 的 zip 中央目录条目中的同名路径组件
  精确匹配；次级为归一化匹配（小写 + 去 .wallpaper 后缀）。
  descriptor 的 identifier 字段本是天然次键，但 DVT 读不到
  （#114 已定，字段留空），故不用。
- AppViewModel.prepareDevicePosterThumbnails：检测成功后（及
  库条目变化时）离线匹配，产出 devicePosterThumbs
  [itemID: 预览 JPEG]；zip 中央目录纯 Swift 解析（EOCD 扫描，
  不解包；zip64/解析失败即无匹配、显示占位）。zip 解析器已
  离线验证：两样本分别得出 9998.Custom-…wallpaper 与
  7400.WWDC_2022-…wallpaper，非 zip 输入优雅返回空。
- UI：清理列表行左侧 34×46 圆角 6 缩略图（fill 裁切、轻阴
  影、无描边，与库列表行同款），匹配不到显示
  tertiarySystemFill 占位 + photo 图标；包名/UUID 文字不变。

### 未动清单

delete_operation / build_delete_archive（逐字）、poster_refresh
与 #111 信号编码、#112/#113 事务骨架、配对/利用链、工作流
文件。#114 删除日志重建的隔离夹对照表
（~/workspace/cocowall-quarantine-map-20261101.json）随恢复功
能取消而作废，仅留档。

### 未验证项（真机验收标准）

- 清理页无「隔离区（可恢复）」区段；检测/清理功能与 #121
  一致（限域、删除搬移语义不变）。
- 检测列表每行左侧有缩略图：本地库里有同包的显示其预览，
  没有的显示占位图；包名/UUID 前缀文字不变。
- 连刷 EVA + HarmonyOS 两包：日志含两包的
  airlift.identifiers.rewritten 行（old 集是否相同即定案材
  料——相同则撞车坐实且当场已修；不同而仍只显示一张则假
  设作废、此日志即下一轮证据）；不注销打开系统选择器，
  两张都在。

### CI 修复补记（run #121，2026-11-01）

#115 首推（run 41295394323）CI 构建失败（Build 步 exit 65、无日志可读），
经 #116–#120 五轮 bisect 收窄（#117 证 Rust 侧单独绿；TendiesView、
新 FFI 链接相继洗清；#116 一步因 #114 版 VM 与 #115 helper 的
deleteImported 签名天然不兼容而被污染，不作证据），最终用本地 Swift
工具链 typecheck 定案：PosterStoreHelper 是 public enum，#115 把
DeleteResponse 由 private 改为 internal 后又让 public 方法
deleteImported 的 completion 暴露该类型，连同 listQuarantine
（QuarantineItem）、restoreQuarantine（RestoreResponse）共三处
「public method cannot use internal type」编译错误。修复：三个结构体
及其成员（含嵌套 ItemResult）改为 public，与同文件 DevicePosterItem
的既有写法一致；其余 #115 代码逐字未动。本地 swiftc -typecheck
（Swift 6.1 + airlift.h modulemap）修复后零错误。

### CI 修复补记（run #123，2026-11-01）

#122 的 CI（run 41307619912）Build 步报 2 条 error：AppViewModel.swift
新增 zip 中央目录解析函数中两处 `fh.seek(toOffset:)`（1158、1181 行）
为 throwing API 而未标记 try。修复（本版 #123，仅动 AppViewModel.swift
该函数）：两处 seek 改为 do/catch、失败即按解析失败返回 nil；同函数
其余 FileHandle 调用（seekToEndOfFile/readData/closeFile）均非 throwing，
已逐一审计。本地验证：swiftc -parse 全文件通过；函数原文抽出编译后
对真实 zip 正确返回 .wallpaper 包名、坏路径返回空。

## Run #124（2026-11-01）：清理列表缩略图匹配修复（登记表 + 基底剥离兜底）

### 病因（真机定案）

#123 真机（Sage 2026-11-01 21:19 截图）：清理列表 5 条缩略图
全为占位图。五条仓内 packageName 基底为 1572/4845/5383/3071/
9589（全 .WWDC_2022-390w-844h@3x~iphone.wallpaper）——正是
#122 标识重写逐包随机化的新基底；本地库同包内部名仍是原始
基底（7400.…）。#122 的匹配按 packageName 精确比对（外加小写/
去后缀归一化），重写后的包必然全灭。匹配键选错了锚：基底恰
是每刷必变的量。

### 修法（只动 Swift 侧；三层，权威性递减）

1. **刷入登记表（主）**：TendiesEngine.flashTendies 新增可选
   回调 onDescriptorInstalled(item, ext, storeUUID)，在每个
   descriptor 的注入事务成功返回后立即调用（抛错则不登记，
   只登记真落仓者；多 descriptor 包逐个登记）。AppViewModel
   在回调里把映射落盘：键 "<ext>/<uuid>"（即
   DevicePosterItem.id）→ FlashRegistryEntry{itemID, itemName,
   relativePath}，JSON 存 UserDefaults 键
   cocowall.flash_registry（与 aircard.saved_tendies 同模式，
   编解码全 try?，无 throwing 调用外泄）。
2. **清理列表三层匹配**（prepareDevicePosterThumbnails 重写）：
   ① 登记表按仓 id 查：命中用库条目（id 优先、relativePath
   兜底）的现成预览与显示名（条目已删时用登记时存的 itemName
   兜底标题）；标题经 devicePosterDisplayNames 覆盖
   item.name，不再显示重写后的仓内包名。② 精确 packageName
   匹配（#122 原逻辑，覆盖重写机制存在前刷入的包），命中同
   时给出缩略图与本地名。③ 基底剥离兜底（仅缩略图）：两侧键
   经 packageFallbackKey 归一（小写、去 .wallpaper 后缀、剥
   开头纯数字基底段 ^\d+\.），后缀一致即命中——覆盖 #122–#123
   间刷入、无登记的存量。已知风险（代码注释已注明）：仅数
   字基底不同的同名异包剥离后会撞键，多命中取库中第一条；
   此层只作存量兜底，新刷入一律走登记表。
3. **删除联动**：清理成功回调按 DeleteResponse.results 中
   ok 的条目移除登记表对应键，避免脏数据。

### 验证（本地）

- swiftc -parse：AppViewModel / TendiesView / TendiesEngine
  三个改动文件全过。
- 逻辑原文 harness（FlashRegistryEntry 与 packageFallbackKey
  逐字抽出编译运行）：Sage 真机五条仓内名（1572/4845/5383/
  3071/9589.…）对本地名 7400.… 精确层全灭（预期）、剥离层
  全命中；异后缀不撞；v6x./3D. 等非纯数字头段不剥；登记表
  JSON 往返一致、按仓 id 命中取本地名、未知 id 落空走下层。
  共 25 项断言全过。
- throwing 审计：新增代码仅 JSONEncoder/Decoder 两处，均
  try? 收口；packageFallbackKey 为纯字符串操作；无新增
  FileHandle 调用；zip 中央目录解析器（#122/#123）复用未动。

### 未动清单

Rust 侧全部、PosterStoreHelper、删除/注入事务、标识重写
（#122）、工作流文件。

### 未验证项（真机验收标准）

- 装 #124 后打开清理列表：#123 前刷入的 5 条 WWDC 应经基底
  剥离兜底显示出库中同包缩略图（若那 5 条实为同包反复刷入，
  标题仍显示仓内名——显示名只来自登记表/精确层）。
- 新刷一张（#124 后）：再开清理列表，该条应经登记表命中，
  缩略图 + 本地显示名同时出现。
- 清理删掉该条后：登记表对应键已移除（行为面无感，仅防脏
  数据）。

## 改动登记 · 内置回环 Packet Tunnel（run #125，2026-11-01，Sage 点名：App 本体自带回环，不再依赖 LocalDevVPN）

### 研究结论（先行调查）

- **现状分工**：Swift 侧不存在 TunnelManager。回环完全由外部
  LocalDevVPN App 提供；本 App 只在 ContentView 的 VPNStatusRow
  里检测 utun 接口是否已存在（NetworkStatus 接口扫描）、给出
  localdevvpn:// 跳转链接，Rust 侧假定 RSD 在 10.7.0.1:49152
  可达（exploit.rs / poster_refresh.rs / poster_store.rs 三处同
  一常量 + 回退地址表 10.7.0.2/.3、10.0.0.1、172.16.0.1；
  AppViewModel.deviceIP 默认 "10.7.0.1" 经 lib.rs setter 注入）。
  Walllive 日志的 `mode=system_vpn` 即其 App 内自带系统 VPN
  配置，与本项目标同形态。
- **上游无可搬**：research/repos 的 AirCard-iOS 与
  AirCard-iOS-latest 全树 grep NetworkExtension /
  NEPacketTunnel / NETunnelProvider 零命中——上游同样依赖外部
  LocalDevVPN，没有 packet tunnel 代码或扩展 target 可带。
- **工程结构无硬卡点**：工程为 XcodeGen（project.yml）。CI
  先 `xcodegen generate` 再 `xcodebuild build -scheme CocoWall`，
  打包步整包拷贝 CocoWall.app；PairingLiveActivity 以
  app-extension target + `embed: true` 先例已被同一构建自动带
  入 PlugIns（#123 产物实测含 PairingLiveActivity.appex）。
  新增扩展照此范式即可被现有构建命令自动带上，**不需要改
  workflow 任何一行**。
- **参考实现（生态内已验证）**：jkcoxson/LocalDevVPN 的
  TunnelProv 源码已通读（GitHub 限流前取到 PacketTunnelProvider.swift
  本体、Constants.swift、Info.plist、entitlements）。其机制：
  接口地址 10.7.1.1/32（与拨号目标不同址）、仅把 peer
  10.7.0.1/32 一条路由纳入隧道、排除默认路由；包环路把 IPv4
  包的源/目的地址互换后写回 packetFlow（src+dst 集合不变，
  IP 头校验和与 TCP 伪首部校验和均不受影响，无需修正校验和），
  包遂以入站形态落到本机监听（RSD 通配监听 49152）。本项按此
  形态自研实现，未复制其代码（该仓许可证为 Other/NOASSERTION）；
  常量键名 TunnelIfaceIP / TunnelPeerIP 与其保持一致。

### 改动清单

- 新增 `Sources/CocoWallTunnel/PacketTunnelProvider.swift`：
  NEPacketTunnelProvider 最小回环——startTunnel 读
  options/providerConfiguration 的 iface/peer 地址（缺省
  10.7.1.1/32 与 10.7.0.1/32，CIDR 解析含前缀缺省与掩码计
  算）→ NEIPv4Settings（includedRoutes 仅 peer 一条，
  excludedRoutes 默认路由）→ setTunnelNetworkSettings 后启
  动 src/dst 互换环路；非 IPv4 与 runt 帧原样透传。
- 新增 `Sources/CocoWallTunnel/Info.plist`：
  NSExtensionPointIdentifier =
  com.apple.networkextension.packet-tunnel，principal class
  $(PRODUCT_MODULE_NAME).PacketTunnelProvider；其余键与
  PairingLiveActivity 的 Info.plist 同构。
- 新增 `Config/CocoWall.entitlements` 与
  `Config/CocoWallTunnel.entitlements`：主 App 与扩展各一份
  com.apple.developer.networking.networkextension =
  [packet-tunnel-provider]（工程此前无任何 entitlements 文件，
  本项首次引入，置于 Config/ 以免落入任何 target 的 sources
  glob）。
- `project.yml`：新增 CocoWallTunnel target（type:
  app-extension，bundle id com.coco.cocowall.tunnel，
  INFOPLIST_FILE + CODE_SIGN_ENTITLEMENTS）；CocoWall target
  加 `- target: CocoWallTunnel, embed: true` 依赖与自身
  CODE_SIGN_ENTITLEMENTS。
- 新增 `Sources/App/LoopbackTunnelManager.swift`（@MainActor
  ObservableObject）：NETunnelProviderManager 载入/查找既存
  配置（按 providerBundleIdentifier 匹配）、首次创建配置
  （serverAddress 10.7.0.1，providerConfiguration 写入
  TunnelIfaceIP/TunnelPeerIP，localizedDescription
  "CocoWall 内置回环"）→ saveToPreferences → 回读 →
  startVPNTunnel；NEVPNStatusDidChange 观察回填状态；中文
  状态文案与错误回显（lastError）。
- `Sources/App/ContentView.swift`（仅 VPNStatusRow）：内置
  回环升为主位——未连通时绿色框内「开启内置回环」按钮 +
  状态/错误行；已连通且由内置回环提供时显示「关闭内置回
  环」；原 LocalDevVPN 步骤与 localdevvpn:// 链接保留为兜
  底（标题改「或使用 LocalDevVPN（外部 App）：」）；未连通
  副标题文案改「运行刷入前请先开启回环（内置或
  LocalDevVPN）。」。

### 未动清单

AppViewModel.swift、TendiesView.swift、poster_store 全部、
Rust 侧全部（拨号地址与回退表不变——内置回环的 peer 正是
10.7.0.1）、PairingLiveActivity、工作流文件、
TendiesEngine 等受保护文件。#124 的登记表/缩略图改动零冲突
（本项未碰其文件）。

### 本地验证

- project.yml 以 YAML 解析通过，三 target 结构与依赖/权益
  设置回读正确；三份 plist 以 plistlib 解析通过（扩展点、
  principal class、entitlements 内容逐项核对）。
- 新 Swift 文件与 ContentView.swift 以本地 swiftc -parse
  全过；CIDREndpoint 原文抽出编译实测（/32、/24 缺省、/8、
  非法前缀回退共 5 项断言）+ 合成 IPv4 包 src/dst 互换断
  言，全过。
- 与远端 #123 的 ContentView.swift / project.yml 逐字 diff：
  差异恰为本项改动，无夹带。

### 未验证项（真机验收标准，诚实标注）

- 首次点「开启内置回环」时 iOS 的「添加 VPN 配置」系统授
  权弹窗及允许后配置落盘——只能真机验。
- 扩展在 Sage 侧载签名链下能否被系统正常拉起：本构建为无
  签名产物，entitlements 是否被其签名工具如实授予
  （networkextension）属签名链行为，构建侧无法确证；若真
  机 startVPNTunnel 报 entitlement 类错误，先查此项。
- 回环连通性：开启后 VPNStatusRow 应转绿（utun 出现）、刷
  入日志 tunnel connected 与 #114/#123 同形态跑通——真机
  验。在此之前内置回环只算「已实装、未验证」，LocalDevVPN
  兜底入口因此保留。
- 产物自查：CI 绿后主线下载 artifact 解包应见
  Payload/CocoWall.app/PlugIns/CocoWallTunnel.appex（构建侧
  无法直接读 artifact 清单，此项随主线交付时一并核对）。

### 追加（同轮 #124）：壁纸页顶部状态区

Sage 2026-11-01 21:28 追加，与 #125（内置回环扩展，UI 在设置
侧）并行不冲突。壁纸页 Form 最上方新增状态区 Section（在
「获取更多壁纸」之前；原有两入口位置不变）：

- 「连接回环」按钮：与设置侧既有「启动 LocalDevVPN」同一动
  作（UIApplication 打开 localdevvpn://），本页新增顶部入
  口，设置侧原入口保留、不迁走（两处同动作不打架）。
- 配对文件：已识别 / 未识别。来源 = vm.hasPairingFile，由
  refreshPairingFile() 刷新——口径为规范配对文件
  （PairingController.pairingFilePath()，即 RPPairing 配对缓
  存落盘的 aircard_pairing.plist）存在且非空；更深的有效性
  只能在隧道连接时验证，无现成只读接口，故以此为口径。
- 本机系统：iOS <UIDevice.current.systemVersion> + 判定。
  判定纯函数 AppViewModel.systemSupportLevel：<17.0 不支
  持；17.0–27.1 支持；≥27.2 风险提示（通道被修补口径）。
  harness 边界验证 14 例全过（27.0.1→支持、27.2→风险、
  28.0→风险、空串→不支持不崩）。
- 回环连接：已连接 / 未连接。来源 = vm.vpnUp，由
  refreshNetworkStatus() 刷新——NetworkStatus 接口扫描
  （隧道接口/到设备 IP 10.7.0.1 的路由），不开新连接；内
  置回环（#125）与外部 LocalDevVPN 任一连通都会点亮。
- 刷新时机：进壁纸页 onAppear 各查一次 + 状态区标题右侧
  刷新按钮手动合并刷新（refreshPairingFile +
  refreshNetworkStatus）。

真机验收追加：开壁纸页顶部四件齐全；未开 LocalDevVPN 时
回环显示未连接、开启后手动刷新显示已连接；配对文件、本机
系统（iOS 27.0.1 · 支持）与真机事实相符。

## 改动登记 · 壁纸页连接回环改接内置回环（run #127，2026-11-02，Sage 纠正：回环长在软件本身，不下载、不跳转 LocalDevVPN）

### 病因（真机定案）

#126 真机（Sage 2026-11-02 01:21）：点壁纸页顶部状态区的
「连接回环」仍跳转到 LocalDevVPN。#124 当时把该按钮接的
是旧的外跳动作，与 Sage 本意（回环长在 CocoWall 本体里、
用户在 App 内点连接就直接连上）不符。#125 的内置回环开关
只落在设置页 VPNStatusRow，壁纸页没有接上。
补充定案（Sage 2026-11-02 01:25）：设置页里那个内置回环
开关他根本没找到——可发现性就是这次的真 bug。故本轮定纪
律：壁纸页这一处就是唯一入口的心智模型，不依赖用户先去
设置页开任何东西；按钮标题在任何状态下都写明「内置回
环」（不许只写含糊的「连接」二字）；连接状态紧贴按钮下
方一行显示。设置侧原样保留，不为此额外做引导。

### 改动清单（只动 TendiesView 状态区 + 管理器共享接线；ContentView 仅一行接线）

1. **TendiesView 状态区「连接回环」按钮改接内置回环**：
   改接 LoopbackTunnelManager（start/stop）。未连接点按 =
   保存 VPN 配置（首次触发系统「添加 VPN 配置」授权弹窗，
   属预期）并启动 CocoWallTunnel 扩展；标题按状态恒带「内
   置回环」：未连接「连接内置回环」（副文案「CocoWall 自
   带回环，点按直接连接，无需其他 App」；未配置时副文案
   提示首次系统授权）、连接中「内置回环连接中…」/断开中
   「内置回环断开中…」（按钮禁用 + ProgressView）、已连接
   「断开内置回环」。「回环连接」状态行挪到紧贴按钮下方
   （在配对文件/本机系统之前）。按钮任何状态下不跳
   localdevvpn:// 或 App Store；壁纸页可见文案中的
   LocalDevVPN 字样一并撤掉（文件内仅剩口径说明注释）。
2. **状态行双口径**：「回环连接」一行改由纯函数
   loopbackPresentation 映射——以内置隧道 NEVPNStatus 为主
   （已连接（内置回环）/连接中…/断开中…/未连接）；内置不
   在场时外部 LocalDevVPN 在跑（vm.vpnUp 接口扫描）仍显示
   「已连接」（刷入照样可用）。isBusy（正在保存配置、状态
   尚未翻转）按连接中呈现，防重复点。进页面 onAppear 与区
   头刷新按钮都会 reload 内置状态 + 刷新外部探活。
3. **错误原样进状态区**：loopback.lastError 若有值，在状态
   区内以红色 caption 原样显示（管理器文案已是「中文前缀
   + 系统错误原文」，如「开启内置回环失败：…」），供截图
   回传诊断签名/entitlement 链，不吞错。
4. **管理器收敛为共享实例**：LoopbackTunnelManager 新增
   static let shared；TendiesView 与 ContentView 的
   VPNStatusRow 都改用共享实例（按 provider bundle id
   com.coco.cocowall.tunnel 匹配的同一份系统 VPN 配置档
   案）。ContentView 除该一行接线外逐字未动；隧道扩展本
   体与管理器核心逻辑（start/stop/reload 实现）未动。

### 本地验证

- swiftc -parse：TendiesView / ContentView /
  LoopbackTunnelManager 三文件全过（本地 Swift 6.1 工具链，
  parse 级；完整类型检查以 CI 为准）。
- 按钮状态映射原文抽出 harness（LoopbackPhase 纯枚举镜像
  NEVPNStatus 七态 + loopbackPresentation 本体）：16 条断
  言全过——五态×（忙碌位/外部探活）关键组合的标题/可用性/
  状态行文案全对；副文案口径（invalid 提示首次授权、
  connected 说明点按断开）对；全部呈现文案无 LocalDevVPN
  字样；全部状态下按钮标题均含「内置回环」（可发现性纪
  律断言）。

### 未动清单

- ContentView 设置侧 UI 与行为（仅 @StateObject→共享实例
  一行接线）；隧道扩展 CocoWallTunnel 本体；AppViewModel；
  TendiesEngine；poster_store；project.yml；.github/workflows。

### 未验证项（真机验收标准）

- 装 #127 后在壁纸页点「连接回环」：首次应弹系统「添加
  VPN 配置」授权 → 标题变「连接中…」按钮禁用 → 变「断开
  回环」且状态行「已连接（内置回环）」→ 不开 LocalDevVPN
  直接刷入应跑通。全程不应出现跳转 LocalDevVPN。
- 若签名链未授予 networkextension 权限，点按后状态区应出
  现一行红字「开启内置回环失败：<系统错误原文>」（典型为
  NEVPNError / entitlement 类描述）——截图该行即为下一步诊
  断证据。

## 改动登记 · 壁纸页整页改版（run #128，2026-11-02，Sage 设计定稿 v5/v8 一次整批实装）

### 定稿来源

Sage 2026-11-02 凌晨亲自美术指导、逐项删改后定稿：主页面
照设计稿 v5（~/workspace/cocowall-design/wallpaper-page-v5.png）、
全屏选择页照 v8（imported-picker-page-v8.png）。核心口径：
扇形排版是他定的、不得被替换；展开 = 全屏 push 进独立页面
（不是弹层、不是原地换网格，此前两版理解均被当场纠正）。

### 改动清单（只重排布局与位置，全部现有行为与判定逻辑复用）

1. **TendiesView 整页改版**（Form → ScrollView 自绘）：
   - 页头：左大标题「我的壁纸」；右上角圆形展开按钮（浅蓝
     底、蓝色 chevron.down），点按经现有 NavigationStack 的
     navigationDestination push 全屏「已导入的壁纸」页。原
     工具栏 + 导入按钮从页头移除；系统导航栏在本页隐藏
     （toolbar(.hidden, for: .navigationBar)），推送页自带
     系统导航栏（返回 + 标题 + 全选）。
   - 扇形壁纸区：本地库壁纸横向 ScrollView，卡片 150×200
     竖幅、按索引循环旋转 [-8,-4,0,4,8] 度、HStack 负间距
     （-62）交叠、zIndex 按与中心索引距离叠放（中间靠前），
     从左至右排列、左滑浏览、右侧自然露半张。缩略图/名称
     用现有数据；已选蓝圈描边 + 右下蓝勾徽标；点按切换选中
     （vm.tendieItems[i].isSelected，与旧列表同一选择模型）。
     空库沿用旧空态口径（文案中原「点右上角 +」因按钮搬家
     改为「点下方『导入壁纸』」）。
   - 已选行：左「已选 <名字、…>」（未选显示「还没选择要刷
     入的壁纸」）、右「共 N 张」。
   - 底部 sheet 区（浅灰 #F7F7FA 圆角 28 大卡、白卡瓷砖）：
     a. 顶部白色胶囊状态条：回环 / 配对文件 / 系统三段，
        值语义色（已连接/已识别/支持=绿，未连接/未识别=红，
        系统风险提示=橙、不支持=红），段前同色小圆点。判定
        全部复用现有实现：回环 = #127 loopbackPresentation
        同源的 NEVPN 主口径 + vm.vpnUp 兜底（紧凑短值）；
        配对文件 = vm.hasPairingFile；系统 = systemSupportLevel
        （紧凑文案「iOS x · 支持/风险提示/不支持」）。刷新触发
        沿用 #127（onAppear 三查 + 管理器 NEVPN 观察），本轮
        不做手动刷新按钮（旧状态区右上角刷新按钮随旧区撤除）。
        启停失败红字沿用 #127 纪律：loopback.lastError 原文
        显示在状态条正下方，有错才显示。
     b. 主按钮：整宽蓝胶囊「刷入 N 张壁纸」，行为 = 现有
        vm.flashSelectedTendies()；刷入中呈现沿用旧口径
        （spinner + 进度条，白卡内）；N=0 禁用。
     c. 「导入壁纸」白色宽条紧贴主按钮下方（蓝色圆圈 + 号）：
        原页头 + 号搬家，showFilePicker → TendiesDocumentPickerView
        → vm.importTendieFiles 链路与原来完全一致。
     d. 小字行：容器已检测到时单行「目标：已检测到
        PosterBoard 容器 ✓ · 刷入后先尝试免注销刷新」；未
        检测到时沿用旧文案「刷入时将自动检测 PosterBoard
        容器。」。注：旧第二行尾句「如未生效可手动点注销」
        因注销按钮已删（见删除项）不再成立，按定稿稿面只保留
        前半口径。
     e. 双列瓷砖：左「获取更多壁纸」（副文案定稿稿面
        「飞书合集，持续更新」，行为不变 = 系统浏览器打开
        飞书 wiki Oi6pwrRp9i8wd2kBl0Lc4bn9nTb）；右「内置回环」
        （副文案随状态：已连接·点击断开=绿 / 未连接·点击连接 /
        连接中…=橙；点击 = #127 现成启停：LoopbackTunnelManager.shared
        start/stop，任何状态不跳转外部 App；忙态禁用）。
     f. 整宽瓷砖压底「清除壁纸」（红色垃圾桶，副文案「检测
        并清除本机已导入的壁纸」）：点击 = 旧「检测本机已导
        入的壁纸」入口原行为（vm.showDevicePosterSheet = true
        + detectDevicePosters()），进现有 DevicePosterCleanupView；
        devicePosterStatus 非空时仍在 sheet 内显示一行（旧
        信息面保留）。
   - 长按菜单（判断性保留）：旧列表行的「详情 / 删除」在新
     版式无位置，扇形卡与选择页格子均挂 contextMenu 提供
     详情（TendieDetailSheet）与删除（vm.deleteTendie），
     不改变点按 = 选中的定稿行为。
   - 缩略图共用组件 TendieThumbnailView（扇形卡与选择页
     共用；缺预览时 .task 调 vm.regenerateTendiePreview，
     与旧行同口径）。旧 TendieRowView 保留未删（暂无引用）。

2. **新增全屏选择页 ImportedWallpapersView.swift**（新文件，
   project.yml 的 Sources/App 目录源自动纳入，无需改工程）：
   系统导航栏（返回、标题「已导入的壁纸」、右上「全选/取消
   全选」）；副行「共 N 张 · 已选 M 张，点按勾选要刷入的
   壁纸」；三列 LazyVGrid 竖幅大格（缩略图 + 名称，未选右
   下空心圈、已选蓝圈描边 + 蓝勾徽标）；点按切换选中，与
   扇形区共用同一份 isSelected 状态、实时一致；底部固定栏
   左「已选 M 张」、右蓝色胶囊「完成」（dismiss pop 回
   壁纸页）。

3. **日志搬家**：SettingsView（设置页本体在 SettingsView.swift，
   ScrollView + 卡片式，非 ContentView 内 Form）在现有两张
   入口卡（作者 / 设备配对）之后、页面最下面追加日志卡：
   CompactLogView「刷入日志（\(vm.tendiesFlashLog.count) 行）」
   绑 vm.tendiesFlashLog、「活动日志（\(vm.log.count) 行）」
   绑 vm.log，标题与 onClear 与现有用法对齐，并沿用全 App
   「非空才显示」口径。密码盘页 passthm 刷入日志、配对页
   活动日志均不动。SettingsView 为此新增 @EnvironmentObject
   vm 注入（根 TabView 环境现成）。

4. **壁纸页删除项**：强制刷新 PosterBoard 缓存开关行（其
   resetProtections 参数本就是死的——TendiesEngine 内写死
   true，删 UI 即可；AppViewModel.resetPBProtections 属性
   按定稿保留不用）；注销（NeoSpring）按钮行（NeoSpring
   overlay 与 vm.isNeoSpringing 复位逻辑保留——刷入管线侧
   仍可能置位）；壁纸页刷入日志 Section（CompactLogView
   从 TendiesView 撤除，见 3）；#126/#127 旧状态区整块
   （被 4a 状态条取代；loopbackPresentation 纯函数与管理
   器接线保留复用）；旧壁纸库列表与「壁纸库」小节（被扇
   形区 + 全屏页取代；旧列表头部的全选入口由全屏页右上
   「全选」承接）；旧「获取更多壁纸」独立 Section（改瓷
   砖入 sheet）；旧「检测本机已导入的壁纸」独立 Section
   （改「清除壁纸」瓷砖入 sheet）。不新增「配对文件教程」
   「本机系统」按钮（Sage 已删；配对/系统信息只在状态条
   显示）。

5. **未动**：TendiesEngine.swift、rust 树、受保护文件、
   CI workflow、刷入管线 / 标识重写 / 闪存登记 / 清理页
   本体 / 配对页 / 制作页 / 密码盘页 / 底栏四 tab 结构。
   AppViewModel 本轮零改动（删除项只删 UI）。

### 与设计稿的已知偏差

- v5 稿页头右上角仍画 + 号（那是加号搬家前的稿），实装按
  后续定稿（v6/v7 起）画展开按钮；v5 的页脚小字与稿面有
  一行合一行之差（见 1d 注）。
- 扇形区 zIndex 按「与中心索引距离」叠放，横滑时视觉中心
  与索引中心不完全重合——静态稿无法表达滚动中状态，取
  索引中心为近似；真机观感待 Sage 验。
- 全屏页底栏在本 App 的 push 呈现下位于系统 tab bar 之上
  （safeAreaInset），稿面为无底栏全屏——以现成导航模式
  为准，未改 tab 架构（任务书口径）。

### 本地核查

- swiftc -parse 三文件（TendiesView / ImportedWallpapersView /
  SettingsView）全过；推送前远程 head = 808fa28，三份将改
  文件（TendiesView / SettingsView / SPEC）远程内容与本地
  逐字节一致、无分叉。
- 真机视觉与交互（扇形手感、状态条折行、push 转场、日志
  位置）未验证，等 Sage 装机验。

### #128 附则 · 液态玻璃（Sage 2026-11-02 追加，同轮生效）

**Standing 要求（全 App 长期有效）**：所有新建 / 重排的 UI
表面默认按 iOS 26 液态玻璃实现——原生 glassEffect +
GlassEffectContainer 收拢同组玻璃元素，按钮类优先系统
glass / glassProminent 样式；部署目标仍含 iOS 17–25，用
编译期 #if compiler(>=6.2)（旧 SDK 不编译玻璃分支）+ 运行时
#available(iOS 26, *) 双路，旧系统回退 .ultraThinMaterial
等价外观，功能与布局不因回退而变。#128 先覆盖壁纸页新表面；
其余页面（制作 / 密码盘 / 设置正文 / 清理页 / 配对区）已由
run #129 补齐——**全 App 已落地**（明细见文末 #129 登记）。
既有底栏透镜 dock 是既有玻璃实现，不动。
**例外（run #131 补注）**：壁纸页底部 sheet 区经 Sage
2026-11-02 决定不使用液态玻璃，保持纯色平面——该区的
表面口径以文末 #131 登记为准，本附则的默认口径不再
覆盖这一块；其余页面与共用玻璃辅助不受影响。

本轮落点（共用辅助在 TendiesView.swift 顶部：View.glassSurface
（tint / interactive 可选）+ GlassGroup 容器）：

- 壁纸页错误横幅：glassSurface（红 tint）。
- 页头展开圆钮：glassSurface(Circle, 蓝 tint, interactive)
  ——固定 38pt 圆形几何，系统 .glass 样式无法约束尺寸，
  故用 glassEffect 表面实现（仍是原生玻璃 + interactive）。
- 底部 sheet：整体入 GlassGroup（GlassEffectContainer），
  面板本体 glassSurface（圆角 28）。
- 状态胶囊条：glassSurface(Capsule)，在 sheet 的玻璃容器内。
- 刷入主按钮：iOS 26 用系统 .glassProminent 样式（tint 蓝、
  controlSize .large）；旧系统回退自绘蓝胶囊（原 #128
  实现）。刷入中进度卡同换 glassSurface。
- 导入宽条 / 双列瓷砖 / 清除宽条：glassSurface（圆角 20，
  interactive: true），不再自绘白底。
- 全屏选择页底部固定栏：入 GlassGroup，栏面 glassSurface
  (Rectangle)；「完成」按钮同刷入主按钮双路（glassProminent /
  自绘蓝胶囊回退）。
- 扇形区无容器底板（卡片直接浮于页面），无玻璃面可加；
  卡片本体是壁纸缩略图，不玻璃化。
- 设置页日志卡不在本轮清单（属设置正文，随后续独立批次
  一起玻璃化），本轮维持入口卡同款卡面。

## 改动登记 · 全 App 液态玻璃补齐（run #129，2026-11-02，standing 要求收尾轮）

Sage standing 要求「软件 UI 必须都适配 iOS 26 的液态玻璃」的
收尾批次：把 #128 未覆盖的页面表面全部补齐。全程复用 #128
在 TendiesView.swift 顶部建立的共用辅助（View.glassSurface /
GlassGroup）与双路模式（#if compiler(>=6.2) + #available
(iOS 26, *)，旧系统 .ultraThinMaterial / bordered 系样式
回退，最低系统 17.0 不变）。**只换表面材质：布局、文案、
顺序、间距、行为与全部逻辑零改动。**

### 共用辅助新增（TendiesView.swift 玻璃区）

- `View.glassProminentButton(tint:)`：主行动按钮双路——
  iOS 26 用系统 .glassProminent，旧系统保持 .borderedProminent。
- `View.glassButton(tint:)`：次级按钮双路——iOS 26 用系统
  .glass，旧系统保持 .bordered。
  本轮各页按钮一律经这两个辅助换样式，标签与修饰
  （font / controlSize / disabled / tint）原样保留。

### 逐页落点

1. **设置页（SettingsView.swift）**：卡片 VStack 整体入
   GlassGroup；作者/配对两张入口行卡面（原 secondarySystem-
   Background + 阴影）→ glassSurface（圆角 20，interactive）；
   #128 搬来的两张日志卡（刷入日志 / 活动日志，logCard）
   同换 glassSurface（圆角 20）。页面背景与结构不动。
   作者页（AuthorView.swift）「抖音主页」主行动按钮 →
   glassProminentButton()。
2. **配对区（ContentView.swift PairingTab / VPNStatusRow，
   自设置页 sheet 打开）**：头行版本 chip → glassSurface
   (Capsule，蓝 tint)；本机配对 PIN 面板（原橙色淡底）→
   glassSurface（圆角 14，橙 tint）；VPNStatusRow 内置回环
   说明面板（绿）/ LocalDevVPN 说明面板（橙）→ glassSurface
   （圆角 10，对应 tint）。按钮换双路：配对本机 →
   glassProminentButton()；打开设置 App → glassProminent-
   Button（橙）；复制 PIN → glassButton（橙）；取消配对 →
   glassButton（红）；文稿配对文件「使用」、VPNStatusRow 的
   关闭/开启内置回环与刷新按钮 → glassButton()。
   PairingTab 其余 Form Section 为系统行表面，iOS 26 下由
   系统自动呈液态玻璃，未强行套壳。
3. **密码盘页（ContentView.swift PasscodeThemeTab /
   ApplyThemeSection / ThemeCreatorSection）**：两处刷入
   flashButton（正常态 + 失败重试态）→ glassProminentButton
   （重试带橙 tint）；文稿主题「载入」→ glassProminent-
   Button()；次级按钮（在主题制作中编辑 / 导出 .passthm /
   清空全部 / 移除·卸载主题）→ glassButton（破坏性带红
   tint）。刷入日志卡位于系统 Form Section 内（系统表面，
   iOS 26 自动玻璃），其内层 CompactLogView 自绘表面已
   随第 5 项统一玻璃化。PasscodeTargetSection 为系统 Form
   行，未动；KeypadPreviewView 是锁屏预览工作区本体（自绘
   深色磨砂即预览内容，与制作页画布同口径），未动。
   passthm 刷入与 Passcode 逻辑零改动。
4. **制作页（KeyframeEditorView.swift，MakerView 为页签壳）**：
   内容 VStack 入 GlassGroup；素材选择标签 pickerLabel →
   glassSurface（圆角 14，interactive）；时间轴卡
   timelineCard、导出卡 exportCard → glassSurface（圆角
   18）；「打关键帧」与「生成并加入壁纸库」按钮 →
   glassProminentButton()。画布 canvasSection、时间轴轨道
   与一切编辑/导出逻辑未动。
5. **共用日志组件（ContentView.swift CompactLogView）**：
   复制胶囊钮 → glassSurface(Capsule，interactive)；日志
   文本框（原 tertiarySystemBackground + 描边）→
   glassSurface（圆角 10）。该组件为设置页日志卡内层、
   密码盘刷入日志、配对页活动日志共用，一处改动三页一致。
6. **清理页（TendiesView.swift DevicePosterCleanupView）**：
   底部操作栏入 GlassGroup，栏面（原 .bar 材质）→
   glassSurface(Rectangle)；「清理所选」按钮 →
   glassProminentButton（红 tint）。列表本体为系统 List
   行（iOS 26 系统自动玻璃），未强行套壳；检测/删除逻辑
   零改动。

### 未动与已知残留

- TendiesEngine.swift、rust 树、受保护文件、CI workflow
  一概未动；#128 已玻璃化的壁纸页 / 全屏选择页 / 预览页 /
  底栏 dock 未重做。
- 上游 sheet（CreditsSheet / PairingGuideSheet /
  DonateView 等）不在本轮清单，其 bordered 按钮维持系统
  样式原样。
- 既有问题仅记录不扩修：AuthorView 页面背景写死
  Color.white（不跟随深色模式）；设置页背景为
  systemBackground 纯色，玻璃在其上折射内容有限——均属
  版式层问题，不在本轮「只换表面」范围。
- 本地核查：五文件 swiftc -parse 全过；推送前远程 head
  = 5d09bb2，六份将改文件远程 blob 与本地逐字节一致、
  无分叉。真机玻璃质感未验证，等 Sage 装机验。

## 改动登记 · 扇形/展开页四项真机反馈修复（run #130，2026-11-02，Sage 录屏定点修）

在本地 marker commit 1862f3c（#129，未推送）之上的一轮定点
修复，**本轮只本地提交、不推送**（推送待 Sage 发话）。动
TendiesView.swift（扇形区 fanZone/fanCard、页面根部）与
ImportedWallpapersView.swift（全屏选择页）两文件；AppViewModel
未改（批量删除复用其既有 deleteTendie）。卡片尺寸 150×200、
基础旋转档位 [-8,-4,0,4,8]、交叠量 -62 等定稿参数未动。

### 1. 扇形长按菜单脱锚（症状 → 改法）

症状（Sage 录屏）：长按扇形卡（「云朵」）弹出「详情/删除」
时，扇形在菜单背后仍在滑动/移位，菜单与被按卡片脱锚、看着
像浮空。原实现：contextMenu 挂在 rotationEffect 之后、横滑
ScrollView 内的 Button 上——变换后的视图做 contextMenu 预览
锚点本就不稳，ScrollView 惯性也不被长按打断。
改法：扇形卡改手势实现（去 Button+contextMenu）：onTapGesture
点按选中、onLongPressGesture(0.45s) 只设页面状态 fanMenuTarget；
fanZone 的 ScrollView 加 .scrollDisabled(fanMenuTarget != nil)
在菜单呈现期间冻结惯性；菜单改由页面根部 confirmationDialog
（presenting: fanMenuTarget，标题=壁纸名）稳定呈现同一组动作
「详情 / 删除（destructive，走 vm.deleteTendie）/ 取消」。
长按触发附一次轻触觉。视觉与其余行为不变。
展开页格子同标处理：ImportedWallpapersView 的 cell 同样去
contextMenu，改 onTapGesture 勾选 + onLongPressGesture 设
menuTarget、ScrollView .scrollDisabled(menuTarget != nil)、
页面根 confirmationDialog 呈现同一组动作。

### 2. 扇形滑动 Q 弹（症状 → 改法）

症状：扇形横滑是「死的」，无苹果信息式弹性与交互反馈。
改法（只加联动与弹簧，不动定稿几何参数）：fanZone 的
ScrollView 加 .scrollTargetBehavior(.viewAligned)、HStack 加
.scrollTargetLayout()，停下时弹簧式吸附到整卡；fanCard 加
.scrollTransition(.interactive)：以 t=min(1,|phase.value|)
插值——中心卡 scale 1.05 且 rotationEffect 叠加 -base*(1-t)
把基础旋转抵消回正，越往两侧 scale 回到 1.0、旋转回到基础
档位；点按选中加选中态 scaleEffect 1.04 + spring(response
0.3, dampingFraction 0.55) 回弹与一次轻触觉（UIImpactFeedback-
Generator .light，沿用 App 内既有口径；展开页格子点按/长按
同附）。

### 3. 展开页格子大小不一致 + 头部副行重叠（症状 → 改法）

症状（Sage 录屏）：网格格子高度参差（像瀑布流）；顶部
「共 N 张 · 已选 M 张…」副行文字与第一行格子重叠糊在一起。
根因：旧 cell 用 .aspectRatio(0.72, .fit)，格高由内容反推
（有图时按图片原始像素、无图时占位视图无固有尺寸），
LazyVGrid 行高因此不齐且首行测量与副行挤压。
改法：cell 改固定帧——列宽仍由 GridItem(.flexible()) 定，
格高固定 172pt（v8 设计稿量级），TendieThumbnailView 以
frame(maxWidth/maxHeight: .infinity) 填满、超出由 clipShape
裁切（图片为 resizable .fill，天然填充裁切），名称行与勾选
徽标位置统一；头部副行维持 VStack 普通流式布局（副行在
ScrollView 内、网格 padding(.top, 14)），固定格高后任何
滚动位置不再重叠。底栏与系统 dock 的关系维持 #128 现状。

### 4. 展开页底部栏新增「删除」（需求 → 改法）

底部栏布局改：左「已选 N 张」、右依次「删除」「完成」。
「删除」用 #129 共用 glassButton(tint: .red) 红色玻璃次级
样式（role: .destructive），已选 0 张时 disabled + opacity
0.45。点按先弹 confirmationDialog「删除所选壁纸」：破坏性
按钮「删除 N 张」，message 说明「将把所选 N 张壁纸从本机
库中移除，本地文件一并删除」；确认后 deleteSelected() 逐项
调用 vm.deleteTendie(item:)——与长按单删完全相同的路径
（删本地文件 + 移除条目 + saveTendieItems），删后条目消失、
选择集自动剔除，计数与壁纸页扇形（共用同一 vm.tendieItems）
同步刷新。

### 未动与未验证

- TendiesEngine.swift、rust 树、受保护文件、CI workflow、
  #129 玻璃改动一概未动；文案除新增删除确认外未动。
- 本地核查：两文件 swiftc -parse（Swift 6.1，本机回退分支
  编译器）全过；玻璃分支（#if compiler(>=6.2)）本机编不动
  属既有常态，本轮新增代码未用 6.2 门控 API（scrollTransition /
  scrollTargetBehavior / confirmationDialog 均为 iOS 17 基线
  API），仍待推送后 CI 真 Xcode 26 编译为准。
- 未验证项（归 Sage 真机）：长按菜单呈现时扇形是否完全
  冻结、confirmationDialog 的观感是否合意；Q 弹的实际手感
  （viewAligned 吸附点、scrollTransition 中心回正幅度）；
  格子 172 固定高在真机三列宽下的裁切观感；批量删除全链路。

## 改动登记 · 壁纸页底部 sheet 去液态玻璃（run #131，2026-11-02，Sage 真机反馈定的例外）

在本地 commit 9cb0a53（#130，未推送）之上的一轮定点回退，
**本轮只本地提交、不推送**（推送待 Sage 发话）。Sage 看了
#128 真机效果后点名：壁纸页底部 sheet 这一块不要液态玻璃，
改回纯色平面。只动 TendiesView.swift 的 sheet 区表面处理；
布局、尺寸、文案、行为、状态判定与 #128/#130 完全一致。

### 改法（glassSurface / GlassGroup / glassProminent → 实色）

- sheet 面板（bottomSheet）：去掉 GlassGroup 包裹与面板
  glassSurface，改实色背景 #F7F7FA（新增静态色 sheetBackground，
  圆角 28 不变）+ 轻柔投影（black 0.05 / radius 15 / y -4）。
- 胶囊状态条（statusCapsule）：glassSurface(Capsule) 改
  Color.white 实色胶囊填充，原有轻投影保留。
- 刷入主按钮（flashActionButton）：原 iOS 26 .glassProminent
  与旧系统自绘回退双路合并为单一实色实现——纯蓝 #0071E3
  （新增静态色 flashBlue）实色胶囊、高 52、白字，禁用时
  同色 0.45 透明度，投影改蓝 0.28 / radius 11 / y 5；
  legacyFlashButton 随之删除。
- 刷入中进度卡（flashButton 的 running 分支）：glassSurface
  改纯白面（圆角 20）+ 轻投影。
- 导入壁纸宽条（importTile）、双列瓷砖共用实现（sheetTile）、
  清除壁纸宽条（cleanupTile）：glassSurface(圆角 20,
  interactive) 一律改纯白面（圆角 20）+ 轻投影（black 0.04 /
  radius 8 / y 2）。
- 错误横幅（页面顶部 vm.errorMessage 横幅）：glassSurface
  （红 tint）改实色浅红面 Color.red.opacity(0.08)（圆角 14）。

### 不动

- 共用玻璃辅助定义（glassSurface / GlassGroup /
  glassProminentButton / glassButton）原样保留，其他页面
  （#129 覆盖的设置 / 配对 / 密码盘 / 制作 / 清理页）继续用。
- 页头展开圆钮的 glassSurface 玻璃面保留；全屏选择页
  （ImportedWallpapersView）底栏玻璃与红色 glassButton
  删除钮保留；#33 预览页、底栏透镜 dock 不动。
- TendiesEngine.swift、rust 树、受保护文件、CI workflow
  一概未动。

### 未验证

- 本地核查：TendiesView.swift swiftc -parse（Swift 6.1，
  本机回退分支编译器）通过；本轮改动未引入新的 6.2 门控
  API，最终仍以推送后 CI 真 Xcode 26 编译为准。
- 未验证项（归 Sage 真机）：sheet 区纯色平面与页面其余
  玻璃表面（展开钮、选择页）并存时的整体观感。

## 改动登记 · 扇形几何改造 + 展开页固定比例格（run #132，2026-11-02，Sage 定稿试作）

在远程 head 23f477d（#129–#131 合并包）之上的一轮定点改版，
Sage 03:43 发话「来一版试试看」批准出包。动 TendiesView.swift
（扇形区 fanZone/fanCard）与 ImportedWallpapersView.swift
（全屏选择页 cell）两文件；sheet、选择页底栏与批量删除、
长按新菜单、其他页面一概未动。

### A. 扇形几何改造（症状 → 改法）

症状（Sage 真机截图）：扇形绕卡中心旋转 + 交叠 -62，整堆
卡像被打乱的扑克——每张大半个画面被邻卡盖住，卡名伸进
邻卡区域被压掉一半，扇面没有秩序。
改法（主线出稿 wallpaper-page-fan2.png，Sage 点头试作）：
- 旋转支点从卡中心挪到卡片底边再往下约 15% 卡高处
  （rotationEffect anchor = UnitPoint(0.5, 1.15)）：卡片像
  从底部捏住的一把牌，上张下收。静态基础旋转与
  scrollTransition 的回正插值（-base*(1-t)）共用同一支点，
  中心卡角度仍插值到 0。
- 交叠量 -62 → -34：150pt 宽卡每张露出约 116pt（三分之二
  强），画面与卡名可读。卡尺寸 150×200、角度阶梯 ±8/±4
  不变。
- Q 弹保留并微调：scrollTransition 中心放大 1.05 → 1.06，
  新增 offset(y: -6*(1-t)) 中心卡轻微上浮；viewAligned
  吸附、点选弹簧（1.04 + spring 0.3/0.55）+ 轻触觉不变。
- 卡名防压：名称 Text 加 frame(maxWidth: 110) + 尾部截断，
  只占每张卡的可见条，不再伸进被邻卡盖住的区域。
- 缩略图口径审计：扇形卡走共用 TendieThumbnailView（内部
  即 resizable + aspectRatio(.fill)），fanCard 侧原已有
  frame(150, 200) + 圆角 clipShape，本轮补显式 .clipped()，
  与 B 同为填充裁剪口径。

### B. 展开页固定比例格（症状 → 改法）

症状（Sage 真机截图）：#130 定格高 172 后，格内缩略图仍
按原生比例 aspect-fit 式显示——横图上下留白、竖图撑满，
视觉上仍参差。Sage 原话：「把多出来的比例直接裁剪掉。」
改法：弃固定高，改固定比例格——cell 以
aspectRatio(3.0/4.0, .fit) 定框：三列灵活列宽决定宽、高
随之（竖 3:4，宽:高，高大于宽；**此比例为 Sage
2026-11-02 所定「暂时」规格**，后续可再调）。缩略图
（TendieThumbnailView 的 resizable + scaledToFill 口径）
以 frame(maxWidth/maxHeight: .infinity) + .clipped() 填满
整格、多余部分居中裁掉；占位图同框撑满。名字/勾选徽章
位置不变；cell 内已无 aspectRatio(.fit)/scaledToFit 残留。

### 未动与未验证

- AppViewModel、TendiesEngine.swift、rust 树、受保护文件、
  CI workflow 一概未动；工作区其余既存脏改动未带入本轮。
- 本地核查：两文件 swiftc -parse（Swift 6.1）通过；本轮
  新增代码未用 6.2 门控 API，最终以推送后 CI 真 Xcode 26
  编译为准。
- 未验证项（归 Sage 真机）：底部支点扇开的实际观感与
  viewAligned 吸附落点、上浮幅度；3:4 格在真机三列宽下
  的裁切观感（人物类竖图裁左右、横图裁上下的取舍）。
