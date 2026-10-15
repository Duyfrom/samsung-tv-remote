import SwiftUI
import TVKit

struct RemoteView: View {
    @EnvironmentObject private var tv: TVController
    @State private var showSettings = false
    @State private var tab: Tab
    @FocusState private var keyboardFocus: Bool

    enum Tab: String, CaseIterable { case apps = "Apps", numbers = "Numbers", type = "Type" }

    /// `true` when shown in `MainWindow` rather than the menu bar popover.
    var inWindow = false

    init(initialTab: Tab = .apps, inWindow: Bool = false) {
        _tab = State(initialValue: initialTab)
        self.inWindow = inWindow
    }

    var body: some View {
        VStack(spacing: 12) {
            Header(showSettings: $showSettings, inWindow: inWindow)
            if showSettings || tv.status == .noTV {
                SettingsView(done: { showSettings = false })
            } else {
                Group {
                    RemotePad()
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch tab {
                    case .apps: AppsGrid()
                    case .numbers: NumberPad()
                    case .type: TypePanel()
                    }
                }
                .disabled(!tv.isConnected)
                .opacity(tv.isConnected ? 1 : 0.4)
                .animation(.easeOut(duration: 0.2), value: tv.isConnected)
                // Outside the disabled group: "turn on the TV" has to work while it's off.
                ChatBar()
            }
        }
        .padding(14)
        .frame(width: 312)
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocus)
        .onKeyPress(phases: .down, action: handleKey)
        .onAppear {
            tv.refresh()
            keyboardFocus = true
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard tv.isConnected, !showSettings else { return .ignored }
        // Typing in the chat or text fields must not drive the TV.
        if NSApp.keyWindow?.firstResponder is NSText { return .ignored }
        let key: TVKey?
        switch press.key {
        case .upArrow: key = .up
        case .downArrow: key = .down
        case .leftArrow: key = .left
        case .rightArrow: key = .right
        case .return: key = .enter
        case .delete: key = .back
        default:
            switch press.characters.lowercased() {
            case "+", "=": key = .volumeUp
            case "-", "_": key = .volumeDown
            case "m": key = .mute
            case "h": key = .home
            case let c where c.count == 1 && Int(c) != nil: key = .number(Int(c)!)
            default: key = nil
            }
        }
        guard let key else { return .ignored }
        tv.send(key)
        return .handled
    }
}

// MARK: - Header

private struct Header: View {
    @EnvironmentObject private var tv: TVController
    @Binding var showSettings: Bool
    let inWindow: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .shadow(color: dotColor.opacity(0.6), radius: tv.isConnected ? 3 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(tv.info?.name ?? "Samsung TV")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if !inWindow {
                Button { MainWindow.shared.show() } label: {
                    Image(systemName: "macwindow")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(KeyStyle(shape: .circle))
                .help("Open in a window")
            }
            Button { showSettings.toggle() } label: {
                Image(systemName: showSettings ? "xmark" : "gearshape")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(KeyStyle(shape: .circle))
            .help(showSettings ? "Close settings" : "Settings")
            Button { tv.togglePower() } label: {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tv.isConnected ? .white : .primary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(KeyStyle(shape: .circle, tint: tv.isConnected ? .red : nil))
            .disabled(tv.host.isEmpty || tv.status == .waking)
            .help(tv.isConnected ? "Turn the TV off" : "Turn the TV on (Wake-on-LAN)")
        }
    }

    private var dotColor: Color {
        switch tv.status {
        case .connected: return .green
        case .connecting, .waking: return .orange
        case .failed: return .red
        case .off, .noTV: return .secondary
        }
    }

    private var subtitle: String {
        switch tv.status {
        case .noTV: return "Pick your TV below"
        case .connecting: return "Connecting to \(tv.host)…"
        case .connected: return [tv.info?.modelName, tv.host].compactMap { $0 }.joined(separator: " · ")
        case .waking: return "Waking the TV…"
        case .off: return "Off – press ⏻ to turn on"
        case .failed(let why): return why
        }
    }
}

// MARK: - Remote pad

private struct RemotePad: View {
    @EnvironmentObject private var tv: TVController

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                LabeledKey(.source, "cable.connector.horizontal", "Source")
                LabeledKey(.menu, "slider.horizontal.3", "Menu")
                LabeledKey(.guide, "list.bullet.rectangle", "Guide")
                LabeledKey(.info, "info.circle", "Info")
            }

            HStack(alignment: .center, spacing: 0) {
                Rocker(label: "VOL", up: .volumeUp, upSymbol: "plus", down: .volumeDown, downSymbol: "minus",
                       middle: .mute, middleSymbol: tv.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                Spacer(minLength: 0)
                DPad()
                Spacer(minLength: 0)
                Rocker(label: "CH", up: .channelUp, upSymbol: "chevron.up", down: .channelDown, downSymbol: "chevron.down",
                       middle: .channelList, middleSymbol: "list.number")
            }

            HStack(spacing: 6) {
                LabeledKey(.back, "arrow.uturn.backward", "Back")
                LabeledKey(.home, "house.fill", "Home")
                LabeledKey(.exit, "xmark.square", "Exit")
            }

            HStack(spacing: 8) {
                Button { tv.send(.mute) } label: {
                    Image(systemName: tv.muted ? "speaker.slash.fill" : "speaker.fill")
                        .frame(width: 16)
                        .foregroundStyle(tv.muted ? .red : .secondary)
                }
                .buttonStyle(.plain)
                Slider(value: Binding(get: { tv.volume }, set: { tv.setVolume($0) }), in: 0...100)
                    .controlSize(.small)
                Text("\(Int(tv.volume))")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            }

            HStack(spacing: 6) {
                IconKey(.rewind, "backward.fill")
                IconKey(.play, "play.fill")
                IconKey(.pause, "pause.fill")
                IconKey(.stop, "stop.fill")
                IconKey(.fastForward, "forward.fill")
            }
        }
    }
}

private struct DPad: View {
    @EnvironmentObject private var tv: TVController
    private let size: CGFloat = 156

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(0.06))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
            arrow(.up, "chevron.up").offset(y: -size * 0.35)
            arrow(.down, "chevron.down").offset(y: size * 0.35)
            arrow(.left, "chevron.left").offset(x: -size * 0.35)
            arrow(.right, "chevron.right").offset(x: size * 0.35)
            Button { tv.send(.enter) } label: {
                Text("OK")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(KeyStyle(shape: .circle, tint: .accentColor))
        }
        .frame(width: size, height: size)
    }

    private func arrow(_ key: TVKey, _ symbol: String) -> some View {
        Button { tv.send(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(KeyStyle(shape: .circle, idle: .clear))
    }
}

private struct Rocker: View {
    @EnvironmentObject private var tv: TVController
    let label: String
    let up: TVKey, upSymbol: String
    let down: TVKey, downSymbol: String
    let middle: TVKey, middleSymbol: String

    var body: some View {
        VStack(spacing: 2) {
            key(up, upSymbol)
            Button { tv.send(middle) } label: {
                VStack(spacing: 2) {
                    Image(systemName: middleSymbol).font(.system(size: 11))
                    Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }
                .frame(width: 46, height: 40)
            }
            .buttonStyle(KeyStyle(shape: .capsule, idle: .clear))
            key(down, downSymbol)
        }
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func key(_ k: TVKey, _ symbol: String) -> some View {
        Button { tv.send(k) } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 46, height: 44)
        }
        .buttonStyle(KeyStyle(shape: .capsule, idle: .clear))
    }
}

private struct LabeledKey: View {
    @EnvironmentObject private var tv: TVController
    let key: TVKey, symbol: String, title: String
    init(_ key: TVKey, _ symbol: String, _ title: String) { (self.key, self.symbol, self.title) = (key, symbol, title) }

    var body: some View {
        Button { tv.send(key) } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 13))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(KeyStyle())
    }
}

private struct IconKey: View {
    @EnvironmentObject private var tv: TVController
    let key: TVKey, symbol: String
    init(_ key: TVKey, _ symbol: String) { (self.key, self.symbol) = (key, symbol) }

    var body: some View {
        Button { tv.send(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(KeyStyle())
    }
}

// MARK: - Bottom panels

private struct AppsGrid: View {
    @EnvironmentObject private var tv: TVController

    /// The grid shows only these (one tile per name); Claude can still open any installed app.
    private static let shown: Set<String> = ["youtube", "netflix", "fpt play", "web browser"]

    private var apps: [InstalledApp] {
        var seen = Set<String>()
        return tv.apps.filter { Self.shown.contains($0.name.lowercased()) && seen.insert($0.name.lowercased()).inserted }
    }

    var body: some View {
        ScrollView {
            if apps.isEmpty {
                Text(tv.isConnected ? "Loading apps…" : "Apps appear once the TV is connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 8) {
                    ForEach(apps) { app in
                        Button { tv.launch(app) } label: {
                            VStack(spacing: 4) {
                                AppIcon(app: app, image: tv.icon(for: app))
                                Text(app.name)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(KeyStyle(idle: .clear))
                        .help(app.name)
                    }
                }
            }
        }
        .frame(height: 148)
    }
}

private struct AppIcon: View {
    let app: InstalledApp
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [hue.opacity(0.9), hue.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Text(String(app.name.prefix(1))).font(.system(size: 18, weight: .bold)).foregroundStyle(.white))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    private var hue: Color {
        Color(hue: Double(abs(app.id.hashValue) % 360) / 360, saturation: 0.55, brightness: 0.8)
    }
}

private struct NumberPad: View {
    @EnvironmentObject private var tv: TVController

    var body: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(1...9, id: \.self) { digit($0) }
                textKey(.minus, "–")
                digit(0)
                textKey(.previousChannel, "PRE-CH")
            }
            HStack(spacing: 6) {
                colorKey(.red, .red, "A")
                colorKey(.green, .green, "B")
                colorKey(.yellow, .yellow, "C")
                colorKey(.blue, .blue, "D")
            }
        }
        .frame(height: 148, alignment: .top)
    }

    private func digit(_ n: Int) -> some View { textKey(.number(n), "\(n)") }

    private func textKey(_ key: TVKey, _ title: String) -> some View {
        Button { tv.send(key) } label: {
            Text(title)
                .font(.system(size: title.count > 2 ? 10 : 14, weight: .semibold).monospacedDigit())
                .frame(maxWidth: .infinity, minHeight: 26)
        }
        .buttonStyle(KeyStyle())
    }

    private func colorKey(_ key: TVKey, _ color: Color, _ title: String) -> some View {
        Button { tv.send(key) } label: {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 22)
        }
        .buttonStyle(KeyStyle(tint: color.opacity(0.85)))
    }
}

private struct TypePanel: View {
    @EnvironmentObject private var tv: TVController
    @State private var text = ""
    @State private var lastDrag: CGPoint?
    @State private var dragDistance: CGFloat = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Type, then Return to send to the TV", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { tv.sendText(text) }
                Button("Send") { tv.sendText(text) }
                    .controlSize(.small)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                VStack(spacing: 4) {
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.system(size: 18))
                    Text(tv.pointerAvailable ? "Drag to move the pointer, tap to click" : "Touchpad works in the TV's Web Browser")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if let last = lastDrag {
                            let dx = value.location.x - last.x, dy = value.location.y - last.y
                            dragDistance += abs(dx) + abs(dy)
                            tv.movePointer(dx: Int((dx * 2.5).rounded()), dy: Int((dy * 2.5).rounded()))
                        }
                        lastDrag = value.location
                    }
                    .onEnded { _ in
                        if dragDistance < 4 { tv.click() }
                        lastDrag = nil
                        dragDistance = 0
                    }
            )
        }
        .frame(height: 148)
    }
}

// MARK: - Style

struct KeyStyle: ButtonStyle {
    enum Shape { case rounded, circle, capsule }
    var shape: Shape = .rounded
    var tint: Color? = nil
    var idle: Color = Color.primary.opacity(0.07)

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = configuration.isPressed
            ? (tint ?? .accentColor).opacity(0.45)
            : (tint ?? idle)
        configuration.label
            .contentShape(Rectangle())
            .background(background(fill))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    @ViewBuilder private func background(_ fill: Color) -> some View {
        switch shape {
        case .rounded: RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill)
        case .circle: Circle().fill(fill)
        case .capsule: Capsule().fill(fill)
        }
    }
}
