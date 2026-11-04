import SwiftUI
import AirliftFFI

@main
struct AirCardApp: App {
    @StateObject private var vm = AppViewModel()

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

