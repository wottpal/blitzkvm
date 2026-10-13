import Foundation
import JetKVMCore

/// Client-driven still refresh for one device window (RefreshPlanner). On
/// while the session reports ClientRefresh: fork firmware that offers
/// refreshRegions, in a session that sends input, where the engine has turned
/// the device's own refresh off with the quality level. It feeds the planner
/// with shown frames, local input and the link, and sends what it decides as
/// refreshRegions through the engine. Off (disconnected, another session,
/// stock firmware, view-only), it does nothing and the device refreshes as
/// before.
final class StillRefresh {
    private struct State {
        var planner = RefreshPlanner()
        var active = false
        var keysHeld = false
        var pasting = false

        var inputHeld: Bool { keysHeld || pasting }
    }

    private let engine: EngineProcess
    private let state = Locked(State())
    /// Each refresh once the device answered, with its error (self-test).
    /// Main thread.
    var onSent: ((RefreshPlanner.Refresh, String?) -> Void)?

    init(engine: EngineProcess) {
        self.engine = engine
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var isActive: Bool { state.withLock { $0.active } }

    /// Follows the session snapshot (main thread).
    func update(_ snapshot: SessionSnapshot) {
        let on = snapshot.Phase == "connected" && snapshot.ClientRefresh == true
        let pasting = snapshot.PasteInProgress == true
        let started = state.withLock { s -> Bool in
            let started = on && !s.active
            if started { s.planner.start(at: Self.now) }
            s.active = on
            s.planner.minQp = snapshot.MinQP ?? 0
            s.planner.stillQp = snapshot.StillQP ?? 0
            if pasting != s.pasting {
                // A paste types on the device: input until it ends.
                s.pasting = pasting
                s.planner.input(at: Self.now, held: s.inputHeld)
            }
            return started
        }
        if started {
            AppLog.log("still refresh: client-driven (minQp \(snapshot.MinQP ?? 0), stillQp \(snapshot.StillQP ?? 0))")
        }
    }

    /// The window closes: nothing more is sent.
    func stop() {
        state.withLock { $0.active = false }
    }

    /// Follows the engine's transport statistics (main thread).
    func update(stats: [String: Any]) {
        let rttMs = stats["RoundTripMs"] as? Double ?? 0
        let lan = RefreshPlanner.isLANLike(path: stats["Path"] as? String, rttMs: rttMs)
        state.withLock {
            $0.planner.lan = lan
            $0.planner.rtt = rttMs / 1000
        }
    }

    /// Input went to the remote; `keysHeld` while keys stay down there (the
    /// target repeats them on its own).
    func inputSent(keysHeld: Bool) {
        state.withLock { s in
            s.keysHeld = keysHeld
            s.planner.input(at: Self.now, held: s.inputHeld)
        }
    }

    /// A frame reached the view; `changed` is where it differs from the one
    /// before (decoder thread).
    func frameShown(width: Int, height: Int, changed: PixelRect, keyframe: Bool) {
        let refresh = state.withLock { s -> RefreshPlanner.Refresh? in
            guard s.active else { return nil }
            let now = Self.now
            s.planner.frame(at: now, width: width, height: height, changed: changed, keyframe: keyframe)
            return s.planner.decide(at: now)
        }
        guard let refresh else { return }
        Task { @MainActor in
            guard self.isActive else { return }
            var failure: String?
            do {
                try await self.engine.call("refreshRegions", params: refresh.params)
            } catch {
                failure = error.localizedDescription
                if self.isActive { AppLog.log("still refresh failed: \(error.localizedDescription)") }
            }
            self.onSent?(refresh, failure)
        }
    }
}
