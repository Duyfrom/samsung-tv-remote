import Foundation

/// Remote key codes accepted by Samsung Tizen TVs on the `samsung.remote.control` channel.
///
/// Names were recovered with REA from Samsung's own PC Smart View 2 assembly
/// (`SmartView2.Devices.RemoteControls.TvKeyCode`, 280 entries). Only the keys that are
/// useful from a desktop remote are surfaced here; any other `KEY_*` string can be sent
/// through `RemoteChannel.sendKey(_:)` directly.
public enum TVKey: String, CaseIterable, Sendable {
    // Power / input
    case power = "KEY_POWER"
    case powerOff = "KEY_POWEROFF"
    case source = "KEY_SOURCE"
    case hdmi = "KEY_HDMI"
    case hdmi1 = "KEY_HDMI1"
    case hdmi2 = "KEY_HDMI2"
    case hdmi3 = "KEY_HDMI3"
    case tv = "KEY_TV"

    // Navigation
    case home = "KEY_HOME"
    case menu = "KEY_MENU"
    case up = "KEY_UP"
    case down = "KEY_DOWN"
    case left = "KEY_LEFT"
    case right = "KEY_RIGHT"
    case enter = "KEY_ENTER"
    case back = "KEY_RETURN"
    case exit = "KEY_EXIT"
    case info = "KEY_INFO"
    case tools = "KEY_TOOLS"
    case guide = "KEY_GUIDE"
    case search = "KEY_SEARCH"
    case eManual = "KEY_EMANUAL"

    // Volume / channel
    case volumeUp = "KEY_VOLUP"
    case volumeDown = "KEY_VOLDOWN"
    case mute = "KEY_MUTE"
    case channelUp = "KEY_CHUP"
    case channelDown = "KEY_CHDOWN"
    case previousChannel = "KEY_PRECH"
    case channelList = "KEY_CH_LIST"

    // Numbers
    case num0 = "KEY_0", num1 = "KEY_1", num2 = "KEY_2", num3 = "KEY_3", num4 = "KEY_4"
    case num5 = "KEY_5", num6 = "KEY_6", num7 = "KEY_7", num8 = "KEY_8", num9 = "KEY_9"
    case minus = "KEY_PLUS100"

    // Colour keys (A/B/C/D on Samsung remotes)
    case red = "KEY_RED"
    case green = "KEY_GREEN"
    case yellow = "KEY_YELLOW"
    case blue = "KEY_CYAN"

    // Media
    case play = "KEY_PLAY"
    case pause = "KEY_PAUSE"
    case stop = "KEY_STOP"
    case rewind = "KEY_REWIND"
    case fastForward = "KEY_FF"
    case record = "KEY_REC"

    // Picture / sound
    case pictureMode = "KEY_PMODE"
    case soundMode = "KEY_SOUND_MODE"
    case aspect = "KEY_ASPECT"
    case subtitle = "KEY_SUB_TITLE"
    case caption = "KEY_CAPTION"
    case sleep = "KEY_SLEEP"

    public static func number(_ n: Int) -> TVKey {
        [.num0, .num1, .num2, .num3, .num4, .num5, .num6, .num7, .num8, .num9][max(0, min(9, n))]
    }
}
