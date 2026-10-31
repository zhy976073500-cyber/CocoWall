import ActivityKit
import Foundation

/// Live Activity attributes for the on-device pairing flow.
///
/// This file is compiled into BOTH the app target and the
/// PairingLiveActivity widget extension target (see project.yml) so the
/// two processes agree on the content-state schema. Keep it free of any
/// app-only or extension-only dependencies.
struct PairingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            /// Host is broadcasting; no PIN yet.
            case pairing
            /// PIN generated — show it so the user can type it in Settings.
            case pinReady
            /// Pairing file written.
            case succeeded
            /// Failed or cancelled by the user.
            case failed
        }

        var phase: Phase
        /// The 6-digit pairing PIN; only meaningful in `.pinReady`.
        var pin: String?
        /// Short result line; only meaningful in `.failed`.
        var message: String?

        init(phase: Phase, pin: String? = nil, message: String? = nil) {
            self.phase = phase
            self.pin = pin
            self.message = message
        }

        // MARK: Display copy (shared by island + lock-screen banner)

        var statusText: String {
            switch phase {
            case .pairing: return "配对中"
            case .pinReady: return "待输入"
            case .succeeded: return "配对成功"
            case .failed: return message ?? "配对失败"
            }
        }

        var compactText: String {
            switch phase {
            case .pairing: return "配对中"
            case .pinReady: return pin ?? ""
            case .succeeded: return "成功"
            case .failed: return "失败"
            }
        }

        var iconName: String {
            switch phase {
            case .pairing: return "antenna.radiowaves.left.and.right"
            case .pinReady: return "textformat.123"
            case .succeeded: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            }
        }

        var detailText: String {
            switch phase {
            case .pairing: return "正在广播配对服务，去设置里继续"
            case .pinReady: return "设置 › 隐私与安全性 › 开发者模式 › 与 CocoWall 配对"
            case .succeeded: return "配对文件已生成，可以开始刷入"
            case .failed: return "回到 CocoWall 可重新发起配对"
            }
        }
    }

    init() {}
}
