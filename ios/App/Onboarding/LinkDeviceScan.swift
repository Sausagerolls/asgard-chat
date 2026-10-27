import AsgardKit
import SwiftUI
import VisionKit

/// Scans the QR code shown on an existing device (Settings > Devices > Link a device).
struct LinkDeviceScanView: View {
    let server: String
    @Environment(ChatEngine.self) private var engine
    @Environment(Router.self) private var router
    @State private var code = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                QRScanner { payload in handle(payload) }
                    .clipShape(.rect(cornerRadius: 28))
                    .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Brand.bifrost, lineWidth: 3))
                    .frame(height: 340)
            } else {
                ContentUnavailableView("Camera unavailable", systemImage: "camera", description: Text("Type the code shown on your other device."))
            }
            Text("On your other device, open Settings › Devices › Link a device and point this camera at the code.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack {
                TextField("XXXX-XXXX-XXXX-XXXX", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled().font(.body.monospaced())
                Button("Link") { Task { await claim(host: nil) } }.buttonStyle(.glassProminent).disabled(code.count < 8 || working)
            }
            .glassCard()
            if let error { Text(error).foregroundStyle(.red) }
            if working { ProgressView() }
            Spacer()
        }
        .padding()
        .background(AuroraBackground(intensity: 0.5))
        .navigationTitle("Link device")
        .onAppear {
            if let p = router.pendingLink {
                code = p.code
                router.pendingLink = nil
                Task { await claim(host: p.host) }
            }
        }
    }

    func handle(_ payload: String) {
        guard !working, let url = URL(string: payload), url.scheme == "asgard",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let c = items.first(where: { $0.name == "code" })?.value else { return }
        code = c
        Task { await claim(host: items.first(where: { $0.name == "host" })?.value) }
    }

    func claim(host: String?) async {
        let base = host.map { "https://" + $0 } ?? server
        guard let url = URL(string: base) else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            try await engine.claimDeviceLink(server: url, code: code, deviceName: UIDevice.current.name)
            PushRegistrar.shared.register()
        } catch {
            self.error = (error as? APIError)?.message ?? error.localizedDescription
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let b) in items { if let s = b.payloadStringValue { onCode(s) } }
        }
    }
}
