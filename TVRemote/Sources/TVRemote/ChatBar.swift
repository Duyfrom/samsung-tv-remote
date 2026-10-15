import SwiftUI
import TVKit

/// Bottom of the remote: Claude chat, saved shortcuts and the shortcut recorder.
struct ChatBar: View {
    @EnvironmentObject private var tv: TVController
    @ObservedObject private var chat = ClaudeChat.shared
    @State private var text = ""
    @State private var shortcutName = ""

    var body: some View {
        VStack(spacing: 6) {
            if !chat.lines.isEmpty { transcript }
            if let steps = tv.recording {
                recorder(steps)
            } else if !tv.shortcuts.isEmpty {
                shortcutChips
            }
            HStack(spacing: 6) {
                Button {
                    shortcutName = ""
                    tv.startRecording()
                } label: {
                    Image(systemName: "record.circle")
                        .foregroundStyle(tv.recording == nil ? Color.secondary : Color.red)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(KeyStyle(shape: .circle))
                .disabled(tv.recording != nil || !tv.isConnected)
                .help("Record a shortcut: press it, use the remote, then name it")

                TextField("Ask Claude… “mở FPT Play”", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)

                if chat.isBusy {
                    ProgressView().controlSize(.small).frame(width: 26, height: 26)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(text.isEmpty ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(text.isEmpty)
                    .help("Send to Claude (Haiku 5.5)")
                }
            }
        }
    }

    private func send() {
        chat.send(text)
        text = ""
    }

    private var transcript: some View {
        ZStack(alignment: .topTrailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(chat.lines) { line in
                            LineView(line: line).id(line.id)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chat.lines) {
                    if let last = chat.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onAppear { if let last = chat.lines.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            Button { chat.clear() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(4)
            .help("Clear the conversation")
        }
        .frame(maxHeight: 104)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var shortcutChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tv.shortcuts) { shortcut in
                    Button { tv.run(shortcut) } label: {
                        Label(shortcut.name, systemImage: "bolt.fill")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(KeyStyle(shape: .capsule))
                    .disabled(!tv.isConnected)
                    .help(shortcut.summary)
                    .contextMenu {
                        Button("Delete “\(shortcut.name)”", role: .destructive) { tv.deleteShortcut(shortcut) }
                    }
                }
            }
        }
    }

    private func recorder(_ steps: [Shortcut.Step]) -> some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text("\(steps.count) step\(steps.count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            TextField("Name, e.g. VTV1", text: $shortcutName)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit { tv.stopRecording(saveAs: shortcutName) }
            Button("Save") { tv.stopRecording(saveAs: shortcutName) }
                .controlSize(.small)
                .disabled(shortcutName.trimmingCharacters(in: .whitespaces).isEmpty || steps.isEmpty)
            Button { tv.stopRecording(saveAs: "") } label: { Image(systemName: "xmark") }
                .controlSize(.small)
                .help("Discard the recording")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.08)))
    }
}

private struct LineView: View {
    let line: ClaudeChat.Line

    var body: some View {
        switch line.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(line.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.accentColor))
                    .textSelection(.enabled)
            }
            .padding(.trailing, 16) // room for the clear button
        case .assistant:
            Text(line.text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .padding(.trailing, 18)
        case .action:
            Label(line.text, systemImage: "bolt.horizontal.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .error:
            Label(line.text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}
