import AVFoundation
import SwiftUI
import UIKit

/// The camera with QR detection, or why it can't run (no camera, access
/// denied).
struct QRScannerPanel: View {
    let onCode: (String) -> Void
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    private let hasCamera = AVCaptureDevice.default(for: .video) != nil

    var body: some View {
        ZStack {
            Color.black
            if !hasCamera {
                message("No Camera", "This device has no camera. Paste the code instead.", settings: false)
            } else {
                switch access {
                case .authorized:
                    QRScannerView(onCode: onCode)
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.85), lineWidth: 3)
                        .frame(width: 210, height: 210)
                        .accessibilityHidden(true)
                case .notDetermined:
                    ProgressView().tint(.white)
                        .task { access = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied }
                default:
                    message("Camera Off", "Allow camera access in Settings to scan the code, or paste it below.", settings: true)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func message(_ title: String, _ text: String, settings: Bool) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(text).font(.footnote).multilineTextAlignment(.center).opacity(0.8)
            if settings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { UIApplication.shared.open(url) }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        }
        .foregroundStyle(.white)
        .padding()
    }
}

/// An AVFoundation capture session that reports QR codes.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onCode = onCode
    }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.fmdlabs.blitzkvm.scanner")
    private var preview: AVCaptureVideoPreviewLayer?
    private var last: (code: String, at: Date)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = session
        queue.async { if !session.isRunning { session.startRunning() } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        let codes = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        MainActor.assumeIsolated {
            for code in codes {
                // The same code reports every frame: pass it on once a second.
                if let last, last.code == code, Date().timeIntervalSince(last.at) < 1 { continue }
                last = (code, Date())
                onCode?(code)
            }
        }
    }
}
