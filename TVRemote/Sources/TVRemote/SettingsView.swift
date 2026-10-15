import SwiftUI
import TVKit

struct SettingsView: View {
    @EnvironmentObject private var tv: TVController
    var done: () -> Void
    @State private var hostDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("TV") {
                HStack(spacing: 6) {
                    TextField("IP address", text: $hostDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(applyHost)
                    Button(tv.isScanning ? "Scanning…" : "Scan") { tv.scan() }
                        .disabled(tv.isScanning)
                }
                if tv.isScanning {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
                ForEach(tv.discovered) { found in
                    Button {
                        tv.select(found)
                        hostDraft = found.host
                        done()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "tv").frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(found.name).font(.system(size: 12, weight: .medium))
                                Text("\(found.modelName) · \(found.host)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if found.host == tv.host { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(KeyStyle())
                }
                if !tv.isScanning, tv.discovered.isEmpty, tv.status == .noTV {
                    Text("No TV found yet. Turn the TV on, make sure it's on the same Wi-Fi, then Scan.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            section("Power on") {
                TextField("TV MAC address (for Wake-on-LAN)", text: $tv.mac)
                    .textFieldStyle(.roundedBorder)
                Text("Filled in automatically from the TV. ⏻ sends a Wake-on-LAN packet when the TV is off.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("App") {
                Toggle("Open at login", isOn: Binding(get: { tv.launchAtLogin }, set: { tv.launchAtLogin = $0 }))
            }

            if let info = tv.info {
                section("Device") {
                    row("Model", info.modelName)
                    row("Platform", info.model ?? "–")
                    row("Network", info.networkType ?? "–")
                    row("Resolution", info.resolution ?? "–")
                    row("Remote", info.tokenAuthSupport ? "wss :8002 (token)" : "ws :8001")
                }
            }

            Divider()
            HStack {
                Button("Reconnect") { applyHost(); tv.connect() }
                Spacer()
                Button("Quit TV Remote") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .onAppear {
            hostDraft = tv.host
            if tv.discovered.isEmpty { tv.scan() }
        }
    }

    private func applyHost() {
        let trimmed = hostDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != tv.host else { return }
        tv.host = trimmed
        tv.mac = ""
        tv.connect()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).textSelection(.enabled)
        }
        .font(.caption)
    }
}
