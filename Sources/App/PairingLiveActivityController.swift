import ActivityKit
import Foundation

/// Drives the pairing Live Activity (Dynamic Island + lock-screen banner)
/// from the view-model layer. It only observes the pairing state that
/// `AppViewModel` already publishes (status / PIN / result); the pairing
/// machinery in `PairingController` is untouched.
///
/// Lifecycle: `begin()` when a pairing attempt starts, `pinReady(_:)`
/// when the 6-digit code exists, then exactly one of `succeeded()` /
/// `failed(message:)` which shows the result briefly and ends the
/// activity. All methods are no-ops when Live Activities are unavailable
/// or no activity is running.
@MainActor
final class PairingLiveActivityController {
    static let shared = PairingLiveActivityController()

    private var activity: Activity<PairingActivityAttributes>?
    private var lastPIN: String?

    private init() {}

    /// End any activities left over from a previous process (cold start).
    static func endStaleActivities() {
        Task {
            for activity in Activity<PairingActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func begin() {
        lastPIN = nil
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Drop stragglers from an earlier attempt in this process.
        for other in Activity<PairingActivityAttributes>.activities
        where other.id != activity?.id {
            Task { await other.end(nil, dismissalPolicy: .immediate) }
        }
        guard activity == nil else { return }
        let content = ActivityContent(
            state: PairingActivityAttributes.ContentState(phase: .pairing),
            staleDate: nil
        )
        do {
            activity = try Activity.request(
                attributes: PairingActivityAttributes(),
                content: content,
                pushType: nil
            )
        } catch {
            activity = nil
        }
    }

    func pinReady(_ pin: String) {
        guard let activity, lastPIN != pin else { return }
        lastPIN = pin
        let content = ActivityContent(
            state: PairingActivityAttributes.ContentState(phase: .pinReady, pin: pin),
            staleDate: nil
        )
        Task { await activity.update(content) }
    }

    func succeeded() {
        finish(phase: .succeeded, message: nil, linger: 4)
    }

    func failed(message: String) {
        finish(phase: .failed, message: message, linger: 3)
    }

    private func finish(
        phase: PairingActivityAttributes.ContentState.Phase,
        message: String?,
        linger: TimeInterval
    ) {
        guard let activity else { return }
        self.activity = nil
        lastPIN = nil
        let content = ActivityContent(
            state: PairingActivityAttributes.ContentState(phase: phase, message: message),
            staleDate: nil
        )
        Task {
            await activity.update(content)
            await activity.end(
                content,
                dismissalPolicy: .after(Date().addingTimeInterval(linger))
            )
        }
    }
}
