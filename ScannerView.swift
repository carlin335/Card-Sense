//
//  ScannerView.swift
//  CardSense
//
//  Created by Carlin Jon Soorenian on 10/10/25.
//
import SwiftUI
import AVFoundation
import Vision
import UIKit
import CoreMedia
import QuartzCore

/// Fullscreen scanner using rear camera + Vision OCR via `CardScannerEngine`.
/// Presents a live preview with trading-card guides and streams results to `onResult`.
struct ScannerView: View {
    let game: Game
    let onResult: (_ name: String?, _ number: String?) -> Void

    @State private var engine: CardScannerEngine?
    @State private var isAuthorized = false

    init(game: Game = .pokemon,
         onResult: @escaping (_ name: String?, _ number: String?) -> Void) {
        self.game = game
        self.onResult = onResult
    }

    private var languageHints: [String] {
        switch game {
        case .pokemon:          return ["en-US", "en", "ja"]
        case .magic, .yugioh:   return ["en-US", "en", "fr-FR", "de-DE", "es-ES", "it-IT"]
        }
    }

    var body: some View {
        ZStack {
            if isAuthorized {
                CameraPreview(engine: $engine, onHit: { hit in
                    let h = hit.normalized
                    guard h.hasContent else { return }
                    onResult(h.name, h.number)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                })
                .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera.viewfinder").font(.system(size: 52))
                    Text("Camera access is required to scan cards.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        .task { await setup() }
        .onDisappear { engine?.reset() }
    }

    // MARK: - Setup

    private func setup() async {
        // Camera auth
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
        case .notDetermined:
            isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            isAuthorized = false
        }
        // Engine
        engine = CardScannerEngine(languages: languageHints)
    }
}

// MARK: - CameraPreview (UIKit bridge)

/// A UIViewControllerRepresentable that shows a live camera preview and
/// forwards frames to CardScannerEngine. Emits ScanHit to SwiftUI via `onHit`.
struct CameraPreview: UIViewControllerRepresentable {
    @Binding var engine: CardScannerEngine?
    let onHit: (ScanHit) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onHit: onHit)
    }

    func makeUIViewController(context: Context) -> CameraVC {
        let vc = CameraVC()
        vc.engineProvider = { engine }
        vc.onHit = { [weak coord = context.coordinator] hit in
            coord?.onHit(hit)
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraVC, context: Context) {
        uiViewController.engineProvider = { engine }
    }

    final class Coordinator {
        let onHit: (ScanHit) -> Void
        init(onHit: @escaping (ScanHit) -> Void) {
            self.onHit = onHit
        }
    }
}

// MARK: - CameraVC

/// Handles AVCaptureSession and delivers frames to the engine.
/// Adds card-aligned frame guides: WHITE dashed card, BLUE top band (name), GREEN bottom band (number).
final class CameraVC: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    // Engine is supplied from SwiftUI via closure to keep lifetime in SwiftUI.
    var engineProvider: () -> CardScannerEngine? = { nil }
    var onHit: ((ScanHit) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "CardSense.CameraQueue")

    private var previewLayer: AVCaptureVideoPreviewLayer?

    // Guide layers
    private let frameLayer = CAShapeLayer()
    private let nameLayer  = CAShapeLayer()
    private let numLayer   = CAShapeLayer()
    private let nameNote   = CATextLayer()
    private let numNote    = CATextLayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
        configureGuides()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        drawGuides(in: view.bounds.integral)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        session.startRunning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    // MARK: Session

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        // Input
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration(); return
        }
        session.addInput(input)

        // Output
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }

        if let connection = output.connection(with: .video),
           connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        session.commitConfiguration()

        // Preview
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    // MARK: Guides

    private func configureGuides() {
        // WHITE dashed outer card frame
        frameLayer.fillColor = UIColor.clear.cgColor
        frameLayer.strokeColor = UIColor.white.withAlphaComponent(0.95).cgColor
        frameLayer.lineWidth = 2
        frameLayer.lineDashPattern = [6, 6] as [NSNumber]

        // BLUE = name (top)
        nameLayer.fillColor = UIColor.clear.cgColor
        nameLayer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.95).cgColor
        nameLayer.lineWidth = 2
        nameLayer.lineDashPattern = [5, 5] as [NSNumber]

        // GREEN = number (bottom)
        numLayer.fillColor = UIColor.clear.cgColor
        numLayer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.95).cgColor
        numLayer.lineWidth = 3
        numLayer.lineDashPattern = [7, 5] as [NSNumber]

        setupTextLayer(nameNote, text: "Aim name here", color: .systemBlue)
        setupTextLayer(numNote, text: "Aim numbers here", color: .systemGreen)

        [frameLayer, nameLayer, numLayer, nameNote, numNote].forEach { view.layer.addSublayer($0) }
    }

    private func setupTextLayer(_ layer: CATextLayer, text: String, color: UIColor) {
        layer.alignmentMode = .center
        layer.foregroundColor = color.cgColor
        layer.contentsScale = UIScreen.main.scale
        layer.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        layer.fontSize = 12
        layer.string = text
        layer.backgroundColor = UIColor.black.withAlphaComponent(0.25).cgColor
        layer.cornerRadius = 8
        layer.masksToBounds = true
    }

    /// Layout the dashed card + top/bottom bands to match real trading cards.
    private func drawGuides(in bounds: CGRect) {
        let b = bounds
        guard b.width > 1, b.height > 1 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Card-sized focus frame centered on screen
        let inset = b.insetBy(dx: b.width * 0.18,  // horizontal padding
                              dy: b.height * 0.10) // vertical padding

        // ---- NAME (BLUE) — near the top edge, thin title strip ----
        let nameMarginTop  = inset.height * 0.05
        let nameHeight     = inset.height * 0.12
        let nameSideInset  = inset.width  * 0.08
        let nameRect = CGRect(
            x: inset.minX + nameSideInset,
            y: inset.minY + nameMarginTop,
            width: inset.width - (nameSideInset * 2.0),
            height: nameHeight
        )

        // ---- NUMBER (GREEN) — bottom edge band ----
        let numMarginBottom = inset.height * 0.04
        let numHeight       = inset.height * 0.10
        let numSideInset    = inset.width  * 0.05
        let numRect = CGRect(
            x: inset.minX + numSideInset,
            y: inset.maxY - numHeight - numMarginBottom,
            width: inset.width - (numSideInset * 2.0),
            height: numHeight
        )

        // Draw paths
        frameLayer.path = UIBezierPath(roundedRect: inset, cornerRadius: 18).cgPath
        nameLayer.path  = UIBezierPath(roundedRect: nameRect, cornerRadius: 10).cgPath
        numLayer.path   = UIBezierPath(roundedRect: numRect,  cornerRadius: 10).cgPath

        // Notes (small labels)
        let noteH: CGFloat = 18
        nameNote.frame = CGRect(x: nameRect.minX,
                                y: nameRect.maxY + 6,
                                width: nameRect.width,
                                height: noteH)
        numNote.frame  = CGRect(x: numRect.minX,
                                y: numRect.minY - noteH - 6,
                                width: numRect.width,
                                height: noteH)

        CATransaction.commit()
    }

    // MARK: Delegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let engine = engineProvider() else { return }
        if let hit = engine.process(sampleBuffer: sampleBuffer), hit.hasContent {
            DispatchQueue.main.async { [weak self] in
                self?.onHit?(hit.normalized)
            }
        }
    }
}
