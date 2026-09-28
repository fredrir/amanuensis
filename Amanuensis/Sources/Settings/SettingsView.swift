import Carbon
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case shortcuts = "Shortcuts"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "command"
        }
    }
}

/// Drives the preference-style toolbar tab selection from the window controller.
@MainActor
final class SettingsTabModel: ObservableObject {
    @Published var selectedTab: SettingsTab {
        didSet {
            UserDefaults.standard.set(
                selectedTab.rawValue, forKey: SettingsPersistence.windowTabKey)
        }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: SettingsPersistence.windowTabKey),
            let tab = SettingsTab(rawValue: raw)
        {
            selectedTab = tab
        } else {
            selectedTab = .general
        }
    }
}

@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published var action: ShortcutAction?
    @Published var error: String?
    private var monitor: Any?

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        action = nil
        ShortcutMonitor.shared.suspendForRecording(false)
    }

    func start(
        _ action: ShortcutAction, save: @escaping (ShortcutMonitor.KeyboardShortcut?) -> String?
    ) {
        stop()
        self.action = action
        error = nil
        ShortcutMonitor.shared.suspendForRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .leftMouseDown, .rightMouseDown,
        ]) { [weak self] event in
            guard let self else { return event }
            guard event.type == .keyDown else {
                self.stop()
                return event
            }
            if event.isARepeat { return nil }
            let shortcut = ShortcutMonitor.KeyboardShortcut(
                keyCode: Int(event.keyCode), modifiers: event.modifierFlags)
            if shortcut.modifiers.isEmpty && event.keyCode == kVK_Escape {
                self.stop()
            } else if shortcut.modifiers.isEmpty
                && (event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete)
            {
                self.error = save(nil)
                self.stop()
            } else if let error = shortcut.validationError {
                self.error = error
            } else if let error = save(shortcut) {
                self.error = error
            } else {
                self.stop()
            }
            return nil
        }
    }
}

struct ShortcutRecorderButton: View {
    let label: String
    let action: ShortcutAction
    let shortcut: ShortcutMonitor.KeyboardShortcut?
    let otherShortcuts: [ShortcutMonitor.KeyboardShortcut]
    let save: (ShortcutMonitor.KeyboardShortcut?) -> Void
    @ObservedObject var recorder: ShortcutRecorder
    @ObservedObject private var monitor = ShortcutMonitor.shared

    private var isRecording: Bool { recorder.action == action }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    if isRecording {
                        recorder.stop()
                    } else {
                        recorder.start(action) { candidate in
                            if let candidate, otherShortcuts.contains(candidate) {
                                return "Shortcut assigned to another action"
                            }
                            save(candidate)
                            return nil
                        }
                    }
                } label: {
                    HStack {
                        if isRecording {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                        }
                        Text(
                            isRecording
                                ? "Press keys…" : (shortcut?.description ?? "Record Shortcut")
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(
                    "\(label): \(isRecording ? "recording" : shortcut?.description ?? "not set")")

                Button {
                    recorder.stop()
                    save(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(shortcut == nil && !isRecording)
                .help("Clear shortcut")
                .accessibilityLabel("Clear \(label)")
            }

            if let error = isRecording ? recorder.error : monitor.registrationErrors[action] {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    let action: ShortcutAction
    let shortcut: ShortcutMonitor.KeyboardShortcut?
    let otherShortcuts: [ShortcutMonitor.KeyboardShortcut]
    let save: (ShortcutMonitor.KeyboardShortcut?) -> Void
    @ObservedObject var recorder: ShortcutRecorder

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.medium)
            }
            Spacer()
            ShortcutRecorderButton(
                label: title,
                action: action,
                shortcut: shortcut,
                otherShortcuts: otherShortcuts,
                save: save,
                recorder: recorder
            )
            .frame(width: 170)
        }
    }
}

struct ShortcutsSettingsView: View {
    @ObservedObject var recorder: ShortcutRecorder
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var providerStore = ProviderStore.shared
    #if DEBUG
        @ObservedObject private var injectionObserver = InjectionObserver.shared
    #endif

    var body: some View {
        Form {
            Section {
                ShortcutRow(
                    title: "Extract Text",
                    action: .visionOCR,
                    shortcut: settings.textShortcut,
                    otherShortcuts: [settings.latexShortcut, settings.markdownShortcut].compactMap {
                        $0
                    },
                    save: { settings.textShortcut = $0 },
                    recorder: recorder
                )

                Divider()

                ShortcutRow(
                    title: "LaTeX",

                    action: .latex,
                    shortcut: settings.latexShortcut,
                    otherShortcuts: [settings.textShortcut, settings.markdownShortcut].compactMap {
                        $0
                    },
                    save: { settings.latexShortcut = $0 },
                    recorder: recorder
                )

                Divider()

                ShortcutRow(
                    title: "Markdown",
                    action: .markdown,
                    shortcut: settings.markdownShortcut,
                    otherShortcuts: [settings.textShortcut, settings.latexShortcut].compactMap {
                        $0
                    },
                    save: { settings.markdownShortcut = $0 },
                    recorder: recorder
                )
            } header: {
                Text("Global Hotkeys")
            }
        }
        .formStyle(.grouped)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsTabModel
    @StateObject private var recorder = ShortcutRecorder()
    #if DEBUG
        @ObservedObject private var injectionObserver = InjectionObserver.shared
    #endif

    var body: some View {
        Group {
            switch model.selectedTab {
            case .general:
                ProviderSettingsView()
            case .shortcuts:
                ShortcutsSettingsView(recorder: recorder)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 520, minHeight: 460)
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))
        ) { _ in
            recorder.objectWillChange.send()
        }
        .onDisappear { recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
            _ in recorder.stop()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
        ) { _ in recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            recorder.stop()
        }
    }
}

#Preview {
    SettingsView(model: SettingsTabModel())
}
