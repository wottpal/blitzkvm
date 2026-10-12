import Foundation
import JetKVMCore

/// Match Window: has the device advertise a display mode of the window's size
/// (RemoteDisplay) so the host switches its resolution to it. Requests wait
/// until resizing settles, and only the newest one is sent while another is
/// in flight. Each change makes the host re-detect the display (the picture
/// pauses for a few seconds), so nothing is sent while the remote already has
/// the size. Main thread only.
final class DisplayFollower {
    private let engine: EngineProcess
    /// The remote's current mode, if there is a picture.
    var currentMode: () -> RemoteDisplay.Mode? = { nil }
    /// Whether the window still drives the remote (checked again when a
    /// request is due).
    var isEnabled: () -> Bool = { true }
    /// A new display mode is being sent to the device (the remote's picture
    /// pauses while it re-detects the display).
    var onResize: ((RemoteDisplay.Mode) -> Void)?
    var onError: ((String) -> Void)?
    /// The mode last asked of the device.
    private(set) var requested: RemoteDisplay.Mode?
    private var wanted: RemoteDisplay.Mode?
    private var settleTimer: Timer?
    private var busy = false

    init(engine: EngineProcess) {
        self.engine = engine
    }

    func request(_ mode: RemoteDisplay.Mode) {
        wanted = mode
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in self?.apply() }
    }

    func cancel() {
        settleTimer?.invalidate()
        wanted = nil
    }

    private func apply() {
        guard !busy, let mode = wanted else { return }
        wanted = nil
        guard isEnabled() else { return }
        // Nothing to do if the remote already has the mode, unless a request
        // for another one is still being applied (the host would then switch
        // to that one). The device reports whole frames per second.
        let current = currentMode()
        let alreadyThere = current.map { $0.size == mode.size && abs($0.refresh - mode.refresh) <= 1 } ?? false
        guard !alreadyThere || (requested != nil && requested != mode) else {
            requested = mode
            return
        }
        busy = true
        Task { @MainActor in
            do {
                let hex = try await engine.call("getEDID", as: String.self)
                guard let current = RemoteDisplay.bytes(hex: hex) else { throw RemoteDisplay.EDIDError.invalid }
                let edid = try RemoteDisplay.edid(current, advertising: mode.size, refresh: mode.refresh)
                requested = mode
                if edid != current {
                    onResize?(mode)
                    try await engine.call("setEDID", params: .object(["edid": .string(RemoteDisplay.hex(edid))]))
                    AppLog.log("remote display: asked for \(mode)")
                }
            } catch {
                onError?("could not resize the remote display: \(error.localizedDescription)")
            }
            busy = false
            // A request that settled meanwhile (its timer has fired).
            if wanted != nil && settleTimer?.isValid != true { apply() }
        }
    }
}
