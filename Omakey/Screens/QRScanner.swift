import AVFoundation
import SwiftUI
import UIKit

/// The camera, full screen, looking for the pairing QR code.
struct QRScannerSheet: View {
    let palette: Palette
    let onCode: (String) -> Void
    let onCancel: () -> Void

    private enum Access { case checking, granted, denied, noCamera }
    @State private var access = Access.checking

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch access {
            case .granted:
                ScannerView(onCode: onCode).ignoresSafeArea()
                RoundedRectangle(cornerRadius: 24)
                    .stroke(palette.accent, lineWidth: 3)
                    .frame(width: 260, height: 260)
                    .accessibilityHidden(true)
            case .denied:
                message("Camera access is off for Omakey. Allow it in Settings, or copy the pairing link on your computer and tap Paste.",
                        settings: true)
            case .noCamera:
                message("This device has no camera. Copy the pairing link on your computer and tap Paste.", settings: false)
            case .checking:
                ProgressView().tint(.white)
            }
            VStack {
                Text("Scan the Omakey pairing code")
                    .font(.mono(16, bold: true))
                    .foregroundStyle(.white)
                    .padding(.top, 24)
                Spacer()
                Button("Cancel", action: onCancel)
                    .font(.mono(16, bold: true))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.18), in: Capsule())
                    .padding(.bottom, 24)
                    .accessibilityIdentifier("omakey.scan.cancel")
            }
        }
        .task { await checkAccess() }
    }

    private func message(_ text: String, settings: Bool) -> some View {
        VStack(spacing: 16) {
            Text(text).font(.mono(14)).foregroundStyle(.white).multilineTextAlignment(.center)
            if settings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(OmakeyButtonStyle(primary: true, palette: palette))
                .frame(maxWidth: 240)
            }
        }
        .padding(32)
    }

    private func checkAccess() async {
        guard AVCaptureDevice.default(for: .video) != nil else {
            access = .noCamera
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: access = .granted
        case .notDetermined: access = await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default: access = .denied
        }
    }
}

private struct ScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var observation: NSKeyValueObservation?
    private var done = false

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
        // Keep the picture upright as the phone turns.
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotation = coordinator
        layer.connection?.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview) { [weak self] c, _ in
            let angle = c.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { self?.preview?.connection?.videoRotationAngle = angle }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        nonisolated(unsafe) let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        nonisolated(unsafe) let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let code = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }.first
        MainActor.assumeIsolated {
            guard !done, let code else { return }
            done = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode?(code)
        }
    }
}
