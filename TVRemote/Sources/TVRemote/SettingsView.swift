import SwiftUI
import TVKit

struct SettingsView: View {
    @EnvironmentObject private var tv: TVController
    var done: () -> Void
    @State private var hostDraft = ""
    @State private var wakeFix = false
    @State private var wakeFixBusy = false
    @State private var wakeFixError: String?
    @State private var update: Updates.Update?
    @State private var updateNote = ""
    @State private var updating = false

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
                Toggle("Wake from long standby", isOn: Binding(get: { wakeFix }, set: setWakeFix))
                    .disabled(wakeFixBusy || tv.host.isEmpty || tv.mac.isEmpty)
                Text("After about 20 minutes off, this TV only wakes on a packet sent straight to it, so the Mac has to keep its address. Turning this on pins it (asks for your admin password once).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let wakeFixError {
                    Text(wakeFixError).font(.caption).foregroundStyle(.red)
                }
            }

            section("App") {
                Toggle("Open at login", isOn: Binding(get: { tv.launchAtLogin }, set: { tv.launchAtLogin = $0 }))
                HStack(spacing: 6) {
                    Button("Check for updates", action: checkForUpdates).disabled(updating)
                    if let update {
                        Button("Update to \(update.version)", action: installUpdate).disabled(updating)
                    }
                }
                .controlSize(.small)
                Text(updateNote.isEmpty ? "Version \(Updater.current ?? "dev")" : updateNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("Claude") {
                row("Chat model", ClaudeChat.model)
                row("API key", APIKey.source.map { "from \($0)" } ?? "not found")
                Text("MCP server for Claude Code / Desktop:")
                    .font(.caption).foregroundStyle(.secondary)
                Text(Self.mcpCommand)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
            wakeFix = WakeFix.isInstalled(host: tv.host, mac: tv.mac)
            hostDraft = tv.host
            if tv.discovered.isEmpty { tv.scan() }
        }
    }

    static var mcpCommand: String {
        let tvmcp = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tvmcp").path
        return "claude mcp add tv-remote -s user -- \"\(tvmcp)\""
    }

    private func checkForUpdates() {
        updating = true
        update = nil
        updateNote = "Checking…"
        Task {
            do {
                update = try await Updater.check()
                updateNote = update.map { "Version \($0.version) is available (you have \(Updater.current ?? "?"))." }
                    ?? "You're up to date (\(Updater.current ?? "?"))."
            } catch {
                updateNote = "Couldn't check: \(error.localizedDescription)"
            }
            updating = false
        }
    }

    private func installUpdate() {
        guard let update else { return }
        updating = true
        updateNote = "Downloading and checking the update… TV Remote restarts when it's installed."
        Task {
            do {
                try await Updater.install(update)
            } catch {
                updateNote = "Update failed: \(error.localizedDescription)"
                updating = false
            }
        }
    }

    private func setWakeFix(_ on: Bool) {
        let host = tv.host, mac = tv.mac
        wakeFixBusy = true
        wakeFixError = nil
        Task.detached {
            let failure: String?
            do {
                if on { try WakeFix.install(host: host, mac: mac) } else { try WakeFix.uninstall(host: host) }
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            let installed = WakeFix.isInstalled(host: host, mac: mac)
            await MainActor.run {
                wakeFix = installed
                wakeFixError = failure == "Cancelled." ? nil : failure
                wakeFixBusy = false
            }
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
