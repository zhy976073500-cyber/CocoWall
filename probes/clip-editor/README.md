# 剪辑制作探针（ClipEditor）

剪辑式 .tendies 制作器探针（v3）：把壁纸制作改成 Blurrr 式剪辑
手感（固定播放头时间轴 + clip 轨道 + 模板动作 + 关键帧轨迹），
导出按真包结构生成三状态 .tendies。给 Sage 真机试用，不是正式版。
bundle id `com.coco.clipeditor`，显示名「剪辑制作探针」，iOS 17+，
SwiftUI，无第三方依赖。

## 定案口径（2026-11-02 / 11-04，不许改）

- 部分（状态）3 个：开屏 Locked / 主屏 Unlock / 熄屏 Sleep。
  编辑器只编开屏、主屏；熄屏导出时自动生成（= 开屏摆位，
  透明度 ×0.5 压暗）。
- 图层 3 组对应 3 个 .ca：背景 / 浮动（多图层，不设上限）/
  前景（文字、扫光，渲染成 PNG）。组固定。
- 背景两张（v2，Sage 试 v1 后定）：开屏背景 + 主屏背景各一张；
  只设一张时另一部分共用这张（退化单图层）。两张都设时靠状态
  透明度绑定分工，切换时交叉淡变。
- 帧口径 60fps：循环默认 240 帧（可选 180/240/360）；
  过渡默认 48 帧（可调 24–60）。
- 动画分工不抢属性：位置/大小/透明度归状态（过渡靠弹簧插值）；
  持续动作归模板，只碰 transform。每图层最多 2 个模板
  （动作槽 + 缩放旋转槽），带幅度/速度滑杆。
- clip 拖两头 = 淡入/淡出帧数。
- 过渡设置（v2）：「开屏入场」（亮屏淡入，管 *→Locked /
  Locked→* 两条过渡，类型渐显/无，帧数与弹簧独立）与「解锁
  过渡」（管其余过渡，类型三选一：渐变（默认）/ 摆位弹簧 /
  渐变+摆位）。入口：状态面板两组 + 背景轨动画段块点开。

## 时间线四段式（v3，2026-11-04 Sage 拍板）

动画不是设置项，而是时间线上实实在在的段。一条线从左到右：

**开屏动画 ｜ 开屏 ｜ 解锁动画 ｜ 主屏**

- 动画段（开屏动画 / 解锁动画，暖色标出）：任意图层（含两张
  背景、浮动、文字、特效）可打关键帧——选中图层 → 段内拖播放
  头 → 画布拖位置、面板滑杆调缩放/旋转/透明度、前移/后移调
  层级 → 点「打关键帧」记下该时刻整套属性（x, y, scale,
  rotation, opacity, zIndex）。同进度重复打帧 = 覆盖；轨道上
  菱形标记可点选、删除；帧间预览按 smoothstep 平滑插值；画布
  随播放头逐帧渲染轨迹。
- 段的编辑长度只是排舞的尺子：开屏动画段默认 3 秒、解锁动画
  段默认 2 秒，各可在 1–8 秒内调（段设置里）；导出时长不按
  它走（见下）。
- 衔接共用同一份数据：开屏动画段最后一帧的姿态 = 开屏摆位
  （双向同步，改哪边都一样）；解锁动画段起点 = 开屏摆位、
  终点 = 主屏摆位（端点由两套摆位充当，只存中间帧）。
- 循环段（开屏 / 主屏）：状态摆位 + 模板动画，与 v2 相同；
  顶栏页签保留为快捷跳转（点页签 = 播放头跳到对应循环段）。

## 导出：轨迹带走、时长重算

- 开屏动画段 → 每图层导出 CAKeyframeAnimation：关键帧时刻按
  段编辑长度归一化为进度 0…1 写 keyTimes；每个有变化的属性
  一条（position 用点列、transform.scale 为相对状态尺寸的
  倍率、transform.rotation.z、opacity）；duration = 开屏入场
  帧数（默认 48 帧 = 0.8s），repeatCount=1、fillMode=forwards
  不回弹。状态值 Locked = 轨迹末帧；层级（zIndex）不做动画，
  只取末帧值写 CALayer 的 zPosition。
- 解锁动画段 → 起点/终点落为 Locked/Unlock 状态值 + 过渡
  （渐变 = opacity 弹簧等，时长 = 解锁过渡帧数，默认 48）；
  **段内中间关键帧本轮只用于编辑器预览与端点提取，不写入
  包**——系统状态切换由弹簧驱动，无法强制走中间点。App 内
  导出提示与本文件都如实写明。
- 无关键帧的图层完全走 v2 老路（状态值 + 模板动画）。

## 导出结构

文件集合镜像已真机验证的 TendiesExporter / keyframe-spike 包
（descriptor、providerInfo、userInfo、Wallpaper.plist、每 .ca 的
index.xml / assetManifest.caml / main.caml / assets、STORE zip）。
状态与动画写法镜像样本包 33_1_lng7（重打包 7400）：三 LKState ×
每图层 5 条 SetValue、6 条通配过渡（CASpringAnimation，弹簧三档：
跟手 300/50/2 = 样本原值、柔和 180/38/2、带弹 260/22/2，
duration = 对应帧数/60）、模板写 CAKeyframeAnimation（transform.*，
一圈 = 循环时长）。identifier 为随机 8xxx 四位，descriptor UUID 随机，
family = CocoClip。
过渡元素按对与类型挂（v2）：入场对（*→Locked、Locked→*）用入场
设置，渐显时仅 opacity、「无」时不挂元素；其余四条用解锁过渡
设置——渐变仅 opacity（样本已验路径）、摆位弹簧仅 position/size
（**实验性，未真机验证**）、渐变+摆位五条全挂。双背景时
Background.ca 含两图层，状态透明度绑定：开屏背景
Locked=开屏值/Unlock=0/Sleep=×0.5，主屏背景
Locked=0/Unlock=主屏值/Sleep=0。

样本包多出的 suggestionMetadata.plist、RuntimeSnapshotMetadata、
homescreen supplement、complication/titleStyle 等属于图库/建议
元数据，不在验证包的「缺一不可」集合内，本探针不生成。

## 已知限制（如实）

- **Swift 未经编译**（开发机 Linux 无 Xcode）：靠 CI 验证。
- **开屏关键帧动画真机行为未验（v3 新增，最大风险）**：轨迹
  写成 CAKeyframeAnimation（repeatCount=1、fillMode=forwards），
  亮屏时 PosterBoard 是否会按写入时长从头重播这条入场动画，
  未知——有可能只在包加载时播一次、或被状态机盖过。与模板
  循环动画同 keyPath 并存时的合成次序同样未验。
- **解锁动画中间关键帧不入包**（v3 口径，见上）：只在编辑器
  预览生效，导出只有端点 + 弹簧过渡。
- **摆位弹簧过渡为实验性（v2 新增，未真机验证）**：给
  position/size 挂 CASpringAnimation 的写法样本包没有（样本
  只有 opacity），PosterBoard 是否按弹簧插值摆位需真机验；
  默认类型仍是已验的「渐变」。
- 状态 CAML 为我方首次生成（此前验证包的状态 elements 为空、
  样本包为 CAPlayground 生成）：三状态切换与弹簧过渡的真机
  行为需 Sage 刷入验证；特别是「过渡元素只挂 opacity、其余
  属性（position/size）切换时 PosterBoard 是否同弹簧插值」
  这一点样本如此、原理如此，但未经我方包实证。
- 淡入/淡出帧数只在编辑器预览生效，未写入导出包
  （opacity 与状态机抢属性的风险未验证，不硬塞）。
- 前景文字预览用 SwiftUI Text、导出用 UIKit 渲染 PNG，
  字形度量同源（bold 系统字体）但像素级不保证完全一致。
- 工程不落盘保存，杀 App 即丢（探针定位）。

## 构建

CocoWall 仓 `clip-editor-probe` 分支，工程在 `probes/clip-editor/`。
GitHub App 无权推 workflow 文件，需 Sage 在网页端把
`probes/clip-editor/ci/build-clip-editor.yml` 的内容新建为
`.github/workflows/build-clip-editor.yml`，推该分支或手动触发后
在 Actions 产物里取 `ClipEditor-unsigned.ipa`。
（注：workflow 已于 v1 时建好，v2 起 push 即自动构建。）
