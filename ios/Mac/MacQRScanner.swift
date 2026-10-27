import AppKit
import AVFoundation
import CoreImage
import SwiftUI

/// Live camera preview that reports the first QR code it sees.
struct MacQRScanner: NSViewRepresentable {
    var onCode: (String) -> Void

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.start(in: view)
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {}

    static func dismantleNSView(_ view: PreviewView, coordinator: Coordinator) { coordinator.stop() }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class PreviewView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            layer?.sublayers?.forEach { $0.frame = bounds }
        }
    }

    nonisolated final class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        let onCode: (String) -> Void
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "asgard.qr")
        private let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        private var found = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func start(in view: PreviewView) {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                guard granted, let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else { return }
                self.session.beginConfiguration()
                if self.session.canAddInput(input) { self.session.addInput(input) }
                let output = AVCaptureVideoDataOutput()
                output.setSampleBufferDelegate(self, queue: self.queue)
                if self.session.canAddOutput(output) { self.session.addOutput(output) }
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    let preview = AVCaptureVideoPreviewLayer(session: self.session)
                    preview.videoGravity = .resizeAspectFill
                    preview.frame = view.bounds
                    // Mirror like a selfie camera so aiming the phone feels natural.
                    preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
                    view.layer?.addSublayer(preview)
                }
                self.queue.async { self.session.startRunning() }
            }
        }

        func stop() { queue.async { self.session.stopRunning() } }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard !found, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let image = CIImage(cvPixelBuffer: buffer)
            guard let code = (detector?.features(in: image).first as? CIQRCodeFeature)?.messageString else { return }
            found = true
            DispatchQueue.main.async { self.onCode(code) }
        }
    }
}
