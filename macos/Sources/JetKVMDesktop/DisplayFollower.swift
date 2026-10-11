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
    /// The remote's current resolution, if there is a picture.
    var currentSize: () -> RemoteDisplay.Size? = { nil }
    /// Whether the window still drives the remote (checked again when a
    /// request is due).
    var isEnabled: () -> Bool = { true }
    /// A new display mode was sent to the device.
    var onResize: ((RemoteDisplay.Size) -> Void)?
    var onError: ((String) -> Void)?
    /// The size last asked of the device.
    private(set) var requested: RemoteDisplay.Size?
    private var wanted: RemoteDisplay.Size?
    private var settleTimer: Timer?
    private var busy = false

    init(engine: EngineProcess) {
        self.engine = engine
    }

    func request(_ size: RemoteDisplay.Size) {
        wanted = size
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in self?.apply() }
    }

    func cancel() {
        settleTimer?.invalidate()
        wanted = nil
    }

    private func apply() {
        guard !busy, let size = wanted else { return }
        wanted = nil
        guard isEnabled() else { return }
        // Nothing to do if the remote already has the size, unless a request
        // for another size is still being applied (the host would then
        // switch to that one).
        guard size != currentSize() || (requested != nil && requested != size) else {
            requested = size
            return
        }
        busy = true
        Task { @MainActor in
            do {
                let hex = try await engine.call("getEDID", as: String.self)
                guard let current = RemoteDisplay.bytes(hex: hex) else { throw RemoteDisplay.EDIDError.invalid }
                let edid = try RemoteDisplay.edid(current, advertising: size)
                requested = size
                if edid != current {
                    try await engine.call("setEDID", params: .object(["edid": .string(RemoteDisplay.hex(edid))]))
                    AppLog.log("remote display: asked for \(size)")
                    onResize?(size)
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
