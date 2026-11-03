import Foundation
import Network

/// WiFi 连接状态监听（run #151）：NWPathMonitor 只认 WiFi 接口
/// （currentPath.usesInterfaceType(.wifi) 且路径 satisfied）。
/// 生命周期由使用方页面驱动——页面出现时 start()、消失时
/// stop()，不留常驻监听。
final class WiFiMonitor: ObservableObject {

    @Published private(set) var isWiFiConnected = false

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.coco.cocowall.wifi-monitor")

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
                && path.usesInterfaceType(.wifi)
            DispatchQueue.main.async {
                self?.isWiFiConnected = connected
            }
        }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}
