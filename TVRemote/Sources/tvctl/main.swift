import Foundation
import TVKit

let usage = """
tvctl – control a Samsung Tizen TV (2016+, e.g. UA49K5500) from the terminal

usage: tvctl [--host IP] <command> [args]

  discover               scan the local network for TVs
  info                   device description (/api/v2/)
  key KEY [KEY…]         send remote keys: KEY_VOLUP, or a name like volumeUp, home, enter
  keys                   list key names
  text "string"          type into the TV's on-screen keyboard
  apps                   list installed apps
  launch APP_ID          launch an app
  url URL                open a web page in the TV's browser
  close APP_ID           close an app
  volume [0-100]         read or set absolute volume
  mute [on|off]          read or set mute
  power                  turn off when on, wake over the network when off
  wake [MAC]             send Wake-on-LAN (MAC defaults to the TV's wifiMac / ARP entry)

The host defaults to $TV_HOST.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("tvctl: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
var host = ProcessInfo.processInfo.environment["TV_HOST"] ?? ""
if let i = args.firstIndex(of: "--host"), i + 1 < args.count {
    host = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
guard let command = args.first else { print(usage); exit(0) }
let rest = Array(args.dropFirst())

func requireHost() -> String {
    if host.isEmpty { fail("no TV address – pass --host IP or set TV_HOST (try `tvctl discover`)") }
    return host
}

/// Resumes a continuation exactly once, from whichever of the event or the timeout comes first.
final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    var cont: CheckedContinuation<T?, Never>?
    func finish(_ value: T?) {
        lock.lock(); defer { lock.unlock() }
        cont?.resume(returning: value)
        cont = nil
    }
}

/// Waits for the first channel event `pick` accepts, after running `trigger`.
func awaitEvent<T>(_ channel: RemoteChannel, timeout: TimeInterval = 5,
                   trigger: () -> Void, _ pick: @escaping (ChannelEvent) -> T?) async -> T? {
    let once = Once<T>()
    return await withCheckedContinuation { cont in
        once.cont = cont
        channel.onEvent = { event in if let v = pick(event) { once.finish(v) } }
        trigger()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.finish(nil) }
    }
}

func openChannel() async -> RemoteChannel {
    let host = requireHost()
    let info: TVInfo
    do { info = try await TVRestClient(host: host).info() } catch { fail("TV at \(host) is not answering (\(error.localizedDescription))") }
    let channel = RemoteChannel(host: host, transport: info.tokenAuthSupport ? .secure : .plain,
                                token: ProcessInfo.processInfo.environment["TV_TOKEN"])
    if ProcessInfo.processInfo.environment["TV_DEBUG"] != nil {
        channel.log = { FileHandle.standardError.write(Data("\($0)\n".utf8)) }
    }
    do {
        if let token = try await channel.connect(), ProcessInfo.processInfo.environment["TV_TOKEN"] != token {
            FileHandle.standardError.write(Data("tvctl: TV issued token \(token) – export TV_TOKEN to reuse it\n".utf8))
        }
    } catch { fail(error.localizedDescription) }
    return channel
}

/// The TV silently drops keys that arrive back to back, and `send` is fire-and-forget.
func settle(_ ms: Int = 350) async { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }

/// The TV discards a command whose client hangs up within ~0.3 s of sending it, so linger before closing.
func close(_ channel: RemoteChannel) async {
    await settle(1200)
    channel.disconnect()
}

func macFor(_ host: String) async -> String? {
    if let mac = try? await TVRestClient(host: host, timeout: 1.5).info().wifiMac { return mac }
    return WakeOnLAN.macAddress(for: host)
}

switch command {
case "discover":
    let tvs = await Discovery.scan()
    if tvs.isEmpty { fail("no TVs answered on the local network – is the TV on?") }
    for tv in tvs { print("\(tv.host)\t\(tv.modelName)\t\(tv.name)\t\(tv.wifiMac ?? "-")") }

case "info":
    do {
        let i = try await TVRestClient(host: requireHost()).info()
        print("""
            name        \(i.name)
            model       \(i.modelName) (\(i.model ?? "?"))
            ip          \(i.ip ?? host)
            mac         \(i.wifiMac ?? "-")
            network     \(i.networkType ?? "-")
            resolution  \(i.resolution ?? "-")
            transport   \(i.tokenAuthSupport ? "wss :8002 + token" : "ws :8001")
            """)
    } catch { fail(error.localizedDescription) }

case "keys":
    for key in TVKey.allCases { print("\("\(key)".padding(toLength: 18, withPad: " ", startingAt: 0)) \(key.rawValue)") }

case "key":
    if rest.isEmpty { fail("which key? e.g. `tvctl key volumeUp`") }
    let channel = await openChannel()
    for name in rest {
        channel.sendKey(TVKey.code(for: name))
        await settle()
    }
    await close(channel)

case "text":
    guard let text = rest.first else { fail("what text?") }
    let channel = await openChannel()
    channel.sendText(text)
    await close(channel)

case "apps":
    let channel = await openChannel()
    let apps = await awaitEvent(channel, trigger: { channel.requestInstalledApps() }) { event -> [InstalledApp]? in
        if case .installedApps(let apps) = event { return apps }
        return nil
    }
    channel.disconnect()
    guard let apps else { fail("the TV did not send its app list") }
    for app in apps.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
        print("\(app.id.padding(toLength: 20, withPad: " ", startingAt: 0)) \(app.appType == 4 ? "native" : "web   ") \(app.name)")
    }

case "launch":
    guard let id = rest.first else { fail("which app id? see `tvctl apps`") }
    // REST POST answers {"ok":true} for native apps without launching them, so always launch over
    // the socket with the action the app list reports (web → DEEP_LINK, native → NATIVE_LAUNCH).
    let channel = await openChannel()
    let apps = await awaitEvent(channel, trigger: { channel.requestInstalledApps() }) { event -> [InstalledApp]? in
        if case .installedApps(let apps) = event { return apps }
        return nil
    }
    let appType = apps?.first(where: { $0.id == id })?.appType ?? (id.contains(".") ? 4 : 2)
    channel.launchApp(id, appType: appType)
    await close(channel)

case "url":
    guard let url = rest.first else { fail("which URL?") }
    let channel = await openChannel()
    channel.openURL(url.contains("://") ? url : "https://" + url)
    await close(channel)

case "close":
    guard let id = rest.first else { fail("which app id?") }
    do { try await TVRestClient(host: requireHost()).closeApp(id) } catch { fail(error.localizedDescription) }

case "volume":
    let rc = RenderingControl(host: requireHost())
    do {
        if let arg = rest.first {
            guard let v = Int(arg) else { fail("volume must be 0-100") }
            try await rc.setVolume(v)
        }
        print(try await rc.volume())
    } catch { fail(error.localizedDescription) }

case "mute":
    let rc = RenderingControl(host: requireHost())
    do {
        if let arg = rest.first { try await rc.setMute(["on", "1", "true", "yes"].contains(arg.lowercased())) }
        print(try await rc.isMuted() ? "on" : "off")
    } catch { fail(error.localizedDescription) }

case "power":
    let host = requireHost()
    if (try? await TVRestClient(host: host, timeout: 1.5).info()) != nil {
        let channel = await openChannel()
        channel.sendKey(.power)
        await close(channel)
        print("sent power")
    } else {
        guard let mac = await macFor(host) else { fail("TV is off and its MAC is unknown – run `tvctl wake MAC`") }
        try? WakeOnLAN.wake(mac: mac, host: host)
        print("TV is off – sent Wake-on-LAN to \(mac)")
    }

case "wake":
    var mac = rest.first
    if mac == nil, !host.isEmpty { mac = await macFor(host) }
    guard let mac else { fail("which MAC?") }
    do { try WakeOnLAN.wake(mac: mac, host: host.isEmpty ? nil : host); print("sent Wake-on-LAN to \(mac)") }
    catch { fail(error.localizedDescription) }

default:
    print(usage)
    exit(2)
}
