import Foundation

// MARK: - 关键帧缓动预设

/// 关键帧缓动预设：与 CAMediaTimingFunction 的四个命名预设一一对应。
/// 三次贝塞尔控制点与系统预设等价——编辑器预览的插值和导出 CAML 里
/// 写给每段的 timingFunction 命名同源，保证所见即所导。
enum KeyframeEasing: String, CaseIterable, Identifiable, Codable {
    case linear
    case easeIn
    case easeOut
    case easeInEaseOut

    var id: String { rawValue }

    /// CAML 里 timingFunction 属性的命名（与 CAMediaTimingFunction 预设名一致）。
    var camlName: String { rawValue }

    var displayName: String {
        switch self {
        case .linear: return "线性"
        case .easeIn: return "缓入"
        case .easeOut: return "缓出"
        case .easeInEaseOut: return "缓入缓出"
        }
    }

    /// 三次贝塞尔控制点 (x1, y1, x2, y2)，两端固定为 (0,0)、(1,1)。
    var controlPoints: (x1: Double, y1: Double, x2: Double, y2: Double) {
        switch self {
        case .linear: return (0, 0, 1, 1)
        case .easeIn: return (0.42, 0, 1, 1)
        case .easeOut: return (0, 0, 0.58, 1)
        case .easeInEaseOut: return (0.42, 0, 0.58, 1)
        }
    }

    /// 把线性进度 x 映射为缓动后的进度 y：先解贝塞尔 x(t) = x，再取 y(t)。
    /// 与 CAMediaTimingFunction 的求值方式等价。
    func evaluate(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let p = controlPoints

        func sampleX(_ t: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * p.x1 + 3 * u * t * t * p.x2 + t * t * t
        }
        func sampleY(_ t: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * p.y1 + 3 * u * t * t * p.y2 + t * t * t
        }
        func sampleDerivativeX(_ t: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * p.x1 + 6 * u * t * (p.x2 - p.x1) + 3 * t * t * (1 - p.x2)
        }

        // Newton 迭代，初值 t = x。
        var t = x
        for _ in 0..<8 {
            let error = sampleX(t) - x
            if abs(error) < 1e-6 { return sampleY(t) }
            let slope = sampleDerivativeX(t)
            if abs(slope) < 1e-6 { break }
            t -= error / slope
            if t < 0 || t > 1 { break }
        }
        // 回退二分法。
        var low = 0.0, high = 1.0
        t = x
        while high - low > 1e-6 {
            if sampleX(t) < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return sampleY(t)
    }
}

// MARK: - 关键帧与工程

/// 一帧：某个时刻浮动图层的中心位置。
/// position 用编辑器画布坐标：画布 390×844pt，原点左上，
/// x 自左向右 0…390，y 自上向下 0…844。
/// 导出时由 TendiesExporter 统一换算为 CAML 坐标 (x, 844 − y)
/// （2026-11-01 真机验证定案：CAML 为左下原点、y 向上）。
struct AnimKeyframe: Identifiable, Equatable {
    var id = UUID()
    var time: Double
    var position: CGPoint
    /// 从本帧到下一帧这一段的缓动（末帧的缓动作用于绕回首帧的收尾段）。
    var easing: KeyframeEasing = .easeInEaseOut
}

/// 相邻两帧之间的一段运动；预览插值与导出编译共用同一份段列表。
struct KeyframeSegment: Equatable {
    var startTime: Double
    var duration: Double
    var from: CGPoint
    var to: CGPoint
    var easing: KeyframeEasing
}

/// 关键帧工程：一条时间轴 + 若干位置关键帧（单个浮动图层）。
struct KeyframeProject: Equatable {
    static let canvasSize = CGSize(width: 390, height: 844)

    /// 总时长（秒），回环播放。
    var duration: Double = 4
    /// 关键帧，恒按 time 升序。
    var keyframes: [AnimKeyframe] = []

    // MARK: 段计算（回环语义）

    /// 全部运动段：相邻帧之间逐段相连，外加末帧绕回首帧的收尾段
    /// （从末帧时刻起到总时长结束，正好在回环点落回首帧位置）。
    /// 首帧时刻之前没有段——图层停在首帧位置（导出时即图层的模型位置）。
    func segments() -> [KeyframeSegment] {
        guard keyframes.count >= 2 else { return [] }
        var result: [KeyframeSegment] = []
        for i in 0..<(keyframes.count - 1) {
            let d = keyframes[i + 1].time - keyframes[i].time
            if d > 0.0001 {
                result.append(KeyframeSegment(
                    startTime: keyframes[i].time, duration: d,
                    from: keyframes[i].position, to: keyframes[i + 1].position,
                    easing: keyframes[i].easing))
            }
        }
        if let last = keyframes.last, let first = keyframes.first {
            let wrap = duration - last.time
            if wrap > 0.0001 {
                result.append(KeyframeSegment(
                    startTime: last.time, duration: wrap,
                    from: last.position, to: first.position,
                    easing: last.easing))
            }
        }
        return result
    }

    /// 任意时刻的图层位置：预览与导出共用同一套插值/缓动。
    /// 无关键帧返回 nil；只有一个关键帧时恒为该帧位置（静态）。
    func position(at t: Double) -> CGPoint? {
        guard let first = keyframes.first else { return nil }
        guard keyframes.count > 1 else { return first.position }
        let tt = min(max(t, 0), duration)
        if tt < first.time { return first.position }
        for seg in segments() {
            if tt >= seg.startTime && tt <= seg.startTime + seg.duration {
                let progress = seg.duration > 0 ? (tt - seg.startTime) / seg.duration : 1
                let e = seg.easing.evaluate(progress)
                return CGPoint(
                    x: seg.from.x + (seg.to.x - seg.from.x) * CGFloat(e),
                    y: seg.from.y + (seg.to.y - seg.from.y) * CGFloat(e))
            }
        }
        return first.position
    }

    // MARK: 编辑操作

    /// 在指定时刻记录一帧：同刻已有帧则覆盖其位置（保留原缓动），否则插入新帧。
    @discardableResult
    mutating func recordKeyframe(time: Double, position: CGPoint) -> AnimKeyframe {
        let t = min(max(time, 0), duration)
        if let idx = keyframes.firstIndex(where: { abs($0.time - t) < 0.01 }) {
            keyframes[idx].position = position
            return keyframes[idx]
        }
        let frame = AnimKeyframe(time: t, position: position)
        keyframes.append(frame)
        keyframes.sort { $0.time < $1.time }
        return frame
    }

    mutating func removeKeyframe(id: UUID) {
        keyframes.removeAll { $0.id == id }
    }

    /// 改总时长后把越界的帧钳回范围内，并去掉钳制后同刻的重复帧（保留先出现者）。
    mutating func clampKeyframesToDuration() {
        for i in keyframes.indices {
            keyframes[i].time = min(max(keyframes[i].time, 0), duration)
        }
        keyframes.sort { $0.time < $1.time }
        var deduped: [AnimKeyframe] = []
        for frame in keyframes {
            if let last = deduped.last, abs(last.time - frame.time) < 0.01 { continue }
            deduped.append(frame)
        }
        keyframes = deduped
    }
}
