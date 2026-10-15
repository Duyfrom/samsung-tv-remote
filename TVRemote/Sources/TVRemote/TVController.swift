import AppKit
import ServiceManagement
import TVKit

/// Owns the connection to one TV and everything the menu bar UI shows about it.
@MainActor
final class TVController: ObservableObject {
    enum Status: Equatable {
        case noTV
        case connecting
        case connected
        case waking
        case off
        case failed(String)
    }

    @Published private(set) var status: Status = .noTV
    @Published private(set) var info: TVInfo?
    @Published var volume: Double = 0
    @Published private(set) var muted = false
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var icons: [String: NSImage] = [:]
    @Published private(set) var discovered: [DiscoveredTV] = []
    @Published private(set) var isScanning = false
    @Published private(set) var pointerAvailable = false

    @Published var host: String { didSet { defaults.set(host, forKey: "host") } }
    @Published var mac: String { didSet { defaults.set(mac, forKey: "mac") } }

    var isConnected: Bool { status == .connected }

    private let defaults = UserDefaults.standard
    private var channel: RemoteChannel?
    private var connectTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    /// After we switch the TV off its network stays up for ~25 s; don't mistake that for "on".
    private var offUntil: Date?
    private var iconQueue: [String] = []
    private var iconInFlight: String?
    private var iconTimeout: Task<Void, Never>?
    private let iconCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.khuongduypham.tvremote/icons", isDirectory: true)

    /// One per app: the TV routes replies such as icons to a single "Mac Remote" client.
    static let shared = TVController()

    private init() {
        host = defaults.string(forKey: "host") ?? ""
        mac = defaults.string(forKey: "mac") ?? ""
        if host.isEmpty { scan(autoSelect: true) } else { connect() }
    }

    // MARK: - Connection

    func connect() {
        guard !host.isEmpty else { status = .noTV; return }
        retryTask?.cancel()
        connectTask?.cancel()
        connectTask = Task { await establish() }
    }

    /// Called when the popover opens so a TV switched on by its own remote shows up immediately.
    func refresh() {
        if isConnected { Task { await refreshVolume() } }
        else if status != .waking, status != .connecting, (offUntil ?? .distantPast) < Date() { connect() }
    }

    private func establish() async {
        // Background retries while the TV is off stay quiet instead of flashing "Connecting…".
        if status == .noTV || status == .connected { status = .connecting }
        let host = self.host
        do {
            let info = try await TVRestClient(host: host, timeout: 2.5).info()
            guard !Task.isCancelled else { return }
            self.info = info
            if mac.isEmpty, let m = info.wifiMac ?? WakeOnLAN.macAddress(for: host) { mac = m }

            let ch = RemoteChannel(host: host, transport: info.tokenAuthSupport ? .secure : .plain,
                                   token: defaults.string(forKey: "token.\(host)"))
            if ProcessInfo.processInfo.environment["TVREMOTE_DEBUG"] != nil {
                ch.log = { FileHandle.standardError.write(Data("\($0.prefix(160))\n".utf8)) }
            }
            ch.onEvent = { [weak self, weak ch] event in
                Task { @MainActor in
                    guard let self, let ch, ch === self.channel else { return }
                    self.handle(event, from: ch)
                }
            }
            channel?.disconnect()
            channel = ch
            let token = try await ch.connect()
            guard !Task.isCancelled, ch === channel else { return }
            if let token { defaults.set(token, forKey: "token.\(host)") }
            status = .connected
            ch.requestInstalledApps()
            await refreshVolume()
        } catch {
            guard !Task.isCancelled else { return }
            channel = nil
            if error is ChannelError {
                status = .failed(error.localizedDescription)
                scheduleRetry(after: 15)
            } else {
                // No answer on :8001 – the TV is off (or not on this network).
                status = .off
                scheduleRetry(after: 8)
            }
        }
    }

    private func handle(_ event: ChannelEvent, from ch: RemoteChannel) {
        switch event {
        case .installedApps(let list):
            apps = list // already in the user's Smart Hub order
            loadIcons(for: list, via: ch)
        case .icon(let path, let png):
            icons[path] = NSImage(data: png)
            try? FileManager.default.createDirectory(at: iconCache, withIntermediateDirectories: true)
            try? png.write(to: cacheFile(for: path))
            if iconInFlight == path { iconInFlight = nil }
            requestNextIcon(ch)
        case .other(let name, _):
            if name == "ms.remote.touchEnable" { pointerAvailable = true }
            if name == "ms.remote.touchDisable" { pointerAvailable = false }
        case .disconnected:
            channel = nil
            pointerAvailable = false
            iconInFlight = nil
            if status == .connected { status = .connecting }
            scheduleRetry(after: 2)
        case .unauthorized, .timeout, .connected:
            break
        }
    }

    // MARK: - App icons

    private func cacheFile(for path: String) -> URL {
        iconCache.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
    }

    private func loadIcons(for list: [InstalledApp], via ch: RemoteChannel) {
        for path in list.compactMap(\.icon) where icons[path] == nil {
            if let image = NSImage(contentsOf: cacheFile(for: path)) { icons[path] = image }
            else if !iconQueue.contains(path) { iconQueue.append(path) }
        }
        requestNextIcon(ch)
    }

    /// One request in flight at a time: during a burst of icon requests the TV drops remote keys.
    private func requestNextIcon(_ ch: RemoteChannel) {
        guard iconInFlight == nil, !iconQueue.isEmpty else { return }
        let path = iconQueue.removeFirst()
        iconInFlight = path
        ch.requestIcon(path)
        iconTimeout?.cancel()
        iconTimeout = Task { [weak self, weak ch] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, let ch, self.iconInFlight == path else { return }
            self.iconInFlight = nil
            self.requestNextIcon(ch)
        }
    }

    private func scheduleRetry(after seconds: Double) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if let until = self.offUntil, until > Date() { return self.scheduleRetry(after: until.timeIntervalSinceNow + 1) }
            self.connect()
        }
    }

    // MARK: - Power

    func togglePower() {
        if isConnected { turnOff() } else { turnOn() }
    }

    private func turnOff() {
        channel?.sendKey(.power)
        offUntil = Date().addingTimeInterval(35)
        let ch = channel
        channel = nil
        status = .off
        pointerAvailable = false
        // Keep the socket open briefly: the TV drops a command if the client hangs up right away.
        Task { try? await Task.sleep(for: .seconds(1.2)); ch?.disconnect() }
        scheduleRetry(after: 36)
    }

    private func turnOn() {
        let shuttingDown = (offUntil ?? .distantPast) > Date()
        offUntil = nil
        retryTask?.cancel()
        connectTask?.cancel()
        status = .waking
        let host = self.host, mac = self.mac
        connectTask = Task {
            // Still in its shutdown window the TV ignores Wake-on-LAN but accepts the power key.
            if shuttingDown, (try? await TVRestClient(host: host, timeout: 1.5).info()) != nil {
                await establish()
                if isConnected { channel?.sendKey(.power) }
                return
            }
            for _ in 0..<20 {
                if !mac.isEmpty { try? WakeOnLAN.wake(mac: mac, host: host) }
                if (try? await TVRestClient(host: host, timeout: 1.5).info()) != nil { break }
                if Task.isCancelled { return }
            }
            await establish()
        }
    }

    // MARK: - Remote

    func send(_ key: TVKey) {
        guard isConnected else { return }
        switch key {
        case .volumeUp, .volumeDown:
            // Step the absolute UPnP volume instead of sending the key: the TV drops repeat volume keys
            // while its volume bar animates in, so quick clicks got lost. It still shows the volume bar.
            setVolume(min(100, max(0, volume.rounded() + (key == .volumeUp ? 1 : -1))))
        default:
            channel?.sendKey(key)
            if key == .mute { refreshVolumeSoon() }
        }
    }

    func sendText(_ text: String) {
        guard isConnected, !text.isEmpty else { return }
        channel?.sendText(text)
    }

    func movePointer(dx: Int, dy: Int) { if isConnected { channel?.moveMouse(dx: dx, dy: dy) } }
    func click() { if isConnected { channel?.click() } }

    func launch(_ app: InstalledApp) {
        guard isConnected else { return }
        // The REST launch answers "ok" for native apps without opening them, so use the socket.
        channel?.launchApp(app.id, appType: app.appType)
    }

    func icon(for app: InstalledApp) -> NSImage? { app.icon.flatMap { icons[$0] } }

    // MARK: - Volume

    func setVolume(_ value: Double) {
        volume = value
        volumeTask?.cancel()
        let host = self.host
        volumeTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            try? await RenderingControl(host: host).setVolume(Int(value.rounded()))
        }
    }

    func refreshVolume() async {
        let rc = RenderingControl(host: host)
        if let v = try? await rc.volume() { volume = Double(v) }
        if let m = try? await rc.isMuted() { muted = m }
    }

    /// The renderer's volume lags the key by up to ~1 s, so read it twice.
    private func refreshVolumeSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await refreshVolume()
            try? await Task.sleep(for: .milliseconds(800))
            await refreshVolume()
        }
    }

    // MARK: - Discovery / settings

    func scan(autoSelect: Bool = false) {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let found = await Discovery.scan()
            discovered = found
            isScanning = false
            if autoSelect, host.isEmpty, found.count == 1 { select(found[0]) }
        }
    }

    func select(_ tv: DiscoveredTV) {
        host = tv.host
        mac = tv.wifiMac ?? ""
        apps = []
        icons = [:]
        connect()
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("TVRemote: login item change failed: \(error)")
            }
            objectWillChange.send()
        }
    }
}
