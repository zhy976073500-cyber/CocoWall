import SwiftUI
import AirliftFFI

@main
struct AirCardApp: App {
    @StateObject private var vm = AppViewModel()
    /// run #170：切回前台即刷新回环探活——用户在别的 App 里
    /// 连上 LocalDevVPN 后切回 CocoWall 时，已显示的页面
    /// onAppear 不重跑，只靠进页刷新会让 vm.vpnUp 一直停在
    /// 旧值、外部档显示滞后；回到前台即重扫一次接口，胶囊
    /// 与配对页随之刷新。refreshNetworkStatus 只读轻量检查
    /// + 同步目标 host，不动隧道本身。
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Route Rust tracing/idevice logs into the app's vm log array.
        // run #159（发布日志总闸）：总闸关闭时不装这条桥——
        // Rust/FFI 的详细日志从源头不进入 App（敏感日志句
        // 不产生）；错误信息由各 Swift 流程自己的错误路径
        // 呈现，不依赖这条明细流。开关见 Utilities 的
        // CWLogGate，覆盖清单见 SPEC run #159 第四节。
        if CWLogGate.detailedLogsEnabled {
            al_log_init({ _, msg in
                guard let msg = msg else { return }
                let line = String(cString: msg)
                DispatchQueue.main.async {
                    AppViewModel.sharedLogSink?(line)
                }
            }, nil)
        }

        // Point the sink at the vm once it's created (set in AppViewModel.init).
        // Ensure ALGetGrappaToken symbol is retained and linked into the binary
        _ = ALGetGrappaToken(0, 0, 0, nil, 0, nil, nil, 0)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                // 统一智能接收（run #165）：系统「打开方式」
                // 送进来的文件统一走 vm 的接路由器按内容
                // 分类（壁纸包 / Base64 编码包 / 配对文件），
                // 见 IntakeRouter.swift。此前 App 没有任何
                // onOpenURL 处理，外部打开只落 Inbox 无人接。
                .onOpenURL { url in
                    vm.handleOpenInURL(url)
                }
                // run #170：切回前台刷新回环探活（见 scenePhase
                // 注释）；Task 跳主线程，避开 onChange 闭包与
                // @MainActor vm 之间的隔离问题（本项目同类写
                // 法，见 AppViewModel 多处 Task { @MainActor in }）。
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { @MainActor in vm.refreshNetworkStatus() }
                    }
                }
        }
    }
}

@_silgen_name("ALGetGrappaToken")
func ALGetGrappaToken(
    _ inVersion: UInt32,
    _ inDeviceType: UInt32,
    _ inProtocolVersion: UInt32,
    _ outBuf: UnsafeMutablePointer<UInt8>?,
    _ maxLen: Int,
    _ outLen: UnsafeMutablePointer<Int>?,
    _ errBuf: UnsafeMutablePointer<CChar>?,
    _ errLen: Int
) -> Int32

