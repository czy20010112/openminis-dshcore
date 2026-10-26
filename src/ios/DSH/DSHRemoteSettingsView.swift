import SwiftUI
import AVFoundation
import UIKit

/// Settings → DSH connection: pair this device with a computer running the DS Bot
/// mobile bridge, then switch the sidebar to that host's conversations.
struct DSHRemoteSettingsView: View {
    @ObservedObject private var store = DSHRemoteStore.shared

    @State private var url = ""
    @State private var code = ""
    @State private var deviceName = UIDevice.current.name
    @State private var scanning = false
    @State private var confirmingDisconnect = false

    var body: some View {
        Form {
            statusSection
            if store.host == nil || store.status.isDisconnected {
                pairingSection
            } else {
                conversationModeSection
                disconnectSection
            }
            if let error = store.errorText, !error.isEmpty {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("DSH Connection")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $scanning) {
            DSHRemoteScannerSheet { value in
                scanning = false
                applyScanned(value)
            } onCancel: { scanning = false }
        }
        .onAppear {
            if url.isEmpty { url = store.host?.url ?? "" }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(statusText)
                Spacer()
                if store.status == .connecting { ProgressView() }
            }
            if let host = store.host {
                HStack { Text("Computer"); Spacer(); Text(host.name ?? host.url).foregroundStyle(.secondary) }
                HStack { Text("Address"); Spacer(); Text(host.url).foregroundStyle(.secondary) }
                HStack { Text("Host ID"); Spacer(); Text(String(host.serverId.prefix(8))).foregroundStyle(.secondary) }
                // [T-remote-writable] One state point for "what can this pairing
                // do": protocol v2 made the remote Session writable (the composer
                // posts to the computer and the reply streams back), so the page
                // that used to promise only rendering now says so. Kept inside the
                // paired branch — before pairing there is nothing to send to.
                if store.status == .connected {
                    Text("Ready to send. Open a conversation to type, watch the answer stream in, and stop it at any time. Attachments aren't supported in this mode yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Not paired yet. On the computer open DS Bot → Settings → Mobile devices, create a pairing code, then enter it here or scan its QR code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pairingSection: some View {
        Section("Pair a computer") {
            TextField("https://your-host.example.com", text: $url)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Pairing code", text: $code)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Device name", text: $deviceName)
            Button {
                store.beginPairing(url: url, code: code, deviceName: deviceName)
            } label: {
                HStack {
                    Text("Pair")
                    Spacer()
                    if store.pairingPhase == .probing || store.pairingPhase == .waiting {
                        ProgressView()
                    }
                }
            }
            .disabled(url.isEmpty || code.isEmpty || store.pairingPhase == .probing || store.pairingPhase == .waiting)
            Button {
                scanning = true
            } label: {
                Label("Scan pairing QR code", systemImage: "qrcode.viewfinder")
            }
            switch store.pairingPhase {
            case .probing:
                Text("Contacting the computer…").font(.footnote).foregroundStyle(.secondary)
            case .waiting:
                Text("Approve this device on the computer (DS Bot → Settings → Mobile devices).").font(.footnote).foregroundStyle(.secondary)
            case .approved:
                Text("Paired.").font(.footnote).foregroundStyle(.green)
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.red)
            case .idle:
                EmptyView()
            }
        }
    }

    private var conversationModeSection: some View {
        Section("Sidebar") {
            Toggle("Show DSH conversations", isOn: Binding(
                get: { store.mode == .dsh },
                set: { on in
                    store.setMode(on ? .dsh : .minis)
                    if on { Task { await store.connect() } }
                }
            ))
            // [T-remote-writable] This sentence used to end at "Messages are
            // rendered here", which was true while the composer was read-only and
            // now reads as a promise of rendering-only. The pairing sends text to
            // the computer, the answer streams back live, and the model still runs
            // there — say exactly that.
            Text("When on, the conversation list shows this computer's conversations instead of local Minis chats. Messages you send from here run on the computer and stream back live; the model never runs on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var disconnectSection: some View {
        Section {
            Button(role: .destructive) {
                confirmingDisconnect = true
            } label: {
                Text("Disconnect this computer")
            }
            .confirmationDialog("Disconnect and forget the pairing?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { store.disconnect() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: Helpers

    private var statusColor: Color {
        switch store.status {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }

    private var statusText: String {
        switch store.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .failed(let message): return message
        case .disconnected: return "Not connected"
        }
    }

    /// Accepts either a bare URL or the JSON payload the DS Bot QR code carries:
    /// {"url":"https://…","code":"…","serverId":"…"}
    private func applyScanned(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let scannedURL = object["url"] as? String { url = scannedURL }
            if let scannedCode = object["code"] as? String { code = scannedCode }
            return
        }
        if trimmed.contains("?code=") || trimmed.contains("&code=") {
            if let components = URLComponents(string: trimmed) {
                if let base = components.scheme.map({ "\($0)://\(components.host ?? "")" }) { url = base }
                if let value = components.queryItems?.first(where: { $0.name == "code" })?.value { code = value }
            }
            return
        }
        if trimmed.hasPrefix("http") { url = trimmed }
        else { code = trimmed }
    }
}

// MARK: - Extensions used above

private extension DSHRemoteStore.Status {
    var isDisconnected: Bool {
        if case .disconnected = self { return true }
        return false
    }
}

// MARK: - QR scanner

/// Minimal AVFoundation QR scanner. Shown as a sheet; calls `onCode` with the raw
/// payload and closes itself.
struct DSHRemoteScannerSheet: View {
    let onCode: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            DSHRemoteCameraView(onCode: onCode)
                .ignoresSafeArea()
                .navigationTitle("Scan pairing code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
        }
    }
}

private struct DSHRemoteCameraView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DSHRemoteScannerController {
        let controller = DSHRemoteScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ uiViewController: DSHRemoteScannerController, context: Context) {}
}

final class DSHRemoteScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var handled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.preview = preview

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !handled,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        handled = true
        session.stopRunning()
        onCode?(value)
    }
}
