import AppKit
import Combine
import SwiftUI

/// UserDefaults keys used to restore the settings window across dev-mode relaunches.
enum SettingsPersistence {
    static let windowAutosaveName = "ScreenScribeSettings"
    static let windowWasOpenKey = "settingsWindowWasOpen"
    static let windowTabKey = "settingsWindowTab"
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    static var shared: SettingsWindowController?

    private let tabModel = SettingsTabModel()
    private var cancellables = Set<AnyCancellable>()

    private enum ToolbarID {
        static let provider = NSToolbarItem.Identifier("settings.provider")
        static let shortcuts = NSToolbarItem.Identifier("settings.shortcuts")
    }

    convenience init() {
        let window = Self.createWindow()
        self.init(window: window)
        configureWindow(window)
        observeTabSelection()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func showWindow(_ sender: Any?) {
        if window == nil {
            let window = Self.createWindow()
            self.window = window
            configureWindow(window)
        }

        UserDefaults.standard.set(true, forKey: SettingsPersistence.windowWasOpenKey)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: SettingsPersistence.windowWasOpenKey)
        Self.shared = nil
    }

    static func showSettings() {
        if shared == nil {
            shared = SettingsWindowController()
        }
        shared?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureWindow(_ window: NSWindow) {
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SettingsView(model: tabModel))
        configureToolbar(for: window)
    }

    private func observeTabSelection() {
        tabModel.$selectedTab
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab in
                self?.window?.toolbar?.selectedItemIdentifier = Self.identifier(for: tab)
            }
            .store(in: &cancellables)
    }

    private func configureToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = Self.identifier(for: tabModel.selectedTab)
        window.toolbar = toolbar
        window.toolbarStyle = .preference
    }

    private static func createWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 440)
        // Keep the window in the same place across dev-mode hot reloads.
        window.setFrameAutosaveName(SettingsPersistence.windowAutosaveName)
        return window
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.provider, ToolbarID.shortcuts, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ToolbarID.provider, ToolbarID.shortcuts, .flexibleSpace]
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.provider, ToolbarID.shortcuts]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.provider:
            return makeToolbarItem(for: .general)
        case ToolbarID.shortcuts:
            return makeToolbarItem(for: .shortcuts)
        default:
            return nil
        }
    }

    private func makeToolbarItem(for tab: SettingsTab) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.identifier(for: tab))
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.icon, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(selectToolbarTab(_:))
        return item
    }

    @objc private func selectToolbarTab(_ sender: NSToolbarItem) {
        tabModel.selectedTab = Self.tab(for: sender.itemIdentifier)
    }

    private static func tab(for identifier: NSToolbarItem.Identifier) -> SettingsTab {
        switch identifier {
        case ToolbarID.provider: return .general
        case ToolbarID.shortcuts: return .shortcuts
        default: return .general
        }
    }

    private static func identifier(for tab: SettingsTab) -> NSToolbarItem.Identifier {
        switch tab {
        case .general: return ToolbarID.provider
        case .shortcuts: return ToolbarID.shortcuts
        }
    }
}
