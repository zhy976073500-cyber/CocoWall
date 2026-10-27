# CocoWall

交互壁纸工具（v1 只做壁纸）：导入 .tendies → 经内置回环隧道 + 配对写入 PosterBoard → App 内管理与移除。

- 规格与格式规范：[SPEC.md](SPEC.md)
- 写入路径调研：research/write-path.md（2026-10-28 已还原 Vellum 的 airlift/AirTraffic 注入流水线，未决项在文末）
- 工程：XcodeGen 描述（project.yml），`xcodegen generate` 生成 .xcodeproj；GitHub Actions 出未签名 IPA。
- 最低系统 iOS 17.0，仅 iPhone。
