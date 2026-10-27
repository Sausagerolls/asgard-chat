import AsgardKit
import CoreImage.CIFilterBuiltins
import LocalAuthentication
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Message history sync and the recovery key, shared by the iPhone and Mac apps.
struct HistorySettingsView: View {
    /// Shows a Done button (when presented as a sheet).
    var showsDone = false
    @Environment(ChatEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var newKey: String?
    @State private var shownKey: String?
    @State private var typed = ""
    @State private var error: String?
    @State private var confirmOff = false

    var body: some View {
        let h = engine.history
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(h)).font(.headline)
                        Text(subtitle(h)).font(.callout).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: h.enabled == true ? (h.hasKey ? "checkmark.shield.fill" : "key.fill") : "clock.arrow.circlepath")
                        .foregroundStyle(h.enabled == true && h.hasKey ? Brand.teal : Brand.gold)
                }
                if let p = h.progress { ProgressView { Text(p).font(.caption) } }
            }
            actions(h)
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Label("Each message key is also locked to your recovery key. The server stores only that locked copy; it can't read your messages.",
                      systemImage: "lock.shield").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Message History")
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .sheet(isPresented: $scanning) { RecoveryKeyScanner { key in scanning = false; typed = key; Task { await restore() } } }
        .task { await engine.refreshHistoryStatus() }
        .sheet(item: Binding(get: { (newKey ?? shownKey).map(KeyBox.init) }, set: { if $0 == nil { newKey = nil; shownKey = nil } })) { box in
            RecoveryKeySheet(key: box.key, isNew: newKey != nil)
        }
        .confirmationDialog("Turn off history sync?", isPresented: $confirmOff, titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) { Task { try? await engine.disableHistory() } }
        } message: { Text("New devices won't be able to see older messages.") }
    }

    @ViewBuilder func actions(_ h: HistoryState) -> some View {
        switch (h.enabled, h.hasKey) {
        case (false?, _):
            Section {
                Button { Task { await turnOn() } } label: { Label("Turn On History Sync", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(h.working)
            } footer: {
                Text("You'll get a recovery key. Your devices share it with each other automatically when you link a new one. Keep a copy somewhere safe: it's the only way to read old messages if you lose every device.")
            }
        case (true?, false):
            Section {
                TextField("XXXX-XXXX-XXXX-…", text: $typed, axis: .vertical)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                Button("Restore Messages") { Task { await restore() } }.disabled(typed.count < 40 || h.working)
                Button { scanning = true } label: { Label("Scan QR Code from Another Device", systemImage: "qrcode.viewfinder") }
            } header: {
                Text("Enter your recovery key")
            } footer: {
                Text("On a device that already has your history: Message History › Show Recovery Key, then scan its QR code here.")
            }
        case (true?, true):
            Section {
                Button { Task { await show() } } label: { Label("Show Recovery Key", systemImage: "key") }
                Button { Task { await engine.backfillHistory(); await engine.importHistory() } } label: { Label("Sync History Now", systemImage: "arrow.clockwise") }
                    .disabled(h.working)
            }
            Section {
                Button("Turn Off History Sync", role: .destructive) { confirmOff = true }
            } footer: {
                Text("Turning it off deletes the encrypted copies on your server. Messages already on your devices stay.")
            }
        default:
            Section { ProgressView() }
        }
    }

    struct KeyBox: Identifiable { var key: String; var id: String { key } }

    func title(_ h: HistoryState) -> String {
        switch (h.enabled, h.hasKey) {
        case (true?, true): "History sync is on"
        case (true?, false): "Restore your message history"
        case (false?, _): "History sync is off"
        default: "Checking…"
        }
    }

    func subtitle(_ h: HistoryState) -> String {
        switch (h.enabled, h.hasKey) {
        case (true?, true): "New devices you link get your full message history, end-to-end encrypted."
        case (true?, false): "Enter the recovery key you saved, or link this device from one you already use."
        case (false?, _): "New devices only see messages sent after they join."
        default: ""
        }
    }

    func turnOn() async {
        error = nil
        do { newKey = try await engine.enableHistory() } catch { self.error = (error as? APIError)?.message ?? error.localizedDescription }
    }

    func restore() async {
        error = nil
        do { try await engine.restoreHistory(typed); typed = "" } catch { self.error = (error as? APIError)?.message ?? error.localizedDescription }
    }

    func show() async {
        let ctx = LAContext()
        var err: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) {
            guard (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Show your recovery key")) == true else { return }
        }
        shownKey = engine.recoveryKeyForDisplay()
    }
}

struct RecoveryKeySheet: View {
    let key: String
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "key.horizontal.fill").font(.system(size: 44)).foregroundStyle(Brand.bifrost)
            Text("Your Recovery Key").font(.title2.bold())
            Text("Write this down or store it in your password manager. To add a device to sync, scan this QR code from its Message History screen.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let qr = RecoveryQR.image(for: key) {
                Image(decorative: qr, scale: 1).interpolation(.none).resizable().frame(width: 180, height: 180)
                    .padding(10).background(.white, in: .rect(cornerRadius: 16))
                    .accessibilityLabel("QR code of your recovery key")
            }
            let groups = key.split(separator: "-").map(String.init)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
                    Text(g).font(.body.monospaced().weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 8))
                        .accessibilityLabel("Group \(i + 1): \(g.map(String.init).joined(separator: " "))")
                }
            }
            .textSelection(.enabled)
            HStack {
                Button { copy(); copied = true } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                ShareLink(item: "Asgard recovery key: \(key)") { Label("Save…", systemImage: "square.and.arrow.up") }
            }
            .buttonStyle(.bordered)
            if isNew {
                Toggle("I've saved my recovery key somewhere safe", isOn: $saved)
            }
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .disabled(isNew && !saved)
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(maxWidth: 520)
        .interactiveDismissDisabled(isNew && !saved)
    }

    func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        #else
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: key]], options: [.expirationDate: Date.now.addingTimeInterval(120)])
        #endif
    }
}

/// Nudge shown at the top of the chat list until history sync is set up on this device.
struct HistoryNudge: View {
    @Environment(ChatEngine.self) private var engine
    var open: () -> Void
    @AppStorage("historyNudgeDismissed") private var dismissed = false

    var body: some View {
        let h = engine.history
        if !engine.isDemo, let enabled = h.enabled, (enabled && !h.hasKey) || (!enabled && !dismissed) || h.working {
            HStack(spacing: 12) {
                Image(systemName: h.working ? "arrow.triangle.2.circlepath" : "key.fill")
                    .foregroundStyle(Brand.gold)
                    .symbolEffect(.rotate, isActive: h.working)
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.working ? "Restoring messages" : enabled ? "Restore your message history" : "Keep your messages on new devices")
                        .font(.subheadline.weight(.semibold))
                    Text(h.progress ?? (enabled ? "Enter your recovery key to read older messages here." : "Turn on history sync and save a recovery key."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !h.working {
                    Button(enabled ? "Restore" : "Set Up", action: open).buttonStyle(.borderedProminent).controlSize(.small)
                    if !enabled {
                        Button { dismissed = true } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).controlSize(.small)
                    }
                }
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }
}

/// QR codes carry the recovery key as asgard://history?key=XXXX-XXXX-…
enum RecoveryQR {
    static func payload(_ key: String) -> String { "asgard://history?key=" + key }

    static func key(from payload: String) -> String? {
        guard let url = URL(string: payload), url.scheme == "asgard", url.host() == "history",
              let k = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "key" })?.value,
              RecoveryKey(k) != nil else { return nil }
        return k
    }

    static func image(for key: String) -> CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(payload(key).utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }
}

/// Camera sheet that reads a recovery key QR code.
struct RecoveryKeyScanner: View {
    var onKey: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message = "Point the camera at the QR code under Show Recovery Key on your other device."

    var body: some View {
        VStack(spacing: 16) {
            Text("Scan Recovery Key").font(.title2.bold())
            scanner
                .frame(width: 320, height: 320)
                .clipShape(.rect(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Brand.bifrost, lineWidth: 3))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(24)
    }

    @ViewBuilder var scanner: some View {
        #if os(macOS)
        MacQRScanner { handle($0) }
        #else
        QRScanner { handle($0) }
        #endif
    }

    func handle(_ payload: String) {
        if let key = RecoveryQR.key(from: payload) { onKey(key) } else { message = "That QR code isn't an Asgard recovery key." }
    }
}
