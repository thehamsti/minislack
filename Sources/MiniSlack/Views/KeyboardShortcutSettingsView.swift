import AppKit
import SwiftUI

/// Editor for every configurable binding. Recording captures the next keystroke
/// and reports rejections and displaced commands inline.
struct KeyboardShortcutSettingsView: View {
    let shortcuts: KeyboardShortcutStore
    var dismiss: (() -> Void)?
    @State private var recordingCommand: KeyboardCommand?
    @State private var message: ShortcutEditorMessage?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(KeyboardCommandSection.allCases) { section in
                        sectionView(section)
                    }
                }
                .padding(16)
            }

            Divider()

            footer
        }
        .frame(width: 460, height: 540)
        .onDisappear {
            recordingCommand = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Keyboard shortcuts")
                .font(.headline)
            Text("Click a shortcut, then press the keys you want.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func sectionView(_ section: KeyboardCommandSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
            Text(section.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(commands(in: section)) { command in
                    if command != commands(in: section).first {
                        Divider()
                    }
                    KeyboardShortcutRow(
                        command: command,
                        binding: shortcuts.binding(for: command),
                        isCustomized: shortcuts.isCustomized(command),
                        isRecording: recordingCommand == command,
                        startRecording: { startRecording(command) },
                        cancelRecording: { recordingCommand = nil },
                        record: { record($0, for: command) },
                        clear: {
                            shortcuts.clear(command)
                            recordingCommand = nil
                            message = .init(
                                text: "\(command.title) has no shortcut.",
                                isWarning: false
                            )
                        },
                        reset: {
                            shortcuts.resetToDefault(command)
                            recordingCommand = nil
                            message = nil
                        }
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let message {
                Label(
                    message.text,
                    systemImage: message.isWarning
                        ? "exclamationmark.triangle.fill"
                        : "info.circle"
                )
                .font(.caption)
                .foregroundStyle(message.isWarning ? Color.orange : Color.secondary)
                .lineLimit(2)
            }

            Spacer(minLength: 4)

            Button("Restore Defaults") {
                shortcuts.resetAllToDefaults()
                recordingCommand = nil
                message = .init(text: "All shortcuts restored.", isWarning: false)
            }
            .controlSize(.small)
            .disabled(!shortcuts.settings.isCustomized)

            if let dismiss {
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func commands(in section: KeyboardCommandSection) -> [KeyboardCommand] {
        KeyboardCommand.allCases.filter { $0.section == section }
    }

    private func startRecording(_ command: KeyboardCommand) {
        recordingCommand = command
        message = .init(
            text: "Press the keys for “\(command.title)”. Esc cancels.",
            isWarning: false
        )
    }

    private func record(_ binding: KeyBinding, for command: KeyboardCommand) {
        switch shortcuts.assign(binding, to: command) {
        case let .success(displaced):
            recordingCommand = nil
            if displaced.isEmpty {
                message = .init(
                    text: "\(command.title): \(binding.displayString)",
                    isWarning: false
                )
            } else {
                let names = displaced.map(\.title).joined(separator: ", ")
                message = .init(
                    text: "\(binding.displayString) taken from \(names).",
                    isWarning: true
                )
            }
        case let .failure(rejection):
            message = .init(text: rejection.message, isWarning: true)
        }
    }
}

private struct ShortcutEditorMessage {
    let text: String
    let isWarning: Bool
}

private struct KeyboardShortcutRow: View {
    let command: KeyboardCommand
    let binding: KeyBinding?
    let isCustomized: Bool
    let isRecording: Bool
    let startRecording: () -> Void
    let cancelRecording: () -> Void
    let record: (KeyBinding) -> Void
    let clear: () -> Void
    let reset: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(command.title)
                .font(.callout)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                if isRecording {
                    cancelRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(label)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(labelStyle)
                    .frame(minWidth: 74)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                isRecording
                                    ? Color.orange.opacity(0.16)
                                    : Color.primary.opacity(0.06)
                            )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                isRecording
                                    ? Color.orange.opacity(0.65)
                                    : Color.primary.opacity(0.08),
                                lineWidth: isRecording ? 1 : 0.5
                            )
                    }
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Press the new keys, or Esc to cancel" : "Click to record a new shortcut")
            .accessibilityLabel("\(command.title) shortcut: \(binding?.displayString ?? "not set")")

            Button(action: clear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(binding == nil)
            .opacity(binding == nil ? 0.3 : 1)
            .help("Remove this shortcut")
            .accessibilityLabel("Remove \(command.title) shortcut")

            Button(action: reset) {
                Image(systemName: "arrow.counterclockwise")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(!isCustomized)
            .opacity(isCustomized ? 1 : 0.3)
            .help("Restore the default (\(command.defaultBinding.displayString))")
            .accessibilityLabel("Restore default \(command.title) shortcut")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            if isRecording {
                ShortcutRecorder(onCancel: cancelRecording, onCapture: record)
                    .frame(width: 0, height: 0)
            }
        }
    }

    private var label: String {
        if isRecording {
            return "Press keys…"
        }
        return binding?.displayString ?? "Not set"
    }

    private var labelStyle: AnyShapeStyle {
        if isRecording {
            return AnyShapeStyle(Color.orange)
        }
        return binding == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
    }
}

/// Swallows key events while a row is recording so the captured keystroke never
/// reaches the app.
private struct ShortcutRecorder: NSViewRepresentable {
    let onCancel: () -> Void
    let onCapture: (KeyBinding) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCancel: onCancel, onCapture: onCapture)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCancel = onCancel
        context.coordinator.onCapture = onCapture
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var onCancel: () -> Void
        var onCapture: (KeyBinding) -> Void
        private var monitor: Any?

        init(onCancel: @escaping () -> Void, onCapture: @escaping (KeyBinding) -> Void) {
            self.onCancel = onCancel
            self.onCapture = onCapture
        }

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else {
                    return event
                }
                if event.keyCode == 53 {
                    onCancel()
                    return nil
                }
                guard let binding = KeyBinding(event: event) else {
                    return nil
                }
                onCapture(binding)
                return nil
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
