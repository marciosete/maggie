import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings → Mobile: turns the companion server on, pairs devices by QR code and lists
/// the ones paired.
struct RemoteSettingsView: View {
    @ObservedObject private var service = RemoteService.shared
    @ObservedObject private var devices = RemoteService.shared.devices
    @State private var portText = ""
    @State private var pairing = false

    var body: some View {
        Form {
            Section {
                Toggle("Allow Maggie Mobile to connect", isOn: $service.isEnabled)
                LabeledContent("Status") {
                    Text(statusText).foregroundStyle(.secondary)
                }
                LabeledContent("Port") {
                    TextField("Port", text: $portText)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(applyPort)
                }
            } header: {
                Text("Mobile")
            } footer: {
                Text("Your phone or iPad reaches this Mac over Tailscale, at home or away. Only devices paired here can connect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Address") {
                ForEach(service.addresses, id: \.self) { address in
                    LabeledContent(address.kind == .tailscale ? "Tailscale" : "Local network") {
                        Text(address.value).textSelection(.enabled).foregroundStyle(.secondary)
                    }
                }
                TextField("Address in the QR code", text: $service.advertisedHost, prompt: Text(service.suggestedHost))
            }

            Section {
                ForEach(devices.devices) { device in
                    LabeledContent {
                        Button("Remove") { service.removeDevice(id: device.id) }
                    } label: {
                        Text(device.name)
                        Text(deviceDetail(device)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Pair a Device…") {
                    if service.beginPairing() != nil { pairing = true }
                }
                .disabled(!isListening)
            } header: {
                Text("Devices")
            }

            RemotePushSettings(push: service.push)

            if let fingerprint = service.fingerprint {
                Section("Certificate") {
                    Text(fingerprint.displayString)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            portText = String(service.port)
            service.refreshAddresses()
        }
        .sheet(isPresented: $pairing) {
            RemotePairingSheet(pairing: service.pairing) { pairing = false }
        }
    }

    private var isListening: Bool {
        if case .listening = service.status { return true }
        return false
    }

    private var statusText: String {
        switch service.status {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .listening(let port):
            let count = service.connectedDevices.count
            return count == 0 ? "Listening on port \(port)" : "\(count) connected"
        case .failed(let message): return message
        }
    }

    private func deviceDetail(_ device: RemoteDevice) -> String {
        if service.connectedDevices.contains(device.id) { return "Connected" }
        guard let lastSeen = device.lastSeen else { return "Never connected" }
        return "Last seen \(lastSeen.formatted(.relative(presentation: .named)))"
    }

    private func applyPort() {
        if let port = UInt16(portText), port > 0 {
            service.port = port
        } else {
            portText = String(service.port)
        }
    }
}

/// Push notifications: the switch, and the APNs key from the Apple developer account.
struct RemotePushSettings: View {
    @ObservedObject var push: RemotePush
    @State private var error: String?

    var body: some View {
        Section {
            Toggle("Notify devices when a session waits or finishes", isOn: $push.isEnabled)
            TextField("Key ID", text: $push.keyID)
            TextField("Team ID", text: $push.teamID)
            TextField("App Bundle ID", text: $push.topic)
            LabeledContent("Key") {
                HStack {
                    Text(push.hasKey ? "AuthKey.p8 loaded" : "None").foregroundStyle(.secondary)
                    Button("Choose .p8…", action: chooseKey)
                }
            }
            if let message = error ?? push.lastResult {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Push Notifications")
        } footer: {
            Text("Create an APNs key in your Apple developer account and choose its .p8 here. These pushes are apart from the Mac's own notifications.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "p8") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try push.importKey(from: url)
            error = nil
        } catch {
            self.error = "That isn't an APNs .p8 key."
        }
    }
}

/// The QR code a device scans to pair, with the code itself to type when scanning won't.
struct RemotePairingSheet: View {
    @ObservedObject var pairing: RemotePairing
    var done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair a Device").font(.headline)
            if let offer = pairing.offer {
                if let image = Self.qrImage(offer.invitation.url.absoluteString) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .accessibilityLabel("Pairing QR code")
                }
                Text("Scan with Maggie Mobile, or paste the link.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(offer.code)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(offer.invitation.url.absoluteString, forType: .string)
                    }
                    Text("Expires \(offer.expires.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("The code was used or expired.").foregroundStyle(.secondary)
            }
            Button("Done") {
                pairing.cancel()
                done()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 320)
    }

    static func qrImage(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
