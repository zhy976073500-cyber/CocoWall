# 壁纸预览探针（TendiesPreview）

Phase 0 探针：验证在普通侧载 iPhone App 的沙盒里、**不刷入、不动 PosterBoard**，
能否直接加载 `.tendies` 里的 `.ca` 包并播放——持续动画 + Locked→Unlock
状态切换（解锁动画）。规格：`../SPEC.md`。技术成熟后才集成进 CocoWall，
本工程独立存在，不依赖 CocoWall 的任何代码/资源。

- Bundle id：`com.coco.tendiespreview`，显示名「壁纸预览探针」，iOS 17.0+，iPhone only
- 私有 API（CAPackage / CAMLParser / CAStateController）**全部运行时动态调用**
  （NSClassFromString + responds(to:) 守卫 + IMP/perform），不硬链接任何私有符号；
  任一类/方法缺失只会写进诊断面板，不会启动崩溃或链接失败。
- ZIP 解包为工程内纯 Swift 最小实现（`ZipExtractor.swift`）：中央目录解析镜像
  CocoWall 已验证的纯 Swift 读法，DEFLATE 走系统 Compression 框架，无第三方依赖。
- 包内 JS（如 7400 Background 的 `Root_Layer.js`）只在诊断里登记，**永不执行**。

## 工程结构

| 文件 | 职责 |
|---|---|
| `Sources/App/TendiesPreviewApp.swift` | 入口；持有 ViewModel，承接「打开方式」送入的 .tendies |
| `Sources/App/ContentView.swift` | 探针 UI：导入、画布、脚本按钮、全部状态按钮、诊断面板 |
| `Sources/App/LayerCanvasView.swift` | 承载 CALayer 树的 UIView（不碰图层时间，动画自然播放） |
| `Sources/App/PreviewViewModel.swift` | 导入/加载/叠层/切状态/剧本/连切自检/诊断汇总 |
| `Sources/App/ZipExtractor.swift` | 无依赖 ZIP 读取（STORE + DEFLATE） |
| `Sources/App/TendiesPackage.swift` | 扫描 .ca 包 + CAML 文本挖掘（状态名/过渡数/src/缺失资源） |
| `Sources/App/PrivateCALoader.swift` | CAPackage 首选、CAMLParser 次选的动态加载，含资源 delegate |
| `Sources/App/StateControllerBridge.swift` | CAStateController/CAState 动态桥（枚举/初始/切换/按名构造兜底） |
| `Sources/App/DynamicRuntime.swift` | 动态调用原语（alloc/getter/perform/IMP），保留语义偏向泄漏而非崩溃 |
| `ci/build-ipa.yml` | CI（需 Sage 网页端放到 `.github/workflows/build-ipa.yml`，GitHub App 无权推 workflow，同 CocoWall/CocoFix 惯例） |

## 验收门六项 · 逐项自测方法

测试包：7400（`upload-2.tendies`）、Cubes（`upload.tendies`，iPad 包）、
keyframe-spike（自制对照组，已过真机刷入验证）。每项都以探针内录屏 +
CocoWall 刷入后的真机录屏逐眼对比为准。

1. **解析** — 依次导入三包。诊断里每个 `.ca` 应出现「加载成功 via …」，
   且图层计数 > 1。任一包出现「两路均失败」，把该包诊断段落整段留档，
   先判断死在 CAPackage 还是 CAMLParser、是类不存在还是 parse 返回 false。
2. **静态画面** — 导入 7400，停在 Locked 态截屏，与真机锁屏截图并排看：
   背景/浮动层/前景层是否齐、位置是否偏。Cubes 同理看 Lock PortraitUp Light。
3. **持续动画** — 导入 Cubes：立方体应持续旋转不停；导入 keyframe-spike：
   橙点应沿对角线往返。导入后不要切状态，先录 10 秒确认动画自启。
4. **解锁动画** — 导入 7400，点「开屏→解锁」：Locked 停 1.5 秒后应按包内
   弹簧过渡切到 Unlock，与真机解锁录屏比节奏（不是瞬切、不是默认 0.25s 淡变）。
5. **状态完整** — 导入 Cubes：状态区应列出 24 个组合状态；逐点
   Lock/Home/Sleep × PortraitUp Light 几个关键项，画面应随之切换；
   再切到 Dark 变体确认外观状态也被枚举到。
6. **稳定性** — 任一包点「连切 20 次自检」：日志应走到「自检完成」，
   进程不崩；同时肉眼看画布有无残影叠影。

不过线的处理（SPEC 定）：先定位死在哪一层（解析器/状态类/资源），
能绕则绕（如 LKState→CAState 映射）；绕不过的包在正式版必须显式标记
「App 内预览不完整」，不许静默给假效果。

## 已知未验点（如实）

- **Swift 代码未在本机编译过**（开发机无 Xcode）。首轮 CI 预计需要
  迭代修错，重点风险：AnyObject 动态调用与 IMP 签名的类型桥接、
  `CGImage as AnyObject` 的返回桥接、CAMLParser/CAPackage 在
  iOS 27 QuartzCore 上的实际选择子集合与本代码的尝试顺序是否对齐。
- CAPackage 的四个候选入口按「公开头文件 + 运行时惯例」排序尝试，
  iOS 上究竟哪个存在、rootLayer 是否可读，未经真机验证。
- CAMLParser 解析时相对资源（`src="assets/…"`）的解析基路径行为
  未验：已用 `-parseContentsOfURL:` + 资源 delegate 双保险，若两者
  都不被调用，图片层会空 — 诊断里的「缺失资源」与画面对照可判。
- CAStateController 是否接受 LKState 风格的状态对象、按名构造的
  状态对象能否被 setState 认领（identity vs name 匹配），未验；
  探针的日志会把这三条路径分开记录（精确匹配/同族变体/按名构造）。
- Cubes 是 iPad 几何包（根图层 3176×3176），探针用 fit 层等比缩放
  进画布；其 24 状态中横屏变体在竖屏画布上只验「能切」，不验构图。
