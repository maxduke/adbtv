#if os(iOS) && canImport(AVFoundation)
import ADBClientCore
import AVFoundation
import SwiftUI
import UIKit

struct ADBQRCodeScannerView: UIViewControllerRepresentable {
    var onPayload: (String) -> Void
    var onFailure: (DiagnosticDetail) -> Void

    func makeUIViewController(context: Context) -> ADBQRCodeScannerViewController {
        ADBQRCodeScannerViewController(
            onPayload: onPayload,
            onFailure: onFailure
        )
    }

    func updateUIViewController(
        _ uiViewController: ADBQRCodeScannerViewController,
        context: Context
    ) {}
}

final class ADBQRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "ADBQRCodeScannerView.Session")
    private let onPayload: (String) -> Void
    private let onFailure: (DiagnosticDetail) -> Void
    private lazy var previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
    private var didFinish = false

    init(
        onPayload: @escaping (String) -> Void,
        onFailure: @escaping (DiagnosticDetail) -> Void
    ) {
        self.onPayload = onPayload
        self.onFailure = onFailure
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        requestCameraAccess()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didFinish else {
            return
        }

        for metadataObject in metadataObjects {
            guard let qrCode = metadataObject as? AVMetadataMachineReadableCodeObject,
                  qrCode.type == .qr,
                  let payload = qrCode.stringValue,
                  (try? ADBPairingQRCode(payload: payload)) != nil else {
                continue
            }

            didFinish = true
            sessionQueue.async { [captureSession] in
                if captureSession.isRunning {
                    captureSession.stopRunning()
                }
            }
            onPayload(payload)
            return
        }
    }

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    if granted {
                        self.configureAndStartSession()
                    } else {
                        self.reportFailure(
                            summary: "Camera access was not granted.",
                            reason: "permissionDenied"
                        )
                    }
                }
            }
        case .denied:
            reportFailure(
                summary: "Camera access is denied.",
                reason: "permissionDenied"
            )
        case .restricted:
            reportFailure(
                summary: "Camera access is restricted.",
                reason: "permissionRestricted"
            )
        @unknown default:
            reportFailure(
                summary: "Camera authorization is unavailable.",
                reason: "unknownAuthorizationStatus"
            )
        }
    }

    private func configureAndStartSession() {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            do {
                let camera = AVCaptureDevice.default(
                    .builtInWideAngleCamera,
                    for: .video,
                    position: .back
                ) ?? AVCaptureDevice.default(for: .video)
                guard let camera else {
                    throw ADBQRCodeScannerError.cameraUnavailable
                }

                let input = try AVCaptureDeviceInput(device: camera)
                let output = AVCaptureMetadataOutput()
                guard self.captureSession.canAddInput(input) else {
                    throw ADBQRCodeScannerError.cannotAddCameraInput
                }
                guard self.captureSession.canAddOutput(output) else {
                    throw ADBQRCodeScannerError.cannotAddMetadataOutput
                }

                self.captureSession.beginConfiguration()
                self.captureSession.addInput(input)
                self.captureSession.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                self.captureSession.commitConfiguration()
                self.captureSession.startRunning()
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.reportFailure(
                        summary: String(describing: error),
                        reason: "captureSessionSetup"
                    )
                }
            }
        }
    }

    private func reportFailure(summary: String, reason: String) {
        guard !didFinish else {
            return
        }
        didFinish = true
        onFailure(DiagnosticDetail(
            summary: summary,
            context: [
                "operation": "scanPairingQRCode",
                "reason": reason
            ]
        ))
    }
}

private enum ADBQRCodeScannerError: Error {
    case cameraUnavailable
    case cannotAddCameraInput
    case cannotAddMetadataOutput
}
#endif
