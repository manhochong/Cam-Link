import AVFoundation
import SwiftUI
import UIKit

struct PairQRScanner: View {
    let onCode: (String) -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QRScannerControllerView(onCode: onCode)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("掃描電腦 QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

private struct QRScannerControllerView: UIViewControllerRepresentable {
    let onCode: (String) -> Bool
    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onCode = onCode
        return controller
    }
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
}

private final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Bool)?
    private let session = AVCaptureSession()
    private let work = DispatchQueue(label: "hk.camlink.qr-camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private let message = UILabel()
    private var delivered = false
    private var visible = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        message.text = "把 Windows 接收器顯示的 QR 對準鏡頭"
        message.textColor = .white
        message.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        message.textAlignment = .center
        message.numberOfLines = 0
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)
        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            message.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            message.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        Task { @MainActor in
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard self.visible else { return }
            guard allowed else {
                self.message.text = "相機權限未允許。請到設定 → Cam Link 開啟相機，或取消後手動輸入地址及配對碼。"
                return
            }
            self.configure()
        }
    }

    private func configure() {
        guard preview == nil else { return }
        do {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                message.text = "找不到可用鏡頭；請改用手動輸入配對。"
                return
            }
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureMetadataOutput()
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                message.text = "目前無法開啟掃描鏡頭，請稍後再試或手動輸入配對。"
                return
            }
            session.addInput(input)
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            guard output.availableMetadataObjectTypes.contains(.qr) else {
                session.commitConfiguration()
                message.text = "此裝置不能識別 QR，請手動輸入配對。"
                return
            }
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.insertSublayer(layer, at: 0)
            preview = layer
            let capture = session
            work.async { capture.startRunning() }
        } catch { message.text = "掃描器無法啟動：\(error.localizedDescription)。可取消後手動配對。" }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        let capture = session
        work.async { if capture.isRunning { capture.stopRunning() } }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let raw = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        Task { @MainActor in
            guard self.visible, !self.delivered else { return }
            if self.onCode?(raw) == true {
                self.delivered = true
                self.message.text = "已讀取配對資料，請核對電腦指紋。"
            } else {
                self.message.text = "這不是有效的 Cam Link 配對 QR。請掃描 Windows 接收器的「顯示 QR 掃描」。"
            }
        }
    }
}
