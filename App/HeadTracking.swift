import CoreMotion
import Foundation
import JammerAudio

/// Follows the listener's head with headphones that have motion sensors (AirPods Pro, Max, 3rd generation and
/// later, some Beats), and turns the binaural listening with it. Listening only: nothing of it reaches the
/// document, an export or a meter. Off until switched on (Audio › Follow Head Movements); macOS asks the first
/// time whether Jämmer may read the headphones' motion (NSMotionUsageDescription). Read by Core Motion's
/// CMHeadphoneMotionManager, which needs no entitlement; the spatial mixer's own head tracking would need
/// `com.apple.developer.coremotion.head-pose`, which only a provisioning profile can give.
@MainActor
final class HeadTracker {
    static let shared = HeadTracker()

    private let manager = CMHeadphoneMotionManager()
    /// Where the head pointed when following began or was centered: the pose is relative to it.
    private var reference: CMAttitude?
    private var simulation: Timer?
    private(set) var isFollowing = false
    /// The latest pose, while following.
    private(set) var pose: HeadPose?

    /// Called with each pose (nil when following stops), and with what went wrong, in the window's words.
    var onPose: ((HeadPose?) -> Void)?
    var onProblem: ((String) -> Void)?

    /// `-headTracking.simulate YES` (debug builds): a slow turn left and right instead of the headphones, so the
    /// way from a pose to the listening can be tried without headphones and without macOS's question.
    static var simulated: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "headTracking.simulate")
        #else
        false
        #endif
    }

    func start() {
        guard !isFollowing else { return }
        reference = nil
        if Self.simulated {
            isFollowing = true
            let began = Date()
            simulation = Timer.scheduledTimer(withTimeInterval: 1.0 / 25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    let t = Date().timeIntervalSince(began)
                    self?.publish(HeadPose(yaw: 30 * sin(t * 2 * .pi / 4)))
                }
            }
            return
        }
        guard manager.isDeviceMotionAvailable else { onProblem?(L10n.text("listen.head.unavailable")); return }
        if CMHeadphoneMotionManager.authorizationStatus() == .denied || CMHeadphoneMotionManager.authorizationStatus() == .restricted {
            onProblem?(L10n.text("listen.head.denied"))
            return
        }
        isFollowing = true
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            MainActor.assumeIsolated {
                guard let self, self.isFollowing else { return }
                if error != nil {
                    self.stop()
                    self.onProblem?(CMHeadphoneMotionManager.authorizationStatus() == .denied ? L10n.text("listen.head.denied") : L10n.text("listen.head.lost"))
                    return
                }
                guard let attitude = motion?.attitude.copy() as? CMAttitude else { return }
                if self.reference == nil { self.reference = attitude.copy() as? CMAttitude }
                if let reference = self.reference { attitude.multiply(byInverseOf: reference) }
                // Core Motion's angles are radians; its yaw turns to the left and its pitch looks up, as HeadPose's.
                let deg = 180 / Double.pi
                self.publish(HeadPose(yaw: attitude.yaw * deg, pitch: attitude.pitch * deg, roll: attitude.roll * deg))
            }
        }
    }

    func stop() {
        guard isFollowing else { return }
        isFollowing = false
        simulation?.invalidate()
        simulation = nil
        if !Self.simulated { manager.stopDeviceMotionUpdates() }
        reference = nil
        pose = nil
        onPose?(nil)
    }

    /// Where the head points now becomes the front.
    func recenter() { reference = nil }

    private func publish(_ p: HeadPose) {
        pose = p
        onPose?(p)
    }
}
